// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IBeetsV3Vault.sol";

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
///      No liquidity plumbing (no unlock/settle/addLiquidity): holders who already own BPT
///      wrap it 1:1 to get a collateral token Tarot understands, and unwrap to get it back.
contract StratusBeetsV3Adapter is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The Beets/Balancer v3 Vault (singleton).
    IBeetsV3Vault public immutable vault;

    /// @notice The wrapped pool token (BPT). `pool()` returns this for IStratusALPT compat.
    address public immutable bpt;

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint8 private immutable _decimals;

    uint256 private constant PRECISION = 1e18;

    event Wrapped(address indexed from, address indexed to, uint256 amount);
    event Unwrapped(address indexed from, address indexed to, uint256 amount);

    constructor(address _vault, address _bpt, string memory _name, string memory _symbol)
        ERC20(_name, _symbol)
    {
        require(_vault != address(0) && _bpt != address(0), "zero");
        vault = IBeetsV3Vault(_vault);
        bpt = _bpt;

        IERC20[] memory tokens = IBeetsV3Vault(_vault).getPoolTokens(_bpt);
        require(tokens.length == 2, "only 2-token pools");
        token0 = tokens[0];
        token1 = tokens[1];

        // 1:1 with the BPT, so share the BPT's decimals.
        _decimals = IERC20Metadata(_bpt).decimals();
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // ===================== 1:1 WRAP / UNWRAP =====================

    /// @notice Wrap `amount` BPT (pulled from msg.sender) and mint the same amount of
    ///         adapter tokens to `to`. No fee, no rebalance.
    function wrap(uint256 amount, address to) external nonReentrant returns (uint256) {
        require(amount > 0, "amount");
        require(to != address(0), "to");
        IERC20(bpt).safeTransferFrom(msg.sender, address(this), amount);
        _mint(to, amount);
        emit Wrapped(msg.sender, to, amount);
        return amount;
    }

    /// @notice Burn `amount` adapter tokens and return the same amount of BPT to `to`.
    function unwrap(uint256 amount, address to) external nonReentrant returns (uint256) {
        require(amount > 0, "amount");
        require(to != address(0), "to");
        _burn(msg.sender, amount);
        IERC20(bpt).safeTransfer(to, amount);
        emit Unwrapped(msg.sender, to, amount);
        return amount;
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

    /// @notice Total value of the adapter's backing in token1 base units, at rate-provider
    ///         prices. Manipulation-resistant (≡ ownershipFraction × pool invariant value).
    function getTotalValueSafe() public view returns (uint256 value) {
        (uint256 total0, uint256 total1, uint256 price) = _valuation();
        value = total1 + Math.mulDiv(total0, price, PRECISION);
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

        // value-per-raw of token i (common units) = sf_i × rate_i / 1e18; ratio gives the price.
        price0in1 = Math.mulDiv(sf[0] * rates[0], PRECISION, sf[1] * rates[1]);
    }
}
