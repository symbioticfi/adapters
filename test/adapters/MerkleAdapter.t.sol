// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

import {AdapterFactory} from "../../src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "../../src/contracts/MerkleAdapter.sol";
import {RootRegistry} from "../../src/contracts/merkle-adapter/RootRegistry.sol";
import {Token} from "../mocks/Token.sol";

import {MerkleAdapterVerifier} from "../../src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IAdapter} from "../../src/interfaces/IAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapterOracle} from "../../src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../../src/interfaces/IMerkleAdapter.sol";
import {IRootRegistry} from "../../src/interfaces/merkle-adapter/IRootRegistry.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {Registry} from "@symbioticfi/core/src/contracts/common/Registry.sol";

import {StdStorage, stdStorage, Test} from "forge-std/Test.sol";

import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";

contract MerkleAdapterVerifierTest is Test {
    MerkleAdapterVerifierHarness internal harness;

    address internal constant TARGET = 0x000000000000000000000000000000000000bEEF;
    /// @dev Golden vector for leaf(TARGET, 0, 0xaabbccdd, 0xff00f00f). Commits the mask
    ///      alongside the masked calldata, so it differs from the mask-free encoding.
    bytes32 internal constant EXPECTED_LEAF = 0x72e4708bcdd5259ecf32ba30eb13421e3a4220b079cc77a22fe57c02cc919263;
    bytes32 internal constant EXPECTED_NONZERO_LEAF =
        0xa6dba7d95be946d28a7938364211c51216ca899a0ce733026e824df6d129cbc4;

    function setUp() public {
        harness = new MerkleAdapterVerifierHarness();
    }

    function test_MaskDataAppliesEachMaskByte() public view {
        assertEq(
            harness.leaf(TARGET, 0, hex"aabbccdd", hex"ff00f00f"),
            keccak256(
                bytes.concat(
                    keccak256(abi.encode(TARGET, bytes1(0), keccak256(hex"ff00f00f"), keccak256(hex"00bb0cd0")))
                )
            )
        );
    }

    function test_LeafUsesCanonicalDoubleHashedEncoding() public view {
        assertEq(harness.leaf(TARGET, 0, hex"aabbccdd", hex"ff00f00f"), EXPECTED_LEAF);
    }

    function testFuzz_LeafUsesNonzeroValueByte(uint96 value) public {
        value = uint96(bound(value, 1, type(uint96).max));
        assertEq(harness.leaf(TARGET, value, hex"aabbccdd", hex"ff00f00f"), EXPECTED_NONZERO_LEAF);
        assertNotEq(EXPECTED_LEAF, EXPECTED_NONZERO_LEAF);
    }

    function test_VerifyAcceptsEmptyProofForMatchingLeafRoot() public view {
        bytes32[] memory proof = new bytes32[](0);

        assertTrue(harness.verify(proof, EXPECTED_LEAF, EXPECTED_LEAF));
    }

    function test_VerifyRejectsEmptyProofForDifferentRoot() public view {
        bytes32[] memory proof = new bytes32[](0);

        assertFalse(harness.verify(proof, bytes32(uint256(EXPECTED_LEAF) + 1), EXPECTED_LEAF));
    }

    function test_MaskDataRevertsWhenMaskLengthDiffersFromCalldataLength() public {
        vm.expectRevert(IMerkleAccount.InvalidDataMaskLength.selector);
        harness.leaf(TARGET, 0, hex"aabbccdd", hex"ff00f0");
    }
}

contract MerkleAdapterVerifierHarness {
    function leaf(address target, uint96 value, bytes calldata data, bytes calldata dataMask)
        external
        pure
        returns (bytes32)
    {
        return MerkleAdapterVerifier.leaf(target, value, data, dataMask);
    }

    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leafHash) external pure returns (bool) {
        return MerkleProof.verifyCalldata(proof, root, leafHash);
    }
}

contract MerkleAdapterLifecycleTest is Test {
    using stdStorage for StdStorage;
    bytes32 internal constant INITIAL_ROOT = keccak256("initial root");
    bytes32 internal constant NEXT_ROOT = keccak256("next root");
    MerkleAdapterVaultRegistry internal vaultFactory;
    AdapterFactory internal adapterFactory;
    MigratablesFactory internal oracleFactory;
    RootRegistry internal rootRegistry;
    MerkleAdapterOracleMock internal oracleImplementation;
    MerkleAdapterVaultMock internal vault;
    MerkleAdapterDelegatorMock internal delegator;
    Token internal asset;
    MerkleAdapter internal adapter;
    address internal account;
    MerkleAdapterOracleMock internal oracle;

    address internal adapterOwner = makeAddr("adapterOwner");
    address internal defaultAdminRoleHolder = makeAddr("defaultAdminRoleHolder");
    address internal protocolOwner = makeAddr("protocolOwner");
    address internal unauthorized = makeAddr("unauthorized");

    function setUp() public {
        vaultFactory = new MerkleAdapterVaultRegistry();
        adapterFactory = new AdapterFactory(address(this));
        oracleFactory = new MigratablesFactory(address(this));
        rootRegistry = new RootRegistry(protocolOwner);
        asset = new Token("Asset");
        vault = new MerkleAdapterVaultMock(address(asset));
        delegator = new MerkleAdapterDelegatorMock(address(vault));
        vault.setDelegator(address(delegator));
        vaultFactory.add(address(vault));

        oracleFactory.whitelist(address(new MerkleAdapterOracleMock(address(oracleFactory))));
        oracleImplementation = new MerkleAdapterOracleMock(address(oracleFactory));
        oracleFactory.whitelist(address(oracleImplementation));

        MerkleAdapter implementation = new MerkleAdapter(
            address(vaultFactory),
            address(adapterFactory),
            address(oracleFactory),
            createMerkleAccountFactory(
                address(this),
                address(adapterFactory),
                address(rootRegistry),
                address(new CapabilitiesRegistry(address(this)))
            )
        );
        adapterFactory.whitelist(address(implementation));

        IMerkleAdapter.InitParams memory params = merkleAdapterInitParams(defaultAdminRoleHolder, address(0));
        adapter = MerkleAdapter(
            payable(adapterFactory.create(1, adapterOwner, abi.encode(address(vault), abi.encode(params))))
        );
        account = adapter.account();
        oracle = MerkleAdapterOracleMock(adapter.oracle());
        _setMerkleRoot(INITIAL_ROOT);
    }

    function test_InitializeStoresRegistryDefaultAdminAndLatestVersionOracle() public view {
        assertEq(adapter.ORACLE_FACTORY(), address(oracleFactory));
        assertEq(MerkleAccount(payable(account)).MERKLE_ADAPTER_FACTORY(), address(adapterFactory));
        assertEq(MerkleAccount(payable(account)).ROOT_REGISTRY(), address(rootRegistry));
        assertEq(MerkleAccount(payable(account)).root(), INITIAL_ROOT);

        assertEq(
            MerkleAccount(payable(account)).getRoleMemberCount(MerkleAccount(payable(account)).DEFAULT_ADMIN_ROLE()), 1
        );
        assertEq(
            MerkleAccount(payable(account)).getRoleMember(MerkleAccount(payable(account)).DEFAULT_ADMIN_ROLE(), 0),
            defaultAdminRoleHolder
        );
        assertFalse(
            MerkleAccount(payable(account)).hasRole(MerkleAccount(payable(account)).DEFAULT_ADMIN_ROLE(), adapterOwner)
        );

        assertEq(oracleFactory.totalEntities(), 1);
        assertEq(oracleFactory.lastVersion(), 2);
        assertEq(oracleFactory.implementation(oracleFactory.lastVersion()), address(oracleImplementation));
        assertEq(oracle.version(), oracleFactory.lastVersion());
        assertEq(oracle.owner(), adapterOwner);
        assertEq(
            oracle.initDataLength(),
            abi.encode(address(adapter), merkleAdapterInitParams(defaultAdminRoleHolder, address(0)).oracleData).length
        );
        assertEq(oracle.initData(), merkleAdapterInitParams(defaultAdminRoleHolder, address(0)).oracleData);
        assertEq(oracle.adapter(), address(adapter));
        assertEq(IAdapter(oracle.adapter()).vault(), address(vault));
    }

    function testFuzz_InitializationForwardsOraclePayloadUnchanged(bytes memory oracleData) public {
        IMerkleAdapter.InitParams memory params = merkleAdapterInitParams(defaultAdminRoleHolder, address(0));
        params.oracleData = oracleData;
        MerkleAdapter created = MerkleAdapter(
            payable(adapterFactory.create(1, adapterOwner, abi.encode(address(vault), abi.encode(params))))
        );
        MerkleAdapterOracleMock receiver = MerkleAdapterOracleMock(created.oracle());
        assertEq(receiver.adapter(), address(created));
        assertEq(receiver.initData(), oracleData);
        assertEq(IMerkleAccount(created.account()).adapter(), address(created));
        assertTrue(IMerkleAccount(created.account()).hasRole(bytes32(0), defaultAdminRoleHolder));
        assertEq(asset.allowance(created.account(), address(created)), type(uint256).max);
        assertEq(asset.allowance(created.account(), created.ACCOUNT_FACTORY()), 0);
    }

    function test_ConstantGetterSelectorsAreUnavailable() public {
        bytes4[3] memory selectors = [
            bytes4(keccak256("ANY_VALUE()")),
            bytes4(keccak256("ANY_TARGET()")),
            bytes4(keccak256("SET_MERKLE_ROOT_ROLE()"))
        ];

        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(adapter).call(abi.encodeWithSelector(selectors[i]));
            assertFalse(success);
        }
    }

    function test_SupportsOnlyInheritedInterfaces() public view {
        assertTrue(MerkleAccount(payable(account)).supportsInterface(type(IERC165).interfaceId));
        assertTrue(MerkleAccount(payable(account)).supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(MerkleAccount(payable(account)).supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertFalse(MerkleAccount(payable(account)).supportsInterface(0xffffffff));
        assertFalse(MerkleAccount(payable(account)).supportsInterface(type(IMerkleAdapter).interfaceId));
    }

    function test_InitializeOmitsZeroRoleHolders() public {
        IMerkleAdapter.InitParams memory params = merkleAdapterInitParams(address(0), address(0));

        MerkleAdapter zeroOwnerAdapter = MerkleAdapter(
            payable(adapterFactory.create(1, address(0), abi.encode(address(vault), abi.encode(params))))
        );

        assertEq(zeroOwnerAdapter.owner(), address(0));
        assertEq(MerkleAccount(payable(zeroOwnerAdapter.account())).root(), bytes32(0));
        assertEq(
            MerkleAccount(payable(zeroOwnerAdapter.account()))
                .getRoleMemberCount(MerkleAccount(payable(zeroOwnerAdapter.account())).DEFAULT_ADMIN_ROLE()),
            0
        );
        assertEq(MerkleAdapterOracleMock(zeroOwnerAdapter.oracle()).owner(), address(0));
    }

    function test_InitializeStartsWithZeroRootAndOnlyDefaultAdmin() public {
        IMerkleAdapter.InitParams memory params = merkleAdapterInitParams(defaultAdminRoleHolder, address(0));
        MerkleAdapter newAdapter = MerkleAdapter(
            payable(adapterFactory.create(1, adapterOwner, abi.encode(address(vault), abi.encode(params))))
        );

        assertEq(MerkleAccount(payable(newAdapter.account())).root(), bytes32(0));
        assertEq(
            MerkleAccount(payable(newAdapter.account()))
                .getRoleMemberCount(MerkleAccount(payable(newAdapter.account())).DEFAULT_ADMIN_ROLE()),
            1
        );
        assertEq(
            MerkleAccount(payable(newAdapter.account()))
                .getRoleMember(MerkleAccount(payable(newAdapter.account())).DEFAULT_ADMIN_ROLE(), 0),
            defaultAdminRoleHolder
        );
    }

    function test_RootRegistryOwnerPublishesRootAndEmits() public {
        address otherAdapter = makeAddr("otherAdapter");

        vm.expectEmit(true, true, false, true, address(rootRegistry));
        emit IRootRegistry.SetRoot(otherAdapter, NEXT_ROOT);
        vm.prank(protocolOwner);
        rootRegistry.setRoot(otherAdapter, NEXT_ROOT);

        assertEq(rootRegistry.roots(otherAdapter), NEXT_ROOT);
    }

    function test_RootRegistryRejectsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        rootRegistry.setRoot(account, NEXT_ROOT);
    }

    function test_TotalAssetsFollowsOracleWithoutAddingFreeAssets() public {
        oracle.setTotalAssets(123);
        assertEq(adapter.totalAssets(), 123);

        asset.transfer(address(adapter), 17);
        oracle.setTotalAssets(456);

        assertEq(adapter.freeAssets(), 17);
        assertEq(adapter.totalAssets(), 456);
    }

    function test_TotalAssetsBubblesOracleRevert() public {
        oracle.setRevertCode(7);

        vm.expectRevert(abi.encodeWithSelector(MerkleAdapterOracleMock.ForcedTotalAssetsRevert.selector, 7));
        adapter.totalAssets();
    }

    function test_AllocationIsImmediatelyUsableWithoutAnotherReport() public {
        asset.transfer(address(vault), 150);
        assertEq(delegator.allocate(address(adapter), 100), 100);
        assertEq(adapter.netFlow(), 100);
        assertEq(adapter.totalAssets(), 100);
        vm.prank(account);
        adapter.push(100);
        assertEq(asset.balanceOf(account), 100);
        assertEq(adapter.totalAssets(), 100);
        assertEq(delegator.allocate(address(adapter), 50), 50);
        assertEq(adapter.netFlow(), 150);
        assertEq(adapter.totalAssets(), 150);
    }

    function test_AllocationDoesNotRefundPendingDemandBeforeReport() public {
        asset.transfer(address(adapter), 40);
        asset.transfer(address(vault), 50);
        oracle.setTotalAssets(40);
        delegator.requestDeallocate(address(adapter), 30);
        assertEq(delegator.allocate(address(adapter), 50), 50);
        assertEq(adapter.pendingDeallocation(), 30);
        assertEq(adapter.netFlow(), 50);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(adapter.totalAssets(), 90);
        assertEq(adapter.deallocatable(), 0);
        oracle.settle(uint48(block.number));
        assertEq(delegator.deallocate(address(adapter), 10), 10);
        assertEq(adapter.pendingDeallocation(), 20);
        assertEq(adapter.netFlow(), 40);
        assertEq(adapter.totalAssets(), 80);
    }

    function test_RequestDeallocateOverwritesAndCanBeCancelled() public {
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 30);
        assertEq(adapter.pendingDeallocation(), 30);
        delegator.requestDeallocate(address(adapter), 50);
        assertEq(adapter.pendingDeallocation(), 50);
        delegator.requestDeallocate(address(adapter), 10);
        assertEq(adapter.pendingDeallocation(), 10);
        delegator.requestDeallocate(address(adapter), 0);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(adapter.netFlow(), 0);
        assertEq(adapter.totalAssets(), 100);
    }

    function test_RequestDeallocateDoesNotRequireIdleBalance() public {
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 100);
        assertEq(adapter.pendingDeallocation(), 100);
        assertEq(adapter.deallocatable(), 0);
        MerkleAccount(payable(account)).manage(new IMerkleAccount.Action[](0));
    }

    function test_PendingDemandProtectsIdleCashFromInvestment() public {
        asset.transfer(address(adapter), 100);
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 60);
        vm.prank(account);
        adapter.push(40);
        vm.prank(account);
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        adapter.push(1);
        assertEq(asset.balanceOf(address(adapter)), 60);
        assertEq(adapter.netFlow(), 0);
        assertEq(adapter.totalAssets(), 100);
    }

    function test_DeallocateWaitsForReportAndReturnsOnlyReleasedAssets() public {
        asset.transfer(address(adapter), 100);
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 40);
        assertEq(delegator.deallocate(address(adapter), 100), 0);
        oracle.settle(uint48(block.number));
        assertEq(delegator.deallocate(address(adapter), 100), 40);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.netFlow(), -40);
        assertEq(adapter.totalAssets(), 60);
        assertEq(asset.balanceOf(address(vault)), 40);
    }

    function test_DeallocateCapsAtReportedNAV() public {
        asset.transfer(address(adapter), 100);
        oracle.setTotalAssets(75);
        delegator.requestDeallocate(address(adapter), 100);
        oracle.settle(uint48(block.number));
        assertEq(adapter.deallocatable(), 75);
        assertEq(delegator.deallocate(address(adapter), type(uint256).max), 75);
        assertEq(asset.balanceOf(address(adapter)), 25);
        assertEq(adapter.totalAssets(), 0);
        assertEq(adapter.deallocatable(), 0);
    }

    function test_DeallocateCannotReturnUnrequestedIdleAssets() public {
        asset.transfer(address(adapter), 75);
        oracle.setTotalAssets(75);
        oracle.settle(uint48(block.number));
        assertEq(delegator.deallocate(address(adapter), 75), 0);
        assertEq(asset.balanceOf(address(adapter)), 75);
        assertEq(adapter.pendingDeallocation(), 0);
    }

    function test_LiquidationFailureRollsBackCashDemandAndCheckpoint() public {
        asset.transfer(address(adapter), 100);
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 70);
        oracle.settle(uint48(block.number));
        oracle.setRevertCode(7);
        assertEq(adapter.deallocatable(), 70);
        vm.expectRevert(abi.encodeWithSelector(MerkleAdapterOracleMock.ForcedTotalAssetsRevert.selector, 7));
        delegator.deallocate(address(adapter), 50);
        assertEq(asset.balanceOf(address(adapter)), 100);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(adapter.pendingDeallocation(), 70);
        assertEq(adapter.netFlow(), 0);
        vm.roll(block.number + 1);
        assertEq(adapter.netFlowAt(uint48(block.number - 1)), 0);
    }

    function test_FailedTokenReturnRollsBackDemandAndCheckpoint() public {
        asset.transfer(address(adapter), 100);
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 70);
        oracle.settle(uint48(block.number));
        vm.prank(address(adapter));
        asset.approve(address(vault), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 50));
        delegator.deallocate(address(adapter), 50);
        assertEq(adapter.netFlow(), 0);
        assertEq(adapter.pendingDeallocation(), 70);
        assertEq(asset.balanceOf(address(adapter)), 100);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function test_PushAndPullRejectCallersOtherThanAccount() public {
        vm.startPrank(unauthorized);
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.push(0);
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.pull(0);
        vm.stopPrank();
    }

    function test_FlowCheckpointRejectsPositiveInt208OverflowAtomically() public {
        uint256 limit = uint256(int256(type(int208).max));
        deal(address(asset), address(vault), limit + 1);
        assertEq(delegator.allocate(address(adapter), limit), limit);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedIntDowncast.selector, 208, int256(limit + 1)));
        delegator.allocate(address(adapter), 1);
        assertEq(adapter.netFlow(), int256(limit));
        assertEq(asset.balanceOf(address(vault)), 1);
        assertEq(asset.balanceOf(address(adapter)), limit);
    }

    function test_FlowCheckpointRejectsNegativeInt208OverflowAtomically() public {
        uint256 limit = uint256(-int256(type(int208).min));
        deal(address(asset), address(adapter), limit + 1);
        oracle.setTotalAssets(limit + 1);
        delegator.requestDeallocate(address(adapter), limit + 1);
        oracle.settle(uint48(block.number));
        assertEq(delegator.deallocate(address(adapter), limit), limit);
        assertEq(adapter.netFlow(), int256(type(int208).min));
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedIntDowncast.selector, 208, -int256(limit) - 1)
        );
        delegator.deallocate(address(adapter), 1);
        assertEq(adapter.netFlow(), int256(type(int208).min));
        assertEq(asset.balanceOf(address(adapter)), 1);
        assertEq(asset.balanceOf(address(vault)), limit);
    }

    function testFuzz_FlowHistorySupportsChangingSigns(int96 first, int96 second) public {
        vm.roll(100);
        uint48 firstBlock = uint48(block.number);
        _setNetFlow(first);
        vm.roll(block.number + 1);
        _setNetFlow(second);
        vm.roll(block.number + 1);
        assertEq(adapter.netFlowAt(firstBlock - 1), 0);
        assertEq(adapter.netFlowAt(firstBlock), first);
        assertEq(adapter.netFlowAt(firstBlock + 1), second);
        assertEq(adapter.netFlow(), second);
    }

    function _setNetFlow(int256 desired) internal {
        int256 delta = desired - adapter.netFlow();
        if (delta >= 0) {
            deal(address(asset), address(vault), uint256(delta));
            delegator.allocate(address(adapter), uint256(delta));
        } else {
            deal(address(asset), address(adapter), uint256(-delta));
            oracle.setTotalAssets(uint256(-delta));
            delegator.requestDeallocate(address(adapter), uint256(-delta));
            oracle.settle(uint48(block.number));
            delegator.deallocate(address(adapter), uint256(-delta));
        }
    }

    function test_AllocationPathsRejectNonDelegator() public {
        vm.startPrank(unauthorized);

        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.allocate(1);
        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.deallocate(1);
        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.requestDeallocate(1);

        vm.stopPrank();
    }

    /// forge-config: default.isolate = true
    function test_AcceptRootStoresExactPublishedRootAndEmits() public {
        vm.prank(protocolOwner);
        rootRegistry.setRoot(account, NEXT_ROOT);
        vm.expectEmit(true, false, false, true, account);
        emit IMerkleAccount.AcceptRoot(NEXT_ROOT);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).acceptRoot(NEXT_ROOT);
        vm.snapshotGasLastCall("MerkleAccount", "acceptRootReplace");
        assertEq(MerkleAccount(payable(account)).root(), NEXT_ROOT);
    }

    /// forge-config: default.isolate = true
    function test_AcceptRootRejectsUnpublishedRoot() public {
        vm.prank(adapterOwner);
        vm.expectRevert(IMerkleAccount.InvalidRoot.selector);
        vm.startSnapshotGas("MerkleAccount", "acceptRootUnpublishedRegion");
        MerkleAccount(payable(account)).acceptRoot(NEXT_ROOT);
        vm.stopSnapshotGas();
    }

    function test_AcceptRootRejectsNonOwner() public {
        vm.prank(protocolOwner);
        rootRegistry.setRoot(account, NEXT_ROOT);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        MerkleAccount(payable(account)).acceptRoot(NEXT_ROOT);
    }

    /// forge-config: default.isolate = true
    function test_AcceptRootAcceptsZeroToDisableProofs() public {
        vm.prank(protocolOwner);
        rootRegistry.setRoot(account, bytes32(0));

        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).acceptRoot(bytes32(0));
        vm.snapshotGasLastCall("MerkleAccount", "acceptRootDisable");

        assertEq(MerkleAccount(payable(account)).root(), bytes32(0));
    }

    /// forge-config: default.isolate = true
    function test_AcceptRootReenablesPublishedRootAfterDisable() public {
        vm.prank(protocolOwner);
        rootRegistry.setRoot(account, bytes32(0));
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).acceptRoot(bytes32(0));
        vm.prank(protocolOwner);
        rootRegistry.setRoot(account, NEXT_ROOT);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).acceptRoot(NEXT_ROOT);
        vm.snapshotGasLastCall("MerkleAccount", "acceptRootEnable");
        assertEq(MerkleAccount(payable(account)).root(), NEXT_ROOT);
    }

    function test_LeafRoleGrantRevokeAndEnumerationControlExecution() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("revocable leaf")));
        IMerkleAccount.Action memory action = _action(address(target), 0, data, _filledMask(data.length, 0));
        bytes32 leafRole = _independentLeaf(action);
        address actionCaller = makeAddr("actionCaller");
        address secondActionCaller = makeAddr("secondActionCaller");
        _setMerkleRoot(leafRole);
        _grantLeaf(action, actionCaller);
        _grantLeaf(action, secondActionCaller);

        assertEq(MerkleAccount(payable(account)).getRoleMemberCount(leafRole), 2);
        assertEq(MerkleAccount(payable(account)).getRoleMember(leafRole, 0), actionCaller);
        assertEq(MerkleAccount(payable(account)).getRoleMember(leafRole, 1), secondActionCaller);
        vm.prank(actionCaller);
        MerkleAccount(payable(account)).manage(_singleton(action));

        vm.prank(defaultAdminRoleHolder);
        MerkleAccount(payable(account)).revokeRole(leafRole, actionCaller);
        assertEq(MerkleAccount(payable(account)).getRoleMemberCount(leafRole), 1);
        assertEq(MerkleAccount(payable(account)).getRoleMember(leafRole, 0), secondActionCaller);
        vm.prank(actionCaller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, actionCaller, leafRole)
        );
        MerkleAccount(payable(account)).manage(_singleton(action));
        assertEq(target.callCount(), 1);
        vm.prank(secondActionCaller);
        MerkleAccount(payable(account)).manage(_singleton(action));
        assertEq(target.callCount(), 2);
    }

    function test_ManageRejectsValidLeafWithoutLeafRole() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("leaf requires its own role")));
        bytes memory dataMask = _filledMask(data.length, 0);
        IMerkleAccount.Action memory action = _action(address(target), 0, data, dataMask);
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
        bytes32 leafRole = keccak256(
            bytes.concat(keccak256(abi.encode(address(target), bytes1(0), keccak256(dataMask), keccak256(data))))
        );

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, leafRole)
        );
        MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(target.callCount(), 0);
    }

    function test_DefaultAdminNeedsExplicitLeafRoleToManage() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("admin needs leaf grant")));
        IMerkleAccount.Action memory action = _action(address(target), 0, data, _filledMask(data.length, 0));
        bytes32 leafRole = _independentLeaf(action);
        _setMerkleRoot(leafRole);
        vm.prank(defaultAdminRoleHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, defaultAdminRoleHolder, leafRole
            )
        );
        MerkleAccount(payable(account)).manage(_singleton(action));
        assertEq(target.callCount(), 0);

        _grantLeaf(action, defaultAdminRoleHolder);
        vm.prank(defaultAdminRoleHolder);
        MerkleAccount(payable(account)).manage(_singleton(action));
        assertEq(target.callCount(), 1);
    }

    function test_ManageUsesFull96BitValue() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        uint96 callValue = type(uint96).max;
        bytes32 marker = keccak256("full native value");
        bytes memory data = abi.encodeCall(target.record, (marker));
        bytes memory dataMask = _filledMask(data.length, 0);
        IMerkleAccount.Action memory action = IMerkleAccount.Action({
            target: address(target), value: callValue, data: data, dataMask: dataMask, proof: new bytes32[](0)
        });
        bytes32 inner = keccak256(
            abi.encode(
                action.target, action.value == 0 ? bytes1(0) : bytes1(0xff), keccak256(dataMask), keccak256(data)
            )
        );
        _grantLeaf(action, address(this));
        _setMerkleRoot(keccak256(bytes.concat(inner)));
        vm.deal(account, callValue);

        MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(target.totalValue(), callValue);
        assertEq(target.lastMarker(), marker);
        assertEq(account.balance, 0);
    }

    function test_ManageAllowsGrantedLeafRole() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        address actionCaller = makeAddr("actionCaller");
        bytes32 marker = keccak256("leaf authorized action");
        bytes memory data = abi.encodeCall(target.record, (marker));
        IMerkleAccount.Action memory action = _action(address(target), 0, data, _filledMask(data.length, 0));
        _setMerkleRoot(_independentLeaf(action));
        _grantLeaf(action, actionCaller);

        vm.prank(actionCaller);
        bytes[] memory results = MerkleAccount(payable(account)).manage(_singleton(action));
        assertEq(target.callCount(), 1);
        assertEq(target.lastMarker(), marker);
        assertEq(results.length, 1);
        assertEq(abi.decode(results[0], (bytes32)), marker);
    }

    function test_ManageRejectsUnrelatedAndWildcardRoles() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("only the leaf role authorizes")));
        IMerkleAccount.Action memory action = _action(address(target), 0, data, _filledMask(data.length, 0));
        bytes32 leafRole = _independentLeaf(action);
        _setMerkleRoot(leafRole);
        vm.startPrank(defaultAdminRoleHolder);
        MerkleAccount(payable(account)).grantRole(keccak256("unrelated action role"), unauthorized);
        MerkleAccount(payable(account)).grantRole(bytes32(type(uint256).max), unauthorized);
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, leafRole)
        );
        MerkleAccount(payable(account)).manage(_singleton(action));
        assertEq(target.callCount(), 0);
    }

    function test_ManageRequiresEveryLeafRoleBeforeDispatch() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        address actionCaller = makeAddr("perLeafCaller");
        bytes memory firstData = abi.encodeCall(target.record, (keccak256("first permission")));
        bytes memory secondData = abi.encodeCall(target.record, (keccak256("second permission")));
        IMerkleAccount.Action memory first = _action(address(target), 0, firstData, _filledMask(firstData.length, 0));
        IMerkleAccount.Action memory second = _action(address(target), 0, secondData, _filledMask(secondData.length, 0));
        bytes32 firstLeaf = _independentLeaf(first);
        bytes32 secondLeaf = _independentLeaf(second);
        first.proof = _singletonProof(secondLeaf);
        second.proof = _singletonProof(firstLeaf);
        _setMerkleRoot(_hashSortedPair(firstLeaf, secondLeaf));
        _grantLeaf(first, actionCaller);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = first;
        actions[1] = second;

        vm.prank(actionCaller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, actionCaller, secondLeaf)
        );
        MerkleAccount(payable(account)).manage(actions);
        assertEq(target.callCount(), 0);

        _grantLeaf(second, actionCaller);
        vm.prank(actionCaller);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(target.callCount(), 2);
    }

    function test_ManageRejectsRoleBoundLeafEncoding() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("wrong leaf")));
        bytes memory mask = _filledMask(data.length, 0);
        IMerkleAccount.Action memory action = _action(address(target), 0, data, mask);
        bytes32 wrongLeaf = keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(keccak256("wrong role"), address(target), bytes1(0), keccak256(mask), keccak256(data))
                )
            )
        );
        _setMerkleRoot(wrongLeaf);
        _grantLeaf(action, address(this));
        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(action));
        assertEq(target.callCount(), 0);
    }

    function test_ManageCannotGrantLaterLeafDuringSameBatch() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("must hold role before batch")));
        IMerkleAccount.Action memory second = _action(address(target), 0, data, _filledMask(data.length, 0));
        bytes32 secondLeaf = _independentLeaf(second);
        bytes memory grantData = abi.encodeCall(IAccessControl.grantRole, (secondLeaf, address(this)));
        IMerkleAccount.Action memory first = _action(account, 0, grantData, _filledMask(grantData.length, 0));
        bytes32 firstLeaf = _independentLeaf(first);
        first.proof = _singletonProof(secondLeaf);
        second.proof = _singletonProof(firstLeaf);
        _setMerkleRoot(_hashSortedPair(firstLeaf, secondLeaf));
        _grantLeaf(first, address(this));
        vm.prank(defaultAdminRoleHolder);
        MerkleAccount(payable(account)).grantRole(bytes32(0), account);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = first;
        actions[1] = second;

        vm.expectCall(account, grantData, uint64(0));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), secondLeaf)
        );
        MerkleAccount(payable(account)).manage(actions);

        assertFalse(MerkleAccount(payable(account)).hasRole(secondLeaf, address(this)));
        assertEq(target.callCount(), 0);
    }

    function testFuzz_ManageForwardsValueUnchanged(uint96 callValue) public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes32 marker = keccak256("exact target and value");
        bytes memory data = abi.encodeCall(target.record, (marker));
        IMerkleAccount.Action memory action = _action(address(target), callValue, data, _filledMask(data.length, 0));
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
        vm.deal(account, callValue);

        MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(target.callCount(), 1);
        assertEq(target.totalValue(), callValue);
        assertEq(account.balance, 0);
    }

    function testFuzz_ManageAllowsDifferentNonzeroValuesForSameLeaf(uint96 value, uint96 changedValue) public {
        vm.assume(value != 0 && changedValue != 0 && value != changedValue);
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("caller supplied native value")));
        bytes memory dataMask = _filledMask(data.length, 0);
        IMerkleAccount.Action memory action = _action(address(target), value, data, dataMask);
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
        vm.deal(account, uint256(value) + changedValue);
        MerkleAccount(payable(account)).manage(_singleton(action));
        action.value = changedValue;

        MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(target.callCount(), 2);
        assertEq(target.totalValue(), uint256(value) + changedValue);
        assertEq(account.balance, 0);
    }

    function test_ManageAllowsAllNonzeroValueBitsWithSameProof() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("all value bits are caller supplied")));
        IMerkleAccount.Action memory action = _action(address(target), 1, data, _filledMask(data.length, 0));
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
        uint96[6] memory values = [uint96(1), 17, (1 << 95) - 1, 1 << 95, (1 << 95) + 17, type(uint96).max];
        uint256 total;
        for (uint256 i; i < values.length; ++i) {
            vm.deal(account, values[i]);
            action.value = values[i];
            MerkleAccount(payable(account)).manage(_singleton(action));
            total += values[i];
        }

        assertEq(target.callCount(), values.length);
        assertEq(target.totalValue(), total);
        assertEq(account.balance, 0);
    }

    function testFuzz_ManageRejectsChangedValueClass(uint96 nonzeroValue, bool startsWithZero) public {
        nonzeroValue = uint96(bound(nonzeroValue, 1, type(uint96).max));
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("zero and nonzero permissions")));
        IMerkleAccount.Action memory action =
            _action(address(target), startsWithZero ? 0 : nonzeroValue, data, _filledMask(data.length, 0));
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
        vm.deal(account, nonzeroValue);
        action.value = startsWithZero ? nonzeroValue : 0;

        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(target.callCount(), 0);
        assertEq(account.balance, nonzeroValue);
    }

    function test_ManageRequiresRoleForValueClass() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("value class role")));
        IMerkleAccount.Action memory action = _action(address(target), 0, data, _filledMask(data.length, 0));
        _grantLeaf(action, address(this));
        action.value = 1;
        _setMerkleRoot(_independentLeaf(action));
        vm.deal(account, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), _independentLeaf(action)
            )
        );
        MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(target.callCount(), 0);
        assertEq(account.balance, 1);
    }

    function test_ManageFullMaskAllowsEveryCalldataBitToChange() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAccount.Action memory action = _action(address(target), 0, hex"1234", hex"ffff");
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));

        bytes[] memory firstResults = MerkleAccount(payable(account)).manage(_singleton(action));
        action.data = hex"abcd";
        bytes[] memory changedResults = MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(firstResults.length, 1);
        assertEq(firstResults[0], bytes(""));
        assertEq(changedResults.length, 1);
        assertEq(changedResults[0], bytes(""));
    }

    function test_ManageZeroMaskRejectsAnyChangedCalldataBit() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAccount.Action memory action = _action(address(target), 0, hex"1234", hex"0000");
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));

        MerkleAccount(payable(account)).manage(_singleton(action));
        action.data = hex"1235";

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(action));
    }

    function test_ManagePartialMasksAllowUnconstrainedBitsAndRejectConstrainedBits() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAccount.Action memory action = _action(address(target), 0, hex"a53c", hex"0ff0");
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));

        action.data = hex"afbc";
        MerkleAccount(payable(account)).manage(_singleton(action));

        action.data = hex"bfbc";
        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(action));

        action.data = hex"afbd";
        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(action));
    }

    function test_ManageRejectsSubstitutedDataMaskProducingTheSameMaskedData() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAccount.Action memory action = _action(address(target), 0, hex"a0", hex"00");
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));

        // `dataMask` is caller-supplied, so a caller can loosen it and compensate in `data`: masking
        // 0xaf with variable bits 0x0f yields the authorized 0xa0. The leaf must commit the mask, otherwise every
        // bit the curator pinned to zero would be free.
        action.data = hex"af";
        action.dataMask = hex"0f";

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(action));
    }

    /// @dev The general form of the above: a pinned argument must not be satisfiable by any bitwise
    ///      superset using a substituted mask. Fuzzed over caller-controlled (data, dataMask) pairs.
    function testFuzz_ManageRejectsEverySubstitutedDataMaskPair(bytes32 authorized, bytes32 substitute) public {
        // An all-ones authorized value leaves both calldata and mask unchanged for every substitute.
        vm.assume(authorized != bytes32(type(uint256).max));

        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAccount.Action memory action =
            _action(address(target), 0, abi.encodePacked(authorized), _filledMask(32, 0));
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));

        // Any (data, dataMask) whose masked result still equals the authorized calldata.
        action.data = abi.encodePacked(authorized | substitute);
        action.dataMask = abi.encodePacked(~authorized);

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(action));
    }

    function test_ManageRejectsDataMaskLengthDifferentFromCalldataLength() public {
        address target = makeAddr("invalidLengthTarget");
        IMerkleAccount.Action memory action = _action(target, 0, hex"1234", hex"0000");
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
        action.dataMask = hex"00";

        vm.expectRevert(IMerkleAccount.InvalidDataMaskLength.selector);
        MerkleAccount(payable(account)).manage(_singleton(action));
    }

    function test_ManageVerifiesIndependentFourLeafSortedPairProof() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAccount.Action memory first = _action(address(target), 0, hex"00", hex"00");
        IMerkleAccount.Action memory second = _action(address(target), 0, hex"01", hex"00");
        IMerkleAccount.Action memory authorized = _action(address(target), 0, hex"02", hex"00");
        IMerkleAccount.Action memory fourth = _action(address(target), 0, hex"03", hex"00");
        bytes32 firstLeaf = _independentLeaf(first);
        bytes32 secondLeaf = _independentLeaf(second);
        bytes32 authorizedLeaf = _independentLeaf(authorized);
        bytes32 fourthLeaf = _independentLeaf(fourth);
        bytes32 firstBranch = _hashSortedPair(firstLeaf, secondLeaf);
        bytes32 secondBranch = _hashSortedPair(authorizedLeaf, fourthLeaf);
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = fourthLeaf;
        proof[1] = firstBranch;
        authorized.proof = proof;
        _grantLeaf(authorized, address(this));
        _setMerkleRoot(_hashSortedPair(firstBranch, secondBranch));

        bytes[] memory results = MerkleAccount(payable(account)).manage(_singleton(authorized));

        assertEq(results.length, 1);
        assertEq(results[0], bytes(""));
    }

    function test_ManageRejectsInvalidMerkleSibling() public {
        address target = makeAddr("invalidSiblingTarget");
        IMerkleAccount.Action memory action = _action(target, 0, hex"12", hex"00");
        IMerkleAccount.Action memory siblingAction = _action(target, 0, hex"34", hex"00");
        bytes32 actionLeaf = _independentLeaf(action);
        bytes32 sibling = _independentLeaf(siblingAction);
        _setMerkleRoot(_hashSortedPair(actionLeaf, sibling));
        action.proof = _singletonProof(bytes32(uint256(sibling) ^ 1));

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(action));
    }

    function test_ManageRejectsStaleProofAfterRootReplacement() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAccount.Action memory action = _action(address(target), 0, hex"12", hex"00");
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
        MerkleAccount(payable(account)).manage(_singleton(action));

        _setMerkleRoot(keccak256("replacement root"));

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(action));
    }

    function test_ManageZeroRootDisablesPreviouslyAuthorizedAction() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAccount.Action memory action = _action(address(target), 0, hex"12", hex"00");
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
        MerkleAccount(payable(account)).manage(_singleton(action));

        _setMerkleRoot(bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(action));
    }

    function test_ManageRejectsProofReplayedWithChangedTarget() public {
        address originalTarget = makeAddr("originalTarget");
        address changedTarget = makeAddr("changedTarget");
        bytes memory data = hex"12";
        bytes memory dataMask = hex"00";
        IMerkleAccount.Action memory original = _action(originalTarget, 0, data, dataMask);
        _setMerkleRoot(_independentLeaf(original));
        IMerkleAccount.Action memory changed = _action(changedTarget, 0, data, dataMask);

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(changed));
    }

    function test_ManageRejectsProofReplayedWithChangedCalldataLength() public {
        address target = makeAddr("changedLengthTarget");
        IMerkleAccount.Action memory original = _action(target, 0, hex"12", hex"00");
        _setMerkleRoot(_independentLeaf(original));
        IMerkleAccount.Action memory changed = _action(target, 0, hex"1200", hex"0000");

        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(_singleton(changed));
    }

    function test_ManagePreflightsEntireBatchBeforeFirstDispatch() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory firstData = abi.encodeCall(target.record, (keccak256("must not execute")));
        IMerkleAccount.Action memory first = _action(address(target), 0, firstData, _filledMask(firstData.length, 0));
        address secondTarget = makeAddr("invalidLastActionTarget");
        IMerkleAccount.Action memory invalidLast = _action(secondTarget, 0, hex"12", hex"00");
        bytes32 firstLeaf = _independentLeaf(first);
        bytes32 secondLeaf = _independentLeaf(invalidLast);
        first.proof = _singletonProof(secondLeaf);
        invalidLast.proof = _singletonProof(bytes32(uint256(firstLeaf) ^ 1));
        _grantLeaf(first, address(this));
        _grantLeaf(invalidLast, address(this));
        _setMerkleRoot(_hashSortedPair(firstLeaf, secondLeaf));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = first;
        actions[1] = invalidLast;

        vm.expectCall(address(target), firstData, uint64(0));
        vm.expectRevert(abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector));
        MerkleAccount(payable(account)).manage(actions);

        assertEq(target.callCount(), 0);
    }

    function test_ManageDispatchesInOrderAndReturnsPositionalData() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes32 firstMarker = keccak256("first result");
        bytes32 secondMarker = keccak256("second result");
        bytes memory firstData = abi.encodeCall(target.recordInOrder, (1, firstMarker));
        bytes memory secondData = abi.encodeCall(target.recordInOrder, (2, secondMarker));
        IMerkleAccount.Action memory first = _action(address(target), 0, firstData, _filledMask(firstData.length, 0));
        IMerkleAccount.Action memory second = _action(address(target), 0, secondData, _filledMask(secondData.length, 0));
        bytes32 firstLeaf = _independentLeaf(first);
        bytes32 secondLeaf = _independentLeaf(second);
        first.proof = _singletonProof(secondLeaf);
        second.proof = _singletonProof(firstLeaf);
        _grantLeaf(first, address(this));
        _grantLeaf(second, address(this));
        _setMerkleRoot(_hashSortedPair(firstLeaf, secondLeaf));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = first;
        actions[1] = second;

        bytes[] memory results = MerkleAccount(payable(account)).manage(actions);

        assertEq(target.callCount(), 2);
        assertEq(results.length, 2);
        assertEq(abi.decode(results[0], (bytes32)), firstMarker);
        assertEq(abi.decode(results[1], (bytes32)), secondMarker);
    }

    function test_ManageAcceptsEmptyBatch() public {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](0);

        vm.prank(unauthorized);
        bytes[] memory results = MerkleAccount(payable(account)).manage(actions);

        assertEq(results.length, 0);
    }

    function test_ManageEmptyBatchDoesNotChangeFlowOrDemand() public {
        asset.transfer(address(adapter), 50);
        oracle.setTotalAssets(50);
        delegator.requestDeallocate(address(adapter), 20);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](0);
        assertEq(MerkleAccount(payable(account)).manage(actions).length, 0);
        assertEq(adapter.deallocatable(), 0);
        assertEq(adapter.stagedLiquidity(), 20);
        assertEq(adapter.pendingDeallocation(), 20);
        assertEq(adapter.netFlow(), 0);
    }

    function test_ManageCannotTemporarilyReleaseReservedAssets() public {
        MerkleAdapterAssetReturnTarget returnTarget = new MerkleAdapterAssetReturnTarget();
        asset.transfer(address(vault), 50);
        delegator.allocate(address(adapter), 50);
        delegator.requestDeallocate(address(adapter), 50);

        bytes memory takeData = abi.encodeCall(IMerkleAdapter.push, (1));
        bytes memory returnData =
            abi.encodeCall(returnTarget.returnAsset, (IERC20(address(asset)), address(adapter), 1));
        IMerkleAccount.Action memory take = _action(address(adapter), 0, takeData, _filledMask(takeData.length, 0));
        IMerkleAccount.Action memory restore =
            _action(address(returnTarget), 0, returnData, _filledMask(returnData.length, 0));
        bytes32 takeLeaf = _independentLeaf(take);
        bytes32 restoreLeaf = _independentLeaf(restore);
        take.proof = _singletonProof(restoreLeaf);
        restore.proof = _singletonProof(takeLeaf);
        _grantLeaf(take, address(this));
        _grantLeaf(restore, address(this));
        _setMerkleRoot(_hashSortedPair(takeLeaf, restoreLeaf));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = take;
        actions[1] = restore;

        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(asset.balanceOf(address(adapter)), 50);
        assertEq(asset.balanceOf(address(returnTarget)), 0);
    }

    function test_ManageRejectsReleaseOfReservedAssets() public {
        asset.transfer(address(vault), 50);
        delegator.allocate(address(adapter), 50);
        delegator.requestDeallocate(address(adapter), 50);

        bytes memory data = abi.encodeCall(IMerkleAdapter.push, (1));
        IMerkleAccount.Action memory action = _action(address(adapter), 0, data, _filledMask(data.length, 0));
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));

        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        MerkleAccount(payable(account)).manage(_singleton(action));
        assertEq(asset.balanceOf(address(adapter)), 50);
    }

    function test_ManageAllowsProofReuseWhileRootAndRoleRemainUnchanged() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        address actionCaller = makeAddr("reusableProofCaller");
        bytes memory data = abi.encodeCall(target.record, (keccak256("reusable proof")));
        IMerkleAccount.Action memory action = _action(address(target), 0, data, _filledMask(data.length, 0));
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
        vm.prank(defaultAdminRoleHolder);
        MerkleAccount(payable(account)).grantRole(_independentLeaf(action), actionCaller);

        vm.startPrank(actionCaller);
        MerkleAccount(payable(account)).manage(_singleton(action));
        MerkleAccount(payable(account)).manage(_singleton(action));
        vm.stopPrank();

        assertEq(target.callCount(), 2);
    }

    function test_ManageBubblesExactTargetRevertAndRollsBackEarlierCalls() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory firstData = abi.encodeCall(target.record, (keccak256("rolled back")));
        uint256 errorCode = 77;
        bytes32 errorContext = keccak256("exact revert data");
        bytes memory secondData = abi.encodeCall(target.revertWith, (errorCode, errorContext));
        IMerkleAccount.Action memory first = _action(address(target), 0, firstData, _filledMask(firstData.length, 0));
        IMerkleAccount.Action memory second = _action(address(target), 0, secondData, _filledMask(secondData.length, 0));
        bytes32 firstLeaf = _independentLeaf(first);
        bytes32 secondLeaf = _independentLeaf(second);
        first.proof = _singletonProof(secondLeaf);
        second.proof = _singletonProof(firstLeaf);
        _grantLeaf(first, address(this));
        _grantLeaf(second, address(this));
        _setMerkleRoot(_hashSortedPair(firstLeaf, secondLeaf));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = first;
        actions[1] = second;

        vm.expectRevert(abi.encodeWithSelector(MerkleAdapterCallTarget.ForcedRevert.selector, errorCode, errorContext));
        MerkleAccount(payable(account)).manage(actions);

        assertEq(target.callCount(), 0);
        assertEq(target.lastMarker(), bytes32(0));
    }

    function test_ManageReceivesEtherAndDispatchesApprovedValue() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        uint96 receivedValue = 3 ether;
        uint96 dispatchedValue = 2 ether;
        vm.deal(address(this), receivedValue);

        (bool success,) = account.call{value: receivedValue}("");
        assertTrue(success);
        assertEq(account.balance, receivedValue);

        bytes32 marker = keccak256("value dispatch");
        bytes memory data = abi.encodeCall(target.record, (marker));
        IMerkleAccount.Action memory action =
            _action(address(target), dispatchedValue, data, _filledMask(data.length, 0));
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));

        MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(account.balance, receivedValue - dispatchedValue);
        assertEq(address(target).balance, dispatchedValue);
        assertEq(target.totalValue(), dispatchedValue);
        assertEq(target.lastMarker(), marker);
    }

    function test_ManageRejectsTargetWithoutCode() public {
        address target = makeAddr("targetWithoutCode");
        IMerkleAccount.Action memory action = _action(target, 0, bytes(""), bytes(""));
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));

        vm.expectRevert(abi.encodeWithSelector(Address.AddressEmptyCode.selector, target));
        MerkleAccount(payable(account)).manage(_singleton(action));
    }

    function test_ManageRejectsRecursiveManageCall() public {
        MerkleAdapterReentrantTarget target = new MerkleAdapterReentrantTarget(account);
        bytes memory innerData = abi.encodeCall(target.markReentered, ());
        IMerkleAccount.Action memory inner = _action(address(target), 0, innerData, _filledMask(innerData.length, 0));
        bytes memory outerData = abi.encodeCall(target.reenter, ());
        IMerkleAccount.Action memory outer = _action(address(target), 0, outerData, _filledMask(outerData.length, 0));
        bytes32 innerLeaf = _independentLeaf(inner);
        bytes32 outerLeaf = _independentLeaf(outer);
        inner.proof = _singletonProof(outerLeaf);
        outer.proof = _singletonProof(innerLeaf);
        _grantLeaf(outer, address(this));
        _grantLeaf(inner, address(target));
        _setMerkleRoot(_hashSortedPair(innerLeaf, outerLeaf));
        target.setReentrantCall(abi.encodeCall(MerkleAccount(payable(account)).manage, (_singleton(inner))));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        MerkleAccount(payable(account)).manage(_singleton(outer));

        assertEq(target.reenteredCount(), 0);
    }

    function testFuzz_ManageTransfersAcrossRepeatedLeavesAndCallers(uint96 amount, uint96 remaining) public {
        uint256 balance = asset.balanceOf(address(this));
        uint256 first = bound(amount, 1, balance / 3);
        uint256 last = bound(remaining, 1, balance - 2 * first);
        asset.transfer(account, 2 * first + last);
        IMerkleAccount.Action memory action = _transferAction(first);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = action;
        actions[1] = action;

        MerkleAccount(payable(account)).manage(actions);

        assertEq(asset.balanceOf(unauthorized), 2 * first);
        assertEq(asset.balanceOf(account), last);
        vm.prank(defaultAdminRoleHolder);
        MerkleAccount(payable(account)).grantRole(_independentLeaf(action), unauthorized);
        action.data = abi.encodeCall(IERC20.transfer, (unauthorized, last));
        vm.prank(unauthorized);
        MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(asset.balanceOf(unauthorized), 2 * first + last);
        assertEq(asset.balanceOf(account), 0);
    }

    function test_ManagedTransferCannotSpendSeparateReserves() public {
        asset.transfer(address(vault), 100);
        delegator.allocate(address(adapter), 100);
        IMerkleAccount.Action memory action = _transferAction(40);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, account, 0, 40));
        MerkleAccount(payable(account)).manage(_singleton(action));

        assertEq(asset.balanceOf(address(adapter)), 100);
        assertEq(asset.balanceOf(unauthorized), 0);
    }

    function _transferAction(uint256 amount) internal returns (IMerkleAccount.Action memory action) {
        bytes memory data = abi.encodeCall(IERC20.transfer, (unauthorized, amount));
        bytes memory mask = _filledMask(data.length, 0);
        for (uint256 i = 36; i < mask.length; ++i) {
            mask[i] = 0xff;
        }
        action = _action(address(asset), 0, data, mask);
        _grantLeaf(action, address(this));
        _setMerkleRoot(_independentLeaf(action));
    }

    function _action(address target, uint96 value, bytes memory data, bytes memory dataMask)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = IMerkleAccount.Action({
            target: target, value: value, data: data, dataMask: dataMask, proof: new bytes32[](0)
        });
    }

    function _singleton(IMerkleAccount.Action memory action)
        internal
        pure
        returns (IMerkleAccount.Action[] memory actions)
    {
        actions = new IMerkleAccount.Action[](1);
        actions[0] = action;
    }

    function _singletonProof(bytes32 sibling) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }

    function _filledMask(uint256 length, bytes1 value) internal pure returns (bytes memory dataMask) {
        dataMask = new bytes(length);
        for (uint256 i; i < length; ++i) {
            dataMask[i] = value;
        }
    }

    function _independentLeaf(IMerkleAccount.Action memory action) internal pure returns (bytes32) {
        bytes memory maskedData = new bytes(action.data.length);
        for (uint256 i; i < action.data.length; ++i) {
            maskedData[i] = action.data[i] & ~action.dataMask[i];
        }
        bytes32 inner = keccak256(
            abi.encode(
                action.target,
                action.value == 0 ? bytes1(0) : bytes1(0xff),
                keccak256(action.dataMask),
                keccak256(maskedData)
            )
        );
        return keccak256(bytes.concat(inner));
    }

    function _hashSortedPair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return left < right ? keccak256(bytes.concat(left, right)) : keccak256(bytes.concat(right, left));
    }

    function _grantLeaf(IMerkleAccount.Action memory action, address holder) internal {
        vm.prank(defaultAdminRoleHolder);
        MerkleAccount(payable(account)).grantRole(_independentLeaf(action), holder);
    }

    function _setMerkleRoot(bytes32 root) internal {
        vm.prank(protocolOwner);
        rootRegistry.setRoot(account, root);
        vm.prank(adapterOwner);
        MerkleAccount(payable(account)).acceptRoot(root);
    }
}

contract MerkleAdapterVaultRegistry is Registry {
    function add(address entity) external {
        _addEntity(entity);
    }
}

contract MerkleAdapterVaultMock {
    address public immutable asset;
    address public delegator;

    constructor(address asset_) {
        asset = asset_;
    }

    function setDelegator(address delegator_) external {
        delegator = delegator_;
    }

    function pull(uint256 amount, address recipient) external {
        IERC20(asset).transfer(recipient, amount);
    }

    function push(uint256 amount, address provider) external {
        IERC20(asset).transferFrom(provider, address(this), amount);
    }
}

contract MerkleAdapterDelegatorMock {
    address public immutable VAULT;

    constructor(address vault) {
        VAULT = vault;
    }

    function allocate(address adapter, uint256 amount) external returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        MerkleAdapterVaultMock(VAULT).pull(amount, adapter);
        uint256 allocated = IAdapter(adapter).allocate(amount);
        if (allocated < amount) {
            MerkleAdapterVaultMock(VAULT).push(amount - allocated, adapter);
        }
        IAdapter(adapter).totalAssets();
        return allocated;
    }

    function deallocate(address adapter, uint256 amount) external returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        uint256 deallocated = IAdapter(adapter).deallocate(amount);
        if (deallocated > 0) {
            MerkleAdapterVaultMock(VAULT).push(deallocated, adapter);
        }
        // Mirror UniversalDelegator's final NAV read when emitting Deallocate.
        IAdapter(adapter).totalAssets();
        return deallocated;
    }

    function requestDeallocate(address adapter, uint256 amount) external {
        IAdapter(adapter).requestDeallocate(amount);
    }
}

contract MerkleAdapterCallTarget {
    error ForcedRevert(uint256 code, bytes32 context);
    error UnexpectedCallOrder(uint256 expected, uint256 actual);

    uint256 public callCount;
    uint256 public totalValue;
    bytes32 public lastMarker;

    function record(bytes32 marker) external payable returns (bytes32) {
        ++callCount;
        totalValue += msg.value;
        lastMarker = marker;
        return marker;
    }

    function recordInOrder(uint256 expectedOrder, bytes32 marker) external returns (bytes32) {
        uint256 actualOrder = callCount + 1;
        if (actualOrder != expectedOrder) {
            revert UnexpectedCallOrder(expectedOrder, actualOrder);
        }
        callCount = actualOrder;
        lastMarker = marker;
        return marker;
    }

    function revertWith(uint256 code, bytes32 context) external pure {
        revert ForcedRevert(code, context);
    }
}

contract MerkleAdapterFallbackTarget {
    fallback() external payable {}
}

contract MerkleAdapterAssetReturnTarget {
    function returnAsset(IERC20 asset, address recipient, uint256 amount) external {
        asset.transfer(recipient, amount);
    }
}

contract MerkleAdapterReentrantTarget {
    address public immutable ADAPTER;

    bytes internal _reentrantCall;
    uint256 public reenteredCount;

    constructor(address adapter_) {
        ADAPTER = adapter_;
    }

    function setReentrantCall(bytes calldata reentrantCall) external {
        _reentrantCall = reentrantCall;
    }

    function reenter() external {
        (bool success, bytes memory returnData) = ADAPTER.call(_reentrantCall);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function markReentered() external {
        ++reenteredCount;
    }
}

contract MerkleAdapterOracleMock is MigratableEntity, IMerkleAdapterOracle {
    error ForcedTotalAssetsRevert(uint256 code);

    address public adapter;
    uint256 public initDataLength;
    bytes public initData;
    int256 public valuationOffset;
    uint256 internal _revertCode;

    constructor(address factory) MigratableEntity(factory) {}

    function validate() external view returns (uint256 assets) {
        if (_revertCode != 0) revert ForcedTotalAssetsRevert(_revertCode);
        return totalAssets();
    }

    function setTotalAssets(uint256 assets) external {
        require(assets <= uint256(type(int256).max), "mock NAV overflow");
        valuationOffset = int256(assets) - IMerkleAdapter(adapter).netFlow();
    }

    function settle(uint48 snapshotBlock) external {
        IMerkleAdapter(adapter).settleReport(snapshotBlock, totalAssets());
    }

    function setRevertCode(uint256 code) external {
        _revertCode = code;
    }

    function totalAssets() public view returns (uint256 assets) {
        int256 adjusted = valuationOffset + IMerkleAdapter(adapter).netFlow();
        require(adjusted >= 0, "negative mock NAV");
        return uint256(adjusted);
    }

    function _initialize(uint64, address, bytes memory data) internal override {
        initDataLength = data.length;
        (address adapter_, bytes memory oracleData) = abi.decode(data, (address, bytes));
        adapter = adapter_;
        initData = oracleData;
    }
}
