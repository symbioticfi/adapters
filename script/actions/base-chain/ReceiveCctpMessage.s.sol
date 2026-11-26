// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/ReceiveCctpMessageBase.s.sol";

contract ReceiveCctpMessageScript is ReceiveCctpMessageBaseScript {
    bytes constant MESSAGE = hex"";
    bytes constant ATTESTATION = hex"";

    /// @notice Relays an attested CCTP message. Run on the destination chain: Base for deposits, Ethereum for returns.
    function run() public {
        runBase(MESSAGE, ATTESTATION);
    }
}
