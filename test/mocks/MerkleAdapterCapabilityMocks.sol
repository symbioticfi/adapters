// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @dev A delegatecall module whose state belongs to each adapter, at its own namespace.
contract MerkleAdapterStateCapabilityMock {
    bytes32 private constant _STORAGE_SLOT = keccak256("test.merkle-adapter.state-capability");

    struct State {
        uint256 value;
        address sender;
        uint256 callValue;
        address context;
    }

    /// @dev Records the call context in the adapter's namespaced storage.
    function setCapabilityValue(uint256 value) external payable {
        State storage state = _state();
        state.value = value;
        state.sender = msg.sender;
        state.callValue = msg.value;
        state.context = address(this);
    }

    /// @dev Reads the namespaced state without changing dispatch or module storage.
    function capabilityState() external view returns (uint256, address, uint256, address) {
        State storage state = _state();
        return (state.value, state.sender, state.callValue, state.context);
    }

    /// @dev Returns arbitrary bytes without Solidity's dynamic-bytes ABI wrapper.
    function returnRaw(bytes calldata data) external pure {
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            calldatacopy(pointer, data.offset, data.length)
            return(pointer, data.length)
        }
    }

    /// @dev Reverts with arbitrary bytes after writing, to exercise rollback through both proxies.
    function writeThenRevert(uint256 value, bytes calldata data) external payable {
        _state().value = value;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            calldatacopy(pointer, data.offset, data.length)
            revert(pointer, data.length)
        }
    }

    /// @dev Locates storage without relying on the adapter's ordinary slot layout.
    function _state() private pure returns (State storage state) {
        bytes32 slot = _STORAGE_SLOT;
        assembly ("memory-safe") {
            state.slot := slot
        }
    }
}

/// @dev Echoes raw calldata for explicitly registered padded-selector edge cases.
contract MerkleAdapterRawFallbackCapabilityMock {
    /// @dev Echoing a full padded selector proves the module would accept short calldata if dispatch allowed it.
    fallback(bytes calldata data) external returns (bytes memory) {
        return data;
    }
}

/// @dev A callback-only capability that validates delegatecall context under STATICCALL.
contract MerkleAdapterSignatureCapabilityMock is IERC1271 {
    /// @dev The signature names the expected adapter and callback caller for a fixed digest.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address expectedAdapter, address expectedCaller) = abi.decode(signature, (address, address));
        if (
            hash == keccak256("merkle adapter callback") && address(this) == expectedAdapter
                && msg.sender == expectedCaller
        ) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}

/// @dev Models a protocol invoking the adapter's ERC-1271 callback with STATICCALL.
contract MerkleAdapterSignatureCallerMock {
    /// @dev Calls the standard view interface, forcing the EVM static execution flag.
    function checkSignature(address adapter, bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return IERC1271(adapter).isValidSignature(hash, signature);
    }
}
