// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Throwaway helper for local fork testing only: executes a real swap against a
///      Uniswap-V3-style pool (Shadow) so the pool's own period/tick checkpoints actually
///      advance — evm_increaseTime alone doesn't trigger that, only a real pool interaction
///      does. Not part of the protocol; nothing references this outside test/fork tooling.
contract PoolSwapHelper {
    function doSwap(address pool, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) external {
        (bool ok, bytes memory ret) = pool.call(
            abi.encodeWithSignature(
                "swap(address,bool,int256,uint160,bytes)",
                address(this),
                zeroForOne,
                amountSpecified,
                sqrtPriceLimitX96,
                ""
            )
        );
        require(ok, string(ret));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) IERC20(_token0()).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(_token1()).transfer(msg.sender, uint256(amount1Delta));
    }

    address public token0;
    address public token1;

    function setTokens(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    function _token0() internal view returns (address) { return token0; }
    function _token1() internal view returns (address) { return token1; }
}
