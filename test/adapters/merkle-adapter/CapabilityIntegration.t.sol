// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {BorrowCapability} from "src/contracts/merkle_adapter/BorrowCapability.sol";
import {ThreeFCapability} from "src/contracts/merkle_adapter/ThreeFCapability.sol";
import {CoWSwapCapability} from "src/contracts/merkle_adapter/CoWSwapCapability.sol";
import {LiquidLaneRedeemCapability} from "src/contracts/merkle_adapter/LiquidLaneRedeemCapability.sol";
import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";
import {IThreeFCapability} from "src/interfaces/merkle_adapter/IThreeFCapability.sol";
import {ICoWSwapCapability} from "src/interfaces/merkle_adapter/ICoWSwapCapability.sol";
import {ILiquidLaneRedeemCapability} from "src/interfaces/merkle_adapter/ILiquidLaneRedeemCapability.sol";
import {ILiquidLaneReactor} from "src/interfaces/merkle_adapter/ILiquidLaneReactor.sol";
import {IAssetRateLimits} from "src/interfaces/merkle_adapter/IAssetRateLimits.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {BorrowCapabilityTokenMock, BorrowCapabilityPoolMock} from "./mocks/BorrowCapabilityMocks.sol";
import {CoWCapabilitySettlementMock} from "test/mocks/CoWSwapCapabilityMocks.sol";
import {
    ThreeFCapabilityWhitelistMock,
    ThreeFCapabilityFacilityMock,
    ThreeFCapabilityRequestMock,
    ThreeFCapabilityPositionManagerMock,
    ThreeFCapabilityCollateralMock
} from "test/mocks/ThreeFCapabilityPushMocks.sol";
import {Token} from "test/mocks/Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

contract CapabilityIntegrationTest is CapabilityTestBase {
    function test_AllFourCapabilitiesCoexistWithoutOverwritingAdapterOrEachOther() public {
        BorrowCapabilityTokenMock asset = new BorrowCapabilityTokenMock();
        Token rwa = new Token("RWA");
        _deployAdapter(address(asset));
        address vault = adapter.vault();
        asset.mint(address(adapter), 1000e18);
        BorrowCapabilityPoolMock pool = new BorrowCapabilityPoolMock(address(asset));
        asset.mint(address(pool), 1000e18);
        pool.setCollateral(address(adapter), 240e18);
        _installCapability(
            adapter,
            IImmutableFactory(address(new ImmutableFactory(type(BorrowCapability).creationCode))).create(""),
            _borrowSelectors()
        );
        _manage(
            address(adapter),
            abi.encodeCall(
                IBorrowCapability.initializeBorrow,
                (IBorrowCapability.InitParams(
                        address(pool),
                        pool.borrow.selector,
                        address(asset),
                        address(pool),
                        abi.encodeCall(pool.getUserAccountData, (address(adapter))),
                        160,
                        1.2e18
                    ))
            )
        );

        ThreeFCapabilityWhitelistMock whitelist = new ThreeFCapabilityWhitelistMock();
        ThreeFCapabilityFacilityMock facility = new ThreeFCapabilityFacilityMock();
        ThreeFCapabilityRequestMock request = new ThreeFCapabilityRequestMock(address(asset), "request-1");
        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.Whitelisted);
        facility.setIntent(
            1,
            address(request),
            address(new ThreeFCapabilityPositionManagerMock(address(new ThreeFCapabilityCollateralMock(address(rwa))))),
            true
        );
        _installCapability(
            adapter, address(new ThreeFCapability(address(whitelist), address(facility))), _threeFSelectors()
        );
        _manage(
            address(adapter), abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (address(rwa), 20e18, 1 days))
        );
        request.authorizeMinting(address(adapter), 10e18, 1e18);
        _manage(address(asset), abi.encodeCall(IERC20.approve, (address(request), 10e18)));
        _manage(
            address(adapter),
            abi.encodeCall(IThreeFCapability.mintRequest, (address(request), 10e18, 1e18, block.timestamp))
        );

        CoWCapabilitySettlementMock settlement = new CoWCapabilitySettlementMock();
        _installCapability(adapter, address(new CoWSwapCapability(address(settlement))), _cowSelectors());
        bytes memory orderUid = abi.decode(
            _manage(
                address(adapter),
                abi.encodeCall(
                    ICoWSwapCapability.convert,
                    (
                        address(asset),
                        100e18,
                        address(rwa),
                        ICoWSwapCapability.OrderParams(95e18, uint32(block.timestamp + 1800), bytes32(0))
                    )
                )
            ),
            (bytes)
        );

        bytes32 digest = _signRedemption(address(rwa));
        _manage(
            address(adapter),
            abi.encodeCall(
                IBorrowCapability.borrow,
                (abi.encodeCall(pool.borrow, (address(asset), 200e18, 2, 0, address(adapter))))
            )
        );
        assertEq(BorrowCapability(address(adapter)).getHealthFactor(), 1.2e18);
        assertEq(ThreeFCapability(address(adapter)).pendingAssets(address(request)), 10e18);
        assertEq(ThreeFCapability(address(adapter)).remainingAssets(address(rwa)), 10e18);
        assertEq(ThreeFCapability(address(adapter)).threeFPositionAssets(), 10e18);
        assertEq(CoWSwapCapability(address(adapter)).activeOrderUid(address(asset)), orderUid);
        assertGt(settlement.preSignature(orderUid), 0);
        assertEq(LiquidLaneRedeemCapability(address(adapter)).activeRequest(address(rwa)), digest);
        assertEq(
            LiquidLaneRedeemCapability(address(adapter)).isValidSignature(digest, hex"1234"),
            IERC1271.isValidSignature.selector
        );
        assertEq(adapter.owner(), address(this));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.totalAssets(), 0);
        assertEq(adapter.getCapabilities().length, 4);
        assertTrue(adapter.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertEq(adapter.getRoleMemberCount(bytes32(0)), 1);
        assertEq(adapter.getRoleMember(bytes32(0), 0), address(this));
        assertEq(asset.balanceOf(address(adapter)), 1190e18);
    }

    function _signRedemption(address rwa) internal returns (bytes32) {
        address reactor = address(new CapabilityNonceReactor());
        address protocol = address(0xBEEF);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = ILiquidLaneRedeemCapability.REACTOR.selector;
        selectors[1] = ILiquidLaneRedeemCapability.PROTOCOL.selector;
        selectors[2] = ILiquidLaneRedeemCapability.activeRequest.selector;
        selectors[3] = ILiquidLaneRedeemCapability.signatures.selector;
        selectors[4] = ILiquidLaneRedeemCapability.signRequest.selector;
        selectors[5] = ILiquidLaneRedeemCapability.revokeRequest.selector;
        selectors[6] = ILiquidLaneRedeemCapability.finalizeRequest.selector;
        selectors[7] = ILiquidLaneRedeemCapability.hashRequest.selector;
        selectors[8] = IERC1271.isValidSignature.selector;
        _installCapability(adapter, address(new LiquidLaneRedeemCapability(reactor, protocol)), selectors);
        ILiquidLaneReactor.Output[] memory outputs = new ILiquidLaneReactor.Output[](1);
        outputs[0] =
            ILiquidLaneReactor.Output(BorrowCapability(address(adapter)).borrowAsset(), 95e18, address(adapter));
        ILiquidLaneReactor.Request memory request =
            ILiquidLaneReactor.Request(rwa, 100e18, outputs, block.timestamp + 1 hours, 7, protocol);
        return abi.decode(
            _manage(address(adapter), abi.encodeCall(ILiquidLaneRedeemCapability.signRequest, (request, hex"1234"))),
            (bytes32)
        );
    }
}

/// @dev Only the external nonce-read boundary is needed; full Reactor settlement has a dedicated integration suite.
contract CapabilityNonceReactor {
    function isUsedNonce(address, uint256) external pure returns (bool) {
        return false;
    }
}
