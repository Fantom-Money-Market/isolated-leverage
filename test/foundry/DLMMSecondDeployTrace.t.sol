// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./DLMMRebalanceCycle.t.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Logs the second deployIdle trace (no leverage) to compare burn proceeds vs remint.
contract DLMMSecondDeployTraceTest is DLMMRebalanceCycleTest {
    function test_traceSecondDeployIdle() public {
        emit log_named_uint("wS idle before 2nd deploy", IERC20(wS).balanceOf(address(vault)));
        emit log_named_uint("USSD idle before 2nd deploy", IERC20(USSD).balanceOf(address(vault)));
        factory.deployIdleVault(address(vault));
    }
}
