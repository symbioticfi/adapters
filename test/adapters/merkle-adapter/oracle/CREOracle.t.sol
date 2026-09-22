// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {merkleAdapterInitParams, defaultOracleInitParams} from "test/helpers/MerkleInitialization.sol";

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ORACLE_GUARD_ROLE, ORACLE_LIMITS_ROLE} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {StdStorage, stdStorage, Test} from "forge-std/Test.sol";

import {CREWorkflowRegistryTestHelper} from "test/helpers/CREWorkflowRegistry.sol";

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

abstract contract CREOracleTestBase is CREWorkflowRegistryTestHelper {
    using stdStorage for StdStorage;
    bytes32 constant WORKFLOW = keccak256("approved NAV workflow");
    KeystoneForwarder internal forwarder;
    MigratablesFactory internal factory;
    CREOracle internal oracle;
    CREOracle internal implementation;
    MerkleAdapter internal adapter;
    address internal account;
    MerkleAdapterDelegatorMock internal delegator;
    Token internal asset;

    function setUp() public virtual {
        _setUpReportContext();
        _setUpWorkflowRegistry();
        forwarder = new KeystoneForwarder();
        address[] memory signers = new address[](4);
        for (uint256 i; i < 4; ++i) {
            signers[i] = vm.addr(i + 1);
        }
        forwarder.setConfig(1, 1, 1, signers);
        factory = new MigratablesFactory(address(this));
        implementation =
            new CREOracle(address(factory), address(workflowRegistry), address(forwarder), 100, 1 days, 100, 10);
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
                        address(adapterFactory),
                        address(new RootRegistry(address(this))),
                        address(new CapabilitiesRegistry(address(this)))
                    )
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapterFactory.create(
                    1, address(this), abi.encode(address(vault), abi.encode(merkleAdapterInitParams(address(this))))
                ))
        );
        account = adapter.account();
        oracle = CREOracle(adapter.oracle());
        _setUpAcceptedWorkflow();
        oracle.grantRole(ORACLE_GUARD_ROLE, address(this));
    }

    function _setUpAcceptedWorkflow() internal virtual {
        _proposeWorkflow(address(oracle), WORKFLOW);
        _acceptWorkflow(address(oracle), WORKFLOW);
    }

    function _setUpReportContext() internal virtual {
        vm.warp(10_000);
        vm.roll(500);
    }

    function _migrateWithMaxOracleAge(uint256 newMaxOracleAge) internal {
        factory.whitelist(
            address(
                new CREOracle(
                    address(factory),
                    address(workflowRegistry),
                    oracle.FORWARDER(),
                    oracle.MAX_REPORT_AGE(),
                    newMaxOracleAge,
                    oracle.REPORT_INTERVAL(),
                    oracle.REPORT_BUFFER()
                )
            )
        );
        factory.migrate(address(oracle), factory.lastVersion(), "");
    }

    function _deliverWithReview(ICREOracle.Report memory update) internal {
        _deliver(update);
        if (oracle.oracleFrozen()) oracle.unfreezeOracle(abi.encode(update));
    }

    function _expectRecoveryFailure(ICREOracle.Report memory update, bytes4 errorSelector) internal {
        _deliver(update);
        bytes memory payload = abi.encode(update);
        vm.expectRevert(errorSelector);
        oracle.unfreezeOracle(payload);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
    }

    function _report(uint256 assets) internal view returns (ICREOracle.Report memory) {
        return ICREOracle.Report({
            chainId: block.chainid,
            oracle: address(oracle),
            adapter: address(adapter),
            nonce: oracle.nonce() + 1,
            totalAssets: assets,
            snapshotBlock: block.number - 1,
            snapshotTimestamp: block.timestamp - 1
        });
    }

    /// @dev Enter the deferred window when a test exercises two-report accounting.
    function _afterCutoff() internal {
        if (block.timestamp < oracle.cutoff()) vm.warp(oracle.cutoff());
    }

    function _advanceReport() internal {
        vm.roll(block.number + 1);
        uint256 nextTimestamp = block.timestamp + 1;
        if (nextTimestamp <= oracle.cutoff()) nextTimestamp = oracle.cutoff() + 1;
        vm.warp(nextTimestamp);
    }

    function _batch(bool next) internal view returns (IMerkleAdapter.Batch memory batch) {
        if (next) (batch.allocation, batch.deallocation) = adapter.nextBatch();
        else (batch.allocation, batch.deallocation) = adapter.currentBatch();
    }

    function _setAdapterState(bytes4 selector, uint256 field, uint256 value) internal {
        stdstore.target(address(adapter)).sig(selector).depth(field).checked_write(value);
    }

    function _metadata() internal view returns (bytes memory) {
        return abi.encodePacked(WORKFLOW, bytes10("nav"), address(workflowRegistry), bytes2(0));
    }

    function _deliver(ICREOracle.Report memory update) internal {
        bytes memory payload = abi.encode(update);
        vm.prank(address(forwarder));
        oracle.onReport(_metadata(), payload);
    }

    function _expectReportError(ICREOracle.Report memory update, bytes4 errorSelector) internal {
        bytes memory payload = abi.encode(update);
        vm.prank(address(forwarder));
        vm.expectRevert(errorSelector);
        oracle.onReport(_metadata(), payload);
    }

    function _signedReport(ICREOracle.Report memory update, bytes32 workflow)
        internal
        returns (bytes memory raw, bytes[] memory signatures)
    {
        return _signedReport(update, workflow, bytes32(update.nonce));
    }

    function _signedReport(ICREOracle.Report memory update, bytes32 workflow, bytes32 executionId)
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
            address(workflowRegistry),
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

contract CREOracleTest is CREOracleTestBase {
    function test_AdapterCreatesOracleThroughExistingFactoryPayload() public view {
        assertEq(oracle.adapter(), address(adapter));
        assertEq(oracle.owner(), address(this));
        assertEq(oracle.version(), 1);
        assertEq(oracle.MAX_ORACLE_AGE(), 1 days);
        assertEq(oracle.FORWARDER(), address(forwarder));
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(oracle.nonce(), 0);
        assertEq(oracle.totalAssets(), 0);
        assertTrue(oracle.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertTrue(oracle.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(oracle.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertFalse(oracle.supportsInterface(0xffffffff));
    }

    function test_KeystoneForwarderVerifiesSignaturesAndDeliversProductionMetadata() public {
        ICREOracle.Report memory update = _report(645e6);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 0);
        oracle.unfreezeOracle(abi.encode(update));
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
        ICREOracle.Report memory update = _report(100);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, bytes32(uint256(1)));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.nonce(), 0);
        assertFalse(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(1)), bytes2(0)).success);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        (raw, signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertTrue(oracle.oracleFrozen());
        oracle.unfreezeOracle(abi.encode(update));
        assertEq(oracle.totalAssets(), 100);
    }

    function test_OwnerAndOtherCallersCannotSubmitDirectly() public {
        bytes memory payload = abi.encode(_report(100));
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), payload);
        vm.prank(address(adapter));
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), payload);
    }

    function testFuzz_RejectsMalformedMetadata(uint8 length) public {
        vm.assume(length != 64);
        bytes memory metadata = new bytes(length);
        bytes memory payload = abi.encode(_report(100));
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidWorkflow.selector);
        oracle.onReport(metadata, payload);
    }

    function test_RequiresProduction64ByteMetadata() public {
        bytes memory payload = abi.encode(_report(0));
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidWorkflow.selector);
        oracle.onReport(abi.encodePacked(WORKFLOW, bytes10("nav"), address(this)), payload);
        _deliver(_report(0));
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.totalAssets(), 0);
    }

    function testFuzz_RejectsWrongDestination(uint8 field) public {
        ICREOracle.Report memory update = _report(100);
        field = uint8(bound(field, 0, 2));
        if (field == 0) update.chainId += 1;
        else if (field == 1) update.oracle = address(adapter);
        else update.adapter = address(oracle);
        _expectReportError(update, ICREOracle.InvalidReport.selector);
    }

    function test_RejectsTruncatedAndTrailingReportData() public {
        bytes memory payload = abi.encode(_report(100));
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.onReport(_metadata(), bytes.concat(payload, hex"00"));
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.onReport(_metadata(), hex"00");
    }

    function test_RejectsRepeatedAndSkippedEpochs() public {
        ICREOracle.Report memory update = _report(100);
        update.nonce = 0;
        _expectReportError(update, ICREOracle.InvalidNonce.selector);
        update.nonce = 2;
        _expectReportError(update, ICREOracle.InvalidNonce.selector);
        update.nonce = 1;
        _deliverWithReview(update);
        _expectReportError(update, ICREOracle.InvalidNonce.selector);
    }

    function test_RejectsOldAndFutureSnapshotsAtExactAgeBoundary() public {
        ICREOracle.Report memory update = _report(100);
        update.snapshotTimestamp = block.timestamp - 101;
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotTimestamp = block.timestamp + 1;
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotTimestamp = block.timestamp - 100;
        update.snapshotBlock = block.number;
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotBlock = 0;
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotBlock = block.number - 1;
        _deliverWithReview(update);
        assertEq(oracle.totalAssets(), 100);
    }

    function test_RejectsNonAdvancingSnapshotEvenForNextEpoch() public {
        ICREOracle.Report memory update = _report(100);
        _deliverWithReview(update);
        update.nonce = 2;
        _advanceReport();
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotBlock += 1;
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotTimestamp = block.timestamp - 1;
        _deliver(update);
        assertEq(oracle.nonce(), 2);
    }

    function test_NAVReserveReconciliationAcrossAllocationAndDeallocationEpochs() public {
        _deliver(_report(0));
        _advanceReport();
        asset.transfer(adapter.vault(), 100);
        delegator.allocate(address(adapter), 100);
        _deliver(_report(0)); // The first epoch after allocation still reserves it.
        assertEq(adapter.totalAssets(), 100);
        _advanceReport();
        _deliver(_report(100)); // The next epoch incorporates that allocation into NAV.
        assertEq(adapter.totalAssets(), 100);
        _afterCutoff();
        delegator.requestDeallocate(address(adapter), 40);
        _advanceReport();
        _deliver(_report(100)); // The first epoch after withdrawal has not matured its reserve.
        assertEq(adapter.totalAssets(), 100);
        _advanceReport();
        _deliver(_report(100)); // The oracle reserves 40 and stores the remaining 60-unit NAV.
        assertEq(adapter.totalAssets(), 100);
        MerkleAccount(payable(account)).manage(new IMerkleAccount.Action[](0));
        assertEq(adapter.deallocatable(), 40);
        assertEq(delegator.deallocate(address(adapter), 40), 40);
        assertEq(adapter.totalAssets(), 60);
    }

    function test_MigrationPreservesAccountingWorkflowProposalAndGuard() public {
        _deliverWithReview(_report(100));
        bytes32 nextWorkflow = keccak256("next approved workflow");
        _proposeWorkflow(address(oracle), nextWorkflow);
        oracle.freezeOracle();
        uint256 previousCutoff = oracle.cutoff();
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(100, 200);
        assertEq(oracle.MAX_ORACLE_AGE(), 1 days);
        factory.whitelist(
            address(
                new CREOracle(address(factory), address(workflowRegistry), address(forwarder), 200, 1 hours, 100, 10)
            )
        );
        factory.migrate(address(oracle), 2, bytes(""));
        assertEq(oracle.adapter(), address(adapter));
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.totalAssets(), 100);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.snapshotTimestamp(), 9999);
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(workflowRegistry.proposals(address(oracle)), _proposalHash(nextWorkflow));
        assertEq(oracle.MAX_REPORT_AGE(), 200);
        assertEq(oracle.cutoff(), previousCutoff);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.maxOracleGrowthBps(), 100);
        assertEq(oracle.maxOracleLossBps(), 200);
        assertEq(oracle.MAX_ORACLE_AGE(), 1 hours);
        bytes32[3] memory roles = [bytes32(0), ORACLE_GUARD_ROLE, ORACLE_LIMITS_ROLE];
        for (uint256 i; i < roles.length; ++i) {
            assertTrue(oracle.hasRole(roles[i], address(this)));
            assertEq(oracle.getRoleMemberCount(roles[i]), 1);
            assertEq(oracle.getRoleMember(roles[i], 0), address(this));
        }
        oracle.unfreezeOracle("");
        assertFalse(oracle.oracleFrozen());
    }

    function test_ConstructorAcceptsUncheckedInputsAndLifecycleStillValidates() public {
        CREOracle uncheckedOracle =
            new CREOracle(address(factory), address(workflowRegistry), address(0), 0, 0, 100, 10);
        assertEq(uncheckedOracle.FORWARDER(), address(0));
        assertEq(uncheckedOracle.workflowId(), bytes32(0));
        assertEq(uncheckedOracle.MAX_REPORT_AGE(), 0);
        assertEq(uncheckedOracle.MAX_ORACLE_AGE(), 0);
        factory.create(1, address(this), abi.encode(address(0), abi.encode(defaultOracleInitParams(address(this)))));
        vm.expectRevert(IMigratableEntity.AlreadyInitialized.selector);
        implementation.initialize(
            1, address(this), abi.encode(address(adapter), abi.encode(defaultOracleInitParams(address(this))))
        );
        factory.whitelist(
            address(
                new CREOracle(address(factory), address(workflowRegistry), address(forwarder), 100, 1 days, 100, 10)
            )
        );
        factory.migrate(address(oracle), 2, hex"01");
        assertEq(oracle.version(), 2);
    }
}
