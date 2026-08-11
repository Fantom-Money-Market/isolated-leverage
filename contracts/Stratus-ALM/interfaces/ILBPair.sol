// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILBPair
/// @notice Minimal Metropolis Liquidity Book DLMM pair interface (ERC1155-per-bin).
/// @dev mint/burn amounts are packed bytes32 (X low 128, Y high 128) — see
///      LiquidityBookMath.decodeAmounts.
interface ILBPair {
    function getTokenX() external view returns (address);
    function getTokenY() external view returns (address);
    function getBinStep() external view returns (uint16);
    function getActiveId() external view returns (uint24);
    function getBin(uint24 id) external view returns (uint128 binReserveX, uint128 binReserveY);
    function getReserves() external view returns (uint128 reserveX, uint128 reserveY);
    /// @notice Protocol fees still sitting in the pair balance but excluded from getReserves().
    ///         mint() computes received = balance - (_reserves), where _reserves includes these.
    function getProtocolFees() external view returns (uint128 protocolFeeX, uint128 protocolFeeY);
    function totalSupply(uint256 id) external view returns (uint256);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory);

    /// @notice The hooks attached to this pair, packed (lower 160 bits = hook address,
    ///         address(0) if none). See LiquidityBookMath.getHooksAddress.
    function getLBHooksParameters() external view returns (bytes32);

    /// @notice Built-in TWAP oracle (LB v2.1+). `size`/`activeSize` are ring-buffer sample
    ///         counts — a freshly-created or low-activity pair may have activeSize == 0.
    function getOracleParameters()
        external
        view
        returns (uint8 sampleLifetime, uint16 size, uint16 activeSize, uint40 lastUpdated, uint40 firstTimestamp);

    function getOracleSampleAt(uint40 lookupTimestamp)
        external
        view
        returns (uint64 cumulativeId, uint64 cumulativeVolatility, uint64 cumulativeBinCrossed);

    /// @notice Activate (when never used) and/or grow the pair's oracle ring buffer.
    ///         Permissionless. Reverts if `newLength` is not larger than the current size.
    function increaseOracleLength(uint16 newLength) external;

    /// @notice Add liquidity across the bins encoded in `liquidityConfigs`. Caller must
    ///         have already transferred tokenX/tokenY to this pair (no pull/callback —
    ///         unlike Uniswap V3, LB expects payment up front).
    function mint(address to, bytes32[] calldata liquidityConfigs, address refundTo)
        external
        returns (bytes32 amountsReceived, bytes32 amountsLeft, uint256[] memory liquidityMinted);

    /// @notice Burn ERC1155 bin shares, paying out the underlying to `to`.
    function burn(address from, address to, uint256[] calldata ids, uint256[] calldata amountsToBurn)
        external
        returns (bytes32[] memory amounts);

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount) external;
    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts)
        external;
}

/// @title ILBFactory
/// @notice Minimal Metropolis LBFactory interface — resolves a pair address from a
///         token pair + binStep.
interface ILBFactory {
    struct LBPairInformation {
        uint16 binStep;
        address LBPair;
        bool createdByOwner;
        bool ignoredForRouting;
    }

    function getAllLBPairs(address tokenX, address tokenY)
        external
        view
        returns (LBPairInformation[] memory lbPairsAvailable);
}

/// @title ILBHooksRewarder
/// @notice Metropolis per-pair reward hook: METRO emissions for liquidity inside an
///         owner-configurable bin window. Only bins in getRewardedRange() earn METRO.
interface ILBHooksRewarder {
    function getRewardToken() external view returns (address);
    function getRewardedRange() external view returns (uint256 binStart, uint256 binEnd);
    function getPendingRewards(address user, uint256[] calldata ids) external view returns (uint256);
    function isStopped() external view returns (bool);

    /// @notice Claim accrued METRO for `user`'s balance in `ids`. Permissionless caller
    ///         (pays out to `user`, not necessarily msg.sender).
    function claim(address user, uint256[] calldata ids) external;
}
