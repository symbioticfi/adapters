// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {BaseChain} from "./BaseChain.sol";
import {BaseSafePayloads} from "./BaseSafePayloads.sol";
import {ExecutingRecipe} from "../recipes/ExecutingRecipe.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {OP_LESS_OR_EQUAL} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

import {ITokenMessengerV2} from "../utils/interfaces/ICCTPv2.sol";
import {IOptimismPortal} from "../utils/interfaces/IOptimismPortal.sol";

/**
 * @title BaseAliasPayloads
 * @notice Builds leaves for the Base AccessManager controlled by the Ethereum MerkleAccount's alias.
 * @dev Each Base operation is one portal deposit. The mint recipe binds every masked word of the mint batch.
 */
library BaseAliasPayloads {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    /// @notice Raised when the committed cap does not fit a nonzero 3F mint amount.
    error InvalidMaxPrincipal();

    /// @dev Start of depositTransaction's bytes payload, after the selector, five head words and bytes length.
    uint256 internal constant PORTAL_DATA_OFFSET = 196;

    /// @dev Start of AccessManager.execute's calldata payload, after its selector, two head words and bytes length.
    uint256 internal constant EXECUTE_DATA_OFFSET = 100;

    struct Deployment {
        address ethereumAccount;
        address manager;
        address policy;
    }

    /// @notice Returns the Base alias with the manager's ADMIN_ROLE.
    function aliasOf(Deployment memory deployment) internal pure returns (address) {
        return BaseChain.l2Alias(deployment.ethereumAccount);
    }

    /// @notice Builds the Ethereum approval used before the CCTP burn.
    function approveBridge(uint256 amount) internal pure returns (IMerkleAccount.Action memory) {
        return BaseSafePayloads.approveBridge(amount);
    }

    /// @notice Burns Ethereum USDC with the Base AccessManager as the CCTP recipient.
    function bridgeToBase(Deployment memory deployment, uint256 amount)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = _action(
            BaseChain.TOKEN_MESSENGER,
            abi.encodeCall(
                ITokenMessengerV2.depositForBurn,
                (
                    amount,
                    BaseChain.BASE_DOMAIN,
                    bytes32(uint256(uint160(deployment.manager))),
                    BaseChain.ETHEREUM_USDC,
                    bytes32(0),
                    0,
                    BaseChain.STANDARD_FINALITY
                )
            )
        );
        _free(action.dataMask, 4, 32);
    }

    /// @notice Builds the curator action setting the Base USDC budget for an underlying asset.
    function setMaxAssetsPerDuration(
        Deployment memory deployment,
        address underlyingAsset,
        uint256 maxAssets,
        uint48 duration
    ) internal pure returns (IMerkleAccount.Action memory action) {
        action = _deposit(
            deployment,
            _execute(
                deployment.policy,
                abi.encodeCall(
                    IThreeFPolicy.setMaxAssetsPerDuration, (BaseChain.BASE_USDC, underlyingAsset, maxAssets, duration)
                )
            )
        );
        _free(action.dataMask, PORTAL_DATA_OFFSET + EXECUTE_DATA_OFFSET + 36, 96);
    }

    /// @notice Builds the curator action setting the Base policy's minimum yield.
    function setMinYieldPerRequest(Deployment memory deployment, address underlyingAsset, uint256 minimum)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = _deposit(
            deployment,
            _execute(deployment.policy, abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (underlyingAsset, minimum)))
        );
        _free(action.dataMask, PORTAL_DATA_OFFSET + EXECUTE_DATA_OFFSET + 4, 64);
    }

    /// @notice Builds the single Base mint deposit. Authorize its leaf only for the committed Ethereum recipe.
    function mintThreeF(Deployment memory deployment, address request, uint128 maxPrincipal, uint128 minYield)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        bytes[] memory calls = _mintBatch(deployment, request, maxPrincipal, minYield);
        action = _deposit(deployment, abi.encodeCall(Multicall.multicall, (calls)));
        uint256[9] memory offsets = _mintOffsets(calls);
        for (uint256 i; i < offsets.length; ++i) {
            _free(action.dataMask, offsets[i], 32);
        }
    }

    /// @notice Returns the one Ethereum manage action for a 3F mint.
    function mintActions(Deployment memory deployment, address request, uint128 maxPrincipal, uint128 minYield)
        internal
        pure
        returns (IMerkleAccount.Action[] memory actions)
    {
        actions = new IMerkleAccount.Action[](1);
        actions[0] = mintThreeF(deployment, request, maxPrincipal, minYield);
    }

    /// @notice Returns the one leaf committed by the mint recipe.
    function mintLeaves(Deployment memory deployment) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](1);
        leaves[0] = leaf(mintThreeF(deployment, address(0), 0, 0));
    }

    /// @notice Builds the recipe that applies a cap and binds the mint batch's request and bounds to one input set.
    function mintRecipe(Deployment memory deployment, uint256 maxPrincipal)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory)
    {
        if (maxPrincipal == 0 || maxPrincipal > type(uint128).max) revert InvalidMaxPrincipal();
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(8);
        uint256 request = builder.input(0);
        uint256 principal = builder.input(1);
        uint256 minYield = builder.input(2);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), principal);
        builder.check(OP_LESS_OR_EQUAL, principal, builder.literal(maxPrincipal));
        builder.check(OP_LESS_OR_EQUAL, minYield, builder.literal(type(uint128).max));

        uint256[9] memory offsets = _mintOffsets(_mintBatch(deployment, address(0), 0, 0));
        uint256[9] memory values =
            [request, principal, minYield, request, principal, request, principal, minYield, request];
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](offsets.length);
        for (uint256 i; i < offsets.length; ++i) {
            bindings[0][i] = ExecutingRecipe.binding(offsets[i], values[i]);
        }
        builder.manage(builder.literal(1), mintLeaves(deployment), bindings);
        return builder.finish();
    }

    /// @notice Returns the inputs for the committed mint recipe.
    function mintInputs(address request, uint128 maxPrincipal, uint128 minYield)
        internal
        pure
        returns (uint256[] memory inputs)
    {
        inputs = new uint256[](3);
        inputs[0] = uint160(request);
        inputs[1] = maxPrincipal;
        inputs[2] = minYield;
    }

    /// @notice Builds one Base deposit redeeming the manager's position into itself.
    /// @dev The funding operator supplies the verified 3F request. The recipient, owner, selector and value are fixed.
    function redeemThreeF(Deployment memory deployment, address request)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = _deposit(
            deployment,
            _execute(request, abi.encodeCall(IThreeFVaultController.burnAll, (deployment.manager, deployment.manager)))
        );
        _free(action.dataMask, PORTAL_DATA_OFFSET + 4, 32);
    }

    /// @notice Builds one Base deposit approving, burning and clearing the CCTP allowance atomically.
    function bridgeToEthereum(Deployment memory deployment, uint256 amount)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        bytes[] memory calls = new bytes[](3);
        calls[0] = _execute(BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (BaseChain.TOKEN_MESSENGER, amount)));
        calls[1] = _execute(
            BaseChain.TOKEN_MESSENGER,
            abi.encodeCall(
                ITokenMessengerV2.depositForBurn,
                (
                    amount,
                    BaseChain.ETHEREUM_DOMAIN,
                    bytes32(uint256(uint160(deployment.ethereumAccount))),
                    BaseChain.BASE_USDC,
                    bytes32(0),
                    0,
                    BaseChain.STANDARD_FINALITY
                )
            )
        );
        calls[2] = _execute(BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (BaseChain.TOKEN_MESSENGER, 0)));
        action = _deposit(deployment, abi.encodeCall(Multicall.multicall, (calls)));
        _free(action.dataMask, _executeAt(calls, 0) + EXECUTE_DATA_OFFSET + 36, 32);
        _free(action.dataMask, _executeAt(calls, 1) + EXECUTE_DATA_OFFSET + 4, 32);
    }

    /// @notice Returns the Merkle leaf derived from the target and masked payload.
    function leaf(IMerkleAccount.Action memory action) internal pure returns (bytes32) {
        return ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
    }

    function _mintBatch(Deployment memory deployment, address request, uint128 maxPrincipal, uint128 minYield)
        private
        pure
        returns (bytes[] memory calls)
    {
        calls = new bytes[](5);
        calls[0] = _execute(
            deployment.policy,
            abi.encodeCall(IThreeFPolicy.beginPushMint, (BaseChain.BASE_USDC, request, maxPrincipal, minYield))
        );
        calls[1] = _execute(BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (request, maxPrincipal)));
        calls[2] = _execute(request, abi.encodeCall(IThreeFPushRequest.mint, (maxPrincipal, minYield)));
        calls[3] = _execute(BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (request, 0)));
        calls[4] = _execute(deployment.policy, abi.encodeCall(IThreeFPolicy.finishPushMint, (BaseChain.BASE_USDC)));
    }

    /// @dev Returns the bound words in ascending ABI order. The third call varies its execute target.
    function _mintOffsets(bytes[] memory calls) private pure returns (uint256[9] memory) {
        uint256 check = _executeAt(calls, 0) + EXECUTE_DATA_OFFSET;
        uint256 approve = _executeAt(calls, 1) + EXECUTE_DATA_OFFSET;
        uint256 mint = _executeAt(calls, 2);
        return [
            check + 36,
            check + 68,
            check + 100,
            approve + 4,
            approve + 36,
            mint + 4,
            mint + EXECUTE_DATA_OFFSET + 4,
            mint + EXECUTE_DATA_OFFSET + 36,
            _executeAt(calls, 3) + EXECUTE_DATA_OFFSET + 4
        ];
    }

    /// @dev Locates an execute selector inside the portal payload and the multicall bytes array.
    function _executeAt(bytes[] memory calls, uint256 index) private pure returns (uint256 offset) {
        offset = PORTAL_DATA_OFFSET + 100 + 32 * calls.length;
        for (uint256 i; i < index; ++i) {
            offset += 32 + ((calls[i].length + 31) & ~uint256(31));
        }
    }

    function _execute(address target, bytes memory data) private pure returns (bytes memory) {
        return abi.encodeCall(IAccessManager.execute, (target, data));
    }

    function _deposit(Deployment memory deployment, bytes memory data)
        private
        pure
        returns (IMerkleAccount.Action memory)
    {
        return _action(
            BaseChain.BASE_PORTAL,
            abi.encodeCall(
                IOptimismPortal.depositTransaction, (deployment.manager, 0, BaseChain.PORTAL_GAS_LIMIT, false, data)
            )
        );
    }

    function _action(address target, bytes memory data) private pure returns (IMerkleAccount.Action memory) {
        return IMerkleAccount.Action({
            target: target, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
    }

    function _free(bytes memory dataMask, uint256 offset, uint256 length) private pure {
        for (uint256 i = offset; i < offset + length; ++i) {
            dataMask[i] = 0xff;
        }
    }
}
