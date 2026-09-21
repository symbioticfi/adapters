// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Token} from "test/mocks/Token.sol";

contract MerkleWithdrawalReceipt is ERC721 {
    constructor() ERC721("Withdrawal receipt", "RECEIPT") {}

    function mint(address recipient, uint256 tokenId) public {
        _safeMint(recipient, tokenId);
    }

    function mintAndManage(address recipient, IMerkleAccount.Action[] calldata actions) public {
        _safeMint(recipient, 1);
        IMerkleAccount(recipient).manage(actions);
    }
}

contract MerkleAccountNFTsTest is CapabilityTestBase {
    address internal _token;
    address internal _receipt;

    function setUp() public {
        _token = address(new Token("asset"));
        _receipt = address(new MerkleWithdrawalReceipt());
        _deployAdapter(_token);
    }

    function test_ApprovedIssuerCanSafeMintWithdrawalReceiptDuringManage() public {
        _manage(_receipt, abi.encodeCall(MerkleWithdrawalReceipt.mint, (account, 1)));
        assertEq(ERC721(_receipt).ownerOf(1), account);
        assertEq(ERC721(_receipt).balanceOf(account), 1);
        assertEq(IMerkleAccount(account).getCapabilities().length, 0);
    }

    function test_ReceivingReceiptDoesNotGrantIssuerManagementAccess() public {
        IERC20(_token).transfer(account, 10);
        IMerkleAccount.Action[] memory actions =
            _publishCall(_token, abi.encodeCall(IERC20.transfer, (address(0xBAD), 10)));
        bytes32 leaf = IMerkleAccount(account).merkleRoot();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _receipt, leaf)
        );
        MerkleWithdrawalReceipt(_receipt).mintAndManage(account, actions);
        assertEq(IERC20(_token).balanceOf(account), 10);
        assertEq(ERC721(_receipt).balanceOf(account), 0);
        assertFalse(IMerkleAccount(account).hasRole(leaf, _receipt));
    }
}
