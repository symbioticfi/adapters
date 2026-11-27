// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "../../../base-chain/BaseChain.sol";

import {IMessageTransmitterV2} from "../../../utils/interfaces/ICCTPv2.sol";

import {Logs} from "../../../utils/Logs.sol";
import {ScriptBase} from "../../../utils/ScriptBase.s.sol";

/// @title ReceiveCctpMessageBase
/// @notice Base script relaying an attested CCTP v2 message on Ethereum or Base.
contract ReceiveCctpMessageBaseScript is ScriptBase {
    /**
     * @notice Calls `receiveMessage` on the local MessageTransmitter, minting USDC to the message's recipient.
     * @dev Anyone can relay, because the bridge leaves set no destination caller. Fetch `message` and `attestation`
     * from Circle's API, `GET https://iris-api.circle.com/v2/messages/<sourceDomain>?transactionHash=<burnTx>`,
     * once its status is `complete`. Run on the destination chain.
     */
    function runBase(bytes memory message, bytes memory attestation) public virtual returns (bytes memory data) {
        data = abi.encodeCall(IMessageTransmitterV2.receiveMessage, (message, attestation));
        sendTransaction(BaseChain.MESSAGE_TRANSMITTER, data);
        Logs.log(string.concat("Receive CCTP message\n    chainId:", vm.toString(block.chainid)));
        Logs.logSimulationLink(BaseChain.MESSAGE_TRANSMITTER, data);
    }
}
