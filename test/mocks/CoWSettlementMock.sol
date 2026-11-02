// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @dev Models only GPv2 pre-signature ownership. Fork tests use the real settlement and relayer.
contract CoWSettlementMock {
    mapping(bytes orderUid => uint256 value) public preSignature;

    function setPreSignature(bytes calldata orderUid, bool signed) public {
        require(orderUid.length == 56, "GPv2: invalid uid");
        require(address(bytes20(orderUid[32:52])) == msg.sender, "GPv2: cannot presign order");
        preSignature[orderUid] = signed ? uint256(keccak256("GPv2Signing.Scheme.PreSign")) : 0;
    }
}
