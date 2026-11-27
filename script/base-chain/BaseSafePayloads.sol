// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "./BaseChain.sol";
import {ExecutingRecipe} from "../recipes/ExecutingRecipe.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {OP_CALL, OP_EQUAL, OP_LESS_OR_EQUAL, OP_SUB, SRC_INPUT} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";

import {ITokenMessengerV2} from "../utils/interfaces/ICCTPv2.sol";
import {IGnosisSafe} from "../utils/interfaces/IGnosisSafe.sol";
import {IOptimismPortal} from "../utils/interfaces/IOptimismPortal.sol";
import {ISafeModules} from "../utils/interfaces/ISafeModules.sol";

/**
 * @title BaseSafePayloads
 * @notice Library building the Ethereum MerkleAccount actions that fund and operate the Base Safe.
 * @dev Bridge actions call CCTP directly from the MerkleAccount. Every Base action is a Base portal deposit
 * whose L2 sender is the MerkleAccount alias, an enabled module of the Safe:
 *
 *   alias -> Safe.execTransactionFromModule(target, 0, data, CALL)
 *   alias -> Safe.execTransactionFromModule(Safe, 0, execTransactionFromModule(RecipeCapability, 0, execute, DELEGATECALL), CALL)
 *
 * The second form reaches RecipeCapability as the Safe calling itself, which `execute` requires. Each leaf pins
 * the whole nested payload except the documented runtime words, so the Ethereum root authorizes the exact Base
 * call or recipe. Recipe call targets are literal, so the 3F recipes call a runtime-selected request through the
 * Safe itself, `Safe.execTransactionFromModule(request, 0, data, CALL)`, with the request bound from one input. A Safe module call returns false instead of reverting: a failed Base call emits
 * `ExecutionFromModuleFailure` while the portal deposit itself succeeds, and an Ethereum message that reverts
 * on Base cannot be retried.
 */
library BaseSafePayloads {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    /* ERRORS */

    /// @notice Raised when an inner payload is not at the expected offset of its wrapper.
    error InvalidNesting();

    /// @notice Raised when a sentinel amount is absent from the encoded payload.
    error SentinelNotFound();

    /* CONSTANTS */

    /// @dev Start of the `bytes` argument in `depositTransaction`: selector, five head words, length word.
    uint256 internal constant PORTAL_DATA_OFFSET = 196;

    /// @dev Start of the `bytes` argument in `execTransactionFromModule`: selector, four head words, length word.
    uint256 internal constant MODULE_DATA_OFFSET = 164;

    /// @dev Safe operations.
    uint8 internal constant CALL = 0;
    uint8 internal constant DELEGATECALL = 1;

    /// @dev Byte offsets of the two `mint` arguments inside a Safe router call
    /// `execTransactionFromModule(request, 0, mint(maxPt, minYt), CALL)`. The call target word is at offset 4.
    uint256 private constant _ROUTER_MAX_PT_OFFSET = MODULE_DATA_OFFSET + 4;
    uint256 private constant _ROUTER_MIN_YT_OFFSET = MODULE_DATA_OFFSET + 36;

    /// @dev Multicall3 `aggregate3` with one call: the call target word, and the first two words of its return data.
    uint256 private constant _MULTICALL_TARGET_OFFSET = 100;
    uint256 private constant _MULTICALL_FIRST_WORD = 192;
    uint256 private constant _MULTICALL_SECOND_WORD = 224;

    /// @dev Safe v1.4.1 EIP-712 type hashes for the Safe domain and for `SafeMessage(bytes message)`.
    bytes32 private constant _SAFE_DOMAIN_TYPEHASH = 0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
    bytes32 private constant _SAFE_MESSAGE_TYPEHASH =
        0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;

    /// @dev Sentinels that locate the free recipe inputs in an encoded payload.
    uint256 private constant _AMOUNT = uint256(keccak256("BaseSafePayloads.amount"));
    uint256 private constant _REQUEST = uint256(keccak256("BaseSafePayloads.request"));
    uint256 private constant _MAX_ASSETS = uint256(keccak256("BaseSafePayloads.maxAssets"));

    /* STRUCTS */

    /**
     * @notice Deployed addresses that the payloads pin.
     * @param ethereumAccount Ethereum MerkleAccount whose alias is a module of the Safe.
     * @param safe Base Safe holding the USDC.
     * @param recipeCapability RecipeCapability delegatecalled by the Safe.
     * @param policy ThreeFPolicy bound to the Safe.
     */
    struct Deployment {
        address ethereumAccount;
        address safe;
        address recipeCapability;
        address policy;
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Builds the Ethereum action approving CCTP to burn USDC from the MerkleAccount.
     * @dev Pins USDC and the TokenMessenger; only the amount is free. Pair it with `bridgeToBase` in one
     * `manage` call so the approval is consumed in the same transaction.
     */
    function approveBridge(uint256 amount) internal pure returns (IMerkleAccount.Action memory action) {
        action = _action(BaseChain.ETHEREUM_USDC, abi.encodeCall(IERC20.approve, (BaseChain.TOKEN_MESSENGER, amount)));
        _free(action.dataMask, 36, 32);
    }

    /**
     * @notice Builds the Ethereum action burning USDC through CCTP Standard Transfer to the Base Safe.
     * @dev Pins the Base domain, the Safe as recipient, USDC, zero fee and Standard finality; only the amount is
     * free. Anyone can relay the attested message on Base with `ReceiveCctpMessage`.
     */
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
                    bytes32(uint256(uint160(deployment.safe))),
                    BaseChain.ETHEREUM_USDC,
                    bytes32(0),
                    0,
                    BaseChain.STANDARD_FINALITY
                )
            )
        );
        _free(action.dataMask, 4, 32);
    }

    /**
     * @notice Builds the portal action setting the Safe policy's USDC budget for one 3F underlying asset.
     * @dev Calls `ThreeFPolicy.setMaxAssetsPerDuration` from the Safe. Pins the policy and USDC; the underlying
     * asset, budget and window are free, so grant this leaf only to the curator.
     */
    function setMaxAssetsPerDuration(
        Deployment memory deployment,
        address underlyingAsset,
        uint256 maxAssets,
        uint48 duration
    ) internal pure returns (IMerkleAccount.Action memory) {
        bytes memory data = abi.encodeCall(
            IThreeFPolicy.setMaxAssetsPerDuration, (BaseChain.BASE_USDC, underlyingAsset, maxAssets, duration)
        );
        bytes memory dataMask = new bytes(data.length);
        _free(dataMask, 36, 96);
        return _call(deployment, deployment.policy, data, dataMask);
    }

    /**
     * @notice Builds the portal action setting the Safe policy's minimum yield for one 3F underlying asset.
     * @dev Calls `ThreeFPolicy.setMinYieldPerRequest` from the Safe. Pins the policy; the underlying asset and
     * minimum are free, so grant this leaf only to the curator.
     */
    function setMinYieldPerRequest(Deployment memory deployment, address underlyingAsset, uint256 minimum)
        internal
        pure
        returns (IMerkleAccount.Action memory)
    {
        bytes memory data = abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (underlyingAsset, minimum));
        bytes memory dataMask = new bytes(data.length);
        _free(dataMask, 4, 64);
        return _call(deployment, deployment.policy, data, dataMask);
    }

    /**
     * @notice Builds the portal action running the 3F mint recipe in the Safe.
     * @dev Reads `mintAuthorization(safe)` on Base when the deposit runs, so a stale or revoked authorization
     * reverts the recipe before the policy is charged. The recipe then:
     * 1. checks that the authorized principal is nonzero and at most `maxAssets`;
     * 2. charges ThreeFPolicy with the authorized principal and yield;
     * 3. approves the request for the principal, mints through the Safe router with the authorized amounts as
     *    `maxPt` and `minYt`, and clears the approval;
     * 4. checks that the Safe's USDC fell by exactly the principal, because the router returns false on failure.
     * Only `request` and `maxAssets` are free, and one input feeds every use of the request. The policy rejects
     * requests that 3F's factory and Facility do not know.
     */
    function mintThreeF(Deployment memory deployment, address request, uint256 maxAssets)
        internal
        pure
        returns (IMerkleAccount.Action memory)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(16);
        uint256 requestInput = builder.input(0);
        ExecutingRecipe.Query memory authorization = _requestQuery(
            abi.encodeCall(IThreeFPushRequest.mintAuthorization, (deployment.safe)), requestInput, _MULTICALL_FIRST_WORD
        );
        uint256 principal = builder.readQuery(authorization);
        authorization.offset = _MULTICALL_SECOND_WORD;
        uint256 yieldAssets = builder.readQuery(authorization);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), principal);
        builder.check(OP_LESS_OR_EQUAL, principal, builder.input(1));
        ExecutingRecipe.Query memory cash = ExecutingRecipe.balanceQuery(BaseChain.BASE_USDC, deployment.safe);
        uint256 cashBefore = builder.readQuery(cash);
        builder.call(
            deployment.policy,
            abi.encodeCall(IThreeFPolicy.consume, (address(0), 0, 0)),
            _bindings(4, requestInput, 36, principal, 68, yieldAssets)
        );
        builder.call(
            BaseChain.BASE_USDC,
            abi.encodeCall(IERC20.approve, (address(0), 0)),
            _bindings(4, requestInput, 36, principal)
        );
        builder.call(
            deployment.safe,
            _router(abi.encodeCall(IThreeFPushRequest.mint, (0, 0))),
            _bindings(4, requestInput, _ROUTER_MAX_PT_OFFSET, principal, _ROUTER_MIN_YT_OFFSET, yieldAssets)
        );
        builder.call(BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (address(0), 0)), _bindings(4, requestInput));
        uint256 cashAfter = builder.readQuery(cash);
        builder.check(OP_EQUAL, builder.binary(OP_SUB, cashBefore, principal), cashAfter);
        return _inputs(deployment, builder, _REQUEST, uint160(request), _MAX_ASSETS, maxAssets);
    }

    /**
     * @notice Builds the portal action redeeming the Safe's whole position in a 3F request.
     * @dev Runs a recipe in the Safe: checks that 3F's RequestFactory knows the request, calls
     * `burnAll(safe, safe)` on it through the Safe router, then checks that the Safe holds no PT or YT of that
     * request, because the router returns false on failure. Only `request` is free. Call it after the request
     * allows withdrawals (`canWithdraw()`); before that, the recipe reverts.
     */
    function redeemThreeF(Deployment memory deployment, address request)
        internal
        pure
        returns (IMerkleAccount.Action memory)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(8);
        uint256 requestInput = builder.input(0);
        uint256[] memory requestBinding = _bindings(4, requestInput);
        uint256 known = builder.readQuery(
            ExecutingRecipe.Query({
                target: BaseChain.THREE_F_REQUESTS_FACTORY,
                data: abi.encodeCall(IThreeFRequestFactory.isRequest, (address(0))),
                bindings: requestBinding,
                offset: 0
            })
        );
        builder.check(OP_EQUAL, known, builder.literal(1));
        builder.call(
            deployment.safe,
            _router(abi.encodeCall(IThreeFVaultController.burnAll, (deployment.safe, deployment.safe))),
            requestBinding
        );
        ExecutingRecipe.Query memory shares = _requestQuery(
            abi.encodeCall(IThreeFVaultController.balancesOf, (deployment.safe)), requestInput, _MULTICALL_FIRST_WORD
        );
        builder.check(OP_EQUAL, builder.readQuery(shares), builder.literal(0));
        shares.offset = _MULTICALL_SECOND_WORD;
        builder.check(OP_EQUAL, builder.readQuery(shares), builder.literal(0));
        return _inputs(deployment, builder, _REQUEST, uint160(request), 0, 0);
    }

    /**
     * @notice Builds the portal action burning Safe USDC through CCTP Standard Transfer to the Ethereum MerkleAccount.
     * @dev Runs a two-step recipe in the Safe: approve the exact amount to the TokenMessenger, then
     * `depositForBurn` to the Ethereum domain with the MerkleAccount as recipient, zero fee and Standard finality.
     * Only the amount is free. Relay the attested message on Ethereum with `ReceiveCctpMessage`.
     */
    function bridgeToEthereum(Deployment memory deployment, uint256 amount)
        internal
        pure
        returns (IMerkleAccount.Action memory)
    {
        uint256 input = uint256(SRC_INPUT) << 216;
        bytes[] memory steps = new bytes[](2);
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(36, input);
        steps[0] = abi.encodePacked(
            OP_CALL,
            abi.encode(
                BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (BaseChain.TOKEN_MESSENGER, uint256(0))), bindings
            )
        );
        bindings[0] = ExecutingRecipe.binding(4, input);
        steps[1] = abi.encodePacked(
            OP_CALL,
            abi.encode(
                BaseChain.TOKEN_MESSENGER,
                abi.encodeCall(
                    ITokenMessengerV2.depositForBurn,
                    (
                        uint256(0),
                        BaseChain.ETHEREUM_DOMAIN,
                        bytes32(uint256(uint160(deployment.ethereumAccount))),
                        BaseChain.BASE_USDC,
                        bytes32(0),
                        0,
                        BaseChain.STANDARD_FINALITY
                    )
                ),
                bindings
            )
        );
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = _AMOUNT;
        bytes memory data = abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), steps, inputs));
        uint256 offset = _find(data, _AMOUNT);
        bytes memory dataMask = new bytes(data.length);
        _free(dataMask, offset, 32);
        _write(data, offset, amount);
        return _recipe(deployment, data, dataMask);
    }

    /**
     * @notice Builds the portal action that makes the Safe accept one exact ERC-1271 message.
     * @dev The alias, the Safe's only owner, calls `Safe.approveHash` directly with the Safe message hash of
     * `digest`. The Safe's fallback handler then accepts `aliasSignature(deployment)` for `digest` under ERC-1271.
     * Every byte is pinned, so each digest needs its own leaf. Use it for one-time messages such as 3F's
     * `EnrollMaker`; never build a leaf that leaves the digest free, because a free digest could sign a USDC permit.
     */
    function approveMessage(Deployment memory deployment, bytes32 digest)
        internal
        pure
        returns (IMerkleAccount.Action memory)
    {
        bytes memory data = abi.encodeCall(IGnosisSafe.approveHash, (safeMessageHash(deployment.safe, digest)));
        bytes memory portal = abi.encodeCall(
            IOptimismPortal.depositTransaction, (deployment.safe, 0, BaseChain.PORTAL_GAS_LIMIT, false, data)
        );
        return _action(BaseChain.BASE_PORTAL, portal);
    }

    /**
     * @notice Returns the hash that the Safe's fallback handler checks for an ERC-1271 `digest`.
     * @dev Matches `CompatibilityFallbackHandler.getMessageHashForSafe(safe, abi.encode(digest))` on Base.
     */
    function safeMessageHash(address safe, bytes32 digest) internal pure returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(_SAFE_DOMAIN_TYPEHASH, BaseChain.BASE_CHAIN_ID, safe));
        bytes32 structHash = keccak256(abi.encode(_SAFE_MESSAGE_TYPEHASH, keccak256(abi.encode(digest))));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, structHash));
    }

    /**
     * @notice Returns the signature to give a verifier after `approveMessage` has run on Base.
     * @dev A Safe approved-hash signature: the alias as `r`, zero `s` and `v` = 1.
     */
    function aliasSignature(Deployment memory deployment) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes32(uint256(uint160(BaseChain.l2Alias(deployment.ethereumAccount)))), bytes32(0), uint8(1)
        );
    }

    /* PRIVATE FUNCTIONS */

    /// @dev Wraps a RecipeCapability `execute` payload as a Safe self-call delegatecall, then as a portal action.
    function _recipe(Deployment memory deployment, bytes memory data, bytes memory dataMask)
        private
        pure
        returns (IMerkleAccount.Action memory)
    {
        bytes memory module = abi.encodeCall(
            ISafeModules.execTransactionFromModule, (deployment.recipeCapability, 0, data, DELEGATECALL)
        );
        return _call(deployment, deployment.safe, module, _nest(module, data, dataMask, MODULE_DATA_OFFSET));
    }

    /// @dev Wraps a Safe call as `execTransactionFromModule`, then as a Base portal deposit to the Safe, carrying
    /// the inner mask to its nested offsets. The call target is always pinned.
    function _call(Deployment memory deployment, address target, bytes memory data, bytes memory dataMask)
        private
        pure
        returns (IMerkleAccount.Action memory)
    {
        bytes memory module = abi.encodeCall(ISafeModules.execTransactionFromModule, (target, 0, data, CALL));
        bytes memory moduleMask = _nest(module, data, dataMask, MODULE_DATA_OFFSET);
        bytes memory portal = abi.encodeCall(
            IOptimismPortal.depositTransaction, (deployment.safe, 0, BaseChain.PORTAL_GAS_LIMIT, false, module)
        );
        return IMerkleAccount.Action({
            target: BaseChain.BASE_PORTAL,
            value: 0,
            data: portal,
            dataMask: _nest(portal, module, moduleMask, PORTAL_DATA_OFFSET),
            proof: new bytes32[](0)
        });
    }

    /// @dev Encodes `execute` for a built recipe with up to two sentinel inputs, writes the runtime values over the
    /// sentinels and frees exactly those words. A zero second sentinel means the recipe has one input.
    function _inputs(
        Deployment memory deployment,
        ExecutingRecipe.Builder memory builder,
        uint256 firstSentinel,
        uint256 firstValue,
        uint256 secondSentinel,
        uint256 secondValue
    ) private pure returns (IMerkleAccount.Action memory) {
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        uint256[] memory inputs = new uint256[](secondSentinel == 0 ? 1 : 2);
        inputs[0] = firstSentinel;
        if (secondSentinel != 0) inputs[1] = secondSentinel;
        bytes memory data = abi.encodeCall(IRecipeCapability.execute, (recipe.queries, recipe.steps, inputs));
        bytes memory dataMask = new bytes(data.length);
        uint256 offset = _find(data, firstSentinel);
        _free(dataMask, offset, 32);
        _write(data, offset, firstValue);
        if (secondSentinel != 0) {
            offset = _find(data, secondSentinel);
            _free(dataMask, offset, 32);
            _write(data, offset, secondValue);
        }
        return _recipe(deployment, data, dataMask);
    }

    /// @dev Encodes a Safe router call: the Safe, an enabled module of itself, calls the request bound at offset 4.
    function _router(bytes memory data) private pure returns (bytes memory) {
        return abi.encodeCall(ISafeModules.execTransactionFromModule, (address(0), 0, data, CALL));
    }

    /// @dev Builds a query reading one word that a runtime-selected request returns for `data`. The recipe engine
    /// needs a literal query target, so Multicall3 calls the request bound from `request`.
    function _requestQuery(bytes memory data, uint256 request, uint256 offset)
        private
        pure
        returns (ExecutingRecipe.Query memory)
    {
        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](1);
        calls[0] = IMulticall3.Call3({target: address(0), allowFailure: false, callData: data});
        return ExecutingRecipe.Query({
            target: BaseChain.MULTICALL3,
            data: abi.encodeCall(IMulticall3.aggregate3, (calls)),
            bindings: _bindings(_MULTICALL_TARGET_OFFSET, request),
            offset: offset
        });
    }

    /// @dev Returns one call binding.
    function _bindings(uint256 offset, uint256 operand) private pure returns (uint256[] memory bindings) {
        bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(offset, operand);
    }

    /// @dev Returns two call bindings; offsets must ascend.
    function _bindings(uint256 offset0, uint256 operand0, uint256 offset1, uint256 operand1)
        private
        pure
        returns (uint256[] memory bindings)
    {
        bindings = new uint256[](2);
        bindings[0] = ExecutingRecipe.binding(offset0, operand0);
        bindings[1] = ExecutingRecipe.binding(offset1, operand1);
    }

    /// @dev Returns three call bindings; offsets must ascend.
    function _bindings(
        uint256 offset0,
        uint256 operand0,
        uint256 offset1,
        uint256 operand1,
        uint256 offset2,
        uint256 operand2
    ) private pure returns (uint256[] memory bindings) {
        bindings = new uint256[](3);
        bindings[0] = ExecutingRecipe.binding(offset0, operand0);
        bindings[1] = ExecutingRecipe.binding(offset1, operand1);
        bindings[2] = ExecutingRecipe.binding(offset2, operand2);
    }

    /// @dev Checks that `inner` is the `bytes` argument starting at `offset` of `outer` and returns `outer`'s mask
    /// with `innerMask` copied to that offset; the wrapper's own bytes stay pinned.
    function _nest(bytes memory outer, bytes memory inner, bytes memory innerMask, uint256 offset)
        private
        pure
        returns (bytes memory dataMask)
    {
        uint256 length = inner.length;
        if (innerMask.length != length || offset + length > outer.length) revert InvalidNesting();
        bool nested;
        assembly ("memory-safe") {
            nested := and(
                eq(mload(add(outer, offset)), length),
                eq(keccak256(add(add(outer, 32), offset), length), keccak256(add(inner, 32), length))
            )
        }
        if (!nested) revert InvalidNesting();
        dataMask = new bytes(outer.length);
        for (uint256 i; i < length; ++i) {
            dataMask[offset + i] = innerMask[i];
        }
    }

    /// @dev Creates a value-free action with an all-pinned mask.
    function _action(address target, bytes memory data) private pure returns (IMerkleAccount.Action memory) {
        return IMerkleAccount.Action({
            target: target, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
    }

    /// @dev Marks `length` bytes from `offset` as free in a mask.
    function _free(bytes memory dataMask, uint256 offset, uint256 length) private pure {
        for (uint256 i = offset; i < offset + length; ++i) {
            dataMask[i] = 0xff;
        }
    }

    /// @dev Writes one word into an encoded payload.
    function _write(bytes memory data, uint256 offset, uint256 value) private pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), value)
        }
    }

    /// @dev Locates a sentinel word in an encoded payload.
    function _find(bytes memory data, uint256 sentinel) private pure returns (uint256) {
        uint256 length = data.length;
        for (uint256 i; i + 32 <= length; ++i) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), i))
            }
            if (word == sentinel) return i;
        }
        revert SentinelNotFound();
    }
}
