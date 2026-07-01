// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IVoter {
    /// @notice Get the gauge address for a given pool
    /// @param pool The pool address
    /// @return gauge The gauge address
    function gaugeForPool(address pool) external view returns (address gauge);

    /// @notice Claim CL gauge rewards for multiple positions
    /// @param _gauges Array of gauge addresses
    /// @param _tokens Array of reward token addresses for each gauge
    /// @param _nfpTokenIds Array of NFT position token IDs for each gauge
    function claimClGaugeRewards(
        address[] calldata _gauges,
        address[][] calldata _tokens,
        uint256[][] calldata _nfpTokenIds
    ) external;

    /// @notice Claim CL gauge rewards and exit positions
    /// @param _gauges Array of gauge addresses
    /// @param _tokens Array of reward token addresses for each gauge
    /// @param _nfpTokenIds Array of NFT position token IDs for each gauge
    function claimClGaugeRewardsAndExit(
        address[] memory _gauges,
        address[][] memory _tokens,
        uint256[][] memory _nfpTokenIds
    ) external;
}
