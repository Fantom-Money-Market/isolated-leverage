// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./DLMMRebalanceCycle.t.sol";
import "../../contracts/Stratus-ALM/interfaces/ILBPair.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DLMMBurnStyleTest is DLMMRebalanceCycleTest {
    function test_burnOneAtATime_thenMint() public {
        uint24[] memory binIds = vault.getBinIds();
        uint256 n = binIds.length;

        for (uint256 i = 0; i < n; i++) {
            uint256 bal = ILBPair(PAIR).balanceOf(address(vault), binIds[i]);
            if (bal == 0) continue;
            uint256[] memory ids = new uint256[](1);
            uint256[] memory amounts = new uint256[](1);
            ids[0] = binIds[i];
            amounts[0] = bal;
            vm.prank(address(vault));
            ILBPair(PAIR).burn(address(vault), address(vault), ids, amounts);
        }

        (uint128 resX, uint128 resY) = ILBPair(PAIR).getReserves();
        uint256 balX = IERC20(wS).balanceOf(PAIR);
        uint256 balY = IERC20(USSD).balanceOf(PAIR);
        emit log_named_uint("balX >= resX", balX >= resX ? 1 : 0);
        emit log_named_uint("balY >= resY", balY >= resY ? 1 : 0);
        emit log_named_uint("surplusX", balX > resX ? balX - resX : 0);
        emit log_named_uint("deficitY", resY > balY ? resY - balY : 0);

        factory.deployIdleVault(address(vault));
    }

    function test_burnBatch_thenMint() public {
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
        vm.prank(address(vault));
        ILBPair(PAIR).burn(address(vault), address(vault), ids, amounts);

        (uint128 resX, uint128 resY) = ILBPair(PAIR).getReserves();
        emit log_named_uint("batch surplusX", IERC20(wS).balanceOf(PAIR) > resX ? IERC20(wS).balanceOf(PAIR) - resX : 0);
        emit log_named_uint("batch deficitY", resY > IERC20(USSD).balanceOf(PAIR) ? resY - IERC20(USSD).balanceOf(PAIR) : 0);

        factory.deployIdleVault(address(vault));
    }
}
