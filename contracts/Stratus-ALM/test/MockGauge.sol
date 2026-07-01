// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./MockERC20.sol";

/// @notice Test-only stand-in for IShadowGaugeV3: pays a fixed, known amount of a mintable
///         reward token on every getReward call, so reward-harvest tests are deterministic
///         and don't depend on live emission timing/amounts.
contract MockGauge {
    MockERC20 public immutable rewardToken;
    uint256 public rewardPerCall;

    constructor(address _rewardToken, uint256 _rewardPerCall) {
        rewardToken = MockERC20(_rewardToken);
        rewardPerCall = _rewardPerCall;
    }

    function setRewardPerCall(uint256 amount) external {
        rewardPerCall = amount;
    }

    /// @dev Matches IShadowGaugeV3.getReward's selector; args beyond `tokens`/`receiver` are
    ///      unused by this stub since it always pays the same flat amount per call.
    function getReward(
        address,
        uint256,
        int24,
        int24,
        address[] memory tokens,
        address receiver
    ) external {
        if (rewardPerCall == 0) return;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(rewardToken)) {
                rewardToken.mint(receiver, rewardPerCall);
            }
        }
    }
}
