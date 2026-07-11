// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./DLMMRebalanceCycle.t.sol";
import "../../contracts/Stratus-ALM/interfaces/ILBPair.sol";

contract DLMMDiagnoseTest is DLMMRebalanceCycleTest {
    function test_binStateBeforeSecondMint() public {
        uint24 active = ILBPair(PAIR).getActiveId();
        uint24 target = active + 1; // 8384920

        (uint128 rx0, uint128 ry0) = ILBPair(PAIR).getBin(target);
        uint256 sup0 = ILBPair(PAIR).totalSupply(target);
        uint256 bal0 = ILBPair(PAIR).balanceOf(address(vault), target);
        emit log_named_uint("active", active);
        emit log_named_uint("bin rx before 2nd", rx0);
        emit log_named_uint("bin ry before 2nd", ry0);
        emit log_named_uint("bin supply before 2nd", sup0);
        emit log_named_uint("vault bal before 2nd", bal0);

        (uint128 resX, uint128 resY) = ILBPair(PAIR).getReserves();
        emit log_named_uint("pair resX", resX);
        emit log_named_uint("pair resY", resY);

        vm.expectRevert();
        factory.deployIdleVault(address(vault));

        (uint128 rx1, uint128 ry1) = ILBPair(PAIR).getBin(target);
        emit log_named_uint("bin rx after fail", rx1);
        emit log_named_uint("bin ry after fail", ry1);
    }
}
