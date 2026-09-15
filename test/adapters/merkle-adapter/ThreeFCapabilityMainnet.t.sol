// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {AdapterFactory} from "../../../src/contracts/AdapterFactory.sol";
import {MerkleAdapter} from "../../../src/contracts/MerkleAdapter.sol";
import {RootRegistry} from "../../../src/contracts/merkle_adapter/RootRegistry.sol";
import {ThreeFCapability} from "../../../src/contracts/merkle_adapter/ThreeFCapability.sol";
import {ANY_ROLE, IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {IThreeFCapability} from "../../../src/interfaces/merkle_adapter/IThreeFCapability.sol";
import {IThreeFPushRequest} from "../../../src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFWhitelist} from "../../../src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {
    MerkleAdapterDelegatorMock,
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "../MerkleAdapter.t.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

interface IThreeFForkRequest is IThreeFPushRequest {
    error AlreadyRepaid();

    function owner() external view returns (address);
    function authorizeMinting(address account, uint128 principal, uint128 yieldAmount) external;
}

/// @notice Exercises the complete Merkle batch against deployed 3F Request, Facility, and position-manager contracts.
/// @dev The historical block has request-6981 active. Fork-local owner impersonation provides its mint authorization.
contract ThreeFCapabilityMainnetTest is Test {
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
                    address(vaultFactory), address(adapterFactory), address(oracleFactory), address(roots)
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapterFactory.create(
                    1, address(this), abi.encode(address(vault), abi.encode(IMerkleAdapter.InitParams(address(this))))
                ))
        );
        oracle = MerkleAdapterOracleMock(adapter.oracle());

        MigratablesFactory capabilityFactory = new MigratablesFactory(address(this));
        ThreeFPushMainnetWhitelist whitelist = new ThreeFPushMainnetWhitelist(address(REQUEST));
        capabilityFactory.whitelist(
            address(new ThreeFCapability(address(capabilityFactory), address(whitelist), FACILITY))
        );
        capability = ThreeFCapability(capabilityFactory.create(1, address(this), abi.encode(address(adapter))));
        _configureLimits(USCC, 20_000, 1, PRINCIPAL);

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
        assertEq(asset.balanceOf(address(capability)), 0);
        assertEq(asset.balanceOf(address(REQUEST)), requestBalance + PRINCIPAL);
        assertEq(asset.allowance(address(capability), address(REQUEST)), 0);
        assertEq(capability.pendingAssets(address(REQUEST)), PRINCIPAL);
        assertEq(capability.requestIndex(address(REQUEST)), 1);
        assertEq(capability.totalAssets(), PRINCIPAL);
        (uint256 principalShares, uint256 yieldShares) = REQUEST.balancesOf(address(capability));
        assertEq(principalShares, PRINCIPAL);
        assertEq(yieldShares, YIELD);
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
        assertEq(asset.allowance(address(adapter), address(capability)), 0);
        assertEq(capability.requestsLength(), 0);
        assertEq(adapter.pendingAllocation(1), PRINCIPAL);
        (uint256 principalShares, uint256 yieldShares) = REQUEST.balancesOf(address(capability));
        assertEq(principalShares, 0);
        assertEq(yieldShares, 0);
        (uint128 principalAuthorization, uint128 yieldAuthorization) = REQUEST.mintAuthorization(address(capability));
        assertEq(principalAuthorization, PRINCIPAL);
        assertEq(yieldAuthorization, YIELD);
    }

    /// @dev Configuring settlement USDC must not authorize the real intent's distinct USCC collateral.
    function test_MainnetFundingAssetLimitsDoNotEnableCollateralUnderlying() public {
        _configureLimits(USCC, 0, 0, 0);
        _configureLimits(address(asset), 0, 1, type(uint256).max);
        IMerkleAdapter.Action[] memory actions = _mintActions();
        _publishBatch(actions);

        vm.expectRevert(IThreeFCapability.UnconfiguredAsset.selector);
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
        assertEq(asset.balanceOf(address(capability)), 0);
        assertEq(asset.balanceOf(address(REQUEST)), requestBalance);
        assertEq(asset.allowance(address(adapter), address(capability)), 0);
        assertEq(asset.allowance(address(capability), address(REQUEST)), 0);
        assertEq(capability.requestsLength(), 0);
        (uint256 principalShares, uint256 yieldShares) = REQUEST.balancesOf(address(capability));
        assertEq(principalShares, 0);
        assertEq(yieldShares, 0);
        (uint128 principalAuthorization, uint128 yieldAuthorization) = REQUEST.mintAuthorization(address(capability));
        assertEq(principalAuthorization, PRINCIPAL);
        assertEq(yieldAuthorization, YIELD);
    }

    /// @dev Applies capability configuration through a fully constrained single-leaf adapter permission.
    function _configureLimits(address underlying, uint256 minYield, uint256 minPrincipal, uint256 maxPrincipal)
        internal
    {
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        actions[0] = _action(
            address(capability),
            abi.encodeCall(IThreeFCapability.setLimitsPerRequest, (underlying, minYield, minPrincipal, maxPrincipal))
        );
        _publishBatch(actions);
        adapter.manage(actions);
    }

    /// @dev Approves capability funding and mints in one fully proof-authorized adapter transaction.
    function _mintThroughMerkleBatch() internal {
        IMerkleAdapter.Action[] memory actions = _mintActions();
        _publishBatch(actions);
        adapter.manage(actions);
    }

    /// @dev Creates exact call permissions so execution cannot substitute another request or spender.
    function _mintActions() internal view returns (IMerkleAdapter.Action[] memory actions) {
        actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(asset), abi.encodeCall(IERC20.approve, (address(capability), PRINCIPAL)));
        actions[1] = _action(
            address(capability),
            abi.encodeCall(IThreeFCapability.mintRequest, (address(REQUEST), PRINCIPAL, YIELD, block.timestamp))
        );
    }

    /// @dev Binds every calldata byte for these integration permissions.
    function _action(address target, bytes memory data) internal pure returns (IMerkleAdapter.Action memory action) {
        bytes memory mask = new bytes(data.length);
        for (uint256 i; i < mask.length; ++i) {
            mask[i] = 0xff;
        }
        action = IMerkleAdapter.Action(ANY_ROLE, target, 0, data, mask, new bytes32[](0));
    }

    /// @dev Encodes the leaf independently of the production verifier.
    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        action.role, action.target, uint96(0), keccak256(action.dataMask), keccak256(action.data)
                    )
                )
            )
        );
    }

    /// @dev Publishes one- or two-leaf trees and the corresponding proofs through real root acceptance.
    function _publishBatch(IMerkleAdapter.Action[] memory actions) internal {
        bytes32 root = _leaf(actions[0]);
        if (actions.length == 2) {
            bytes32 second = _leaf(actions[1]);
            actions[0].proof = new bytes32[](1);
            actions[0].proof[0] = second;
            actions[1].proof = new bytes32[](1);
            actions[1].proof[0] = root;
            root = root < second ? keccak256(bytes.concat(root, second)) : keccak256(bytes.concat(second, root));
        }
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
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
