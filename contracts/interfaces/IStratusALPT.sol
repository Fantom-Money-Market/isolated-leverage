// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStratusALPT {
    // --- Manipulation-resistant valuation surface (the standard) ---
    // Every Stratus collateral conformer exposes these, regardless of venue:
    //   - CL vaults (Shadow/Thick) source them from a pool TWAP
    //   - the Beets adapter sources them from Balancer-v3 rate providers
    // Collateral prices off THESE (not spot getTotalAmounts + slot0), so the lending
    // layer is venue-agnostic and not manipulable.

    /// @notice Total position value in token1 base units, at the safe price.
    function getTotalValueSafe() external view returns (uint256 value);

    /// @notice Safe price of token0 denominated in token1 (1e18). Manipulation-resistant.
    function twapPrice() external view returns (uint256 price);

    /// @notice Holdings (token0, token1) evaluated at the safe price.
    function getTotalAmountsSafe() external view returns (uint256 total0, uint256 total1);

    /// @notice Safe value of one whole collateral token in token1 base units.
    function pricePerShareSafe() external view returns (uint256);

    // --- Reference / spot (UI only — NOT for collateral pricing) ---
    function getTotalAmounts() external view returns (uint256 total0, uint256 total1);
    function totalSupply() external view returns (uint256);
    function pool() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    
    // --- ERC20 Functions (inherited) ---
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}