// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ITokenMessengerV2
 * @notice Minimal interface for Circle's CCTP v2 TokenMessenger.
 */
interface ITokenMessengerV2 {
    /**
     * @notice Burns tokens from the caller and emits a message to mint them on the destination domain.
     * @param amount Amount to burn.
     * @param destinationDomain CCTP domain of the destination chain.
     * @param mintRecipient Recipient on the destination domain, left-padded to 32 bytes.
     * @param burnToken Token to burn.
     * @param destinationCaller Only caller allowed to relay on the destination, or zero for anyone.
     * @param maxFee Maximum fee paid on the destination domain, in burned tokens.
     * @param minFinalityThreshold Finality required before attestation: 1000 is Fast, 2000 is Standard.
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    /**
     * @notice Returns the local MessageTransmitter.
     * @return transmitter Local MessageTransmitter.
     */
    function localMessageTransmitter() external view returns (address transmitter);
}

/**
 * @title IMessageTransmitterV2
 * @notice Minimal interface for Circle's CCTP v2 MessageTransmitter.
 */
interface IMessageTransmitterV2 {
    /**
     * @notice Returns the CCTP domain of this chain.
     * @return domain Local CCTP domain.
     */
    function localDomain() external view returns (uint32 domain);

    /**
     * @notice Relays an attested message and mints the burned tokens to its recipient.
     * @param message Message emitted on the source domain.
     * @param attestation Circle attestation of the message.
     * @return success Whether the message was received.
     */
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}
