// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {GuardedCallsTokenMock, GuardedCallsPoolMock} from "./mocks/GuardedCallsMocks.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {
    LiquidLaneSignatureValidator
} from "src/contracts/merkle-adapter/signature-validators/LiquidLaneSignatureValidator.sol";

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {ICoWSwapSettlement} from "src/interfaces/common/ICoWSwapConverter.sol";
import {ILiquidLaneReactor} from "src/interfaces/merkle-adapter/signature-validators/ILiquidLaneReactor.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/GuardedCallsMocks.sol";
import {CoWSettlementMock} from "test/mocks/CoWSettlementMock.sol";
import {ThreeFRequestMock} from "test/mocks/ThreeFRequestMocks.sol";
import {Token} from "test/mocks/Token.sol";

contract CapabilityIntegrationTest is CapabilityTestBase {
    function test_CapabilitiesAndDirectCoWCallsCoexistWithoutOverwritingAdapterOrEachOther() public {
        GuardedCallsTokenMock asset = new GuardedCallsTokenMock();
        Token rwa = new Token("RWA");
        _deployAdapter(address(asset));
        address vault = adapter.vault();
        asset.mint(address(adapter), 1000e18);
        GuardedCallsPoolMock pool = new GuardedCallsPoolMock(address(asset));
        asset.mint(address(pool), 1000e18);
        pool.setCollateral(address(adapter), 240e18);
        _installCapability(adapter, address(new GuardedCallsCapability()), _guardedSelectors());
        BorrowTestCall memory healthFactor = BorrowTestCall(
            address(new AaveHealthFactor()),
            abi.encodeCall(AaveHealthFactor.getHealthFactor, (address(pool), address(adapter)))
        );
        _minimum = 1.2e18;

        ThreeFRequestMock request = new ThreeFRequestMock(address(asset), "request-1");
        request.authorizeMinting(address(adapter), 10e18, 1e18);
        _manage(address(asset), abi.encodeCall(IERC20.approve, (address(request), 10e18)));
        _manage(address(request), abi.encodeCall(request.mint, (uint128(10e18), uint128(1e18))));

        CoWSettlementMock settlement = new CoWSettlementMock();
        bytes memory orderUid = abi.encodePacked(keccak256("order"), address(adapter), uint32(block.timestamp + 1800));
        _manage(address(settlement), abi.encodeCall(ICoWSwapSettlement.setPreSignature, (orderUid, true)));

        bytes32 digest = _signRedemption(address(rwa), address(asset));
        _manage(
            address(adapter),
            _guardedData(
                address(pool),
                healthFactor.target,
                abi.encodeCall(pool.borrow, (address(asset), uint256(200e18), 2, 0, address(adapter))),
                healthFactor.data
            )
        );
        assertEq(_healthValue(healthFactor.target, healthFactor.data), 1.2e18);
        (uint256 pt, uint256 yt) = request.balancesOf(address(adapter));
        assertEq(pt, 10e18);
        assertEq(yt, 1e18);
        assertGt(settlement.preSignature(orderUid), 0);
        assertEq(adapter.isValidSignature(digest, adapter.signatures(digest)), IERC1271.isValidSignature.selector);
        assertEq(adapter.owner(), address(this));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.totalAssets(), 0);
        assertEq(adapter.getCapabilities().length, 1);
        assertTrue(adapter.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertEq(adapter.getRoleMemberCount(bytes32(0)), 1);
        assertEq(adapter.getRoleMember(bytes32(0), 0), address(this));
        assertEq(asset.balanceOf(address(adapter)), 1190e18);
    }

    function _signRedemption(address rwa, address asset) internal returns (bytes32) {
        address reactor = address(new CapabilityNonceReactor());
        address protocol = address(0xBEEF);
        address validator = address(new LiquidLaneSignatureValidator(reactor, protocol));
        ILiquidLaneReactor.Output[] memory outputs = new ILiquidLaneReactor.Output[](1);
        outputs[0] = ILiquidLaneReactor.Output(asset, 95e18, address(adapter));
        ILiquidLaneReactor.Request memory request =
            ILiquidLaneReactor.Request(rwa, 100e18, outputs, block.timestamp + 1 hours, 7, protocol);
        bytes32 digest = LiquidLaneSignatureValidator(validator).hashRequest(request);
        _manage(
            address(adapter),
            abi.encodeCall(IMerkleAdapter.setSignature, (digest, abi.encode(validator, abi.encode(request))))
        );
        return digest;
    }
}

/// @dev Only the external nonce-read boundary is needed; full Reactor settlement has a dedicated integration suite.
contract CapabilityNonceReactor {
    function isUsedNonce(address, uint256) external pure returns (bool) {
        return false;
    }
}
