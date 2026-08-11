// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StratusVaultBase
/// @notice Venue-agnostic core of a Stratus ALPT vault: the fungible ERC20 wrapper,
///         the ERC4626 virtual-shares accounting, deposit/withdraw orchestration, the
///         manipulation-resistant valuation surface, and the reward-per-share
///         accumulator. Everything here is identical regardless of the underlying
///         venue (Shadow CL, Thick CL, Balancer weighted) — the venue is plugged in
///         through a small set of abstract hooks.
/// @dev The whole point of Stratus is that ALPT prices and behaves IDENTICALLY across
///      venues so money-legos (lending, leverage, Tarot) work the same on any of them.
///      That guarantee is enforced structurally: every venue adapter inherits this base,
///      so the external surface (deposit / withdraw / pricePerShareSafe / convertTo…)
///      cannot drift between venues.
abstract contract StratusVaultBase is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ----- immutables -----
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    address public immutable factory;
    uint8 internal immutable _shareDecimals; // token1 decimals + DECIMALS_OFFSET

    // ----- config -----
    uint8 public protocolFee;  // percent (0-30) of realized fees/rewards to factory
    uint256 public upwardBias; // 100 = symmetric ranges; <100 wider below, >100 wider above

    // ----- constants -----
    // Virtual shares/assets — OpenZeppelin ERC4626's inflation-attack defense. The share
    // math behaves as if the vault always holds VIRTUAL_SHARES extra shares backed by
    // VIRTUAL_ASSETS, so a donation attack costs ~VIRTUAL_SHARES x a victim's deposit.
    // DECIMALS_OFFSET also sets the ALPT scale (decimals = token1 decimals + offset), so
    // one whole ALPT is ~one whole token1 of value.
    uint8 internal constant DECIMALS_OFFSET = 6;
    uint256 internal constant VIRTUAL_SHARES = 10 ** DECIMALS_OFFSET; // 1e6
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint32 internal constant TWAP_PERIOD = 30 minutes;
    uint256 internal constant BASIS_POINTS = 10000;
    uint256 internal constant PRECISION = 1e18;     // price scale (matches UniswapV3PriceHelper)
    uint256 internal constant ACC_PRECISION = 1e18; // reward-per-share scale

    // ----- reward distribution (accumulator) -----
    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address => uint256) public rewardPerShareStored;
    mapping(address => mapping(address => uint256)) public userRewardPerSharePaid;
    mapping(address => mapping(address => uint256)) public rewardsAccrued;

    // ----- events -----
    event Deposit(address indexed sender, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed sender, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event RewardTokensSet(address[] tokens);
    event ProtocolFeeUpdated(uint8 newFee);

    constructor(
        address _factory,
        address _token0,
        address _token1,
        uint256 _upwardBias,
        uint8 _protocolFee,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        if (_factory == address(0) || _protocolFee > 30 || _upwardBias < 50 || _upwardBias > 200) revert BadInput();

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        factory = _factory;
        upwardBias = _upwardBias;
        protocolFee = _protocolFee;
        // ALPT decimals = token1 (numeraire) decimals + offset, so 1 ALPT ~ 1 token1 value.
        _shareDecimals = IERC20Metadata(_token1).decimals() + DECIMALS_OFFSET;
    }

    // Compact custom errors (smaller bytecode than require-strings; shared with derived vaults).
    error Unauthorized();
    error BadInput();
    error Slippage();
    error VaultPaused();

    /// @notice Emergency stop. Halts new deposits and rebalancing; withdraw/claimRewards stay
    ///         open on purpose — a panic must never be able to trap user funds.
    bool public paused;
    event EmergencyPause(bool paused);

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    /// @notice Trip the emergency stop: blocks deposit() and rebalance()/rebalanceViaSwap()
    ///         until resume() is called. Withdrawals and reward claims are never paused.
    function panicAtTheDisco() external onlyFactory {
        paused = true;
        emit EmergencyPause(true);
    }

    /// @notice Lift the emergency stop.
    function resume() external onlyFactory {
        paused = false;
        emit EmergencyPause(false);
    }

    /// @notice ALPT decimals = token1 decimals + DECIMALS_OFFSET.
    function decimals() public view override returns (uint8) {
        return _shareDecimals;
    }

    // ===================== VENUE HOOKS (implemented by adapters) =====================

    /// @notice Manipulation-resistant valuation in ONE shot: the vault's holdings
    ///         (token0, token1) evaluated at a manipulation-resistant price, plus that
    ///         price (token0 denominated in token1, 1e18). CL adapters use a TWAP; the
    ///         Balancer adapter uses a rate provider / oracle. Returning all three from
    ///         one call lets CL adapters do a single observe().
    function _safeValuation() internal view virtual returns (uint256 total0, uint256 total1, uint256 priceX1e18);

    /// @notice Holdings at the CURRENT (spot/manipulable) price — UI/reference only.
    function _totalAmountsSpot() internal view virtual returns (uint256 total0, uint256 total1);

    /// @notice Spot price of token0 in token1 (1e18). UI/reference only.
    function _spotPrice() internal view virtual returns (uint256);

    /// @notice Realize accrued fees (and skim the protocol cut) into idle balance.
    ///         Called before any share-price-sensitive action.
    function _realizeFees() internal virtual;

    /// @notice Pull `shares`/`totalWithVirtual` of the venue positions and send the
    ///         underlying directly to `to`. Idle balances are swept separately by the base.
    function _withdrawPositions(uint256 shares, uint256 totalWithVirtual, address to)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1);

    /// @notice Re-center ranges around the current tick and deploy whatever's already idle.
    ///         Venue-specific; factory-gated. No swap — a genuine one-sided imbalance stays
    ///         idle. The permissionless, swap-funded rebalanceViaSwap() (CL vaults) is the
    ///         main way a vault actually gets fully balanced; this is just the recenter step.
    function deployIdle() external virtual;

    // ===================== DEPOSIT / WITHDRAW =====================

    /// @dev ERC4626 virtual-shares math for one (totals, price) basis. First deposit and
    ///      inflation are handled uniformly — no special-casing, no MINIMUM_LIQUIDITY mint.
    function _sharesFor(
        uint256 deposit0,
        uint256 deposit1,
        uint256 total0,
        uint256 total1,
        uint256 price
    ) internal view returns (uint256) {
        uint256 depositValue1 = deposit1 + Math.mulDiv(deposit0, price, PRECISION);
        uint256 totalValue1 = total1 + Math.mulDiv(total0, price, PRECISION);
        return Math.mulDiv(depositValue1, totalSupply() + VIRTUAL_SHARES, totalValue1 + VIRTUAL_ASSETS);
    }

    /// @notice Deposit token0/token1, receive ALPT shares. Tokens sit as idle balance
    ///         until the next rebalance deploys them (Gamma model).
    function deposit(uint256 deposit0, uint256 deposit1, address to, uint256 minShares)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (deposit0 == 0 && deposit1 == 0) revert BadInput();
        if (to == address(0) || to == address(this)) revert BadInput();

        _realizeFees();

        // Withdraw pays a pro-rata slice of the live basket; entry must not mint more shares
        // than that basket backs when safe and spot diverge. Price the deposit both ways and
        // mint the lesser — conservative for any mix / either direction of divergence.
        // Manipulating spot can only reduce the attacker's own shares; honest depositors use minShares.
        (uint256 pt0, uint256 pt1) = _totalAmountsSpot();
        uint256 sharesSpot = _sharesFor(deposit0, deposit1, pt0, pt1, _spotPrice());

        if (totalSupply() == 0) {
            // Bootstrap: no existing holders to protect, and some venues (DLMM) cannot serve
            // a safe price until the oracle has history. Spot-only minting is fine here.
            shares = sharesSpot;
        } else {
            (uint256 st0, uint256 st1, uint256 safePrice) = _safeValuation();
            uint256 sharesSafe = _sharesFor(deposit0, deposit1, st0, st1, safePrice);
            shares = sharesSafe < sharesSpot ? sharesSafe : sharesSpot;
        }
        if (shares == 0 || shares < minShares) revert Slippage();

        if (deposit0 > 0) token0.safeTransferFrom(msg.sender, address(this), deposit0);
        if (deposit1 > 0) token1.safeTransferFrom(msg.sender, address(this), deposit1);

        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, deposit0, deposit1);
    }

    /// @notice Burn shares and receive the proportional underlying (positions + idle).
    function withdraw(uint256 shares, address to, uint256 minAmount0, uint256 minAmount1)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0 || shares > balanceOf(msg.sender)) revert BadInput();
        if (to == address(0)) revert BadInput();

        _realizeFees();

        // Redeem against the virtual-share-inclusive supply (ERC4626): the VIRTUAL_SHARES
        // fraction is never redeemable, which is the inflation buffer.
        uint256 total = totalSupply() + VIRTUAL_SHARES; // pre-burn

        (amount0, amount1) = _withdrawPositions(shares, total, to);

        // Proportional idle balances (includes net fees realized in _realizeFees).
        uint256 unused0 = Math.mulDiv(token0.balanceOf(address(this)), shares, total);
        uint256 unused1 = Math.mulDiv(token1.balanceOf(address(this)), shares, total);
        if (unused0 > 0) token0.safeTransfer(to, unused0);
        if (unused1 > 0) token1.safeTransfer(to, unused1);
        amount0 += unused0;
        amount1 += unused1;

        if (amount0 < minAmount0 || amount1 < minAmount1) revert Slippage();

        _burn(msg.sender, shares);
        emit Withdraw(msg.sender, to, shares, amount0, amount1);
    }

    // ===================== VALUATION SURFACE (composable, venue-uniform) =====================

    /// @notice Holdings at the CURRENT (spot) price. For UI/internal use.
    function getTotalAmounts() public view returns (uint256 total0, uint256 total1) {
        return _totalAmountsSpot();
    }

    /// @notice Manipulation-resistant holdings: the split is evaluated at the safe price,
    ///         not spot. THIS is the value legos should price against.
    function getTotalAmountsSafe() public view returns (uint256 total0, uint256 total1) {
        (total0, total1, ) = _safeValuation();
    }

    /// @notice Safe price of token0 denominated in token1 (1e18). Basis for the value
    ///         functions below; manipulation-resistant.
    function twapPrice() public view returns (uint256 price) {
        (, , price) = _safeValuation();
    }

    /// @notice Total vault value in token1, at the safe price. Manipulation-resistant.
    function getTotalValueSafe() public view returns (uint256 value) {
        (uint256 t0, uint256 t1, uint256 price) = _safeValuation();
        value = t1 + Math.mulDiv(t0, price, PRECISION);
    }

    /// @notice Total vault value in token1 at the current (spot) price. UI/reference only —
    ///         manipulable; NEVER use for collateral pricing. Use getTotalValueSafe.
    function getTotalValue() public view returns (uint256 value) {
        (uint256 t0, uint256 t1) = _totalAmountsSpot();
        value = t1 + Math.mulDiv(t0, _spotPrice(), PRECISION);
    }

    /// @notice ERC4626-style: token1-denominated safe value of `shares` ALPT.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, getTotalValueSafe() + VIRTUAL_ASSETS, totalSupply() + VIRTUAL_SHARES);
    }

    /// @notice ERC4626-style: ALPT shares for `assets` of token1-denominated value (safe).
    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + VIRTUAL_SHARES, getTotalValueSafe() + VIRTUAL_ASSETS);
    }

    /// @notice Safe value of ONE whole ALPT in token1 base units — the composable,
    ///         manipulation-resistant price a lending market / oracle should use to value
    ///         ALPT as collateral. Consumers multiply by their token1 price.
    function pricePerShareSafe() external view returns (uint256) {
        return convertToAssets(10 ** _shareDecimals);
    }

    // ===================== REWARD ACCUMULATOR (MasterChef-style) =====================

    /// @notice Configure which reward tokens the vault distributes (factory only).
    /// @dev Adds (dedup); does not remove, so accrued balances stay claimable. Adapters
    ///      that earn no emissions (e.g. fee-only venues) simply never set any.
    function setRewardTokens(address[] calldata tokens) external onlyFactory {
        _registerRewardTokens(tokens);
        emit RewardTokensSet(tokens);
    }

    /// @notice The configured reward-token set.
    function rewardTokensList() external view returns (address[] memory) {
        return rewardTokens;
    }

    /// @notice Claim accrued rewards for the caller.
    function claimRewards() external nonReentrant {
        _settleRewards(msg.sender);
        uint256 len = rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = rewardTokens[i];
            uint256 amount = rewardsAccrued[token][msg.sender];
            if (amount > 0) {
                rewardsAccrued[token][msg.sender] = 0;
                IERC20(token).safeTransfer(msg.sender, amount);
                emit RewardClaimed(msg.sender, token, amount);
            }
        }
    }

    /// @notice Claimable reward for a holder/token, including not-yet-settled accrual.
    function pendingReward(address user, address token) external view returns (uint256) {
        uint256 unsettled = Math.mulDiv(
            balanceOf(user),
            rewardPerShareStored[token] - userRewardPerSharePaid[token][user],
            ACC_PRECISION
        );
        return rewardsAccrued[token][user] + unsettled;
    }

    /// @dev Credit `net` of `token` across current supply (caller already holds the tokens).
    ///      Denominator includes VIRTUAL_SHARES so a harvest at near-zero real supply cannot
    ///      inflate the accumulator unboundedly.
    function _distributeReward(address token, uint256 net) internal {
        if (!isRewardToken[token] || net == 0) return;
        rewardPerShareStored[token] += Math.mulDiv(net, ACC_PRECISION, totalSupply() + VIRTUAL_SHARES);
    }

    function _registerRewardTokens(address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (!isRewardToken[tokens[i]]) {
                isRewardToken[tokens[i]] = true;
                rewardTokens.push(tokens[i]);
            }
        }
    }

    function _settleRewards(address user) internal {
        if (user == address(0)) return;
        uint256 bal = balanceOf(user);
        uint256 len = rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = rewardTokens[i];
            uint256 acc = rewardPerShareStored[token];
            uint256 paid = userRewardPerSharePaid[token][user];
            if (acc != paid) {
                if (bal > 0) rewardsAccrued[token][user] += Math.mulDiv(bal, acc - paid, ACC_PRECISION);
                userRewardPerSharePaid[token][user] = acc;
            }
        }
    }

    /// @notice Settle rewards for both parties on every balance change (OZ v5 hook).
    function _update(address from, address to, uint256 value) internal override {
        _settleRewards(from);
        _settleRewards(to);
        super._update(from, to, value);
    }

    // ===================== ADMIN =====================

    function updateProtocolFee(uint8 newFee) external onlyFactory {
        if (newFee > 30) revert BadInput();
        protocolFee = newFee;
        emit ProtocolFeeUpdated(newFee);
    }
}
