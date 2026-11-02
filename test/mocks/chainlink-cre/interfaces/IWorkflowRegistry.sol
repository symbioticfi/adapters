// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev Read/admin ABI for the pinned upstream test reference deployed with `deployCode`.
interface IWorkflowRegistry {
    enum WorkflowStatus {
        ACTIVE,
        PAUSED
    }

    error WorkflowDoesNotExist();
    error BinaryURLRequired();
    error DonLimitNotSet(string donFamily);
    error OwnershipLinkDoesNotExist(address owner);
    error LinkOwnerRequestExpired(address caller, uint256 currentTime, uint256 expiryTimestamp);
    error WorkflowIDAlreadyExists(bytes32 workflowId);

    struct WorkflowMetadataView {
        bytes32 workflowId;
        address owner;
        uint64 createdAt;
        WorkflowStatus status;
        string workflowName;
        string binaryUrl;
        string configUrl;
        string tag;
        bytes attributes;
        string donFamily;
    }

    function owner() external view returns (address);
    function typeAndVersion() external view returns (string memory);
    function updateAllowedSigners(address[] calldata signers, bool allowed) external;
    function setDONLimit(string calldata donFamily, uint32 donLimit, uint32 userDefaultLimit) external;
    function adminPauseWorkflow(bytes32 workflowId) external;
    function unlinkOwner(address owner, uint256 expiry, bytes calldata signature) external;
    function getWorkflowById(bytes32 id) external view returns (WorkflowMetadataView memory);
    function isOwnerLinked(address owner) external view returns (bool);
    function isRequestAllowlisted(address owner, bytes32 digest) external view returns (bool);
    function totalActiveWorkflowsOnDON(string calldata donFamily) external view returns (uint256);
    function totalActiveWorkflowsByOwner(address owner) external view returns (uint256);
}
