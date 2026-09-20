// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {GuardedCallsTokenMock, GuardedCallsPoolMock} from "./mocks/GuardedCallsMocks.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {
    LIQUID_LANE_REQUEST_TYPEHASH,
    LIQUID_LANE_OUTPUT_TYPEHASH
} from "src/interfaces/merkle-adapter/ILiquidLaneReactor.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/GuardedCallsMocks.sol";
import {ThreeFRequestMock} from "test/mocks/ThreeFRequestMocks.sol";
import {Token} from "test/mocks/Token.sol";

contract CapabilityIntegrationTest is CapabilityTestBase {
    function test_CapabilitiesAndSignatureApprovalsCoexistWithoutOverwritingAdapterOrEachOther() public {
        GuardedCallsTokenMock asset = new GuardedCallsTokenMock();
        Token rwa = new Token("RWA");
        _deployAdapter(address(asset));
        address vault = adapter.vault();
        asset.mint(account, 1000e18);
        GuardedCallsPoolMock pool = new GuardedCallsPoolMock(address(asset));
        asset.mint(address(pool), 1000e18);
        pool.setCollateral(account, 240e18);
        _installCapability(adapter, address(new GuardedCallsCapability()), _guardedSelectors());
        BorrowTestCall memory healthFactor = BorrowTestCall({
            target: address(new AaveHealthFactor()),
            data: abi.encodeCall(AaveHealthFactor.getHealthFactor, (address(pool), account))
        });
        _minimum = 1.2e18;

        ThreeFRequestMock request = new ThreeFRequestMock(address(asset), "request-1");
        request.authorizeMinting(account, 10e18, 1e18);
        _manage(address(asset), abi.encodeCall(IERC20.approve, (address(request), 10e18)));
        _manage(address(request), abi.encodeCall(request.mint, (uint128(10e18), uint128(1e18))));

        bytes32 typedDigest;
        {
            bytes memory encodedStruct = abi.encode(keccak256("Order(address token)"), address(asset));
            bytes32 domainSeparator = keccak256("EIP-712 domain");
            typedDigest = MessageHashUtils.toTypedDataHash(domainSeparator, keccak256(encodedStruct));
            _manage(account, abi.encodeCall(IMerkleAccount.setSignature, (domainSeparator, encodedStruct)));
        }

        bytes32 digest = _signRedemption(address(rwa), address(asset));
        _manage(
            account,
            _guardedData(
                address(pool),
                healthFactor.target,
                abi.encodeCall(pool.borrow, (address(asset), uint256(200e18), 2, 0, account)),
                healthFactor.data
            )
        );
        assertEq(_healthValue(healthFactor.target, healthFactor.data), 1.2e18);
        (uint256 pt, uint256 yt) = request.balancesOf(account);
        assertEq(pt, 10e18);
        assertEq(yt, 1e18);
        assertEq(IMerkleAccount(account).isValidSignature(typedDigest, bytes("")), IERC1271.isValidSignature.selector);
        assertEq(IMerkleAccount(account).isValidSignature(digest, bytes("")), IERC1271.isValidSignature.selector);
        assertEq(adapter.owner(), address(this));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.totalAssets(), 0);
        assertEq(adapter.getCapabilities().length, 1);
        assertTrue(adapter.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertEq(adapter.getRoleMemberCount(bytes32(0)), 1);
        assertEq(adapter.getRoleMember(bytes32(0), 0), address(this));
        assertEq(asset.balanceOf(account), 1190e18);
    }

    function _signRedemption(address rwa, address asset) internal returns (bytes32) {
        bytes32 domain = keccak256("Reactor domain");
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            domain,
            keccak256(
                abi.encode(
                    LIQUID_LANE_REQUEST_TYPEHASH,
                    rwa,
                    uint256(100e18),
                    keccak256(
                        abi.encode(keccak256(abi.encode(LIQUID_LANE_OUTPUT_TYPEHASH, asset, uint256(95e18), account)))
                    ),
                    block.timestamp + 1 hours,
                    uint256(7),
                    address(0xBEEF)
                )
            )
        );
        _manage(
            account,
            abi.encodeCall(
                IMerkleAccount.setSignature,
                (
                    domain,
                    abi.encode(
                        LIQUID_LANE_REQUEST_TYPEHASH,
                        rwa,
                        uint256(100e18),
                        asset,
                        uint256(95e18),
                        account,
                        block.timestamp + 1 hours,
                        uint256(7),
                        address(0xBEEF)
                    )
                )
            )
        );
        return digest;
    }
}
