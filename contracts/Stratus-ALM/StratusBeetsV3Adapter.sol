// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IBeetsV3Vault.sol";
import "./interfaces/IBeetsGauge.sol";

/// @title StratusBeetsV3Adapter
/// @notice Makes a Beets/Balancer-v3 pool token (BPT) consumable by the Stratus/Tarot
///         lending layer, WITHOUT re-wrapping it in a full ALM vault. A Beets BPT is
///         already a fungible ERC20 — the only thing missing for money-legos is a
///         manipulation-resistant price. This is a 1:1 BPT wrapper that adds exactly that:
///         the standard Stratus safe-valuation surface (getTotalValueSafe / twapPrice /
///         pricePerShareSafe), sourced from Balancer-v3 rate providers.
/// @dev Manipulation resistance is structural, not TWAP-based: value = ownershipFraction ×
///      Σ(balancesRawᵢ × scalingFactorᵢ × rateᵢ), and the rates come from each token's
///      external rate provider (e.g. stS.getRate()), not the pool's spot ratio. A swap that
///      skews reserves conserves that sum, so there is no tick to push.
///
///      Wrapped BPT is auto-staked in the pool's Curve-style gauge (when configured) so
///      emissions accrue to adapter holders via the same MasterChef accumulator used by
///      CL vaults. Call collectGaugeRewards() to pull gauge emissions on-chain, then
///      claimRewards() to receive your share.
contract StratusBeetsV3Adapter is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The Beets/Balancer v3 Vault (singleton).
    IBeetsV3Vault public immutable vault;

    /// @notice The wrapped pool token (BPT). `pool()` returns this for IStratusALPT compat.
    address public immutable bpt;

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint8 private immutable _decimals;

    address public owner;
    address public gauge;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant ACC_PRECISION = 1e18;

    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address => uint256) public rewardPerShareStored;
    mapping(address => mapping(address => uint256)) public userRewardPerSharePaid;
    mapping(address => mapping(address => uint256)) public rewardsAccrued;

    event Wrapped(address indexed from, address indexed to, uint256 amount);
    event Unwrapped(address indexed from, address indexed to, uint256 amount);
    event Deposit(address indexed sender, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed sender, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event GaugeSet(address indexed gauge);
    event GaugeRewardsCollected(address[] tokens, uint256[] amounts);
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event RewardTokensSet(address[] tokens);

    /// @dev Set only for the duration of our own vault.unlock() round-trip. The unlock
    ///      hooks are external (the Vault invokes them by calldata), so without this an
    ///      attacker could call vault.unlock(encodedHook) themselves and have the Vault
    ///      call back into us with msg.sender == vault — passing a naive sender check.
    bool private _inVaultOp;

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(
        address _vault,
        address _bpt,
        address _gauge,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        require(_vault != address(0) && _bpt != address(0), "zero");
        vault = IBeetsV3Vault(_vault);
        bpt = _bpt;
        owner = msg.sender;

        IERC20[] memory tokens = IBeetsV3Vault(_vault).getPoolTokens(_bpt);
        require(tokens.length == 2, "only 2-token pools");
        token0 = tokens[0];
        token1 = tokens[1];

        _decimals = IERC20Metadata(_bpt).decimals();

        if (_gauge != address(0)) _setGauge(_gauge);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Wire the pool's Curve-style gauge and stake any idle BPT already held.
    function setGauge(address _gauge) external onlyOwner {
        _setGauge(_gauge);
    }

    /// @notice Configure reward tokens distributed to adapter holders (owner only).
    function setRewardTokens(address[] calldata tokens) external onlyOwner {
        _registerRewardTokens(tokens);
        emit RewardTokensSet(tokens);
    }

    function rewardTokensList() external view returns (address[] memory) {
        return rewardTokens;
    }

    // ===================== 1:1 WRAP / UNWRAP =====================

    /// @notice Wrap `amount` BPT (pulled from msg.sender), stake in the gauge if configured,
    ///         and mint the same amount of adapter tokens to `to`.
    function wrap(uint256 amount, address to) external nonReentrant returns (uint256) {
        require(amount > 0, "amount");
        require(to != address(0), "to");
        IERC20(bpt).safeTransferFrom(msg.sender, address(this), amount);
        _stakeBpt(amount);
        _mint(to, amount);
        emit Wrapped(msg.sender, to, amount);
        return amount;
    }

    /// @notice Burn adapter tokens and return the same amount of BPT to `to` (unstaked first).
    function unwrap(uint256 amount, address to) external nonReentrant returns (uint256) {
        require(amount > 0, "amount");
        require(to != address(0), "to");
        _burn(msg.sender, amount);
        _unstakeBpt(amount, to);
        emit Unwrapped(msg.sender, to, amount);
        return amount;
    }

    // ===================== RAW-TOKEN DEPOSIT / WITHDRAW =====================
    // Same signatures as the Stratus CL vaults, so the lending stack (supply flow,
    // LeverageRouter, UnwindRouter) treats a Beets market identically to a Shadow/Thick
    // one. Liquidity moves through the Balancer v3 Vault's transient-accounting unlock
    // callback — no dependency on Balancer's Router or Permit2.

    /// @notice Deposit raw token0/token1 (any mix, either may be 0), add liquidity to the
    ///         Beets pool, stake the minted BPT, and mint the same amount of adapter
    ///         shares to `to`. The 1:1 share:BPT invariant is preserved.
    function deposit(uint256 deposit0, uint256 deposit1, address to, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        require(deposit0 > 0 || deposit1 > 0, "amounts");
        require(to != address(0), "to");

        if (deposit0 > 0) token0.safeTransferFrom(msg.sender, address(this), deposit0);
        if (deposit1 > 0) token1.safeTransferFrom(msg.sender, address(this), deposit1);

        _inVaultOp = true;
        bytes memory result = vault.unlock(
            abi.encodeCall(this.depositHook, (deposit0, deposit1, minShares))
        );
        _inVaultOp = false;

        shares = abi.decode(result, (uint256));
        _stakeBpt(shares);
        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, deposit0, deposit1);
    }

    /// @notice Burn `shares` adapter tokens, remove proportional liquidity from the Beets
    ///         pool, and send the underlying token0/token1 to `to`.
    function withdraw(uint256 shares, address to, uint256 minAmount0, uint256 minAmount1)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        require(shares > 0, "shares");
        require(to != address(0), "to");

        _burn(msg.sender, shares);
        _unstakeBpt(shares, address(this));

        _inVaultOp = true;
        bytes memory result = vault.unlock(
            abi.encodeCall(this.withdrawHook, (shares, to, minAmount0, minAmount1))
        );
        _inVaultOp = false;

        (amount0, amount1) = abi.decode(result, (uint256, uint256));
        emit Withdraw(msg.sender, to, shares, amount0, amount1);
    }

    /// @dev Vault unlock callback for deposit. UNBALANCED = exact amounts in, so any token
    ///      mix works (matching the CL vaults' idle-pot deposits). The add creates token
    ///      debts in the Vault's transient accounting; we pay them by transferring each
    ///      token in and settling.
    /// @dev Hooks return TYPED values, never pre-encoded bytes: unlock() relays the hook's
    ///      raw returndata, and a `bytes` return would arrive double-wrapped (offset+length
    ///      words first — decoding that as uint256 yields 32, the offset, not the value).
    function depositHook(uint256 deposit0, uint256 deposit1, uint256 minBptOut)
        external
        returns (uint256 bptAmountOut)
    {
        require(msg.sender == address(vault) && _inVaultOp, "hook");

        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[0] = deposit0;
        exactAmountsIn[1] = deposit1;

        (, bptAmountOut, ) = vault.addLiquidity(
            AddLiquidityParams({
                pool: bpt,
                to: address(this),
                maxAmountsIn: exactAmountsIn,
                minBptAmountOut: minBptOut,
                kind: AddLiquidityKind.UNBALANCED,
                userData: ""
            })
        );

        if (deposit0 > 0) {
            token0.safeTransfer(address(vault), deposit0);
            vault.settle(token0, deposit0);
        }
        if (deposit1 > 0) {
            token1.safeTransfer(address(vault), deposit1);
            vault.settle(token1, deposit1);
        }
    }

    /// @dev Vault unlock callback for withdraw. PROPORTIONAL exit; the Vault burns the BPT
    ///      we hold and credits us the underlying, which we send straight to the recipient.
    ///      Typed returns for the same relayed-returndata reason as depositHook.
    function withdrawHook(uint256 bptIn, address to, uint256 minAmount0, uint256 minAmount1)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        require(msg.sender == address(vault) && _inVaultOp, "hook");

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = minAmount0;
        minAmountsOut[1] = minAmount1;

        (, uint256[] memory amountsOut, ) = vault.removeLiquidity(
            RemoveLiquidityParams({
                pool: bpt,
                from: address(this),
                maxBptAmountIn: bptIn,
                minAmountsOut: minAmountsOut,
                kind: RemoveLiquidityKind.PROPORTIONAL,
                userData: ""
            })
        );

        if (amountsOut[0] > 0) vault.sendTo(token0, to, amountsOut[0]);
        if (amountsOut[1] > 0) vault.sendTo(token1, to, amountsOut[1]);

        return (amountsOut[0], amountsOut[1]);
    }

    // ===================== GAUGE REWARDS =====================

    /// @notice Pull pending gauge emissions, then credit adapter holders via the accumulator.
    ///         Permissionless — call before claimRewards() or let claimRewards() do it.
    function collectGaugeRewards()
        public
        nonReentrant
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        (tokens, amounts) = _collectGaugeRewards();
        emit GaugeRewardsCollected(tokens, amounts);
    }

    /// @notice Claim accrued gauge rewards for the caller.
    function claimRewards() external nonReentrant {
        _collectGaugeRewards();
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

    // ===================== IStratusALPT SURFACE =====================

    function pool() external view returns (address) {
        return bpt;
    }

    /// @notice The adapter's share of each pool reserve (raw token units), backed 1:1 by
    ///         the minted supply of BPT. Donation-immune: keyed off totalSupply(), not the
    ///         adapter's raw BPT balance.
    function getTotalAmounts() public view returns (uint256 total0, uint256 total1) {
        (total0, total1, ) = _valuation();
    }

    /// @notice Same quantities as getTotalAmounts — the manipulation resistance lives in the
    ///         price used to value them, not in the quantities. (No spot vs safe split: a
    ///         rate-provider-priced BPT has no tick to manipulate.)
    function getTotalAmountsSafe() external view returns (uint256 total0, uint256 total1) {
        (total0, total1, ) = _valuation();
    }

    /// @notice Safe price of token0 in token1 (1e18), from the pool's rate providers.
    function twapPrice() public view returns (uint256 price) {
        (, , price) = _valuation();
    }

    /// @notice Total value of the adapter's backing in token1 base units, anchored to the
    ///         pool invariant (Balancer BPT rate), not the live reserve vector.
    /// @dev Rate-priced reserve sums rise when the pool is skewed (slippage stays in-pool),
    ///      so they are not swap-invariant and are unsafe as collateral. The invariant /
    ///      bptRate is conserved under swaps (grows only from fees):
    ///      getRate() == computeInvariant(balancesLiveScaled18) / bptTotalSupply.
    ///      Convert to token1: supply * bptRate / (sf1 * rate1).
    ///      Deliberately ≤ getTotalAmounts()-implied value when skewed — conservative for lending.
    function getTotalValueSafe() public view returns (uint256 value) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        (uint256[] memory sf, uint256[] memory rates) = vault.getPoolTokenRates(bpt);
        uint256 denom = sf[1] * rates[1];
        if (denom == 0) return 0;
        value = Math.mulDiv(supply, IRateProvider(bpt).getRate(), denom);
    }

    /// @notice Spot value — for a rate-priced BPT there is no meaningful spot/safe gap, so
    ///         this equals getTotalValueSafe. Present for IStratusALPT conformance.
    function getTotalValue() external view returns (uint256) {
        return getTotalValueSafe();
    }

    /// @notice Safe value of one whole adapter token (= one BPT) in token1 base units —
    ///         the composable price a lending market should use as collateral value.
    function pricePerShareSafe() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(getTotalValueSafe(), 10 ** _decimals, supply);
    }

    // ===================== INTERNALS =====================

    function _setGauge(address _gauge) internal {
        require(_gauge != address(0), "zero gauge");
        require(IBeetsGauge(_gauge).lp_token() == bpt, "lp mismatch");
        gauge = _gauge;
        IERC20(bpt).forceApprove(_gauge, type(uint256).max);
        uint256 idle = IERC20(bpt).balanceOf(address(this));
        if (idle > 0) _stakeBpt(idle);
        emit GaugeSet(_gauge);
    }

    function _stakeBpt(uint256 amount) internal {
        if (gauge == address(0) || amount == 0) return;
        IBeetsGauge(gauge).deposit(amount, address(this));
    }

    function _unstakeBpt(uint256 amount, address to) internal {
        if (gauge == address(0)) {
            IERC20(bpt).safeTransfer(to, amount);
            return;
        }
        IBeetsGauge(gauge).withdraw(amount, to);
    }

    function _collectGaugeRewards()
        internal
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        if (gauge == address(0) || rewardTokens.length == 0) {
            return (new address[](0), new uint256[](0));
        }

        tokens = rewardTokens;
        amounts = new uint256[](tokens.length);

        uint256[] memory balBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
        }

        uint256[] memory allIndexes;
        IBeetsGauge(gauge).claim_rewards(address(this), address(this), allIndexes);

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 received = IERC20(tokens[i]).balanceOf(address(this)) - balBefore[i];
            amounts[i] = received;
            if (received > 0) _distributeReward(tokens[i], received);
        }
    }

    function _distributeReward(address token, uint256 net) internal {
        if (!isRewardToken[token] || net == 0) return;
        uint256 supply = totalSupply();
        if (supply == 0) return;
        rewardPerShareStored[token] += Math.mulDiv(net, ACC_PRECISION, supply);
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

    function _update(address from, address to, uint256 value) internal override {
        _settleRewards(from);
        _settleRewards(to);
        super._update(from, to, value);
    }

    /// @dev (total0, total1, price0in1) at rate-provider prices.
    ///      total_i = totalSupply × balancesRawᵢ / bptSupply  (our 1:1 share of reserves)
    ///      price0in1 = (sf0·rate0·1e18) / (sf1·rate1)         (token0 in token1, 1e18)
    function _valuation() internal view returns (uint256 total0, uint256 total1, uint256 price0in1) {
        uint256 supply = totalSupply();
        uint256 bptSupply = vault.totalSupply(bpt);
        (uint256[] memory sf, uint256[] memory rates) = vault.getPoolTokenRates(bpt);

        if (supply > 0 && bptSupply > 0) {
            (, , uint256[] memory balancesRaw, ) = vault.getPoolTokenInfo(bpt);
            total0 = Math.mulDiv(supply, balancesRaw[0], bptSupply);
            total1 = Math.mulDiv(supply, balancesRaw[1], bptSupply);
        }

        price0in1 = Math.mulDiv(sf[0] * rates[0], PRECISION, sf[1] * rates[1]);
    }
}
