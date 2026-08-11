// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./interfaces/IFactory.sol";
import "./interfaces/IBDeployer.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/ICDeployer.sol";
import "./interfaces/ICollateral.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IStratusALPT.sol";
import "./LendingPoolStruct.sol";

contract TarotFactory is IFactory {
    // --- Custom Errors ---
    error AlreadyExists();
    error AlreadyInitialized();
    error CollateralizableNotCreated();
    error Borrowable0NotCreated();
    error Borrowable1NotCreated();
    error Unauthorized();

    // --- State Variables ---

    address public admin;
    address public pendingAdmin;
    address public reservesAdmin;
    address public reservesPendingAdmin;
    address public reservesManager;

    // Internal mapping to store lending pools
    mapping(address => LendingPool) internal _lendingPools; // get by StratusALPT vault

    address[] internal _allLendingPools; // address of the StratusALPT vault

    IBDeployer public immutable bDeployer;
    ICDeployer public immutable cDeployer;

    // --- Events ---

    event LendingPoolInitialized(
        address indexed stratusALPT,
        address indexed token0,
        address indexed token1,
        address collateral,
        address borrowable0,
        address borrowable1,
        uint256 lendingPoolId
    );
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
    event NewAdmin(address oldAdmin, address newAdmin);
    event NewReservesAdmin(address oldReservesAdmin, address newReservesAdmin);
    event NewReservesManager(
        address oldReservesManager,
        address newReservesManager
    );
    event NewReservesPendingAdmin(address oldReservesPendingAdmin, address newReservesPendingAdmin);


    // --- Constructor ---

    constructor(
        address _admin,
        address _reservesAdmin,
        IBDeployer _bDeployer,
        ICDeployer _cDeployer
    ) {
        admin = _admin;
        reservesAdmin = _reservesAdmin;
        bDeployer = _bDeployer;
        cDeployer = _cDeployer;
        emit NewAdmin(address(0), _admin);
        emit NewReservesAdmin(address(0), _reservesAdmin);
    }

    // --- External Functions ---

    function allLendingPoolsLength() external view override returns (uint256) {
        return _allLendingPools.length;
    }

    function allLendingPools(uint256 index) external view override returns (address) {
        return _allLendingPools[index];
    }

    function getLendingPool(address stratusALPT) external view override returns (LendingPool memory) {
        return _lendingPools[stratusALPT];
    }

    function createCollateral(address stratusALPT)
        external
        override
        returns (address) // Removed 'collateral' from here
    {
        _getTokens(stratusALPT);
        if (_lendingPools[stratusALPT].collateral != address(0)) {
            revert AlreadyExists();
        }
        address collateral = cDeployer.deployCollateral(stratusALPT); // Declared 'collateral' here
        ICollateral(collateral)._setFactory();
        _createLendingPool(stratusALPT);
        _lendingPools[stratusALPT].collateral = collateral;
        return collateral; // Explicitly return
    }

    function createBorrowable0(address stratusALPT)
        external
        override
        returns (address) // Removed 'borrowable0' from here
    {
        _getTokens(stratusALPT);
        if (_lendingPools[stratusALPT].borrowable0 != address(0)) {
            revert AlreadyExists();
        }
        address borrowable0 = bDeployer.deployBorrowable(stratusALPT, 0); // Declared 'borrowable0' here
        IBorrowable(borrowable0)._setFactory();
        _createLendingPool(stratusALPT);
        _lendingPools[stratusALPT].borrowable0 = borrowable0;
        return borrowable0; // Explicitly return
    }

    function createBorrowable1(address stratusALPT)
        external
        override
        returns (address) // Removed 'borrowable1' from here
    {
        _getTokens(stratusALPT);
        if (_lendingPools[stratusALPT].borrowable1 != address(0)) {
            revert AlreadyExists();
        }
        address borrowable1 = bDeployer.deployBorrowable(stratusALPT, 1); // Declared 'borrowable1' here
        IBorrowable(borrowable1)._setFactory();
        _createLendingPool(stratusALPT);
        _lendingPools[stratusALPT].borrowable1 = borrowable1;
        return borrowable1; // Explicitly return
    }

    function initializeLendingPool(address stratusALPT) external override {
        (address token0, address token1) = _getTokens(stratusALPT);
        LendingPool storage lPool = _lendingPools[stratusALPT];
        if (lPool.initialized) {
            revert AlreadyInitialized();
        }

        if (lPool.collateral == address(0)) {
            revert CollateralizableNotCreated();
        }
        if (lPool.borrowable0 == address(0)) {
            revert Borrowable0NotCreated();
        }
        if (lPool.borrowable1 == address(0)) {
            revert Borrowable1NotCreated();
        }

        // Pricing comes from the underlying ALPT (getTotalValueSafe / twapPrice); there is
        // no separate per-pair oracle to initialize here.

        // Initialize collateral and borrowable tokens
        ICollateral(lPool.collateral)._initialize(
            "Tarot Collateral",
            "cTAROT",
            stratusALPT,
            lPool.borrowable0,
            lPool.borrowable1
        );
        IBorrowable(lPool.borrowable0)._initialize(
            "Tarot Borrowable",
            "bTAROT",
            token0,
            lPool.collateral
        );
        IBorrowable(lPool.borrowable1)._initialize(
            "Tarot Borrowable",
            "bTAROT",
            token1,
            lPool.collateral
        );

        lPool.initialized = true;
        emit LendingPoolInitialized(
            stratusALPT,
            token0,
            token1,
            lPool.collateral,
            lPool.borrowable0,
            lPool.borrowable1,
            lPool.lendingPoolId
        );
    }

    // Admin functions for managing factory ownership and reserves
    function _setPendingAdmin(address newPendingAdmin) external override {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
        address oldPendingAdmin = pendingAdmin;
        pendingAdmin = newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
    }

    function _acceptAdmin() external override {
        if (msg.sender != pendingAdmin) {
            revert Unauthorized();
        }
        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, address(0));
    }

    function _setReservesPendingAdmin(address newReservesPendingAdmin)
        external
        override
    {
        if (msg.sender != reservesAdmin) {
            revert Unauthorized();
        }
        address oldReservesPendingAdmin = reservesPendingAdmin;
        reservesPendingAdmin = newReservesPendingAdmin;
        emit NewReservesPendingAdmin(
            oldReservesPendingAdmin,
            newReservesPendingAdmin
        );
    }

    function _acceptReservesAdmin() external override {
        if (msg.sender != reservesPendingAdmin) {
            revert Unauthorized();
        }
        address oldReservesAdmin = reservesAdmin;
        address oldReservesPendingAdmin = reservesPendingAdmin;
        reservesAdmin = reservesPendingAdmin;
        reservesPendingAdmin = address(0);
        emit NewReservesAdmin(oldReservesAdmin, reservesAdmin);
        emit NewReservesPendingAdmin(oldReservesPendingAdmin, address(0));
    }

    function _setReservesManager(address newReservesManager) external override {
        if (msg.sender != reservesAdmin) {
            revert Unauthorized();
        }
        address oldReservesManager = reservesManager;
        reservesManager = newReservesManager;
        emit NewReservesManager(oldReservesManager, newReservesManager);
    }

    // --- Private Functions ---

    /// @notice Internal helper to get token0 and token1 addresses from a StratusALPT vault.
    /// @param stratusALPT The address of the StratusALPT vault.
    /// @return token0 The address of the first token.
    /// @return token1 The address of the second token.
    function _getTokens(address stratusALPT)
        private
        view
        returns (address token0, address token1)
    {
        token0 = IStratusALPT(stratusALPT).token0();
        token1 = IStratusALPT(stratusALPT).token1();
    }

    /// @notice Internal helper to create a new lending pool entry if it doesn't exist.
    /// @param stratusALPT The address of the StratusALPT vault for the new lending pool.
    function _createLendingPool(address stratusALPT) private {
        if (_lendingPools[stratusALPT].lendingPoolId != 0) return; // Already exists
        _allLendingPools.push(stratusALPT);
        _lendingPools[stratusALPT] = LendingPool(
            false, // initialized
            uint24(_allLendingPools.length), // lendingPoolId (1-based index)
            address(0), // collateral
            address(0), // borrowable0
            address(0)  // borrowable1
        );
    }
}
