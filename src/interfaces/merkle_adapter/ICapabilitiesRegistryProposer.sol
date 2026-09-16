// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ICapabilitiesRegistryProposer
 * @notice Interface for protocol proposals of exact implementation code and immutable selectors to curator registries.
 */
interface ICapabilitiesRegistryProposer {
    /* ERRORS */

    /**
     * @notice Raised when an implementation manifest has already been initialized.
     */
    error CapabilityAlreadyInitialized();

    /**
     * @notice Raised when proposing an implementation without an initialized manifest.
     */
    error CapabilityNotInitialized();

    /**
     * @notice Raised when a selector appears more than once.
     */
    error DuplicateSelector();

    /**
     * @notice Raised when a manifest has no selectors.
     */
    error EmptySelectors();

    /**
     * @notice Raised when an implementation has no deployed code.
     */
    error InvalidCapability();

    /**
     * @notice Raised when deployed implementation code differs from its registered runtime code hash.
     */
    error InvalidCapabilityCode();

    /**
     * @notice Raised when the proposed registry has no deployed code.
     */
    error InvalidRegistry();

    /**
     * @notice Raised when a selector is zero, which is reserved for malformed or empty calls.
     */
    error InvalidSelector();

    /* EVENTS */

    /**
     * @notice Emitted when the protocol commits an immutable implementation manifest.
     * @param capability Direct implementation address.
     * @param codeHash Hash of the implementation's runtime bytecode.
     * @param selectors Selectors exposed by the implementation, in registration order.
     */
    event InitCapability(address indexed capability, bytes32 codeHash, bytes4[] selectors);

    /**
     * @notice Emitted when the protocol proposes or withdraws an exact capability for a registry and adapter.
     * @param registry Intended curator registry.
     * @param adapter Intended adapter.
     * @param capability Direct implementation address.
     * @param status Whether the proposal is active.
     */
    event SetProposedStatus(address indexed registry, address indexed adapter, address indexed capability, bool status);

    /* FUNCTIONS */

    /**
     * @notice Returns the immutable runtime code hash, or zero for an unknown implementation.
     * @param capability Direct implementation address.
     * @return codeHash Registered runtime code hash.
     */
    function capabilityCodeHash(address capability) external view returns (bytes32 codeHash);

    /**
     * @notice Returns the protocol's proposal status for an exact registry, adapter, and implementation.
     * @dev This records intent; the accepting registry also checks that the runtime code still matches.
     * @param registry Intended curator registry.
     * @param adapter Intended adapter.
     * @param capability Direct implementation address.
     * @return status Whether the protocol has an active proposal.
     */
    function isProposed(address registry, address adapter, address capability) external view returns (bool status);

    /**
     * @notice Returns whether an implementation manifest has been initialized.
     * @param capability Direct implementation address.
     * @return initialized Whether a manifest is registered.
     */
    function isInitialized(address capability) external view returns (bool initialized);

    /**
     * @notice Returns an implementation's immutable selectors in registration order.
     * @param capability Direct implementation address.
     * @return selectors Registered selectors, or an empty array before initialization.
     */
    function getCapabilitySelectors(address capability) external view returns (bytes4[] memory selectors);

    /**
     * @notice Commits the deployed runtime code hash and selectors of an implementation once.
     * @dev Only the protocol owner may call. Requires deployed code and a nonempty list of unique,
     * nonzero selectors. New code or selectors require a new implementation address. This does not
     * propose the capability to any registry, execute its code, or grant installation permission.
     * @param capability Direct implementation address; upgradeable proxies are not supported.
     * @param selectors Selectors exposed by the implementation.
     */
    function initCapability(address capability, bytes4[] calldata selectors) external;

    /**
     * @notice Proposes or withdraws an implementation for an exact curator registry and adapter.
     * @dev Only the protocol owner may call. Proposal requires an initialized manifest, unchanged code,
     * and a deployed registry. Withdrawal blocks acceptance and future installation, but leaves
     * installed functions active until their adapter owner removes them. A proposal never accepts
     * or installs code on the curator's behalf.
     * @param registry Intended curator registry.
     * @param adapter Intended adapter.
     * @param capability Direct implementation address.
     * @param newStatus Whether the proposal is active.
     */
    function setProposedStatus(address registry, address adapter, address capability, bool newStatus) external;
}
