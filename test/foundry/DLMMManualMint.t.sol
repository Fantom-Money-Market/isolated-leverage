// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./DLMMRebalanceCycle.t.sol";
import "../../contracts/Stratus-ALM/interfaces/ILBPair.sol";
import "../../contracts/Stratus-ALM/libraries/LiquidityBookMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DLMMManualMintTest is DLMMRebalanceCycleTest {
    function test_balancesAfterManualBurn() public {
        uint24 active = ILBPair(PAIR).getActiveId();
        uint24 target = active + 1;

        uint24[] memory binIds = vault.getBinIds();
        uint256 n = binIds.length;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            uint256 bal = ILBPair(PAIR).balanceOf(address(vault), binIds[i]);
            if (bal > 0) {
                ids[count] = binIds[i];
                amounts[count] = bal;
                count++;
            }
        }
        assembly {
            mstore(ids, count)
            mstore(amounts, count)
        }

        (uint128 resX0, uint128 resY0) = ILBPair(PAIR).getReserves();
        emit log_named_uint("before burn balX", IERC20(wS).balanceOf(PAIR));
        emit log_named_uint("before burn balY", IERC20(USSD).balanceOf(PAIR));
        emit log_named_uint("before burn resX", resX0);
        emit log_named_uint("before burn resY", resY0);

        vm.prank(address(vault));
        ILBPair(PAIR).burn(address(vault), address(vault), ids, amounts);

        (uint128 resX1, uint128 resY1) = ILBPair(PAIR).getReserves();
        uint256 balX = IERC20(wS).balanceOf(PAIR);
        uint256 balY = IERC20(USSD).balanceOf(PAIR);
        emit log_named_uint("after burn vault wS", IERC20(wS).balanceOf(address(vault)));
        emit log_named_uint("after burn vault USSD", IERC20(USSD).balanceOf(address(vault)));
        emit log_named_uint("after burn balX", balX);
        emit log_named_uint("after burn balY", balY);
        emit log_named_uint("after burn resX", resX1);
        emit log_named_uint("after burn resY", resY1);
        emit log_named_uint("balX >= resX", balX >= resX1 ? 1 : 0);
        emit log_named_uint("balY >= resY", balY >= resY1 ? 1 : 0);

        (uint128 rx, uint128 ry) = ILBPair(PAIR).getBin(target);
        emit log_named_uint("target bin rx", rx);
        emit log_named_uint("target bin ry", ry);
        emit log_named_uint("target supply", ILBPair(PAIR).totalSupply(target));

        // mimic first X-side mint: 133 wS to bin target
        uint256 amount = 133333333333333333329;
        bytes32[] memory cfg = new bytes32[](1);
        cfg[0] = LiquidityBookMath.encodeLiquidityConfig(uint64(1e18), 0, target);

        vm.startPrank(address(vault));
        IERC20(wS).transfer(PAIR, amount);
        emit log_named_uint("after xfer balX", IERC20(wS).balanceOf(PAIR));
        emit log_named_uint("after xfer balY", IERC20(USSD).balanceOf(PAIR));
        ILBPair(PAIR).mint(address(vault), cfg, address(vault));
        vm.stopPrank();
    }
}
