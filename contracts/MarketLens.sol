// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ILensFactory {
    function allLendingPoolsLength() external view returns (uint256);
    function allLendingPools(uint256 index) external view returns (address);
    function getLendingPool(address alpt)
        external
        view
        returns (LendingPoolRef memory);
}

struct LendingPoolRef {
    bool initialized;
    uint24 lendingPoolId;
    address collateral;
    address borrowable0;
    address borrowable1;
}

interface ILensAlpt {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function getTotalValueSafe() external view returns (uint256);
    function twapPrice() external view returns (uint256);
    function pricePerShareSafe() external view returns (uint256);
    function pool() external view returns (address);
    function bpt() external view returns (address);
    function gauge() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function pendingReward(address user, address token) external view returns (uint256);
    function rewardTokensList() external view returns (address[] memory);
    // DLMM-only (StratusDLMMVault): binStep() is the feature-probe marker, pair() the venue pool.
    function binStep() external view returns (uint16);
    function pair() external view returns (address);
}

interface ILensBorrowable {
    function totalBalance() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function borrowRate() external view returns (uint256);
    function borrowBalance(address borrower) external view returns (uint256);
    function exchangeRate() external returns (uint256);
    function underlying() external view returns (address);
}

interface ILensCollateral {
    function underlying() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function exchangeRate() external returns (uint256);
    function accountLiquidity(address borrower) external returns (uint256 liquidity, uint256 shortfall);
    function safetyMarginSqrt() external view returns (uint256);
    function liquidationIncentive() external view returns (uint256);
    function pendingVaultReward(address user, address token) external view returns (uint256);
    function vaultRewardTokensList() external view returns (address[] memory);
}

interface ILensErc20 {
    function balanceOf(address) external view returns (uint256);
}

/// @notice One-stop read surface for the frontend: enumerates every lending market across
///         all registered Tarot factories and self-describes each one — venue kind, token
///         metadata, valuation, lend-side state, risk params, and per-user positions.
///         The frontend needs exactly ONE address per chain (this lens) instead of a
///         hand-maintained per-market config.
/// @dev Functions are deliberately non-view where the underlying protocol getters mutate
///      (exchangeRate/accountLiquidity accrue interest) — call them via eth_call and
///      declare them `view` in the client ABI, the standard Impermax/Tarot lens pattern.
///      Holds no funds; the only state is the factory registry and venue-kind overrides.
contract MarketLens {
    /// @notice DLMM is a declared-but-unimplemented venue kind (future work): the enum
    ///         slot and the kind-override registry are the extension points, so adding a
    ///         DLMM adapter later requires no lens redeploy — just setKindOverride.
    enum VenueKind {
        UNKNOWN,
        SHADOW_CL,
        THICK_CL,
        BEETS_V3,
        DLMM
    }

    struct TokenMeta {
        address token;
        string symbol;
        uint8 decimals;
    }

    struct MarketInfo {
        address alpt; // the vault/adapter (Collateral.underlying)
        address collateral;
        address borrowable0;
        address borrowable1;
        VenueKind kind;
        address venuePool; // CL pool or BPT
        address venueGauge; // address(0) when the venue has none
        TokenMeta token0;
        TokenMeta token1;
        // valuation (manipulation-resistant surface)
        uint256 totalValueSafe; // token1 base units
        uint256 twapPrice; // token0 in token1, 1e18
        uint256 pricePerShareSafe;
        uint256 alptTotalSupply;
        // lend side
        uint256 cash0;
        uint256 cash1;
        uint256 totalBorrows0;
        uint256 totalBorrows1;
        uint256 borrowRate0;
        uint256 borrowRate1;
        // risk params
        uint256 safetyMarginSqrt;
        uint256 liquidationIncentive;
    }

    struct UserPosition {
        address collateral;
        uint256 cTokenBalance;
        uint256 cTokenExchangeRate; // ALPT per cToken, 1e18
        uint256 borrowBalance0;
        uint256 borrowBalance1;
        uint256 liquidity;
        uint256 shortfall;
        uint256 wallet0;
        uint256 wallet1;
        uint256 walletAlpt;
    }

    address public owner;
    address[] public factories;
    mapping(address => bool) public isFactory;
    /// @dev alpt => forced kind; overrides feature detection (and the only path to DLMM
    ///      until a DLMM adapter defines its own detectable surface).
    mapping(address => VenueKind) public kindOverride;

    event FactoryAdded(address indexed factory);
    event FactoryRemoved(address indexed factory);
    event KindOverrideSet(address indexed alpt, VenueKind kind);

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(address[] memory _factories) {
        owner = msg.sender;
        for (uint256 i = 0; i < _factories.length; i++) {
            _addFactory(_factories[i]);
        }
    }

    // ===================== REGISTRY =====================

    function addFactory(address factory) external onlyOwner {
        _addFactory(factory);
    }

    function removeFactory(address factory) external onlyOwner {
        require(isFactory[factory], "unknown");
        isFactory[factory] = false;
        for (uint256 i = 0; i < factories.length; i++) {
            if (factories[i] == factory) {
                factories[i] = factories[factories.length - 1];
                factories.pop();
                break;
            }
        }
        emit FactoryRemoved(factory);
    }

    function setKindOverride(address alpt, VenueKind kind) external onlyOwner {
        kindOverride[alpt] = kind;
        emit KindOverrideSet(alpt, kind);
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        owner = newOwner;
    }

    function factoriesLength() external view returns (uint256) {
        return factories.length;
    }

    // ===================== MARKETS =====================

    /// @notice Every initialized lending market across all registered factories.
    /// @dev Fully view — market data reads no accruing getters. Only the user-position
    ///      surface (getUserPositions) is non-view, because Tarot's exchangeRate() and
    ///      accountLiquidity() accrue interest on read.
    function getAllMarkets() external view returns (MarketInfo[] memory markets) {
        uint256 total = _countMarkets();
        markets = new MarketInfo[](total);
        uint256 k = 0;
        for (uint256 f = 0; f < factories.length; f++) {
            ILensFactory factory = ILensFactory(factories[f]);
            uint256 n = factory.allLendingPoolsLength();
            for (uint256 i = 0; i < n; i++) {
                address alpt = factory.allLendingPools(i);
                LendingPoolRef memory ref = factory.getLendingPool(alpt);
                if (ref.collateral == address(0) || ref.borrowable0 == address(0) || ref.borrowable1 == address(0)) {
                    continue;
                }
                markets[k++] = _marketInfo(alpt, ref);
            }
        }
        assembly {
            mstore(markets, k)
        } // trim skipped slots
    }

    /// @notice The caller-agnostic position of `user` in every market, index-aligned with
    ///         getAllMarkets().
    function getUserPositions(address user) external returns (UserPosition[] memory positions) {
        uint256 total = _countMarkets();
        positions = new UserPosition[](total);
        uint256 k = 0;
        for (uint256 f = 0; f < factories.length; f++) {
            ILensFactory factory = ILensFactory(factories[f]);
            uint256 n = factory.allLendingPoolsLength();
            for (uint256 i = 0; i < n; i++) {
                address alpt = factory.allLendingPools(i);
                LendingPoolRef memory ref = factory.getLendingPool(alpt);
                if (ref.collateral == address(0) || ref.borrowable0 == address(0) || ref.borrowable1 == address(0)) {
                    continue;
                }
                positions[k++] = _userPosition(alpt, ref, user);
            }
        }
        assembly {
            mstore(positions, k)
        }
    }

    /// @notice Pending reward amounts for `user` on one market: rewards owed at the
    ///         cToken layer (Collateral accumulator) for each reward token, plus the raw
    ///         reward-token list. Kept separate from getUserPositions to bound gas.
    function getUserRewards(address collateral, address user)
        external
        view
        returns (address[] memory tokens, uint256[] memory pending)
    {
        try ILensCollateral(collateral).vaultRewardTokensList() returns (address[] memory t) {
            tokens = t;
        } catch {
            return (new address[](0), new uint256[](0));
        }
        pending = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            pending[i] = ILensCollateral(collateral).pendingVaultReward(user, tokens[i]);
        }
    }

    // ===================== INTERNALS =====================

    function _countMarkets() internal view returns (uint256 total) {
        for (uint256 f = 0; f < factories.length; f++) {
            total += ILensFactory(factories[f]).allLendingPoolsLength();
        }
    }

    function _addFactory(address factory) internal {
        require(factory != address(0), "zero");
        require(!isFactory[factory], "dup");
        isFactory[factory] = true;
        factories.push(factory);
        emit FactoryAdded(factory);
    }

    function _marketInfo(address alpt, LendingPoolRef memory ref)
        internal
        view
        returns (MarketInfo memory m)
    {
        m.alpt = alpt;
        m.collateral = ref.collateral;
        m.borrowable0 = ref.borrowable0;
        m.borrowable1 = ref.borrowable1;

        ILensAlpt v = ILensAlpt(alpt);
        (m.kind, m.venuePool, m.venueGauge) = _detectVenue(alpt);
        m.token0 = _tokenMeta(v.token0());
        m.token1 = _tokenMeta(v.token1());

        m.totalValueSafe = v.getTotalValueSafe();
        m.twapPrice = v.twapPrice();
        m.pricePerShareSafe = v.pricePerShareSafe();
        m.alptTotalSupply = v.totalSupply();

        m.cash0 = ILensBorrowable(ref.borrowable0).totalBalance();
        m.cash1 = ILensBorrowable(ref.borrowable1).totalBalance();
        m.totalBorrows0 = ILensBorrowable(ref.borrowable0).totalBorrows();
        m.totalBorrows1 = ILensBorrowable(ref.borrowable1).totalBorrows();
        m.borrowRate0 = ILensBorrowable(ref.borrowable0).borrowRate();
        m.borrowRate1 = ILensBorrowable(ref.borrowable1).borrowRate();

        m.safetyMarginSqrt = ILensCollateral(ref.collateral).safetyMarginSqrt();
        m.liquidationIncentive = ILensCollateral(ref.collateral).liquidationIncentive();
    }

    function _userPosition(address alpt, LendingPoolRef memory ref, address user)
        internal
        returns (UserPosition memory p)
    {
        p.collateral = ref.collateral;
        p.cTokenBalance = ILensCollateral(ref.collateral).balanceOf(user);
        p.cTokenExchangeRate = ILensCollateral(ref.collateral).exchangeRate();
        p.borrowBalance0 = ILensBorrowable(ref.borrowable0).borrowBalance(user);
        p.borrowBalance1 = ILensBorrowable(ref.borrowable1).borrowBalance(user);
        if (p.cTokenBalance > 0 || p.borrowBalance0 > 0 || p.borrowBalance1 > 0) {
            (p.liquidity, p.shortfall) = ILensCollateral(ref.collateral).accountLiquidity(user);
        }
        ILensAlpt v = ILensAlpt(alpt);
        p.wallet0 = ILensErc20(v.token0()).balanceOf(user);
        p.wallet1 = ILensErc20(v.token1()).balanceOf(user);
        p.walletAlpt = v.balanceOf(user);
    }

    /// @dev Feature-probe the underlying to classify the venue. An explicit override wins.
    ///      Detection order: bpt() → Beets/Balancer adapter; binStep() → DLMM (Metropolis
    ///      Liquidity Book); gauge() nonzero + pool() → gauged CL (Shadow); pool() only →
    ///      fee-only CL (Thick).
    function _detectVenue(address alpt)
        internal
        view
        returns (VenueKind kind, address venuePool, address venueGauge)
    {
        VenueKind forced = kindOverride[alpt];

        try ILensAlpt(alpt).bpt() returns (address bpt_) {
            venuePool = bpt_;
            try ILensAlpt(alpt).gauge() returns (address g) {
                venueGauge = g;
            } catch {}
            kind = forced != VenueKind.UNKNOWN ? forced : VenueKind.BEETS_V3;
            return (kind, venuePool, venueGauge);
        } catch {}

        try ILensAlpt(alpt).binStep() returns (uint16) {
            try ILensAlpt(alpt).pair() returns (address p) {
                venuePool = p;
            } catch {}
            kind = forced != VenueKind.UNKNOWN ? forced : VenueKind.DLMM;
            return (kind, venuePool, venueGauge);
        } catch {}

        try ILensAlpt(alpt).pool() returns (address pool_) {
            venuePool = pool_;
        } catch {}

        try ILensAlpt(alpt).gauge() returns (address g) {
            venueGauge = g;
            kind = forced != VenueKind.UNKNOWN ? forced : VenueKind.SHADOW_CL;
            return (kind, venuePool, venueGauge);
        } catch {}

        kind = forced != VenueKind.UNKNOWN
            ? forced
            : (venuePool != address(0) ? VenueKind.THICK_CL : VenueKind.UNKNOWN);
    }

    function _tokenMeta(address token) internal view returns (TokenMeta memory tm) {
        tm.token = token;
        try IERC20Metadata(token).symbol() returns (string memory s) {
            tm.symbol = s;
        } catch {
            tm.symbol = "?";
        }
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            tm.decimals = d;
        } catch {
            tm.decimals = 18;
        }
    }
}
