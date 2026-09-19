// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {ThreeFExecutor} from "src/contracts/periphery/ThreeFExecutor.sol";
import {ThreeFPolicy} from "src/contracts/periphery/ThreeFPolicy.sol";
import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";
import {IExecutor} from "src/interfaces/periphery/IExecutor.sol";
import {IThreeFExecutor} from "src/interfaces/periphery/IThreeFExecutor.sol";
import {IThreeFPolicy} from "src/interfaces/periphery/IThreeFPolicy.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IThreeFNativeRequest is IThreeFPushRequest {
    function owner() external view returns (address);
    function authorizeMinting(address account, uint128 principal, uint128 yieldAmount) external;
}

/// @dev A pinned historical active request, using its actual factory and native mint code.
contract ThreeFExecutorMainnetTest is CapabilityTestBase {
    address internal constant REQUESTS_FACTORY = 0xDE293185e96a42F4c7d1C6479407920b19012Ca5;
    address internal constant REQUEST = 0x4929b2Ef3356e1D5233a5459f1B7281FFC56a60E;
    uint128 internal constant PRINCIPAL = 100_000e6;
    uint128 internal constant YIELD = 2000e6;
    address internal _executor;
    address internal _asset;
    IExecutor.Execution internal _execution;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 25_892_000);
        assertTrue(IThreeFRequestFactory(REQUESTS_FACTORY).isRequest(REQUEST));
        _asset = IThreeFNativeRequest(REQUEST).asset();
        _deployAdapter(_asset);
        _installCapability(adapter, address(new GuardedCallsCapability()), _guardedSelectors());
        _executor = address(new ThreeFExecutor(address(this), address(adapter), REQUESTS_FACTORY));
        ThreeFExecutor(_executor).setCaller(address(this));
        ThreeFPolicy(ThreeFExecutor(_executor).policy()).setMaxAssetsPerDuration(PRINCIPAL, 1 days);
        ThreeFPolicy(ThreeFExecutor(_executor).policy()).setMinYieldPerRequest(20_000);
        deal(_asset, address(adapter), PRINCIPAL);
        vm.prank(IThreeFNativeRequest(REQUEST).owner());
        IThreeFNativeRequest(REQUEST).authorizeMinting(address(adapter), PRINCIPAL, YIELD);
        bytes memory approval = abi.encodeCall(IERC20.approve, (REQUEST, PRINCIPAL));
        IGuardedCallsCapability.Call[] memory calls = new IGuardedCallsCapability.Call[](1);
        calls[0] = IGuardedCallsCapability.Call(REQUEST, abi.encodeCall(IThreeFPushRequest.mint, (PRINCIPAL, YIELD)));
        bytes memory mint =
            abi.encodeCall(IGuardedCallsCapability.execute, (calls, new IGuardedCallsCapability.Check[](0)));
        _execution.approval.dataMask = new bytes(approval.length);
        _execution.operation.dataMask = new bytes(mint.length);
        for (uint256 i = 4; i < 68; ++i) {
            _execution.approval.dataMask[i] = 0xff;
        }
        for (uint256 i = 132; i < 164; ++i) {
            _execution.operation.dataMask[i] = 0xff;
        }
        for (uint256 i = 232; i < 296; ++i) {
            _execution.operation.dataMask[i] = 0xff;
        }
        bytes32 a = MerkleAdapterVerifier.leaf(_asset, 0, approval, _execution.approval.dataMask);
        bytes32 b = MerkleAdapterVerifier.leaf(address(adapter), 0, mint, _execution.operation.dataMask);
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
        adapter.grantRole(a, _executor);
        adapter.grantRole(b, _executor);
        _execution.approval.proof.push(b);
        _execution.operation.proof.push(a);
        ThreeFExecutor(_executor).setActions(new IExecutor.Action[](0), a, b);
    }

    function test_MainnetFactoryAndNativeMintFromAdapter() public {
        uint256 beforeCash = IERC20(_asset).balanceOf(REQUEST);
        ThreeFExecutor(_executor).mint(REQUEST, PRINCIPAL, YIELD, block.timestamp, _execution);
        assertEq(IERC20(_asset).balanceOf(REQUEST), beforeCash + PRINCIPAL);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).allowance(address(adapter), REQUEST), 0);
        (uint256 principal, uint256 yieldAssets) = IThreeFNativeRequest(REQUEST).balancesOf(address(adapter));
        assertEq(principal, PRINCIPAL);
        assertEq(yieldAssets, YIELD);
        assertEq(ThreeFPolicy(ThreeFExecutor(_executor).policy()).remainingAssets(), 0);
    }

    function test_MainnetFactoryRejectsNonRequest() public {
        vm.expectRevert(IThreeFExecutor.NotRequest.selector);
        ThreeFExecutor(_executor).mint(_asset, PRINCIPAL, YIELD, block.timestamp, _execution);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), PRINCIPAL);
    }

    function test_MainnetOwnerChangesYieldWithoutRootUpdate() public {
        ThreeFPolicy(ThreeFExecutor(_executor).policy()).setMinYieldPerRequest(20_001);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFExecutor(_executor).mint(REQUEST, PRINCIPAL, YIELD, block.timestamp, _execution);
        ThreeFPolicy(ThreeFExecutor(_executor).policy()).setMinYieldPerRequest(20_000);
        ThreeFExecutor(_executor).mint(REQUEST, PRINCIPAL, YIELD, block.timestamp, _execution);
    }
}
