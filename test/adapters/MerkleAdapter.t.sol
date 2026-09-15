// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {AdapterFactory} from "../../src/contracts/AdapterFactory.sol";
import {MerkleAdapter} from "../../src/contracts/MerkleAdapter.sol";
import {RootRegistry} from "../../src/contracts/merkle_adapter/RootRegistry.sol";
import {MerkleAdapterVerifier} from "../../src/contracts/merkle_adapter/libraries/MerkleAdapterVerifier.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {Registry} from "@symbioticfi/core/src/contracts/common/Registry.sol";
import {IAdapter} from "../../src/interfaces/IAdapter.sol";
import {ANY_ROLE, ANY_VALUE, ANY_VALUE_FLAG, IMerkleAdapter} from "../../src/interfaces/IMerkleAdapter.sol";
import {IMerkleAdapterOracle} from "../../src/interfaces/merkle_adapter/IMerkleAdapterOracle.sol";
import {IRootRegistry} from "../../src/interfaces/merkle_adapter/IRootRegistry.sol";

import {Token} from "../mocks/Token.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract MerkleAdapterVerifierTest is Test {
    MerkleAdapterVerifierHarness internal harness;

    bytes32 internal constant ROLE = bytes32(uint256(0x1234));
    address internal constant TARGET = 0x000000000000000000000000000000000000bEEF;
    uint96 internal constant VALUE = 7;
    /// @dev Golden vector for leaf(ROLE, TARGET, VALUE, 0xaabbccdd, 0xff00f00f). Commits the mask
    ///      alongside the masked calldata, so it differs from the mask-free encoding.
    bytes32 internal constant EXPECTED_LEAF = 0xf2ca80c529620c019305718ac97f474105797055206438d3926ec8edf509f24a;

    function setUp() public {
        harness = new MerkleAdapterVerifierHarness();
    }

    function test_MaskDataAppliesEachMaskByte() public view {
        assertEq(harness.maskData(hex"aabbccdd", hex"ff00f00f"), hex"aa00c00d");
    }

    function test_LeafUsesCanonicalDoubleHashedEncoding() public view {
        assertEq(harness.leaf(ROLE, TARGET, VALUE, hex"aabbccdd", hex"ff00f00f"), EXPECTED_LEAF);
    }

    function test_VerifyAcceptsEmptyProofForMatchingLeafRoot() public view {
        bytes32[] memory proof = new bytes32[](0);

        assertTrue(harness.verify(proof, EXPECTED_LEAF, ROLE, TARGET, VALUE, hex"aabbccdd", hex"ff00f00f"));
    }

    function test_VerifyRejectsEmptyProofForDifferentRoot() public view {
        bytes32[] memory proof = new bytes32[](0);

        assertFalse(
            harness.verify(
                proof, bytes32(uint256(EXPECTED_LEAF) + 1), ROLE, TARGET, VALUE, hex"aabbccdd", hex"ff00f00f"
            )
        );
    }

    function test_MaskDataRevertsWhenMaskLengthDiffersFromCalldataLength() public {
        vm.expectRevert(IMerkleAdapter.InvalidDataMaskLength.selector);
        harness.maskData(hex"aabbccdd", hex"ff00f0");
    }
}

contract MerkleAdapterVerifierHarness {
    function maskData(bytes calldata data, bytes calldata dataMask) external pure returns (bytes memory) {
        return MerkleAdapterVerifier.maskData(data, dataMask);
    }

    function leaf(bytes32 role, address target, uint96 value, bytes calldata data, bytes calldata dataMask)
        external
        pure
        returns (bytes32)
    {
        return MerkleAdapterVerifier.leaf(role, target, value, data, dataMask);
    }

    function verify(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 role,
        address target,
        uint96 value,
        bytes calldata data,
        bytes calldata dataMask
    ) external pure returns (bool) {
        return MerkleAdapterVerifier.verify(proof, root, role, target, value, data, dataMask);
    }
}

contract MerkleAdapterLifecycleTest is Test {
    bytes32 internal constant INITIAL_ROOT = keccak256("initial root");
    bytes32 internal constant NEXT_ROOT = keccak256("next root");
    bytes32 internal constant ACTION_ROLE = keccak256("action role");
    bytes32 internal constant SECOND_ACTION_ROLE = keccak256("second action role");
    MerkleAdapterVaultRegistry internal vaultFactory;
    AdapterFactory internal adapterFactory;
    MigratablesFactory internal oracleFactory;
    RootRegistry internal rootRegistry;
    MerkleAdapterOracleMock internal oracleImplementation;
    MerkleAdapterVaultMock internal vault;
    MerkleAdapterDelegatorMock internal delegator;
    Token internal asset;
    MerkleAdapter internal adapter;
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
            address(vaultFactory), address(adapterFactory), address(oracleFactory), address(rootRegistry)
        );
        adapterFactory.whitelist(address(implementation));

        IMerkleAdapter.InitParams memory params =
            IMerkleAdapter.InitParams({defaultAdminRoleHolder: defaultAdminRoleHolder});
        adapter = MerkleAdapter(
            payable(adapterFactory.create(1, adapterOwner, abi.encode(address(vault), abi.encode(params))))
        );
        oracle = MerkleAdapterOracleMock(adapter.oracle());
        _setMerkleRoot(INITIAL_ROOT);
    }

    function test_InitializeStoresRegistryDefaultAdminAndLatestVersionOracle() public view {
        assertEq(adapter.ORACLE_FACTORY(), address(oracleFactory));
        assertEq(adapter.ROOT_REGISTRY(), address(rootRegistry));
        assertEq(adapter.merkleRoot(), INITIAL_ROOT);

        assertEq(adapter.getRoleMemberCount(adapter.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(adapter.getRoleMember(adapter.DEFAULT_ADMIN_ROLE(), 0), defaultAdminRoleHolder);
        assertFalse(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), adapterOwner));

        assertEq(oracleFactory.totalEntities(), 1);
        assertEq(oracleFactory.lastVersion(), 2);
        assertEq(oracleFactory.implementation(oracleFactory.lastVersion()), address(oracleImplementation));
        assertEq(oracle.version(), oracleFactory.lastVersion());
        assertEq(oracle.owner(), adapterOwner);
        assertEq(oracle.initDataLength(), 32);
        assertEq(oracle.adapter(), address(adapter));
        assertEq(IAdapter(oracle.adapter()).vault(), address(vault));
    }

    function test_ConstantGetterSelectorsAreUnavailable() public {
        bytes4[4] memory selectors = [
            bytes4(keccak256("ANY_ROLE()")),
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
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertFalse(adapter.supportsInterface(0xffffffff));
        assertFalse(adapter.supportsInterface(type(IMerkleAdapter).interfaceId));
    }

    function test_InitializeOmitsZeroRoleHolders() public {
        IMerkleAdapter.InitParams memory params = IMerkleAdapter.InitParams({defaultAdminRoleHolder: address(0)});

        MerkleAdapter zeroOwnerAdapter = MerkleAdapter(
            payable(adapterFactory.create(1, address(0), abi.encode(address(vault), abi.encode(params))))
        );

        assertEq(zeroOwnerAdapter.owner(), address(0));
        assertEq(zeroOwnerAdapter.merkleRoot(), bytes32(0));
        assertEq(zeroOwnerAdapter.getRoleMemberCount(zeroOwnerAdapter.DEFAULT_ADMIN_ROLE()), 0);
        assertEq(MerkleAdapterOracleMock(zeroOwnerAdapter.oracle()).owner(), address(0));
    }

    function test_InitializeStartsWithZeroRootAndOnlyDefaultAdmin() public {
        IMerkleAdapter.InitParams memory params =
            IMerkleAdapter.InitParams({defaultAdminRoleHolder: defaultAdminRoleHolder});
        MerkleAdapter newAdapter = MerkleAdapter(
            payable(adapterFactory.create(1, adapterOwner, abi.encode(address(vault), abi.encode(params))))
        );

        assertEq(newAdapter.merkleRoot(), bytes32(0));
        assertEq(newAdapter.getRoleMemberCount(newAdapter.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(newAdapter.getRoleMember(newAdapter.DEFAULT_ADMIN_ROLE(), 0), defaultAdminRoleHolder);
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
        rootRegistry.setRoot(address(adapter), NEXT_ROOT);
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

    function test_AllocationIsPendingUntilTheSecondOracleUpdate() public {
        asset.transfer(address(vault), 150);
        assertEq(delegator.allocate(address(adapter), 100), 100);
        assertEq(adapter.pendingAllocation(1), 100);
        assertEq(adapter.totalAssets(), 100);

        oracle.setNonce(1);
        assertEq(delegator.allocate(address(adapter), 50), 50);
        assertEq(adapter.pendingAllocation(2), 50);
        assertEq(adapter.totalAssets(), 150);

        oracle.setTotalAssets(100);
        oracle.setNonce(2);
        assertEq(adapter.totalAssets(), 150);

        oracle.setTotalAssets(150);
        oracle.setNonce(3);
        assertEq(adapter.totalAssets(), 150);
    }

    function test_ActiveAllocationAndRequestNetInBothDirections() public {
        asset.transfer(address(adapter), 40);
        asset.transfer(address(vault), 50);
        oracle.setTotalAssets(40);
        delegator.requestDeallocate(address(adapter), 30);

        assertEq(delegator.allocate(address(adapter), 50), 20);
        assertEq(adapter.toDeallocate(1), 0);
        assertEq(adapter.pendingAllocation(1), 20);

        delegator.requestDeallocate(address(adapter), 10);
        assertEq(adapter.pendingAllocation(1), 10);
        assertEq(adapter.deallocatable(), 10);
        assertEq(delegator.deallocate(address(adapter), 10), 10);
        assertEq(adapter.totalAssets(), 50);
    }

    function test_RequestDeallocateOnlyAdjustsTheActiveEpoch() public {
        asset.transfer(address(adapter), 100);
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 30);

        oracle.setNonce(1);
        delegator.requestDeallocate(address(adapter), 50);
        assertEq(adapter.toDeallocate(1), 30);
        assertEq(adapter.toDeallocate(2), 20);

        delegator.requestDeallocate(address(adapter), 40);
        assertEq(adapter.toDeallocate(1), 30);
        assertEq(adapter.toDeallocate(2), 10);

        delegator.requestDeallocate(address(adapter), 10);
        assertEq(adapter.toDeallocate(1), 30);
        assertEq(adapter.toDeallocate(2), 0);
    }

    function test_RequestDeallocateDoesNotRequireIdleBalance() public {
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 100);
        assertEq(adapter.toDeallocate(1), 100);
        adapter.manage(new IMerkleAdapter.Action[](0));
    }

    function test_MaturedDeallocationRequiresIdleBalance() public {
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 50);
        oracle.setTotalAssets(50);
        oracle.setNonce(2);

        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        adapter.manage(new IMerkleAdapter.Action[](0));
    }

    function test_DeallocateReturnsOnlyMaturedRequestedAssets() public {
        asset.transfer(address(adapter), 100);
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 40);

        assertEq(delegator.deallocate(address(adapter), 100), 0);
        oracle.setNonce(1);
        assertEq(delegator.deallocate(address(adapter), 100), 0);

        oracle.setTotalAssets(60);
        oracle.setNonce(2);
        adapter.manage(new IMerkleAdapter.Action[](0));
        assertEq(adapter.deallocatable(), 40);
        assertEq(adapter.totalAssets(), 100);
        assertEq(delegator.deallocate(address(adapter), 100), 40);
        assertEq(asset.balanceOf(address(adapter)), 60);
        assertEq(asset.balanceOf(address(vault)), 40);
    }

    function test_SkippedOracleNoncesSettleBothTrackedEpochs() public {
        asset.transfer(address(adapter), 100);
        oracle.setTotalAssets(100);
        delegator.requestDeallocate(address(adapter), 20);

        oracle.setNonce(1);
        delegator.requestDeallocate(address(adapter), 50);
        assertEq(adapter.toDeallocate(1), 20);
        assertEq(adapter.toDeallocate(2), 30);

        oracle.setTotalAssets(50);
        oracle.setNonce(4);
        adapter.manage(new IMerkleAdapter.Action[](0));

        assertEq(adapter.deallocatable(), 50);
        assertEq(adapter.totalAssets(), 100);
        assertEq(delegator.deallocate(address(adapter), 50), 50);
        assertEq(adapter.lastSyncedNonce(), 4);
    }

    function test_DeallocateDoesNotReturnUnrequestedIdleAssets() public {
        asset.transfer(address(adapter), 75);
        oracle.setTotalAssets(75);
        assertEq(delegator.deallocate(address(adapter), 75), 0);
        assertEq(asset.balanceOf(address(adapter)), 75);
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

    function test_AcceptRootStoresExactPublishedRootAndEmits() public {
        vm.prank(protocolOwner);
        rootRegistry.setRoot(address(adapter), NEXT_ROOT);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IMerkleAdapter.SetMerkleRoot(NEXT_ROOT);
        vm.prank(adapterOwner);
        adapter.acceptRoot(NEXT_ROOT);
        assertEq(adapter.merkleRoot(), NEXT_ROOT);
    }

    function test_AcceptRootRejectsUnpublishedRoot() public {
        vm.prank(adapterOwner);
        vm.expectRevert(IMerkleAdapter.InvalidRoot.selector);
        adapter.acceptRoot(NEXT_ROOT);
    }

    function test_AcceptRootRejectsNonOwner() public {
        vm.prank(protocolOwner);
        rootRegistry.setRoot(address(adapter), NEXT_ROOT);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        adapter.acceptRoot(NEXT_ROOT);
    }

    function test_AcceptRootAcceptsZeroToDisableProofs() public {
        vm.prank(protocolOwner);
        rootRegistry.setRoot(address(adapter), bytes32(0));

        vm.prank(adapterOwner);
        adapter.acceptRoot(bytes32(0));

        assertEq(adapter.merkleRoot(), bytes32(0));
    }

    function test_DefaultAdminGrantsRevokesAndEnumeratesRoles() public {
        address actionCaller = makeAddr("actionCaller");
        address secondActionCaller = makeAddr("secondActionCaller");

        vm.startPrank(defaultAdminRoleHolder);
        adapter.grantRole(ACTION_ROLE, actionCaller);
        adapter.grantRole(ACTION_ROLE, secondActionCaller);
        vm.stopPrank();

        assertEq(adapter.getRoleMemberCount(ACTION_ROLE), 2);
        assertEq(adapter.getRoleMember(ACTION_ROLE, 0), actionCaller);
        assertEq(adapter.getRoleMember(ACTION_ROLE, 1), secondActionCaller);

        vm.prank(defaultAdminRoleHolder);
        adapter.revokeRole(ACTION_ROLE, actionCaller);

        assertEq(adapter.getRoleMemberCount(ACTION_ROLE), 1);
        assertEq(adapter.getRoleMember(ACTION_ROLE, 0), secondActionCaller);
    }

    function test_ManageAllowsAnyRoleFromUnassignedCaller() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes32 marker = keccak256("public action");
        bytes memory data = abi.encodeCall(target.record, (marker));
        IMerkleAdapter.Action memory action =
            _action(ANY_ROLE, address(target), 0, data, _filledMask(data.length, 0xff));
        _setMerkleRoot(_independentLeaf(action));

        vm.prank(unauthorized);
        bytes[] memory results = adapter.manage(_singleton(action));

        assertEq(results.length, 1);
        assertEq(abi.decode(results[0], (bytes32)), marker);
        assertEq(target.callCount(), 1);
    }

    function test_ManageUsesValueWildcardFlagAndLow95BitValue() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        uint96 callValue = 17;
        bytes32 marker = keccak256("packed wildcard flags");
        bytes memory data = abi.encodeCall(target.record, (marker));
        bytes memory dataMask = _filledMask(data.length, 0xff);
        IMerkleAdapter.Action memory action = IMerkleAdapter.Action({
            role: ANY_ROLE,
            target: address(target),
            flagsAndValue: ANY_VALUE_FLAG | callValue,
            data: data,
            dataMask: dataMask,
            proof: new bytes32[](0)
        });
        bytes memory maskedData = data;
        bytes32 inner =
            keccak256(abi.encode(action.role, action.target, ANY_VALUE, keccak256(dataMask), keccak256(maskedData)));
        _setMerkleRoot(keccak256(bytes.concat(inner)));
        vm.deal(address(adapter), callValue);

        adapter.manage(_singleton(action));

        assertEq(target.totalValue(), callValue);
        assertEq(target.lastMarker(), marker);
    }

    function test_ManageAllowsGrantedNonPublicRole() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        address actionCaller = makeAddr("actionCaller");
        bytes32 marker = keccak256("restricted action");
        bytes memory data = abi.encodeCall(target.record, (marker));
        IMerkleAdapter.Action memory action =
            _action(ACTION_ROLE, address(target), 0, data, _filledMask(data.length, 0xff));
        _setMerkleRoot(_independentLeaf(action));

        vm.prank(defaultAdminRoleHolder);
        adapter.grantRole(ACTION_ROLE, actionCaller);

        vm.prank(actionCaller);
        adapter.manage(_singleton(action));

        assertEq(target.callCount(), 1);
        assertEq(target.lastMarker(), marker);
    }

    function test_ManageRejectsCallerWithoutActionRoleBeforeDispatch() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory data = abi.encodeCall(target.record, (keccak256("unauthorized action")));
        IMerkleAdapter.Action memory action =
            _action(ACTION_ROLE, address(target), 0, data, _filledMask(data.length, 0xff));
        _setMerkleRoot(_independentLeaf(action));

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, ACTION_ROLE)
        );
        adapter.manage(_singleton(action));

        assertEq(target.callCount(), 0);
    }

    function test_ManageRequiresEveryRoleInMixedRoleBatch() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        address actionCaller = makeAddr("mixedRoleCaller");
        bytes memory firstData = abi.encodeCall(target.record, (keccak256("public")));
        bytes memory secondData = abi.encodeCall(target.record, (keccak256("restricted")));
        IMerkleAdapter.Action memory first =
            _action(ANY_ROLE, address(target), 0, firstData, _filledMask(firstData.length, 0xff));
        IMerkleAdapter.Action memory second =
            _action(ACTION_ROLE, address(target), 0, secondData, _filledMask(secondData.length, 0xff));
        bytes32 firstLeaf = _independentLeaf(first);
        bytes32 secondLeaf = _independentLeaf(second);
        first.proof = _singletonProof(secondLeaf);
        second.proof = _singletonProof(firstLeaf);
        _setMerkleRoot(_hashSortedPair(firstLeaf, secondLeaf));
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = first;
        actions[1] = second;

        vm.prank(actionCaller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, actionCaller, ACTION_ROLE)
        );
        adapter.manage(actions);
        assertEq(target.callCount(), 0);

        vm.prank(defaultAdminRoleHolder);
        adapter.grantRole(ACTION_ROLE, actionCaller);
        vm.prank(actionCaller);
        adapter.manage(actions);
        assertEq(target.callCount(), 2);
    }

    function test_ManageRejectsProofReplayedAcrossRestrictedRolesOrAsAnyRole() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        address actionCaller = makeAddr("crossRoleCaller");
        bytes memory data = abi.encodeCall(target.record, (keccak256("role-bound")));
        bytes memory dataMask = _filledMask(data.length, 0xff);
        IMerkleAdapter.Action memory authorized = _action(ACTION_ROLE, address(target), 0, data, dataMask);
        _setMerkleRoot(_independentLeaf(authorized));

        vm.startPrank(defaultAdminRoleHolder);
        adapter.grantRole(ACTION_ROLE, actionCaller);
        adapter.grantRole(SECOND_ACTION_ROLE, actionCaller);
        vm.stopPrank();

        IMerkleAdapter.Action memory changedRestrictedRole =
            _action(SECOND_ACTION_ROLE, address(target), 0, data, dataMask);
        vm.prank(actionCaller);
        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(changedRestrictedRole));

        IMerkleAdapter.Action memory changedToAnyRole = _action(ANY_ROLE, address(target), 0, data, dataMask);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(changedToAnyRole));

        assertEq(target.callCount(), 0);
    }

    function test_ManageUsesLow95BitsAsExactValue() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        uint96 callValue = 17;
        bytes32 marker = keccak256("exact target and value");
        bytes memory data = abi.encodeCall(target.record, (marker));
        IMerkleAdapter.Action memory action =
            _action(ANY_ROLE, address(target), callValue, data, _filledMask(data.length, 0xff));
        _setMerkleRoot(_independentLeaf(action));
        vm.deal(address(adapter), callValue);

        adapter.manage(_singleton(action));

        assertEq(target.callCount(), 1);
        assertEq(target.totalValue(), callValue);
    }

    function test_ManageValueWildcardExecutesDifferentLow95BitValues() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        uint96 ordinaryValue = 13;
        uint96 largeValue = ANY_VALUE - 29;
        bytes memory data = abi.encodeCall(target.record, (keccak256("value wildcard")));
        bytes memory dataMask = _filledMask(data.length, 0xff);
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, address(target), ANY_VALUE_FLAG, data, dataMask);
        _setMerkleRoot(_independentLeaf(action));
        vm.deal(address(adapter), ordinaryValue + largeValue);

        adapter.manage(_singleton(action));
        action.flagsAndValue = ANY_VALUE_FLAG | ordinaryValue;
        adapter.manage(_singleton(action));
        action.flagsAndValue = ANY_VALUE_FLAG | largeValue;
        adapter.manage(_singleton(action));

        assertEq(target.callCount(), 3);
        assertEq(target.totalValue(), ordinaryValue + largeValue);
    }

    function test_ManageZeroMaskAllowsEveryCalldataBitToChange() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, address(target), 0, hex"1234", hex"0000");
        _setMerkleRoot(_independentLeaf(action));

        bytes[] memory firstResults = adapter.manage(_singleton(action));
        action.data = hex"abcd";
        bytes[] memory changedResults = adapter.manage(_singleton(action));

        assertEq(firstResults.length, 1);
        assertEq(firstResults[0], bytes(""));
        assertEq(changedResults.length, 1);
        assertEq(changedResults[0], bytes(""));
    }

    function test_ManageFullMaskRejectsAnyChangedCalldataBit() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, address(target), 0, hex"1234", hex"ffff");
        _setMerkleRoot(_independentLeaf(action));

        adapter.manage(_singleton(action));
        action.data = hex"1235";

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(action));
    }

    function test_ManagePartialMasksAllowUnconstrainedBitsAndRejectConstrainedBits() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, address(target), 0, hex"a53c", hex"f00f");
        _setMerkleRoot(_independentLeaf(action));

        action.data = hex"afbc";
        adapter.manage(_singleton(action));

        action.data = hex"bfbc";
        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(action));

        action.data = hex"afbd";
        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(action));
    }

    function test_ManageRejectsSubstitutedDataMaskProducingTheSameMaskedData() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, address(target), 0, hex"a0", hex"ff");
        _setMerkleRoot(_independentLeaf(action));

        // `dataMask` is caller-supplied, so a caller can loosen it and compensate in `data`: masking
        // 0xaf with 0xf0 yields the authorized 0xa0. The leaf must commit the mask, otherwise every
        // bit the curator pinned to zero would be free.
        action.data = hex"af";
        action.dataMask = hex"f0";

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(action));
    }

    /// @dev The general form of the above: a pinned argument must not be satisfiable by any bitwise
    ///      superset. Fuzzed over the whole caller-controlled (data, dataMask) pair space.
    function testFuzz_ManageRejectsEverySubstitutedDataMaskPair(bytes32 authorized, bytes32 substitute) public {
        vm.assume(authorized != substitute);

        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAdapter.Action memory action =
            _action(ANY_ROLE, address(target), 0, abi.encodePacked(authorized), _filledMask(32, 0xff));
        _setMerkleRoot(_independentLeaf(action));

        // Any (data, dataMask) whose masked result still equals the authorized calldata.
        action.data = abi.encodePacked(authorized | substitute);
        action.dataMask = abi.encodePacked(authorized);

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(action));
    }

    function test_ManageRejectsDataMaskLengthDifferentFromCalldataLength() public {
        address target = makeAddr("invalidLengthTarget");
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, target, 0, hex"1234", hex"ffff");
        _setMerkleRoot(_independentLeaf(action));
        action.dataMask = hex"ff";

        vm.expectRevert(IMerkleAdapter.InvalidDataMaskLength.selector);
        adapter.manage(_singleton(action));
    }

    function test_ManageVerifiesIndependentFourLeafSortedPairProof() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAdapter.Action memory first = _action(ANY_ROLE, address(target), 0, hex"00", hex"ff");
        IMerkleAdapter.Action memory second = _action(ANY_ROLE, address(target), 0, hex"01", hex"ff");
        IMerkleAdapter.Action memory authorized = _action(ANY_ROLE, address(target), 0, hex"02", hex"ff");
        IMerkleAdapter.Action memory fourth = _action(ANY_ROLE, address(target), 0, hex"03", hex"ff");
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
        _setMerkleRoot(_hashSortedPair(firstBranch, secondBranch));

        bytes[] memory results = adapter.manage(_singleton(authorized));

        assertEq(results.length, 1);
        assertEq(results[0], bytes(""));
    }

    function test_ManageRejectsInvalidMerkleSibling() public {
        address target = makeAddr("invalidSiblingTarget");
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, target, 0, hex"12", hex"ff");
        IMerkleAdapter.Action memory siblingAction = _action(ANY_ROLE, target, 0, hex"34", hex"ff");
        bytes32 actionLeaf = _independentLeaf(action);
        bytes32 sibling = _independentLeaf(siblingAction);
        _setMerkleRoot(_hashSortedPair(actionLeaf, sibling));
        action.proof = _singletonProof(bytes32(uint256(sibling) ^ 1));

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(action));
    }

    function test_ManageRejectsStaleProofAfterRootReplacement() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, address(target), 0, hex"12", hex"ff");
        _setMerkleRoot(_independentLeaf(action));
        adapter.manage(_singleton(action));

        _setMerkleRoot(keccak256("replacement root"));

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(action));
    }

    function test_ManageZeroRootDisablesPreviouslyAuthorizedAction() public {
        MerkleAdapterFallbackTarget target = new MerkleAdapterFallbackTarget();
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, address(target), 0, hex"12", hex"ff");
        _setMerkleRoot(_independentLeaf(action));
        adapter.manage(_singleton(action));

        _setMerkleRoot(bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(action));
    }

    function test_ManageRejectsProofReplayedWithChangedTarget() public {
        address originalTarget = makeAddr("originalTarget");
        address changedTarget = makeAddr("changedTarget");
        bytes memory data = hex"12";
        bytes memory dataMask = hex"ff";
        IMerkleAdapter.Action memory original = _action(ANY_ROLE, originalTarget, 0, data, dataMask);
        _setMerkleRoot(_independentLeaf(original));
        IMerkleAdapter.Action memory changed = _action(ANY_ROLE, changedTarget, 0, data, dataMask);

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(changed));
    }

    function test_ManageRejectsProofReplayedWithChangedValue() public {
        address target = makeAddr("changedValueTarget");
        IMerkleAdapter.Action memory original = _action(ANY_ROLE, target, 0, hex"12", hex"ff");
        _setMerkleRoot(_independentLeaf(original));
        IMerkleAdapter.Action memory changed = _action(ANY_ROLE, target, 1, hex"12", hex"ff");
        vm.deal(address(adapter), 1);

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(changed));
    }

    function test_ManageRejectsProofReplayedWithChangedCalldataLength() public {
        address target = makeAddr("changedLengthTarget");
        IMerkleAdapter.Action memory original = _action(ANY_ROLE, target, 0, hex"12", hex"ff");
        _setMerkleRoot(_independentLeaf(original));
        IMerkleAdapter.Action memory changed = _action(ANY_ROLE, target, 0, hex"1200", hex"ffff");

        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 0));
        adapter.manage(_singleton(changed));
    }

    function test_ManagePreflightsEntireBatchBeforeFirstDispatch() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory firstData = abi.encodeCall(target.record, (keccak256("must not execute")));
        IMerkleAdapter.Action memory first =
            _action(ANY_ROLE, address(target), 0, firstData, _filledMask(firstData.length, 0xff));
        address secondTarget = makeAddr("invalidLastActionTarget");
        IMerkleAdapter.Action memory invalidLast = _action(ANY_ROLE, secondTarget, 0, hex"12", hex"ff");
        bytes32 firstLeaf = _independentLeaf(first);
        bytes32 secondLeaf = _independentLeaf(invalidLast);
        first.proof = _singletonProof(secondLeaf);
        invalidLast.proof = _singletonProof(bytes32(uint256(firstLeaf) ^ 1));
        _setMerkleRoot(_hashSortedPair(firstLeaf, secondLeaf));
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = first;
        actions[1] = invalidLast;

        vm.expectCall(address(target), firstData, uint64(0));
        vm.expectRevert(abi.encodeWithSelector(IMerkleAdapter.InvalidMerkleProof.selector, 1));
        adapter.manage(actions);

        assertEq(target.callCount(), 0);
    }

    function test_ManageDispatchesInOrderAndReturnsPositionalData() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes32 firstMarker = keccak256("first result");
        bytes32 secondMarker = keccak256("second result");
        bytes memory firstData = abi.encodeCall(target.recordInOrder, (1, firstMarker));
        bytes memory secondData = abi.encodeCall(target.recordInOrder, (2, secondMarker));
        IMerkleAdapter.Action memory first =
            _action(ANY_ROLE, address(target), 0, firstData, _filledMask(firstData.length, 0xff));
        IMerkleAdapter.Action memory second =
            _action(ANY_ROLE, address(target), 0, secondData, _filledMask(secondData.length, 0xff));
        bytes32 firstLeaf = _independentLeaf(first);
        bytes32 secondLeaf = _independentLeaf(second);
        first.proof = _singletonProof(secondLeaf);
        second.proof = _singletonProof(firstLeaf);
        _setMerkleRoot(_hashSortedPair(firstLeaf, secondLeaf));
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = first;
        actions[1] = second;

        bytes[] memory results = adapter.manage(actions);

        assertEq(target.callCount(), 2);
        assertEq(results.length, 2);
        assertEq(abi.decode(results[0], (bytes32)), firstMarker);
        assertEq(abi.decode(results[1], (bytes32)), secondMarker);
    }

    function test_ManageAcceptsEmptyBatch() public {
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](0);

        vm.prank(unauthorized);
        bytes[] memory results = adapter.manage(actions);

        assertEq(results.length, 0);
    }

    function test_ManageEmptyBatchSyncsAccounting() public {
        asset.transfer(address(adapter), 50);
        oracle.setTotalAssets(50);
        delegator.requestDeallocate(address(adapter), 20);
        oracle.setTotalAssets(30);
        oracle.setNonce(2);

        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](0);
        assertEq(adapter.manage(actions).length, 0);
        assertEq(adapter.lastSyncedNonce(), 2);
        assertEq(adapter.deallocatable(), 20);
    }

    function test_ManageAllowsTransientReservedBalanceShortfall() public {
        MerkleAdapterAssetReturnTarget returnTarget = new MerkleAdapterAssetReturnTarget();
        asset.transfer(address(vault), 50);
        delegator.allocate(address(adapter), 50);

        bytes memory takeData = abi.encodeCall(asset.transfer, (address(returnTarget), 1));
        bytes memory returnData =
            abi.encodeCall(returnTarget.returnAsset, (IERC20(address(asset)), address(adapter), 1));
        IMerkleAdapter.Action memory take =
            _action(ANY_ROLE, address(asset), 0, takeData, _filledMask(takeData.length, 0xff));
        IMerkleAdapter.Action memory restore =
            _action(ANY_ROLE, address(returnTarget), 0, returnData, _filledMask(returnData.length, 0xff));
        bytes32 takeLeaf = _independentLeaf(take);
        bytes32 restoreLeaf = _independentLeaf(restore);
        take.proof = _singletonProof(restoreLeaf);
        restore.proof = _singletonProof(takeLeaf);
        _setMerkleRoot(_hashSortedPair(takeLeaf, restoreLeaf));
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = take;
        actions[1] = restore;

        adapter.manage(actions);
        assertEq(asset.balanceOf(address(adapter)), 50);
        assertEq(asset.balanceOf(address(returnTarget)), 0);
    }

    function test_ManageRejectsReservedBalanceShortfallAfterBatch() public {
        asset.transfer(address(vault), 50);
        delegator.allocate(address(adapter), 50);

        bytes memory data = abi.encodeCall(asset.transfer, (address(this), 1));
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, address(asset), 0, data, _filledMask(data.length, 0xff));
        _setMerkleRoot(_independentLeaf(action));

        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        adapter.manage(_singleton(action));
        assertEq(asset.balanceOf(address(adapter)), 50);
    }

    function test_ManageAllowsProofReuseWhileRootAndRoleRemainUnchanged() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        address actionCaller = makeAddr("reusableProofCaller");
        bytes memory data = abi.encodeCall(target.record, (keccak256("reusable proof")));
        IMerkleAdapter.Action memory action =
            _action(ACTION_ROLE, address(target), 0, data, _filledMask(data.length, 0xff));
        _setMerkleRoot(_independentLeaf(action));
        vm.prank(defaultAdminRoleHolder);
        adapter.grantRole(ACTION_ROLE, actionCaller);

        vm.startPrank(actionCaller);
        adapter.manage(_singleton(action));
        adapter.manage(_singleton(action));
        vm.stopPrank();

        assertEq(target.callCount(), 2);
    }

    function test_ManageBubblesExactTargetRevertAndRollsBackEarlierCalls() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        bytes memory firstData = abi.encodeCall(target.record, (keccak256("rolled back")));
        uint256 errorCode = 77;
        bytes32 errorContext = keccak256("exact revert data");
        bytes memory secondData = abi.encodeCall(target.revertWith, (errorCode, errorContext));
        IMerkleAdapter.Action memory first =
            _action(ANY_ROLE, address(target), 0, firstData, _filledMask(firstData.length, 0xff));
        IMerkleAdapter.Action memory second =
            _action(ANY_ROLE, address(target), 0, secondData, _filledMask(secondData.length, 0xff));
        bytes32 firstLeaf = _independentLeaf(first);
        bytes32 secondLeaf = _independentLeaf(second);
        first.proof = _singletonProof(secondLeaf);
        second.proof = _singletonProof(firstLeaf);
        _setMerkleRoot(_hashSortedPair(firstLeaf, secondLeaf));
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = first;
        actions[1] = second;

        vm.expectRevert(abi.encodeWithSelector(MerkleAdapterCallTarget.ForcedRevert.selector, errorCode, errorContext));
        adapter.manage(actions);

        assertEq(target.callCount(), 0);
        assertEq(target.lastMarker(), bytes32(0));
    }

    function test_ManageReceivesEtherAndDispatchesApprovedValue() public {
        MerkleAdapterCallTarget target = new MerkleAdapterCallTarget();
        uint96 receivedValue = 3 ether;
        uint96 dispatchedValue = 2 ether;
        vm.deal(address(this), receivedValue);

        (bool success,) = address(adapter).call{value: receivedValue}("");
        assertTrue(success);
        assertEq(address(adapter).balance, receivedValue);

        bytes32 marker = keccak256("value dispatch");
        bytes memory data = abi.encodeCall(target.record, (marker));
        IMerkleAdapter.Action memory action =
            _action(ANY_ROLE, address(target), dispatchedValue, data, _filledMask(data.length, 0xff));
        _setMerkleRoot(_independentLeaf(action));

        adapter.manage(_singleton(action));

        assertEq(address(adapter).balance, receivedValue - dispatchedValue);
        assertEq(address(target).balance, dispatchedValue);
        assertEq(target.totalValue(), dispatchedValue);
        assertEq(target.lastMarker(), marker);
    }

    function test_ManageRejectsTargetWithoutCode() public {
        address target = makeAddr("targetWithoutCode");
        IMerkleAdapter.Action memory action = _action(ANY_ROLE, target, 0, bytes(""), bytes(""));
        _setMerkleRoot(_independentLeaf(action));

        vm.expectRevert(abi.encodeWithSelector(Address.AddressEmptyCode.selector, target));
        adapter.manage(_singleton(action));
    }

    function test_ManageRejectsRecursiveManageCall() public {
        MerkleAdapterReentrantTarget target = new MerkleAdapterReentrantTarget(address(adapter));
        bytes memory innerData = abi.encodeCall(target.markReentered, ());
        IMerkleAdapter.Action memory inner =
            _action(ANY_ROLE, address(target), 0, innerData, _filledMask(innerData.length, 0xff));
        bytes memory outerData = abi.encodeCall(target.reenter, ());
        IMerkleAdapter.Action memory outer =
            _action(ANY_ROLE, address(target), 0, outerData, _filledMask(outerData.length, 0xff));
        bytes32 innerLeaf = _independentLeaf(inner);
        bytes32 outerLeaf = _independentLeaf(outer);
        inner.proof = _singletonProof(outerLeaf);
        outer.proof = _singletonProof(innerLeaf);
        _setMerkleRoot(_hashSortedPair(innerLeaf, outerLeaf));
        target.setReentrantCall(abi.encodeCall(adapter.manage, (_singleton(inner))));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        adapter.manage(_singleton(outer));

        assertEq(target.reenteredCount(), 0);
    }

    function _action(bytes32 role, address target, uint96 flagsAndValue, bytes memory data, bytes memory dataMask)
        internal
        pure
        returns (IMerkleAdapter.Action memory action)
    {
        action = IMerkleAdapter.Action({
            role: role,
            target: target,
            flagsAndValue: flagsAndValue,
            data: data,
            dataMask: dataMask,
            proof: new bytes32[](0)
        });
    }

    function _singleton(IMerkleAdapter.Action memory action)
        internal
        pure
        returns (IMerkleAdapter.Action[] memory actions)
    {
        actions = new IMerkleAdapter.Action[](1);
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

    function _independentLeaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        bytes memory maskedData = new bytes(action.data.length);
        for (uint256 i; i < action.data.length; ++i) {
            maskedData[i] = action.data[i] & action.dataMask[i];
        }
        uint96 flagsAndValue = action.flagsAndValue;
        uint96 value = flagsAndValue & ANY_VALUE;
        bytes32 inner = keccak256(
            abi.encode(
                action.role,
                action.target,
                flagsAndValue & ANY_VALUE_FLAG == 0 ? value : ANY_VALUE,
                keccak256(action.dataMask),
                keccak256(maskedData)
            )
        );
        return keccak256(bytes.concat(inner));
    }

    function _hashSortedPair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return left < right ? keccak256(bytes.concat(left, right)) : keccak256(bytes.concat(right, left));
    }

    function _setMerkleRoot(bytes32 root) internal {
        vm.prank(protocolOwner);
        rootRegistry.setRoot(address(adapter), root);
        vm.prank(adapterOwner);
        adapter.acceptRoot(root);
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
    uint256 internal _totalAssets;
    uint256 internal _revertCode;
    uint256 public override nonce;

    constructor(address factory) MigratableEntity(factory) {}

    function setTotalAssets(uint256 assets) external {
        _totalAssets = assets;
    }

    function setRevertCode(uint256 code) external {
        _revertCode = code;
    }

    function setNonce(uint256 nonce_) external {
        nonce = nonce_;
    }

    function totalAssets() external view returns (uint256 assets) {
        if (_revertCode != 0) {
            revert ForcedTotalAssetsRevert(_revertCode);
        }
        assets = _totalAssets;
    }

    function _initialize(uint64, address, bytes memory data) internal override {
        initDataLength = data.length;
        adapter = abi.decode(data, (address));
    }
}
