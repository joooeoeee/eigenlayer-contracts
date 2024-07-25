// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IStrategy.sol";

/**
 * @title Interface for the `StrategyFactory` contract.
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 * @dev This may not be compatible with non-standard ERC20 tokens. Caution is warranted.
 */
interface IStrategyFactory {
    // @notice Upgradeable beacon which new Strategies deployed by this contract point to
    function strategyBeacon() external view returns (IBeacon);

    // @notice Mapping token => Strategy contract for the token
    function tokenStrategy(IERC20 token) external view returns (IStrategy);

    /**
     * @notice Deploy a new strategyBeacon contract for the ERC20 token.
     * @dev A strategy contract must not yet exist for the token.
     * $dev Immense caution is warranted for non-standard ERC20 tokens, particularly "reentrant" tokens
     * like those that conform to ERC777.
     */
    function deployNewStrategy(IERC20 token) external returns (IStrategy newStrategy);

    /**
     * @notice Owner-only function to pass through a call to `StrategyManager.addStrategiesToDepositWhitelist`
     * @dev Also adds the `strategiesToWhitelist` to the `tokenStrategy` mapping
     */
    function whitelistStrategies(
        IStrategy[] calldata strategiesToWhitelist,
        bool[] calldata thirdPartyTransfersForbiddenValues
    ) external;

    // @notice Emitted when the `strategyBeacon` is changed
    event StrategyBeaconModified(IBeacon previousBeacon, IBeacon newBeacon);

    // @notice Emitted whenever a slot is set in the `tokenStrategy` mapping
    event StrategySetForToken(IERC20 token, IStrategy strategy);
}