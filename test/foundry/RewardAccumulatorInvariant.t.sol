// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "./harness/RewardVaultHarness.sol";
import "./handlers/RewardHandler.sol";
import "../../contracts/Stratus-ALM/test/MockERC20.sol";

/// @notice Invariant suite for the reward-per-share accumulator (StratusVaultBase) — the
///         live-incident bug class: a permissionless harvest landing while real totalSupply
///         was tiny inflated rewardPerShareStored by an unbounded factor, which fed a raw
///         (overflow-unsafe) multiplication in _settleRewards on every transfer/deposit/
///         withdraw, risking a permanently-reverting (fund-locking) holder.
///
///         Two invariants are checked across long random deposit/withdraw/transfer/harvest/
///         claim sequences (RewardHandler):
///           1. No handler call ever reverts unexpectedly (enforced by foundry.toml's
///              invariant.fail_on_revert = true — any revert not explicitly handled by the
///              handler's own bounding fails the run).
///           2. Reward conservation: nothing is ever claimable/claimed beyond what was
///              actually harvested (rounding can only lose dust, never manufacture value).
///
///   forge test --match-contract RewardAccumulatorInvariantTest -vv
contract RewardAccumulatorInvariantTest is Test {
    RewardVaultHarness harness;
    RewardHandler handler;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 rewardToken;

    function setUp() public {
        MockERC20 a = new MockERC20("Token A", "A");
        MockERC20 b = new MockERC20("Token B", "B");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        rewardToken = new MockERC20("Reward", "RWD");

        harness = new RewardVaultHarness(address(this), address(token0), address(token1));
        address[] memory rts = new address[](1);
        rts[0] = address(rewardToken);
        harness.setRewardTokens(rts); // address(this) == factory, so onlyFactory passes

        handler = new RewardHandler(harness, token0, token1, rewardToken);

        targetContract(address(handler));
    }

    /// @dev sum(pendingReward) + already-claimed <= total ever harvested, for every actor.
    function invariant_rewardConservation() public view {
        uint256 outstanding = 0;
        address[4] memory actors = handler.actorsList();
        for (uint256 i = 0; i < actors.length; i++) {
            outstanding += harness.pendingReward(actors[i], address(rewardToken));
        }
        assertLe(
            outstanding + handler.totalClaimed(),
            handler.totalHarvested(),
            "reward accumulator manufactured value out of thin air"
        );
    }
}
