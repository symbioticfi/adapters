// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {merkleAdapterInitParams, defaultOracleInitParams} from "test/helpers/MerkleInitialization.sol";

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {ICREOracle, ORACLE_GUARD_ROLE, ORACLE_LIMITS_ROLE} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

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
        implementation = new CREOracle(address(factory), address(workflowRegistry), address(forwarder));
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

    function _deliverWithReview(ICREOracle.Report memory update) internal {
        _deliver(update);
        if (oracle.snapshotBlock() != update.snapshotBlock) {
            bytes memory payload = abi.encode(update);
            assertEq(oracle.rejectedReportHash(), keccak256(payload));
            oracle.acceptReport(payload);
            adapter.syncReport();
        }
    }

    /// @dev The report values the completed preceding block, before any flows in the current block.
    function _report(uint256 assets) internal view returns (ICREOracle.Report memory) {
        return ICREOracle.Report({
            chainId: block.chainid,
            adapter: address(adapter),
            totalAssets: assets,
            snapshotBlock: SafeCast.toUint48(vm.getBlockNumber() - 1),
            snapshotTimestamp: SafeCast.toUint48(vm.getBlockTimestamp() - 1)
        });
    }

    function _advanceReport() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _fundPortfolio(uint256 amount) internal {
        _deliver(_report(0));
        asset.transfer(adapter.vault(), amount);
        assertEq(delegator.allocate(address(adapter), amount), amount);
        _advanceReport();
        _deliver(_report(amount));
    }

    function _releasePortfolio(uint256 amount) internal {
        delegator.requestDeallocate(address(adapter), amount);
        _advanceReport();
        _deliver(_report(adapter.totalAssets()));
    }

    function _metadata() internal view returns (bytes memory) {
        return abi.encodePacked(WORKFLOW, bytes10("nav"), address(workflowRegistry), bytes2(0));
    }

    function _deliver(ICREOracle.Report memory update) internal {
        _submitReport(update);
        if (oracle.snapshotBlock() == update.snapshotBlock) adapter.syncReport();
    }

    function _assertReportedAssets(uint256 expectedAssets) internal view {
        (uint48 reportBlock, uint256 reportedAssets) = oracle.latestSnapshot();
        assertEq(reportBlock, oracle.snapshotBlock());
        assertEq(reportedAssets, expectedAssets);
    }

    function _submitReport(ICREOracle.Report memory update) internal {
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
        return _signedReport(update, workflow, bytes32(uint256(update.snapshotBlock)));
    }

    function _signedReport(ICREOracle.Report memory update, bytes32 workflow, bytes32 executionId)
        internal
        returns (bytes memory raw, bytes[] memory signatures)
    {
        return _signedReport(update, workflow, executionId, address(workflowRegistry));
    }

    function _signedReport(
        ICREOracle.Report memory update,
        bytes32 workflow,
        bytes32 executionId,
        address workflowOwner
    ) internal returns (bytes memory raw, bytes[] memory signatures) {
        raw = abi.encodePacked(
            uint8(1),
            executionId,
            uint32(block.timestamp),
            uint32(1),
            uint32(1),
            workflow,
            bytes10("nav"),
            workflowOwner,
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
    function test_AdapterCreatesOracleThroughExistingFactoryPayload() public {
        assertEq(oracle.adapter(), address(adapter));
        assertEq(oracle.owner(), address(this));
        assertEq(oracle.version(), 1);
        assertEq(oracle.forwarder(), address(forwarder));
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
        assertEq(oracle.snapshotBlock(), 0);
        assertEq(oracle.totalAssets(), 0);
        vm.expectRevert(IMerkleAdapterOracle.OracleStale.selector);
        oracle.latestSnapshot();
        vm.expectRevert(IMerkleAdapterOracle.OracleStale.selector);
        adapter.totalAssets();
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
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        assertEq(oracle.snapshotBlock(), 0);
        oracle.acceptReport(abi.encode(update));
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(adapter.totalAssets(), 645e6);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.snapshotTimestamp(), 9999);
        IRouter.TransmissionInfo memory info =
            forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(update.snapshotBlock)), bytes2(0));
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
        assertEq(oracle.snapshotBlock(), 0);
    }

    function test_ForwarderRecordsWrongWorkflowAsFailedAndAllowsCorrectRetry() public {
        ICREOracle.Report memory update = _report(100);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, bytes32(uint256(1)));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.snapshotBlock(), 0);
        assertFalse(
            forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(update.snapshotBlock)), bytes2(0)).success
        );
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        (raw, signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        oracle.acceptReport(abi.encode(update));
        assertEq(adapter.totalAssets(), 100);
    }

    function test_OwnerAndOtherCallersCannotSubmitDirectly() public {
        bytes memory payload = abi.encode(_report(100));
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), payload);
        vm.prank(address(adapter));
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), payload);
    }

    function test_ForwarderRejectsWrongWorkflowOwnerAndAcceptsRegistryOwner() public {
        ICREOracle.Report memory update = _report(0);
        (bytes memory raw, bytes[] memory signatures) =
            _signedReport(update, WORKFLOW, bytes32(uint256(update.snapshotBlock)), address(this));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(
            uint256(
                forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(update.snapshotBlock)), bytes2(0)).state
            ),
            uint256(IRouter.TransmissionState.FAILED)
        );
        assertEq(oracle.snapshotBlock(), 0);
        assertEq(oracle.rejectedReportHash(), bytes32(0));

        (raw, signatures) = _signedReport(update, WORKFLOW);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertTrue(
            forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(update.snapshotBlock)), bytes2(0)).success
        );
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
        assertEq(oracle.snapshotTimestamp(), update.snapshotTimestamp);
    }

    function testFuzz_RejectsWrongWorkflowOwner(address workflowOwner, bytes10 workflowName, bytes2 reportId) public {
        vm.assume(workflowOwner != address(workflowRegistry));
        bytes memory metadata = abi.encodePacked(WORKFLOW, workflowName, workflowOwner, reportId);
        bytes memory payload = abi.encode(_report(100));
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidWorkflow.selector);
        oracle.onReport(metadata, payload);
        assertEq(oracle.snapshotBlock(), 0);
        assertEq(oracle.snapshotTimestamp(), 0);
        vm.expectRevert(IMerkleAdapterOracle.OracleStale.selector);
        adapter.totalAssets();
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function testFuzz_AcceptsRegistryOwnerWithAnyWorkflowNameAndReportId(bytes10 workflowName, bytes2 reportId) public {
        bytes memory metadata = abi.encodePacked(WORKFLOW, workflowName, address(workflowRegistry), reportId);
        bytes memory payload = abi.encode(_report(0));
        vm.prank(address(forwarder));
        oracle.onReport(metadata, payload);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.snapshotTimestamp(), 9999);
        assertEq(adapter.totalAssets(), 0);
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
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(adapter.totalAssets(), 0);
    }

    function testFuzz_RejectsWrongDestination(uint8 field) public {
        ICREOracle.Report memory update = _report(100);
        field = uint8(bound(field, 0, 1));
        if (field == 0) update.chainId += 1;
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

    function test_RejectsRepeatedSnapshotsAndAllowsGapsBetweenReports() public {
        ICREOracle.Report memory update = _report(100);
        _deliverWithReview(update);
        _expectReportError(update, ICREOracle.StaleReport.selector);
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 1000);
        _deliver(_report(100));
        assertEq(oracle.snapshotBlock(), block.number - 1);
    }

    function test_AcceptsDelayedSnapshotButRejectsFutureOrIncompleteSnapshot() public {
        ICREOracle.Report memory update = _report(100);
        update.snapshotTimestamp = SafeCast.toUint48(block.timestamp + 1);
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotTimestamp = SafeCast.toUint48(block.timestamp - 101);
        update.snapshotBlock = SafeCast.toUint48(block.number);
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotBlock = 0;
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotBlock = SafeCast.toUint48(block.number - 1);
        _deliverWithReview(update);
        assertEq(adapter.totalAssets(), 100);
    }

    function test_RejectsNonAdvancingSnapshotBlockOrTimestamp() public {
        ICREOracle.Report memory update = _report(100);
        _deliverWithReview(update);
        _advanceReport();
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotBlock += 1;
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotTimestamp = SafeCast.toUint48(block.timestamp - 1);
        update.snapshotBlock -= 1;
        _expectReportError(update, ICREOracle.StaleReport.selector);
        update.snapshotBlock += 1;
        _deliver(update);
        assertEq(oracle.snapshotBlock(), 500);
    }

    function test_NAVReconcilesAllocationsAndWithdrawalsImmediately() public {
        _deliver(_report(0));
        asset.transfer(adapter.vault(), 100);
        delegator.allocate(address(adapter), 100);
        assertEq(adapter.totalAssets(), 100);
        _assertReportedAssets(0);
        assertEq(adapter.netFlow(), 100);
        delegator.requestDeallocate(address(adapter), 40);
        assertEq(adapter.totalAssets(), 100);
        assertEq(delegator.deallocate(address(adapter), 40), 0);
        _advanceReport();
        _deliver(_report(100));
        assertEq(delegator.deallocate(address(adapter), 40), 40);
        assertEq(adapter.totalAssets(), 60);
        _advanceReport();
        _deliver(_report(60));
        assertEq(adapter.totalAssets(), 60);
        _assertReportedAssets(60);
        assertEq(adapter.netFlow(), 60);
    }

    function test_MigrationPreservesAccountingWorkflowProposalAndGuard() public {
        _deliverWithReview(_report(100));
        bytes32 nextWorkflow = keccak256("next approved workflow");
        _proposeWorkflow(address(oracle), nextWorkflow);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(300);
        _deliver(rejected);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(10_000, 20_000, 0);
        factory.whitelist(address(new CREOracle(address(factory), address(workflowRegistry), address(forwarder))));
        factory.migrate(address(oracle), 2, bytes(""));
        assertEq(oracle.adapter(), address(adapter));
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(adapter.totalAssets(), 100);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.snapshotTimestamp(), 9999);
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
        _assertProposal(address(oracle), nextWorkflow);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));
        assertEq(oracle.maxOracleGrowth(), 10_000);
        assertEq(oracle.maxOracleLoss(), 20_000);
        bytes32[3] memory roles = [bytes32(0), ORACLE_GUARD_ROLE, ORACLE_LIMITS_ROLE];
        for (uint256 i; i < roles.length; ++i) {
            assertTrue(oracle.hasRole(roles[i], address(this)));
            assertEq(oracle.getRoleMemberCount(roles[i]), 1);
            assertEq(oracle.getRoleMember(roles[i], 0), address(this));
        }
        oracle.acceptReport(abi.encode(rejected));
        assertEq(adapter.totalAssets(), 300);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_ImplementationAndItsProxiesShareTheConstructorForwarder() public {
        address second = factory.create(
            1, makeAddr("second owner"), abi.encode(address(adapter), abi.encode(defaultOracleInitParams(address(0))))
        );
        assertEq(implementation.forwarder(), address(forwarder));
        assertEq(oracle.forwarder(), address(forwarder));
        assertEq(ICREOracle(second).forwarder(), address(forwarder));
        assertEq(ICREOracle(second).adapter(), address(adapter));
    }

    function test_MigrationSelectsNewForwarderAndPreservesReportState() public {
        _fundPortfolio(1000);
        address replacementForwarder = makeAddr("replacement forwarder");
        uint48 acceptedBlock = oracle.snapshotBlock();
        uint48 acceptedTimestamp = oracle.snapshotTimestamp();
        factory.whitelist(address(new CREOracle(address(factory), address(workflowRegistry), replacementForwarder)));
        factory.migrate(address(oracle), factory.lastVersion(), "");
        assertEq(oracle.forwarder(), replacementForwarder);
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertEq(oracle.snapshotTimestamp(), acceptedTimestamp);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(oracle.adapter(), address(adapter));
        assertEq(workflowRegistry.workflowId(address(oracle)), WORKFLOW);
        _advanceReport();
        bytes memory metadata = _metadata();
        bytes memory data = abi.encode(_report(1000));
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        oracle.onReport(metadata, data);
        vm.prank(replacementForwarder);
        oracle.onReport(metadata, data);
        assertEq(oracle.snapshotBlock(), vm.getBlockNumber() - 1);
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_ConstructorAcceptsUncheckedInputsAndLifecycleStillValidates() public {
        CREOracle uncheckedOracle = new CREOracle(address(factory), address(workflowRegistry), address(0));
        assertEq(uncheckedOracle.forwarder(), address(0));
        assertEq(workflowRegistry.workflowId(address(uncheckedOracle)), bytes32(0));
        factory.create(1, address(this), abi.encode(address(0), abi.encode(defaultOracleInitParams(address(this)))));
        vm.expectRevert(IMigratableEntity.AlreadyInitialized.selector);
        implementation.initialize(
            1, address(this), abi.encode(address(adapter), abi.encode(defaultOracleInitParams(address(this))))
        );
        factory.whitelist(address(new CREOracle(address(factory), address(workflowRegistry), address(forwarder))));
        factory.migrate(address(oracle), 2, hex"01");
        assertEq(oracle.version(), 2);
    }
}
