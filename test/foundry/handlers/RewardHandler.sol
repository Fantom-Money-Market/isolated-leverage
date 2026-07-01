// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../harness/RewardVaultHarness.sol";
import "../../../contracts/Stratus-ALM/test/MockERC20.sol";

/// @notice Invariant-fuzzing handler: drives random deposit/withdraw/transfer/claim/harvest
///         sequences against RewardVaultHarness. Harvest amounts are deliberately allowed to
///         range up to extreme values (this is exactly what blew up the live accumulator) —
///         every OTHER action is bounded to its own valid domain so the only reverts that can
///         happen are genuine bugs, not handler misuse.
contract RewardHandler is Test {
    RewardVaultHarness public harness;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public rewardToken;

    uint256 constant N_ACTORS = 4;
    address[N_ACTORS] public actors;

    uint256 public totalHarvested;
    uint256 public totalClaimed;

    constructor(RewardVaultHarness _harness, MockERC20 _token0, MockERC20 _token1, MockERC20 _rewardToken) {
        harness = _harness;
        token0 = _token0;
        token1 = _token1;
        rewardToken = _rewardToken;
        for (uint256 i = 0; i < N_ACTORS; i++) {
            actors[i] = address(uint160(0x1000 + i));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % N_ACTORS];
    }

    function deposit(uint256 actorSeed, uint96 amt0, uint96 amt1) external {
        address actor = _actor(actorSeed);
        amt0 = uint96(bound(amt0, 1, 1e24));
        amt1 = uint96(bound(amt1, 1, 1e24));

        token0.mint(actor, amt0);
        token1.mint(actor, amt1);

        vm.startPrank(actor);
        token0.approve(address(harness), amt0);
        token1.approve(address(harness), amt1);
        harness.deposit(amt0, amt1, actor, 0);
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 fraction) external {
        address actor = _actor(actorSeed);
        uint256 bal = harness.balanceOf(actor);
        if (bal == 0) return;
        uint256 shares = bound(fraction, 1, bal);

        vm.prank(actor);
        harness.withdraw(shares, actor, 0, 0);
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 fraction) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = harness.balanceOf(from);
        if (bal == 0) return;
        uint256 amt = bound(fraction, 1, bal);

        vm.prank(from);
        harness.transfer(to, amt);
    }

    /// @dev Deliberately wide range — this is the exact lever that blew up the live
    ///      accumulator (an ordinary-sized harvest landing while real supply was tiny).
    function harvest(uint128 net) external {
        uint256 amount = bound(net, 0, 1e50);
        harness.harvest(address(rewardToken), amount);
        totalHarvested += amount;
    }

    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 before = rewardToken.balanceOf(actor);
        vm.prank(actor);
        harness.claimRewards();
        totalClaimed += rewardToken.balanceOf(actor) - before;
    }

    function actorsList() external view returns (address[N_ACTORS] memory) {
        return actors;
    }
}
