// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./base/StratusCLVaultBase.sol";
import "./interfaces/IShadowV3Pool.sol";

/// @title StratusShadowVault
/// @notice Fungible ERC20 (ALPT) wrapper around a Shadow (Ramses V3 fork) CL position.
///         All share accounting, valuation, rebalancing and reward distribution live in
///         StratusCLVaultBase / StratusVaultBase; this adapter supplies only the
///         Shadow-specific pool ops (which thread a `uint256 index`) and the SHADOW
///         gauge-emission harvest (direct getReward, no NFT).
/// @dev Positions are identified by keccak256(abi.encodePacked(vault, INDEX, tickLower, tickUpper));
///      liquidity is always read live from the pool, never cached.
contract StratusShadowVault is StratusCLVaultBase {
    using SafeERC20 for IERC20;

    uint256 private constant INDEX = 0; // single position per tick-range

    /// @notice Gauge, set by the factory after creation (0 = plain fee-collecting pool).
    IShadowGaugeV3 public gauge;

    event GaugeRewardsCollected(address[] tokens, uint256[] netAmounts);
    event GaugeSet(address indexed gauge);

    constructor(
        address _factory,
        address _pool,
        uint256 _upwardBias,
        uint8 _protocolFee,
        string memory _name,
        string memory _symbol
    ) StratusCLVaultBase(_factory, _pool, _upwardBias, _protocolFee, _name, _symbol) {}

    // ===================== FORK OPS (Shadow threads INDEX) =====================

    function _clPosition(int24 tickLower, int24 tickUpper)
        internal
        view
        override
        returns (uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1)
    {
        bytes32 key = keccak256(abi.encodePacked(address(this), INDEX, tickLower, tickUpper));
        (liquidity, , , tokensOwed0, tokensOwed1) = IShadowV3Pool(pool).positions(key);
    }

    function _clMint(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        override
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = IShadowV3Pool(pool).mint(address(this), INDEX, tickLower, tickUpper, liquidity, "");
    }

    function _clBurn(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        override
        returns (uint256 owed0, uint256 owed1)
    {
        (owed0, owed1) = IShadowV3Pool(pool).burn(INDEX, tickLower, tickUpper, liquidity);
    }

    function _clCollect(int24 tickLower, int24 tickUpper, address to, uint128 c0, uint128 c1)
        internal
        override
        returns (uint256 amount0, uint256 amount1)
    {
        (uint128 a0, uint128 a1) = IShadowV3Pool(pool).collect(to, INDEX, tickLower, tickUpper, c0, c1);
        amount0 = a0;
        amount1 = a1;
    }

    // ===================== GAUGE REWARDS (direct, no NFT) =====================

    /// @notice Set the gauge (factory only). Reward tokens are configured separately via
    ///         setRewardTokens (typically just SHADOW).
    function setGauge(address _gauge) external onlyFactory {
        if (_gauge == address(0)) revert BadInput();
        gauge = IShadowGaugeV3(_gauge);
        emit GaugeSet(_gauge);
    }

    /// @notice Claim the configured reward tokens (e.g. SHADOW) for all ranges via the
    ///         gauge's direct getReward path, skim the protocol cut, and distribute the
    ///         rest to holders through the reward-per-share accumulator. Permissionless.
    function collectGaugeRewards()
        public
        nonReentrant
        returns (address[] memory tokens, uint256[] memory netAmounts)
    {
        (tokens, netAmounts, ) = _harvest(address(0), 0);
        emit GaugeRewardsCollected(tokens, netAmounts);
    }

    /// @inheritdoc StratusCLVaultBase
    /// @dev Pay the swap-rebalance bounty as a REWARD_BOUNTY_BPS cut of freshly-harvested gauge
    ///      emissions — so the bounty is funded by yield, not principal (no slow bleed). Returns
    ///      true iff something was actually paid (i.e. there were rewards to harvest).
    function _payRebalanceBounty(address to) internal override returns (bool paid) {
        (, , paid) = _harvest(to, rewardBountyBps);
    }

    /// @dev Claim the configured reward tokens for all ranges; optionally skim a `cutBps`
    ///      cut to `bountyTo`; take the protocol fee; distribute the remainder to holders via
    ///      the accumulator. Shared by collectGaugeRewards (no bounty) and the rebalance bounty.
    /// @dev `cutBps` is named distinctly from the base contract's `bountyBps` state variable
    ///      (the rebalanceViaSwap fallback bounty) — they're different bounty legs entirely,
    ///      and a same-named parameter here would shadow it and confuse the two.
    function _harvest(address bountyTo, uint256 cutBps)
        internal
        returns (address[] memory tokens, uint256[] memory netAmounts, bool paidBounty)
    {
        if (address(gauge) == address(0) || rewardTokens.length == 0) {
            return (new address[](0), new uint256[](0), false);
        }
        tokens = rewardTokens; // configured subset (e.g. just SHADOW), not all of getRewardTokens()

        uint256[] memory balBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
        }

        // Direct claim: msg.sender (this vault) is the position owner.
        for (uint256 r = 0; r < N_RANGES; r++) {
            gauge.getReward(address(this), INDEX, rangeLower[r], rangeUpper[r], tokens, address(this));
        }

        netAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 received = IERC20(tokens[i]).balanceOf(address(this)) - balBefore[i];
            if (received == 0) continue;
            uint256 bounty = cutBps == 0 ? 0 : (received * cutBps) / BASIS_POINTS;
            if (bounty > 0) {
                IERC20(tokens[i]).safeTransfer(bountyTo, bounty);
                paidBounty = true;
            }
            uint256 rest = received - bounty;
            uint256 fee = (rest * protocolFee) / 100;
            if (fee > 0) IERC20(tokens[i]).safeTransfer(factory, fee);
            uint256 net = rest - fee;
            netAmounts[i] = net;
            _distributeReward(tokens[i], net);
        }
    }
}
