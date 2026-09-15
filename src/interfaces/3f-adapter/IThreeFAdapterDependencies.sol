// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IThreeFFacility
 * @notice Minimal 3F facility interface for intent lookup.
 */
interface IThreeFFacility {
    /* STRUCTS */

    /**
     * @notice Asset configuration for a 3F intent.
     * @param asset Asset or position-manager address.
     * @param isPositionManager Whether `asset` is a position manager.
     */
    struct Asset {
        address asset;
        bool isPositionManager;
    }

    /**
     * @notice Intent configuration returned by `getIntent`.
     * @param depositAsset Asset deposited into the intent.
     * @param targetAsset Target asset or position manager for the intent.
     * @param depositCap Maximum amount that can be deposited into the intent.
     * @param guardKey Guard key address associated with intent authorization.
     * @param resolveStart Timestamp at which the deposit phase ends.
     * @param quorum Quorum threshold required for guard approvals.
     * @param transferableIntent Whether intent token transfers are enabled.
     */
    struct IntentProperties {
        Asset depositAsset;
        Asset targetAsset;
        uint256 depositCap;
        address guardKey;
        uint40 resolveStart;
        uint8 quorum;
        bool transferableIntent;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns the intent configuration and bound contracts for an id.
     * @param id Intent id parsed from the request name.
     * @return properties Intent configuration.
     * @return fund Fund address bound to the intent.
     * @return request Request address bound to the intent.
     * @return resolved Whether the intent has been resolved.
     */
    function getIntent(uint256 id)
        external
        view
        returns (IntentProperties memory properties, address fund, address request, bool resolved);
}

/**
 * @title IThreeFPositionManager
 * @notice Minimal 3F position-manager interface used to resolve collateral.
 */
interface IThreeFPositionManager {
    /* FUNCTIONS */

    /**
     * @notice Returns the collateral and debt asset addresses.
     * @return collateralAsset Collateral asset token.
     * @return debtAsset Debt asset token.
     */
    function assets() external view returns (address collateralAsset, address debtAsset);
}

/**
 * @title IThreeFUnderlyingAsset
 * @notice Minimal collateral-token interface used to resolve the risk-asset key.
 */
interface IThreeFUnderlyingAsset {
    /* FUNCTIONS */

    /**
     * @notice Returns the underlying asset represented by this collateral token.
     * @return asset Underlying asset address.
     */
    function underlying() external view returns (address asset);
}

/**
 * @title IThreeFRequestName
 * @notice Minimal 3F request metadata interface used to parse the intent id.
 */
interface IThreeFRequestName {
    /* FUNCTIONS */

    /**
     * @notice Returns the request name, expected as `request-{id}`.
     * @return name Request name.
     */
    function name() external view returns (string memory name);
}
