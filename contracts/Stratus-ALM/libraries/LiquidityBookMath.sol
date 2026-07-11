// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LiquidityBookMath
/// @notice Minimal bin-id/price conversion and mint-config packing for Trader Joe /
///         Metropolis Liquidity Book (DLMM) pairs, matching the fixed-point conventions
///         (1e18 "price0in1") already used by UniswapV3PriceHelper/TickMath elsewhere in
///         this codebase, rather than LB's native Q128.128 internal representation.
/// @dev Bin price is geometric: price(id) = (1 + binStep/10000) ^ (id - REAL_ID_SHIFT),
///      where price is tokenY per tokenX (i.e. token1 in token0 terms, matching
///      "price0in1" as long as the vault treats tokenX as token0 and tokenY as token1).
library LiquidityBookMath {
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant BASIS_POINTS = 10000;
    /// @dev LB's bin-id origin: id == REAL_ID_SHIFT is the bin priced at exactly 1:1.
    uint256 internal constant REAL_ID_SHIFT = 1 << 23; // 8_388_608

    error PriceOverflow();

    /// @notice Price of one tokenX in tokenY (1e18 fixed point) at bin `id`.
    function getPriceFromId(uint24 id, uint16 binStep) internal pure returns (uint256 price) {
        int256 realId = int256(uint256(id)) - int256(REAL_ID_SHIFT);
        uint256 base = PRECISION + Math.mulDiv(uint256(binStep), PRECISION, BASIS_POINTS);
        price = _pow(base, realId);
    }

    /// @dev Fixed-point (1e18) exponentiation by squaring; `exp` may be negative (1/base^|exp|).
    ///      Bin ids fit in uint24 (max ~16.7M), so |exp| is small enough that this never
    ///      realistically overflows through the intermediate squarings for any sane binStep.
    function _pow(uint256 base1e18, int256 exp) internal pure returns (uint256 result) {
        bool inverse = exp < 0;
        uint256 e = inverse ? uint256(-exp) : uint256(exp);
        result = PRECISION;
        uint256 b = base1e18;
        while (e > 0) {
            if (e & 1 == 1) result = Math.mulDiv(result, b, PRECISION);
            if (e > 1) b = Math.mulDiv(b, b, PRECISION);
            e >>= 1;
        }
        if (inverse) {
            if (result == 0) revert PriceOverflow();
            result = Math.mulDiv(PRECISION, PRECISION, result);
        }
    }

    /// @notice Pack one bin's liquidity-mint config: `distributionX`/`distributionY` are
    ///         1e18-scale fractions of the deposit each bin receives (LB's own convention,
    ///         independent of this codebase's PRECISION reuse above), `id` the target bin.
    /// @dev Layout matches Metropolis' LiquidityConfigurations.encodeParams (verified
    ///      against the real source, joe-v2/src/libraries/math/LiquidityConfigurations.sol):
    ///      id in bits [0,24), distributionY in bits [24,88), distributionX in bits [88,152).
    ///      An earlier version of this function had id at bit 128 — wrong, and the reason
    ///      every mint() attempt reverted with PackedUint128Math__SubUnderflow regardless of
    ///      distribution shape (the pair was decoding garbage bin ids from the misaligned
    ///      packing, not the ids this contract intended).
    function encodeLiquidityConfig(uint64 distributionX, uint64 distributionY, uint24 id)
        internal
        pure
        returns (bytes32 config)
    {
        config = bytes32((uint256(distributionX) << 88) | (uint256(distributionY) << 24) | uint256(id));
    }

    function decodeDistributionX(bytes32 config) internal pure returns (uint64 distributionX) {
        distributionX = uint64(uint256(config) >> 88);
    }

    function decodeDistributionY(bytes32 config) internal pure returns (uint64 distributionY) {
        distributionY = uint64((uint256(config) >> 24) & type(uint64).max);
    }

    function decodeBinId(bytes32 config) internal pure returns (uint24 id) {
        id = uint24(uint256(config));
    }

    /// @notice Decode the packed `bytes32 amounts` LB uses for (amountX, amountY) pairs
    ///         (mint/burn/getBin results): X in the low 128 bits, Y in the high 128 bits.
    function decodeAmounts(bytes32 packed) internal pure returns (uint256 x, uint256 y) {
        x = uint256(packed) & type(uint128).max;
        y = uint256(packed) >> 128;
    }

    /// @notice Extract the hooks contract address from a pair's packed hooksParameters
    ///         (`ILBPair.getLBHooksParameters()`); address(0) if no hook is attached.
    function getHooksAddress(bytes32 hooksParameters) internal pure returns (address hooks) {
        hooks = address(uint160(uint256(hooksParameters)));
    }
}
