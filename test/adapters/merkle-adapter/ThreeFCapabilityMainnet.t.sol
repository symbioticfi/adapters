// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;
import {AdapterFactory} from "../../../src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {CapabilityManifestTestHelper} from "./CapabilityTestBase.sol";
import {ExecutorLiquiditySource} from "./Executor.t.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {
    MerkleAdapterDelegatorMock,
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "../MerkleAdapter.t.sol";
import {MerkleAdapter} from "../../../src/contracts/MerkleAdapter.sol";
import {RootRegistry} from "../../../src/contracts/merkle-adapter/RootRegistry.sol";
import {ThreeFCapability} from "../../../src/contracts/merkle-adapter/capabilities/ThreeFCapability.sol";
import {ThreeFExecutor} from "../../../src/contracts/periphery/ThreeFExecutor.sol";

import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IExecutor} from "../../../src/interfaces/periphery/IExecutor.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {IThreeFCapability} from "../../../src/interfaces/merkle-adapter/capabilities/IThreeFCapability.sol";
import {IThreeFPushRequest} from "../../../src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFWhitelist} from "../../../src/interfaces/3f-adapter/IThreeFWhitelist.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

interface IThreeFForkRequest is IThreeFPushRequest {
    error AlreadyRepaid();

    function owner() external view returns (address);
    function authorizeMinting(address account, uint128 principal, uint128 yieldAmount) external;
}

/// @notice Exercises the complete Merkle batch against deployed 3F Request, Facility, and position-manager contracts.
/// @dev The historical block has request-6981 active. Fork-local owner impersonation provides its mint authorization.
contract ThreeFCapabilityMainnetTest is Test, CapabilityManifestTestHelper {
    uint256 internal constant FORK_BLOCK = 25_892_000;
    address internal constant FACILITY = 0x4e013ca8fF612a58F53C822904cDD0eC538a4A4F;
    address internal constant USCC = 0x14d60E7FDC0D71d8611742720E4C50E7a974020c;
    IThreeFForkRequest internal constant REQUEST = IThreeFForkRequest(0x4929b2Ef3356e1D5233a5459f1B7281FFC56a60E);
    uint128 internal constant PRINCIPAL = 100_000e6;
    uint128 internal constant YIELD = 2000e6;

    MerkleAdapter internal adapter;
    MerkleAdapterOracleMock internal oracle;
    RootRegistry internal roots;
    ThreeFCapability internal capability;
    address internal implementation;
    IERC20 internal asset;

    /// @dev Deploys factory-created adapters on a pinned real protocol fork; no live transaction is broadcast.
    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertFalse(REQUEST.canWithdraw());
        asset = IERC20(REQUEST.asset());

        MerkleAdapterVaultRegistry vaultFactory = new MerkleAdapterVaultRegistry();
        MerkleAdapterVaultMock vault = new MerkleAdapterVaultMock(address(asset));
        MerkleAdapterDelegatorMock delegator = new MerkleAdapterDelegatorMock(address(vault));
        vault.setDelegator(address(delegator));
        vaultFactory.add(address(vault));
        AdapterFactory adapterFactory = new AdapterFactory(address(this));
        MigratablesFactory oracleFactory = new MigratablesFactory(address(this));
        oracleFactory.whitelist(address(new MerkleAdapterOracleMock(address(oracleFactory))));
        roots = new RootRegistry(address(this));
        adapterFactory.whitelist(
            address(
                new MerkleAdapter(
                    address(vaultFactory),
                    address(adapterFactory),
                    address(oracleFactory),
                    address(roots),
                    address(new CapabilitiesRegistry(address(this)))
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapterFactory.create(
                    1, address(this), abi.encode(address(vault), abi.encode(IMerkleAdapter.InitParams(address(this))))
                ))
        );
        oracle = MerkleAdapterOracleMock(adapter.oracle());

        ThreeFPushMainnetWhitelist whitelist = new ThreeFPushMainnetWhitelist(address(REQUEST));
        implementation = address(new ThreeFCapability(address(whitelist), FACILITY));
        _installCapability(adapter, implementation, _threeFSelectors());
        capability = ThreeFCapability(address(adapter));
        _configureLimits(USCC, 20_000, PRINCIPAL);

        deal(address(asset), address(vault), PRINCIPAL);
        assertEq(delegator.allocate(address(adapter), PRINCIPAL), PRINCIPAL);
        oracle.setNonce(2);
        oracle.setTotalAssets(PRINCIPAL);
        vm.prank(REQUEST.owner());
        REQUEST.authorizeMinting(address(capability), PRINCIPAL, YIELD);
    }

    /// @dev Real facility discovery selects USCC limits, then actual Request minting spends USDC and issues PT/YT.
    function test_MainnetMerkleBatchMintsActualRequestAndConsumesAuthorization() public {
        uint256 requestBalance = asset.balanceOf(address(REQUEST));
        _mintThroughMerkleBatch();

        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(implementation), 0);
        assertEq(asset.balanceOf(address(REQUEST)), requestBalance + PRINCIPAL);
        assertEq(asset.allowance(address(capability), address(REQUEST)), 0);
        assertEq(capability.pendingAssets(address(REQUEST)), PRINCIPAL);
        assertEq(capability.requestIndex(address(REQUEST)), 1);
        assertEq(capability.threeFPositionAssets(), PRINCIPAL);
        (uint256 principalShares, uint256 yieldShares) = REQUEST.balancesOf(address(capability));
        assertEq(principalShares, PRINCIPAL);
        assertEq(yieldShares, YIELD);
        (uint128 principalAuthorization, uint128 yieldAuthorization) = REQUEST.mintAuthorization(address(capability));
        assertEq(principalAuthorization, 0);
        assertEq(yieldAuthorization, 0);
        assertEq(capability.remainingAssets(USCC), 0);
    }

    /// @dev Executor obtains the live principal shortfall through a normal leaf before the deployed Request mint.
    function test_MainnetExecutorFundsAndMintsActualRequest() public {
        address factory = address(new ImmutableFactory(type(ThreeFExecutor).creationCode));
        ThreeFExecutor executor =
            ThreeFExecutor(IImmutableFactory(factory).create(abi.encode(address(this), address(adapter))));
        assertTrue(IImmutableFactory(factory).isEntity(address(executor)));
        address keeper = makeAddr("3F executor caller");
        executor.setCaller(keeper);
        ExecutorLiquiditySource source = new ExecutorLiquiditySource(asset, address(adapter));
        uint256 idle = 40_000e6;
        uint256 missing = PRINCIPAL - idle;
        uint256 requestBalance = asset.balanceOf(address(REQUEST));

        IMerkleAdapter.Action[] memory setup = new IMerkleAdapter.Action[](2);
        setup[0] = _action(address(asset), abi.encodeCall(IERC20.approve, (address(REQUEST), PRINCIPAL)));
        setup[1] = _action(address(asset), abi.encodeCall(IERC20.transfer, (address(source), missing)));
        _publishBatch(setup);
        adapter.manage(setup);
        source.setLiquidity(missing);

        IMerkleAdapter.Action[] memory permissions = new IMerkleAdapter.Action[](3);
        permissions[0] = _action(address(source), abi.encodeCall(source.withdraw, (address(adapter), missing)));
        for (uint256 i = 36; i < 68; ++i) {
            permissions[0].dataMask[i] = 0xff;
        }
        permissions[1] = _action(address(asset), abi.encodeCall(IERC20.approve, (address(REQUEST), PRINCIPAL)));
        for (uint256 i = 36; i < 68; ++i) {
            permissions[1].dataMask[i] = 0xff;
        }
        permissions[2] = _mintActions()[1];
        _publishBatch(permissions);
        for (uint256 i; i < permissions.length; ++i) {
            adapter.grantRole(_leaf(permissions[i]), address(executor));
        }

        IExecutor.Action[] memory configured = new IExecutor.Action[](1);
        configured[0] = IExecutor.Action(
            address(asset), abi.encodeCall(IERC20.balanceOf, (address(source))), _leaf(permissions[0])
        );
        executor.setActions(configured, _leaf(permissions[1]), _leaf(permissions[2]));
        assertFalse(adapter.hasRole(_leaf(permissions[0]), keeper));
        assertFalse(adapter.hasRole(_leaf(permissions[1]), keeper));
        IExecutor.Execution memory execution;
        execution.actions = new IMerkleAdapter.Action[](1);
        execution.actions[0] = permissions[0];
        execution.approval = IExecutor.Permission(permissions[1].dataMask, permissions[1].proof);
        execution.operation = IExecutor.Permission(permissions[2].dataMask, permissions[2].proof);
        vm.prank(keeper);
        executor.mint(address(REQUEST), uint128(PRINCIPAL), uint128(YIELD), block.timestamp, execution);

        assertEq(source.withdrawn(), missing);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(REQUEST)), requestBalance + PRINCIPAL);
        assertEq(capability.pendingAssets(address(REQUEST)), PRINCIPAL);
        (uint128 principalAuthorization, uint128 yieldAuthorization) = REQUEST.mintAuthorization(address(capability));
        assertEq(principalAuthorization, 0);
        assertEq(yieldAuthorization, 0);
    }

    /// @dev Spending pending allocations must atomically revert the real Request mint and approval as well.
    function test_MainnetMerkleReserveFailureRollsBackActualMint() public {
        oracle.setNonce(0);
        oracle.setTotalAssets(0);
        uint256 requestBalance = asset.balanceOf(address(REQUEST));
        IMerkleAdapter.Action[] memory actions = _mintActions();
        _publishBatch(actions);

        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        adapter.manage(actions);

        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
        assertEq(asset.balanceOf(address(REQUEST)), requestBalance);
        assertEq(asset.allowance(address(adapter), address(REQUEST)), 0);
        assertEq(capability.requestsLength(), 0);
        assertEq(adapter.pendingAllocation(1), PRINCIPAL);
        (uint256 principalShares, uint256 yieldShares) = REQUEST.balancesOf(address(capability));
        assertEq(principalShares, 0);
        assertEq(yieldShares, 0);
        (uint128 principalAuthorization, uint128 yieldAuthorization) = REQUEST.mintAuthorization(address(capability));
        assertEq(principalAuthorization, PRINCIPAL);
        assertEq(yieldAuthorization, YIELD);
        assertEq(capability.remainingAssets(USCC), PRINCIPAL);
    }

    /// @dev A curator budget blocks an actual authorized Request, then charges its exact funded principal.
    function test_MainnetBudgetCapsActualRequestAndResetsAtBoundary() public {
        _configureLimits(USCC, 20_000, PRINCIPAL - 1);
        IMerkleAdapter.Action[] memory actions = _mintActions();
        _publishBatch(actions);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        adapter.manage(actions);
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
        assertEq(capability.remainingAssets(USCC), PRINCIPAL - 1);

        _configureLimits(USCC, 20_000, PRINCIPAL);
        _mintThroughMerkleBatch();
        assertEq(capability.remainingAssets(USCC), 0);
        vm.warp(block.timestamp + 1 days - 1);
        assertEq(capability.remainingAssets(USCC), 0);
        vm.warp(block.timestamp + 1);
        assertEq(capability.remainingAssets(USCC), PRINCIPAL);
    }

    /// @dev Configuring settlement USDC must not authorize the real intent's distinct USCC collateral.
    function test_MainnetFundingAssetLimitsDoNotEnableCollateralUnderlying() public {
        _configureLimits(USCC, 0, 0);
        _configureLimits(address(asset), 0, type(uint256).max);
        IMerkleAdapter.Action[] memory actions = _mintActions();
        _publishBatch(actions);

        vm.expectRevert(IAssetRateLimits.UnconfiguredAsset.selector);
        adapter.manage(actions);
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
        assertEq(capability.requestsLength(), 0);
    }

    /// @dev A live authorization cannot bypass the deployed Request's repayment deadline; funding rolls back.
    function test_MainnetExpiredRequestRejectsMintAndPreservesFunding() public {
        vm.warp(block.timestamp + 365 days);
        assertTrue(REQUEST.canWithdraw());
        uint256 requestBalance = asset.balanceOf(address(REQUEST));
        IMerkleAdapter.Action[] memory actions = _mintActions();
        _publishBatch(actions);

        vm.expectRevert(IThreeFForkRequest.AlreadyRepaid.selector);
        adapter.manage(actions);

        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
        assertEq(asset.balanceOf(implementation), 0);
        assertEq(asset.balanceOf(address(REQUEST)), requestBalance);
        assertEq(asset.allowance(address(adapter), address(REQUEST)), 0);
        assertEq(asset.allowance(address(capability), address(REQUEST)), 0);
        assertEq(capability.requestsLength(), 0);
        (uint256 principalShares, uint256 yieldShares) = REQUEST.balancesOf(address(capability));
        assertEq(principalShares, 0);
        assertEq(yieldShares, 0);
        (uint128 principalAuthorization, uint128 yieldAuthorization) = REQUEST.mintAuthorization(address(capability));
        assertEq(principalAuthorization, PRINCIPAL);
        assertEq(yieldAuthorization, YIELD);
    }

    /// @dev Applies action configuration through a fully constrained single-leaf adapter permission.
    function _configureLimits(address underlying, uint256 minYield, uint256 maxPrincipal) internal {
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(
            address(capability), abi.encodeCall(IThreeFCapability.setMinYieldPerRequest, (underlying, minYield))
        );
        actions[1] = _action(
            address(capability),
            abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (underlying, maxPrincipal, 1 days))
        );
        _publishBatch(actions);
        adapter.manage(actions);
    }

    /// @dev Approves action funding and mints in one fully proof-authorized adapter transaction.
    function _mintThroughMerkleBatch() internal {
        IMerkleAdapter.Action[] memory actions = _mintActions();
        _publishBatch(actions);
        adapter.manage(actions);
    }

    /// @dev Creates exact call permissions so execution cannot substitute another request or spender.
    function _mintActions() internal view returns (IMerkleAdapter.Action[] memory actions) {
        actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(asset), abi.encodeCall(IERC20.approve, (address(REQUEST), PRINCIPAL)));
        actions[1] = _action(
            address(capability),
            abi.encodeCall(IThreeFCapability.mintRequest, (address(REQUEST), PRINCIPAL, YIELD, block.timestamp))
        );
    }

    /// @dev Binds every calldata byte for these integration permissions.
    function _action(address target, bytes memory data) internal pure returns (IMerkleAdapter.Action memory action) {
        bytes memory mask = new bytes(data.length);
        action = IMerkleAdapter.Action(target, 0, data, mask, new bytes32[](0));
    }

    /// @dev Encodes the leaf independently of the production verifier.
    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        bytes memory masked = new bytes(action.data.length);
        for (uint256 i; i < masked.length; ++i) {
            masked[i] = action.data[i] & ~action.dataMask[i];
        }
        return keccak256(
            bytes.concat(keccak256(abi.encode(action.target, bytes1(0), keccak256(action.dataMask), keccak256(masked))))
        );
    }

    /// @dev Publishes all funding, approval and operation permissions through real root acceptance.
    function _publishBatch(IMerkleAdapter.Action[] memory actions) internal {
        uint256 width = 1;
        uint256 depth;
        while (width < actions.length) {
            width *= 2;
            ++depth;
        }
        bytes32[] memory tree = new bytes32[](2 * width);
        for (uint256 i; i < actions.length; ++i) {
            tree[width + i] = _leaf(actions[i]);
            adapter.grantRole(tree[width + i], address(this));
        }
        for (uint256 i = width - 1; i > 0; --i) {
            bytes32 left = tree[i * 2];
            bytes32 right = tree[i * 2 + 1];
            tree[i] = left < right ? keccak256(bytes.concat(left, right)) : keccak256(bytes.concat(right, left));
        }
        for (uint256 i; i < actions.length; ++i) {
            actions[i].proof = new bytes32[](depth);
            uint256 index = width + i;
            for (uint256 j; j < depth; ++j) {
                actions[i].proof[j] = tree[index ^ 1];
                index /= 2;
            }
        }
        roots.setRoot(address(adapter), tree[1]);
        adapter.acceptRoot(tree[1]);
    }
}

contract ThreeFPushMainnetWhitelist is IThreeFWhitelist {
    address internal immutable _request;

    constructor(address request) {
        _request = request;
    }

    function isWhitelisted(address request) external view returns (WhitelistStatus) {
        return request == _request ? WhitelistStatus.Whitelisted : WhitelistStatus.NotWhitelisted;
    }
}
