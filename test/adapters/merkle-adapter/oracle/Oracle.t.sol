// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {Oracle} from "src/contracts/merkle-adapter/oracle/Oracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IOracle} from "src/interfaces/merkle-adapter/oracle/IOracle.sol";
import {ORACLE_AGE_ROLE, ORACLE_GUARD_ROLE, ORACLE_LIMITS_ROLE} from "src/interfaces/merkle-adapter/oracle/IOracle.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {IReceiver} from "test/mocks/chainlink-cre/interfaces/IReceiver.sol";
import {IRouter} from "test/mocks/chainlink-cre/interfaces/IRouter.sol";
import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";
import {
    MerkleAdapterVaultRegistry,
    MerkleAdapterVaultMock,
    MerkleAdapterDelegatorMock
} from "test/adapters/MerkleAdapter.t.sol";
import {Token} from "test/mocks/Token.sol";
import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";

abstract contract OracleTestBase is Test {
    bytes32 constant WORKFLOW = keccak256("approved NAV workflow");
    KeystoneForwarder internal forwarder;
    MigratablesFactory internal factory;
    Oracle internal oracle;
    Oracle internal implementation;
    MerkleAdapter internal adapter;
    address internal account;
    MerkleAdapterDelegatorMock internal delegator;
    Token internal asset;

    function setUp() public virtual {
        vm.warp(10_000);
        vm.roll(500);
        forwarder = new KeystoneForwarder();
        address[] memory signers = new address[](4);
        for (uint256 i; i < 4; ++i) {
            signers[i] = vm.addr(i + 1);
        }
        forwarder.setConfig(1, 1, 1, signers);
        factory = new MigratablesFactory(address(this));
        implementation = new Oracle(address(factory), address(forwarder), 100);
        factory.whitelist(address(implementation));
        MerkleAdapterVaultRegistry vaultFactory = new MerkleAdapterVaultRegistry();
        asset = new Token("Asset");
        MerkleAdapterVaultMock vault = new MerkleAdapterVaultMock(address(asset));
        delegator = new MerkleAdapterDelegatorMock(address(vault));
        vault.setDelegator(address(delegator));
        vaultFactory.add(address(vault));
        AdapterFactory adapterFactory = new AdapterFactory(address(this));
        adapterFactory.whitelist(
            address(
                new MerkleAdapter(
                    address(vaultFactory),
                    address(adapterFactory),
                    address(factory),
                    createMerkleAccountFactory(
                        address(this),
                        address(new RootRegistry(address(this))),
                        address(new CapabilitiesRegistry(address(this)))
                    )
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapterFactory.create(
                    1,
                    address(this),
                    abi.encode(
                        address(vault), abi.encode(IMerkleAdapter.InitParams({defaultAdminRoleHolder: address(this)}))
                    )
                ))
        );
        account = adapter.account();
        oracle = Oracle(adapter.oracle());
        oracle.proposeWorkflow(WORKFLOW);
        oracle.acceptWorkflow(WORKFLOW);
        MerkleAccount(payable(account)).grantRole(ORACLE_GUARD_ROLE, address(this));
    }

    function _approveReport(IOracle.Report memory update) internal {
        oracle.unfreezeOracle(keccak256(abi.encode(update)));
    }

    function _report(uint256 assets) internal view returns (IOracle.Report memory) {
        return IOracle.Report({
            chainId: block.chainid,
            oracle: address(oracle),
            adapter: address(adapter),
            nonce: oracle.nonce() + 1,
            totalAssets: assets,
            snapshotBlock: block.number - 1,
            snapshotTimestamp: block.timestamp - 1
        });
    }

    function _metadata() internal view returns (bytes memory) {
        return abi.encodePacked(WORKFLOW, bytes10("nav"), address(this));
    }

    function _deliver(IOracle.Report memory update) internal {
        bytes memory payload = abi.encode(update);
        vm.prank(address(forwarder));
        oracle.onReport(_metadata(), payload);
    }

    function _expectReportError(IOracle.Report memory update, bytes4 errorSelector) internal {
        bytes memory payload = abi.encode(update);
        vm.prank(address(forwarder));
        vm.expectRevert(errorSelector);
        oracle.onReport(_metadata(), payload);
    }

    function _signedReport(IOracle.Report memory update, bytes32 workflow)
        internal
        returns (bytes memory raw, bytes[] memory signatures)
    {
        return _signedReport(update, workflow, bytes32(update.nonce));
    }

    function _signedReport(IOracle.Report memory update, bytes32 workflow, bytes32 executionId)
        internal
        returns (bytes memory raw, bytes[] memory signatures)
    {
        raw = abi.encodePacked(
            uint8(1),
            executionId,
            uint32(block.timestamp),
            uint32(1),
            uint32(1),
            workflow,
            bytes10("nav"),
            address(this),
            bytes2(0),
            abi.encode(update)
        );
        bytes32 digest = keccak256(abi.encodePacked(keccak256(raw)));
        signatures = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(i + 1, digest);
            signatures[i] = abi.encodePacked(r, s, uint8(v - 27));
        }
    }
}

contract OracleTest is OracleTestBase {
    function test_AdapterCreatesOracleThroughExistingFactoryPayload() public view {
        assertEq(oracle.adapter(), address(adapter));
        assertEq(oracle.owner(), address(this));
        assertEq(oracle.version(), 1);
        assertEq(oracle.FORWARDER(), address(forwarder));
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(oracle.nonce(), 0);
        assertEq(oracle.totalAssets(), 0);
        assertTrue(oracle.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(0xffffffff));
    }

    function test_KeystoneForwarderVerifiesSignaturesAndDeliversProductionMetadata() public {
        IOracle.Report memory update = _report(645e6);
        _approveReport(update);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.totalAssets(), 645e6);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.snapshotTimestamp(), 9999);
        IRouter.TransmissionInfo memory info =
            forwarder.getTransmissionInfo(address(oracle), bytes32(update.nonce), bytes2(0));
        assertTrue(info.success);
        assertEq(uint256(info.state), uint256(IRouter.TransmissionState.SUCCEEDED));
        vm.expectRevert(abi.encodeWithSelector(IRouter.AlreadyAttempted.selector, info.transmissionId));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
    }

    function test_ForwarderRejectsUntrustedSignatureWithoutUpdatingOracle() public {
        (bytes memory raw, bytes[] memory signatures) = _signedReport(_report(100), WORKFLOW);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(99, keccak256(abi.encodePacked(keccak256(raw))));
        signatures[0] = abi.encodePacked(r, s, uint8(v - 27));
        vm.expectRevert(abi.encodeWithSelector(KeystoneForwarder.InvalidSigner.selector, vm.addr(99)));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.nonce(), 0);
    }

    function test_ForwarderRecordsWrongWorkflowAsFailedAndAllowsCorrectRetry() public {
        _approveReport(_report(100));
        (bytes memory raw, bytes[] memory signatures) = _signedReport(_report(100), bytes32(uint256(1)));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.nonce(), 0);
        assertFalse(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(1)), bytes2(0)).success);
        (raw, signatures) = _signedReport(_report(100), WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.totalAssets(), 100);
    }

    function test_OwnerAndOtherCallersCannotSubmitDirectly() public {
        bytes memory payload = abi.encode(_report(100));
        vm.expectRevert(IOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), payload);
        vm.prank(address(adapter));
        vm.expectRevert(IOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), payload);
    }

    function testFuzz_RejectsMalformedMetadata(uint8 length) public {
        vm.assume(length != 62 && length != 64);
        bytes memory metadata = new bytes(length);
        bytes memory payload = abi.encode(_report(100));
        vm.prank(address(forwarder));
        vm.expectRevert(IOracle.InvalidWorkflow.selector);
        oracle.onReport(metadata, payload);
    }

    function test_Accepts62ByteIdentityMetadataAndZeroNAV() public {
        _deliver(_report(0));
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.totalAssets(), 0);
    }

    function testFuzz_RejectsWrongDestination(uint8 field) public {
        IOracle.Report memory update = _report(100);
        field = uint8(bound(field, 0, 2));
        if (field == 0) update.chainId += 1;
        else if (field == 1) update.oracle = address(adapter);
        else update.adapter = address(oracle);
        _expectReportError(update, IOracle.InvalidReport.selector);
    }

    function test_RejectsTruncatedAndTrailingReportData() public {
        bytes memory payload = abi.encode(_report(100));
        vm.prank(address(forwarder));
        vm.expectRevert(IOracle.InvalidReport.selector);
        oracle.onReport(_metadata(), bytes.concat(payload, hex"00"));
        vm.prank(address(forwarder));
        vm.expectRevert(IOracle.InvalidReport.selector);
        oracle.onReport(_metadata(), hex"00");
    }

    function test_RejectsRepeatedAndSkippedEpochs() public {
        IOracle.Report memory update = _report(100);
        update.nonce = 0;
        _expectReportError(update, IOracle.InvalidNonce.selector);
        update.nonce = 2;
        _expectReportError(update, IOracle.InvalidNonce.selector);
        update.nonce = 1;
        _approveReport(update);
        _deliver(update);
        _expectReportError(update, IOracle.InvalidNonce.selector);
    }

    function test_RejectsOldAndFutureSnapshotsAtExactAgeBoundary() public {
        IOracle.Report memory update = _report(100);
        update.snapshotTimestamp = block.timestamp - 101;
        _expectReportError(update, IOracle.StaleReport.selector);
        update.snapshotTimestamp = block.timestamp + 1;
        _expectReportError(update, IOracle.StaleReport.selector);
        update.snapshotTimestamp = block.timestamp - 100;
        update.snapshotBlock = block.number;
        _expectReportError(update, IOracle.StaleReport.selector);
        update.snapshotBlock = 0;
        _expectReportError(update, IOracle.StaleReport.selector);
        update.snapshotBlock = block.number - 1;
        _approveReport(update);
        _deliver(update);
        assertEq(oracle.totalAssets(), 100);
    }

    function test_RejectsNonAdvancingSnapshotEvenForNextEpoch() public {
        IOracle.Report memory update = _report(100);
        _approveReport(update);
        _deliver(update);
        update.nonce = 2;
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _expectReportError(update, IOracle.StaleReport.selector);
        update.snapshotBlock += 1;
        _expectReportError(update, IOracle.StaleReport.selector);
        update.snapshotTimestamp += 1;
        _deliver(update);
        assertEq(oracle.nonce(), 2);
    }

    function test_NAVReserveReconciliationAcrossAllocationAndDeallocationEpochs() public {
        _deliver(_report(0));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        asset.transfer(adapter.vault(), 100);
        delegator.allocate(address(adapter), 100);
        _deliver(_report(0)); // The first epoch after allocation still reserves it.
        assertEq(adapter.totalAssets(), 100);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _deliver(_report(100)); // The next epoch incorporates that allocation into NAV.
        assertEq(adapter.totalAssets(), 100);
        delegator.requestDeallocate(address(adapter), 40);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _deliver(_report(100)); // The first epoch after withdrawal has not matured its reserve.
        assertEq(adapter.totalAssets(), 100);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _deliver(_report(60)); // The next epoch excludes the matured 40-unit reserve.
        assertEq(adapter.totalAssets(), 100);
        MerkleAccount(payable(account)).manage(new IMerkleAccount.Action[](0));
        assertEq(adapter.deallocatableAt(oracle.nonce()), 40);
        assertEq(delegator.deallocate(address(adapter), 40), 40);
        assertEq(adapter.totalAssets(), 60);
    }

    function test_MigrationPreservesAccountingWorkflowProposalAndGuard() public {
        _approveReport(_report(100));
        _deliver(_report(100));
        bytes32 nextWorkflow = keccak256("next approved workflow");
        oracle.proposeWorkflow(nextWorkflow);
        oracle.freezeOracle();
        MerkleAccount(payable(account)).grantRole(ORACLE_LIMITS_ROLE, address(this));
        MerkleAccount(payable(account)).grantRole(ORACLE_AGE_ROLE, address(this));
        oracle.setOracleLimits(100, 200);
        oracle.setMaxOracleAge(1 hours);
        factory.whitelist(address(new Oracle(address(factory), address(forwarder), 200)));
        factory.migrate(address(oracle), 2, bytes(""));
        assertEq(oracle.adapter(), address(adapter));
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.totalAssets(), 100);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.snapshotTimestamp(), 9999);
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(oracle.proposedWorkflowId(), nextWorkflow);
        assertEq(oracle.MAX_REPORT_AGE(), 200);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.maxOracleGrowthBps(), 100);
        assertEq(oracle.maxOracleLossBps(), 200);
        assertEq(oracle.maxOracleAge(), 1 hours);
    }

    function test_ConstructorAcceptsUncheckedInputsAndLifecycleStillValidates() public {
        Oracle uncheckedOracle = new Oracle(address(factory), address(0), 0);
        assertEq(uncheckedOracle.FORWARDER(), address(0));
        assertEq(uncheckedOracle.workflowId(), bytes32(0));
        assertEq(uncheckedOracle.MAX_REPORT_AGE(), 0);
        vm.expectRevert(IOracle.InvalidAdapter.selector);
        factory.create(1, address(this), abi.encode(address(0)));
        vm.expectRevert(IMigratableEntity.AlreadyInitialized.selector);
        implementation.initialize(1, address(this), abi.encode(address(adapter)));
        factory.whitelist(address(new Oracle(address(factory), address(forwarder), 100)));
        vm.expectRevert(IOracle.InvalidMigrationData.selector);
        factory.migrate(address(oracle), 2, hex"01");
        assertEq(oracle.version(), 1);
    }
}
