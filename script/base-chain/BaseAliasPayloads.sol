// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "./BaseChain.sol";
import {BaseSafePayloads} from "./BaseSafePayloads.sol";
import {ExecutingRecipe} from "../recipes/ExecutingRecipe.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {OP_LESS_OR_EQUAL} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IBaseAliasThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IBaseAliasThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITokenMessengerV2} from "../utils/interfaces/ICCTPv2.sol";
import {IOptimismPortal} from "../utils/interfaces/IOptimismPortal.sol";

/**
 * @title BaseAliasPayloads
 * @notice Library building the Ethereum MerkleAccount actions that operate the MerkleAccount's own alias on Base,
 * with no Safe: the alias is the 3F maker and holds the USDC, PT and YT.
 * @dev Every Base action is one Base portal deposit, so the alias makes exactly one call per action:
 *
 *   alias -> target.call(data)
 *
 * The mint recipe calls the policy directly on Ethereum, then submits three Base deposits in the same `manage`
 * call. A rejected policy charge prevents all deposits. After a successful dispatch, Base runs approval, mint and
 * reset as independent transactions from the alias. Refer to `ALIAS_RUNBOOK.md`.
 */
library BaseAliasPayloads {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    /* ERRORS */

    /// @notice Raised when the mint cap does not fit the `uint128` amounts of 3F `mint`.
    error InvalidMaxPrincipal();

    /* CONSTANTS */

    /// @dev Offset of the `to` word in `depositTransaction` calldata.
    uint256 internal constant PORTAL_TO_OFFSET = 4;

    /// @dev Start of the `bytes` argument in `depositTransaction`: selector, five head words, length word.
    uint256 internal constant PORTAL_DATA_OFFSET = 196;

    /// @dev Offsets of the first two static arguments of the Base call inside the portal calldata.
    uint256 internal constant ARGUMENT_0 = PORTAL_DATA_OFFSET + 4;
    uint256 internal constant ARGUMENT_1 = PORTAL_DATA_OFFSET + 36;

    /// @dev Number of actions in `mintActions`, including the Ethereum policy call.
    uint256 internal constant MINT_ACTIONS = 4;

    /* STRUCTS */

    /**
     * @notice Deployed addresses that the payloads pin.
     * @param ethereumAccount Ethereum MerkleAccount whose alias acts on Base.
     * @param policy Ethereum policy bound to the MerkleAccount.
     */
    struct Deployment {
        address ethereumAccount;
        address policy;
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Returns the alias of the MerkleAccount on Base: the 3F maker and the CCTP recipient of this flow.
     */
    function aliasOf(Deployment memory deployment) internal pure returns (address) {
        return BaseChain.l2Alias(deployment.ethereumAccount);
    }

    /**
     * @notice Builds the Ethereum action approving CCTP to burn USDC from the MerkleAccount.
     * @dev Same leaf as the Safe flow: pins USDC and the TokenMessenger; only the amount is free. Pair it with
     * `bridgeToBase` in one `manage` call.
     */
    function approveBridge(uint256 amount) internal pure returns (IMerkleAccount.Action memory) {
        return BaseSafePayloads.approveBridge(amount);
    }

    /**
     * @notice Builds the Ethereum action burning USDC through CCTP Standard Transfer to the alias on Base.
     * @dev Pins the Base domain, the alias as recipient, USDC, all callers, zero fee and Standard finality; only
     * the amount is free. Anyone can relay the attested message on Base with `ReceiveCctpMessage`.
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
                    bytes32(uint256(uint160(aliasOf(deployment)))),
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
     * @notice Builds the Ethereum action setting the Base collateral underlying for a verified 3F request.
     * @dev Pins the policy. Grant this leaf only to the curator.
     */
    function setRequestUnderlying(Deployment memory deployment, address request, address underlyingAsset)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = _action(
            deployment.policy, abi.encodeCall(IBaseAliasThreeFPolicy.setRequestUnderlying, (request, underlyingAsset))
        );
        _free(action.dataMask, 4, 64);
    }

    /**
     * @notice Builds the Ethereum action setting the policy's USDC budget for one 3F underlying asset.
     * @dev Pins the policy. Grant this leaf only to the curator.
     */
    function setMaxAssetsPerDuration(
        Deployment memory deployment,
        address underlyingAsset,
        uint256 maxAssets,
        uint48 duration
    ) internal pure returns (IMerkleAccount.Action memory action) {
        action = _action(
            deployment.policy,
            abi.encodeCall(IBaseAliasThreeFPolicy.setMaxAssetsPerDuration, (underlyingAsset, maxAssets, duration))
        );
        _free(action.dataMask, 4, 96);
    }

    /**
     * @notice Builds the Ethereum action setting the policy's minimum yield for one 3F underlying asset.
     * @dev Pins the policy. Grant this leaf only to the curator.
     */
    function setMinYieldPerRequest(Deployment memory deployment, address underlyingAsset, uint256 minimum)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = _action(
            deployment.policy, abi.encodeCall(IBaseAliasThreeFPolicy.setMinYieldPerRequest, (underlyingAsset, minimum))
        );
        _free(action.dataMask, 4, 64);
    }

    /**
     * @notice Builds the first mint action, which charges the Ethereum policy before any Base deposit.
     * @dev Pins the policy. Grant this leaf only to the RecipeExecutor that binds the mint inputs.
     */
    function consumeThreeF(Deployment memory deployment, address request, uint256 principal, uint256 yieldAssets)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = _action(
            deployment.policy, abi.encodeCall(IBaseAliasThreeFPolicy.consume, (request, principal, yieldAssets))
        );
        _free(action.dataMask, 4, 96);
    }

    /**
     * @notice Builds the first mint deposit: the alias approves the request to pull the principal.
     * @dev Calls USDC `approve(request, principal)` on Base. Pins USDC; the spender and amount are free, so grant
     * this leaf only to `RecipeExecutor`.
     */
    function approveThreeF(address request, uint256 principal)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = _deposit(BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (request, principal)));
        _free(action.dataMask, ARGUMENT_0, 64);
    }

    /**
     * @notice Builds the second mint deposit: the alias mints PT and YT from its live 3F authorization.
     * @dev Calls `request.mint(maxPt, minYt)` with the principal and yield as the slippage bounds. The deposit
     * target (the request) and both amounts are free, so grant this leaf only to `RecipeExecutor`. The request pulls
     * the principal with the approval from `approveThreeF`.
     */
    function mintThreeF(address request, uint256 principal, uint256 yieldAssets)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = _deposit(request, abi.encodeCall(IThreeFPushRequest.mint, (uint128(principal), uint128(yieldAssets))));
        _free(action.dataMask, PORTAL_TO_OFFSET, 32);
        _free(action.dataMask, ARGUMENT_0, 64);
    }

    /**
     * @notice Builds the third mint deposit: the alias removes any approval left on the request.
     * @dev Calls USDC `approve(request, 0)` on Base. Only the spender is free; the amount is pinned to zero, so the
     * leaf can only remove an approval. The reset deposit still runs if `mint` fails. Grant it to `RecipeExecutor` and
     * to the executor bot, which uses it alone to recover after a failed reset (`ResetThreeFApprovalFromAlias`).
     */
    function resetThreeFApproval(address request) internal pure returns (IMerkleAccount.Action memory action) {
        action = _deposit(BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (request, 0)));
        _free(action.dataMask, ARGUMENT_0, 32);
    }

    /**
     * @notice Builds the deposit in which the alias redeems its whole position in a repaid 3F request.
     * @dev Calls `request.burnAll(alias, alias)`. Only the deposit target is free; the calldata is pinned, so the
     * principal and yield can only go to the alias. Send it after `canWithdraw()` on the request returns true;
     * earlier, the Base transaction reverts.
     */
    function redeemThreeF(Deployment memory deployment, address request)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        address l2Alias = aliasOf(deployment);
        action = _deposit(request, abi.encodeCall(IThreeFVaultController.burnAll, (l2Alias, l2Alias)));
        _free(action.dataMask, PORTAL_TO_OFFSET, 32);
    }

    /**
     * @notice Builds the deposit in which the alias approves CCTP to burn its USDC on Base.
     * @dev Calls USDC `approve(TokenMessengerV2, amount)` on Base. Pins USDC and the spender; only the amount is
     * free. Pair it with `bridgeToEthereum` in one `manage` call.
     */
    function approveBurn(uint256 amount) internal pure returns (IMerkleAccount.Action memory action) {
        action = _deposit(BaseChain.BASE_USDC, abi.encodeCall(IERC20.approve, (BaseChain.TOKEN_MESSENGER, amount)));
        _free(action.dataMask, ARGUMENT_1, 32);
    }

    /**
     * @notice Builds the deposit in which the alias burns USDC through CCTP Standard Transfer to the MerkleAccount.
     * @dev Calls `depositForBurn` on Base with the Ethereum domain, the MerkleAccount as recipient, Base USDC, all
     * callers, zero fee and Standard finality; only the amount is free. Relay the attested message on Ethereum with
     * `ReceiveCctpMessage`.
     */
    function bridgeToEthereum(Deployment memory deployment, uint256 amount)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = _deposit(
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
        _free(action.dataMask, ARGUMENT_0, 32);
    }

    /**
     * @notice Builds the Ethereum policy charge and the three ordered Base deposits.
     * @dev Order: `consumeThreeF`, `approveThreeF`, `mintThreeF`, `resetThreeFApproval`. Pass zero values to get
     * the leaf templates. `RecipeExecutor` overwrites the free words with the recipe inputs, so the values here
     * only matter for logs and simulations.
     */
    function mintActions(Deployment memory deployment, address request, uint256 principal, uint256 yieldAssets)
        internal
        pure
        returns (IMerkleAccount.Action[] memory actions)
    {
        actions = new IMerkleAccount.Action[](MINT_ACTIONS);
        actions[0] = consumeThreeF(deployment, request, principal, yieldAssets);
        actions[1] = approveThreeF(request, principal);
        actions[2] = mintThreeF(request, principal, yieldAssets);
        actions[3] = resetThreeFApproval(request);
    }

    /**
     * @notice Builds the `RecipeExecutor` recipe that charges the policy and sends the mint deposits.
     * @dev Inputs: 0 = request, 1 = principal, 2 = yield. The recipe checks that the principal is between 1 and
     * `maxPrincipal` and that the yield fits `uint128`, then sends one `manage` call with the four mint leaves. Its
     * bindings share the request and amounts across the policy charge and deposits. The policy admits registered
     * Base requests only and checks the principal cap and minimum yield passed to `mint`.
     */
    function mintRecipe(Deployment memory deployment, uint256 maxPrincipal)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory)
    {
        if (maxPrincipal == 0 || maxPrincipal > type(uint128).max) revert InvalidMaxPrincipal();
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(8);
        uint256 request = builder.input(0);
        uint256 principal = builder.input(1);
        uint256 yieldAssets = builder.input(2);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), principal);
        builder.check(OP_LESS_OR_EQUAL, principal, builder.literal(maxPrincipal));
        builder.check(OP_LESS_OR_EQUAL, yieldAssets, builder.literal(type(uint128).max));
        builder.manage(builder.literal(1), mintLeaves(deployment), _mintBindings(request, principal, yieldAssets));
        return builder.finish();
    }

    /**
     * @notice Returns the inputs for `RecipeExecutor.execute` with the recipe from `mintRecipe`.
     * @dev Read `principal` and `yieldAssets` from `mintAuthorization(alias)` on the request on Base.
     */
    function mintInputs(address request, uint256 principal, uint256 yieldAssets)
        internal
        pure
        returns (uint256[] memory inputs)
    {
        inputs = new uint256[](3);
        inputs[0] = uint160(request);
        inputs[1] = principal;
        inputs[2] = yieldAssets;
    }

    /**
     * @notice Returns the four mint leaves in recipe order.
     * @dev Grant the `consumeThreeF`, `approveThreeF` and `mintThreeF` roles to the `RecipeExecutor` that holds the
     * mint recipe, and to no other address. Grant `resetThreeFApproval` to that executor and to the executor bot.
     */
    function mintLeaves(Deployment memory deployment) internal pure returns (bytes32[] memory leaves) {
        IMerkleAccount.Action[] memory actions = mintActions(deployment, address(0), 0, 0);
        leaves = new bytes32[](MINT_ACTIONS);
        for (uint256 i; i < MINT_ACTIONS; ++i) {
            leaves[i] = leaf(actions[i]);
        }
    }

    /**
     * @notice Returns the leaf that the MerkleAccount derives for an action.
     * @dev Uses ActionMasker, so masked runtime words do not change the leaf.
     */
    function leaf(IMerkleAccount.Action memory action) internal pure returns (bytes32) {
        return ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
    }

    /* PRIVATE FUNCTIONS */

    /// @dev Returns the recipe bindings, with ascending offsets within each action.
    function _mintBindings(uint256 request, uint256 principal, uint256 yieldAssets)
        private
        pure
        returns (uint256[][] memory bindings)
    {
        bindings = new uint256[][](MINT_ACTIONS);
        bindings[0] = new uint256[](3);
        bindings[0][0] = ExecutingRecipe.binding(4, request);
        bindings[0][1] = ExecutingRecipe.binding(36, principal);
        bindings[0][2] = ExecutingRecipe.binding(68, yieldAssets);
        bindings[1] = new uint256[](2);
        bindings[1][0] = ExecutingRecipe.binding(ARGUMENT_0, request);
        bindings[1][1] = ExecutingRecipe.binding(ARGUMENT_1, principal);
        bindings[2] = new uint256[](3);
        bindings[2][0] = ExecutingRecipe.binding(PORTAL_TO_OFFSET, request);
        bindings[2][1] = ExecutingRecipe.binding(ARGUMENT_0, principal);
        bindings[2][2] = ExecutingRecipe.binding(ARGUMENT_1, yieldAssets);
        bindings[3] = new uint256[](1);
        bindings[3][0] = ExecutingRecipe.binding(ARGUMENT_0, request);
    }

    /// @dev Wraps one Base call from the alias as a portal deposit with every byte pinned.
    function _deposit(address to, bytes memory data) private pure returns (IMerkleAccount.Action memory) {
        return _action(
            BaseChain.BASE_PORTAL,
            abi.encodeCall(IOptimismPortal.depositTransaction, (to, 0, BaseChain.PORTAL_GAS_LIMIT, false, data))
        );
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
}
