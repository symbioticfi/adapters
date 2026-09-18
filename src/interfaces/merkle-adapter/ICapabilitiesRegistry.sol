// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title ICapabilitiesRegistry
 * @notice Interface for curator acceptance of protocol-proposed capability code for specific adapters.
 */
interface ICapabilitiesRegistry {
    /* ERRORS */

    /**
     * @notice Raised when a capability's manifest has already been accepted.
     */
    error CapabilityAlreadyInitialized();

    /**
     * @notice Raised when approving a capability without a locally accepted manifest.
     */
    error CapabilityNotInitialized();

    /**
     * @notice Raised when the protocol has no active proposal for this registry, adapter, and capability.
     */
    error CapabilityNotProposed();

    /**
     * @notice Raised when deployed code differs from the protocol's immutable runtime code hash.
     */
    error InvalidCapabilityCode();

    /**
     * @notice Raised when selectors differ from the protocol's manifest, including their order.
     */
    error InvalidCapabilitySelectors();

    /* EVENTS */

    /**
     * @notice Emitted when the curator copies an immutable implementation manifest into this registry.
     * @param capability Direct implementation address.
     * @param codeHash Accepted runtime code hash.
     * @param selectors Accepted selectors in registration order.
     */
    event InitCapability(address indexed capability, bytes32 codeHash, bytes4[] selectors);

    /**
     * @notice Emitted when the curator sets local approval for an exact adapter and implementation.
     * @param adapter Intended adapter.
     * @param capability Direct implementation address.
     * @param status Whether the curator accepts this capability for the adapter.
     */
    event SetWhitelistedStatus(address indexed adapter, address indexed capability, bool status);

    /* FUNCTIONS */

    /**
     * @notice Returns the fixed protocol proposer trusted by this curator registry.
     * @return proposer Protocol proposer address.
     */
    function PROPOSER() external view returns (address proposer);

    /**
     * @notice Returns the locally accepted runtime code hash, or zero before initialization.
     * @param capability Direct implementation address.
     * @return codeHash Immutable runtime code hash.
     */
    function capabilityCodeHash(address capability) external view returns (bytes32 codeHash);

    /**
     * @notice Returns the curator's local approval, independently of current protocol proposal status.
     * @param adapter Intended adapter.
     * @param capability Direct implementation address.
     * @return accepted Whether the curator has accepted this exact pair.
     */
    function isAccepted(address adapter, address capability) external view returns (bool accepted);

    /**
     * @notice Returns whether an adapter may install the implementation now.
     * @dev Requires curator acceptance, an active protocol proposal scoped to this registry and adapter,
     * and unchanged implementation code. This is checked at installation, never during dispatch.
     * @param adapter Intended adapter.
     * @param capability Direct implementation address.
     * @return status Whether installation is currently permitted.
     */
    function isWhitelisted(address adapter, address capability) external view returns (bool status);

    /**
     * @notice Returns whether the curator has accepted a capability's immutable manifest.
     * @param capability Direct implementation address.
     * @return initialized Whether a manifest is stored locally.
     */
    function isInitialized(address capability) external view returns (bool initialized);

    /**
     * @notice Returns locally stored selectors, even after proposal withdrawal or local dewhitelisting.
     * @param capability Direct implementation address.
     * @return selectors Immutable selectors in registration order, or an empty array before initialization.
     */
    function getCapabilitySelectors(address capability) external view returns (bytes4[] memory selectors);

    /**
     * @notice Copies a protocol-registered manifest into this curator's registry once.
     * @dev Only the curator owner may call. Requires exactly the proposed selectors and unchanged code.
     * This alone does not authorize any adapter to install the capability or execute its code.
     * @param capability Direct implementation address.
     * @param selectors Exact selectors registered by the protocol proposer.
     */
    function initCapability(address capability, bytes4[] calldata selectors) external;

    /**
     * @notice Accepts a proposed capability for an adapter, copying its manifest if necessary.
     * @dev Only the curator owner may call. Requires a current proposal for this registry and adapter.
     * Emits InitCapability when first initialized and SetWhitelistedStatus with status true.
     * Acceptance does not install routes; the adapter owner separately calls addCapability.
     * @param adapter Intended adapter.
     * @param capability Direct implementation address.
     */
    function acceptCapability(address adapter, address capability) external;

    /**
     * @notice Sets the curator's approval of an exact adapter and implementation pair.
     * @dev Only the curator owner may call. Approval requires a locally initialized manifest, an active
     * protocol proposal, and unchanged code. Revocation is always available and leaves installed
     * functions active until the adapter owner removes them. It never changes accepted selectors.
     * @param adapter Intended adapter.
     * @param capability Direct implementation address.
     * @param newStatus Whether the curator accepts the capability for the adapter.
     */
    function setWhitelistedStatus(address adapter, address capability, bool newStatus) external;
}
