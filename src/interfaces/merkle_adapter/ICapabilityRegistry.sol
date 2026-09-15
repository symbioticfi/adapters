// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICapabilityRegistry
/// @notice Interface for adapter-scoped capability approvals and immutable implementation selector lists.
interface ICapabilityRegistry {
    /// @notice Reverts when a capability's selectors have already been initialized.
    error CapabilityAlreadyInitialized();

    /// @notice Reverts when approving a capability whose selectors have not been initialized.
    error CapabilityNotInitialized();

    /// @notice Reverts when a capability selector appears more than once.
    error DuplicateSelector();

    /// @notice Reverts when a capability has no selectors.
    error EmptySelectors();

    /// @notice Reverts when the capability address has no deployed code.
    error InvalidCapability();

    /// @notice Reverts when a capability selector is zero, which is reserved for malformed or empty calls.
    error InvalidSelector();

    /// @notice Emitted when the owner initializes a capability's immutable selector list.
    /// @param capability Capability implementation address.
    /// @param selectors Selectors exposed by this capability implementation.
    event InitCapability(address indexed capability, bytes4[] selectors);

    /// @notice Emitted when an adapter-specific capability whitelist status is set.
    /// @param adapter Adapter address.
    /// @param capability Capability implementation address.
    /// @param status Whether the capability is whitelisted for the adapter.
    event SetWhitelistedStatus(address indexed adapter, address indexed capability, bool status);

    /// @notice Returns whether a capability implementation is whitelisted for an adapter.
    /// @param adapter Adapter address.
    /// @param capability Capability implementation address.
    /// @return status Whether the capability is whitelisted for the adapter.
    function isWhitelisted(address adapter, address capability) external view returns (bool status);

    /// @notice Returns whether a capability's immutable selector list has been initialized.
    /// @param capability Capability implementation address.
    /// @return initialized Whether the selector list has been initialized.
    function isInitialized(address capability) external view returns (bool initialized);

    /// @notice Returns the configured selectors in their initialization order.
    /// @param capability Capability implementation address.
    /// @return selectors Immutable capability selectors, or an empty array before initialization.
    function getCapabilitySelectors(address capability) external view returns (bytes4[] memory selectors);

    /// @notice Initializes the selectors that adapters use when adding or removing a capability.
    /// @dev Only the owner can initialize a deployed implementation. The list must be nonempty, contain
    ///      distinct nonzero selectors, and cannot be changed after initialization. This does not whitelist
    ///      the capability for any adapter or call the capability implementation.
    /// @param capability Capability implementation address.
    /// @param selectors Selectors exposed by this capability implementation.
    function initCapability(address capability, bytes4[] calldata selectors) external;

    /// @notice Sets the whitelist status of an exact adapter and capability implementation pair.
    /// @dev Only the owner can call this function. Approval requires initialized selectors; revocation
    ///      is allowed even before initialization and does not alter the immutable selector list.
    ///      Revocation prevents future additions; installed functions remain active until the adapter owner removes them.
    /// @param adapter Adapter address.
    /// @param capability Capability implementation address.
    /// @param status Whether the capability is whitelisted for the adapter.
    function setWhitelistedStatus(address adapter, address capability, bool status) external;
}
