// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {OP_CALL, OP_MANAGE} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {
    IThreeFFacility,
    IThreeFPositionManager,
    IThreeFRequestName,
    IThreeFUnderlyingAsset
} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {
    IThreeFPolicy,
    REQUEST_NAME_PREFIX_LENGTH
} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ClaimRecipe} from "script/recipes/ClaimRecipe.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {LLExecuting} from "script/recipes/LLExecuting.sol";
import {LendingRecipe} from "script/recipes/LendingRecipe.sol";
import {RecoveryRecipe} from "script/recipes/RecoveryRecipe.sol";
import {RecipeManifest} from "script/recipes/RecipeManifest.sol";
import {ThreeFExecuting} from "script/recipes/ThreeFExecuting.sol";
import {ThreeFGuardedMint} from "script/recipes/ThreeFGuardedMint.sol";

/**
 * @title BuildRecipe
 * @notice Script for encoding a named recipe and curator transactions from a JSON configuration.
 * @dev Resolves the custody account from the adapter; does not sign or broadcast. Permissions and economic limits
 * must be verified separately. A supplied factory must contain RecipeExecutor creation bytecode.
 */
contract BuildRecipe is Script {
    using stdJson for string;

    string internal _stages;

    /* ERRORS */

    /// @notice Raised when direct policy consumption is configured without an executor address.
    error InvalidPolicyConsumer();

    /// @notice Raised when saved recipe bytes conflict with their hash, arrays, calldata or guarded leaf.
    error InvalidRecipeArtifact();

    /**
     * @notice Raised when the requested template is unsupported.
     */
    error UnknownTemplate();

    /* PUBLIC FUNCTIONS */

    /**
     * @notice Reads a template configuration and writes its ABI-encoded recipe and transaction calldata.
     * @param inputPath JSON configuration matching one of script/recipes/examples/*.json.
     * @param outputPath Destination JSON file; the containing directory must already exist.
     */
    function run(string memory inputPath, string memory outputPath) public {
        string memory source = vm.readFile(inputPath);
        string memory template = source.readString(".template");
        bytes32 templateId = keccak256(bytes(template));
        if (
            templateId != keccak256("lending") && templateId != keccak256("health-recovery")
                && templateId != keccak256("health-claim") && templateId != keccak256("health-repay")
                && templateId != keccak256("claim") && templateId != keccak256("ll-executing")
                && templateId != keccak256("3f-executing")
        ) revert UnknownTemplate();
        address curator = source.readAddress(".curator");
        address provider = source.readAddress(".provider");
        address adapter = source.readAddress(".adapter");
        ExecutingRecipe.Recipe memory recipe;
        string memory guardedMintManifest;
        RecoveryRecipe.Layout memory layout;
        _stages = "";
        vm.serializeJson(outputPath, "{}");

        if (templateId == keccak256("lending")) {
            LendingRecipe.Config memory config;
            config.skipZeroApprovals = _optimization(source, "skipZeroApprovals");
            config.account = IMerkleAdapter(adapter).account();
            config.lbtc = source.readAddress(".addresses.lbtc");
            config.usdc = source.readAddress(".addresses.usdc");
            config.rwa = source.readAddress(".addresses.rwa");
            config.collateralReceipt = source.readAddress(".addresses.collateralReceipt");
            config.variableDebt = source.readAddress(".addresses.variableDebt");
            config.pool = source.readAddress(".addresses.pool");
            config.issuer = source.readAddress(".addresses.issuer");
            if (source.keyExists(".purchaseReceipt")) {
                config.purchaseReceipt = _fundingQuery(source, ".purchaseReceipt");
            }
            config.collateralApprovalLeaf = source.readBytes32(".leaves.collateralApproval");
            config.supplyLeaf = source.readBytes32(".leaves.supply");
            config.borrowLeaf = source.readBytes32(".leaves.borrow");
            config.purchaseApprovalLeaf = source.readBytes32(".leaves.purchaseApproval");
            config.purchaseLeaf = source.readBytes32(".leaves.purchase");
            config.supplyAmountOffsets = source.readUintArray(".amountOffsets.supply");
            config.borrowAmountOffsets = source.readUintArray(".amountOffsets.borrow");
            config.purchaseAmountOffsets = source.readUintArray(".amountOffsets.purchase");
            LendingRecipe.Limits memory limits;
            limits.maxSupplyLbtc = source.readUint(".limits.maxSupplyLbtc");
            limits.maxTotalDebtUsdc = source.readUint(".limits.maxTotalDebtUsdc");
            limits.minRwaPerUsdcWad = source.readUint(".limits.minRwaPerUsdcWad");
            LendingRecipe.Layout memory lending;
            (recipe, lending) = LendingRecipe.build(config, limits);
            vm.serializeBytes(outputPath, "borrowedUsdc", abi.encode(lending.borrowedUsdc));
            vm.serializeBytes(outputPath, "minimumRwa", abi.encode(lending.minimumRwa));
            vm.serializeBytes(outputPath, "rwaReceived", abi.encode(lending.rwaReceived));
            _stages = string.concat(
                "[",
                _stage("Approve collateral", 0, 1),
                ",",
                _stage("Supply collateral", 1, 2),
                ",",
                _stage("Borrow", 2, 3),
                ",",
                _stage("Approve purchase", 3, 4),
                ",",
                _stage("Purchase RWA", 4, 5),
                ",",
                _stage("Clear collateral approval", 5, 6),
                ",",
                _stage("Clear purchase approval", 6, 7),
                "]"
            );
        } else if (templateId == keccak256("3f-executing")) {
            ThreeFExecuting.Config memory config;
            config.skipZeroApprovals = _optimization(source, "skipZeroApprovals");
            config.reuseTupleReads = _optimization(source, "reuseTupleReads");
            config.funding = _funding(source, adapter);
            config.request = source.readAddress(".addresses.request");
            config.approvalLeaf = source.readBytes32(".leaves.approval");
            config.maxPrincipal = source.readUint(".limits.maxPrincipal");
            config.policy = source.readAddress(".addresses.policy");
            config.guardedMint = !source.keyExists(".policy.guardedMint") || source.readBool(".policy.guardedMint");
            (config.mintLeaf, guardedMintManifest) = _serializeThreeFPolicy(source, outputPath, config);
            ThreeFExecuting.Layout memory execution;
            (recipe, execution) = ThreeFExecuting.build(config);
            _stages = string.concat(
                _executionStages(
                    source,
                    execution.sourceCalls,
                    execution.approve,
                    execution.operation,
                    execution.clearApproval,
                    false
                ),
                "]"
            );
            vm.serializeUint(outputPath, "sourceCalls", execution.sourceCalls);
            vm.serializeUint(outputPath, "sourceAmountResults", execution.sourceAmounts);
            vm.serializeUint(outputPath, "operationStep", execution.operation);
            vm.serializeUint(outputPath, "requestInput", 0);
            vm.serializeUint(outputPath, "principalInput", 1);
            vm.serializeUint(outputPath, "yieldInput", 2);
        } else if (templateId == keccak256("ll-executing")) {
            LLExecuting.Config memory config;
            config.skipZeroApprovals = _optimization(source, "skipZeroApprovals");
            config.funding = _funding(source, adapter);
            config.connector = source.readAddress(".addresses.connector");
            config.rwa = source.readAddress(".addresses.rwa");
            config.recipient = source.readAddress(".addresses.recipient");
            config.approvalLeaf = source.readBytes32(".leaves.approval");
            config.swapLeaf = source.readBytes32(".leaves.swap");
            config.maxAmountIn = source.readUint(".limits.maxAmountIn");
            config.maxFundingAmount = source.readUint(".limits.maxFundingAmount");
            if (source.keyExists(".redemption")) {
                config.redemption.leaves = source.readBytes32Array(".redemption.leaves");
                if (config.redemption.leaves.length > 0) {
                    config.redemption.retainsRwa =
                        source.keyExists(".redemption.retainsRwa") && source.readBool(".redemption.retainsRwa");
                    if (source.keyExists(".redemption.amountOffsets")) {
                        config.redemption.amountOffsets = _amountOffsets(source, ".redemption");
                    }
                    config.redemption.spender = source.readAddress(".redemption.spender");
                    config.redemption.approvalLeaf = source.readBytes32(".redemption.approvalLeaf");
                    config.redemption.receipt = _fundingQuery(source, ".redemption.receipt");
                    config.redemption.minReceiptNumerator = source.readUint(".redemption.minReceiptNumerator");
                    config.redemption.receiptDenominator = source.readUint(".redemption.receiptDenominator");
                }
            }
            LLExecuting.Layout memory execution;
            (recipe, execution) = LLExecuting.build(config);
            _stages = _llStages(source, execution);
            vm.serializeUint(outputPath, "sourceCalls", execution.sourceCalls);
            vm.serializeUint(outputPath, "sourceAmountResults", execution.sourceAmounts);
            vm.serializeBytes(outputPath, "amountIn", abi.encode(execution.amountIn));
            vm.serializeBytes(outputPath, "amountOut", abi.encode(execution.amountOut));
            vm.serializeUint(outputPath, "approveStep", execution.approve);
            vm.serializeUint(outputPath, "operationStep", execution.operation);
            vm.serializeUint(outputPath, "clearApprovalStep", execution.clearApproval);
            if (config.redemption.leaves.length > 0) {
                vm.serializeUint(outputPath, "redeemApproveStep", execution.redeemApprove);
                vm.serializeUint(outputPath, "redeemStep", execution.redeem);
                vm.serializeUint(outputPath, "redeemClearApprovalStep", execution.redeemClearApproval);
            }
        } else if (templateId == keccak256("claim")) {
            ClaimRecipe.Claim[] memory claims = new ClaimRecipe.Claim[](_length(source, ".claims"));
            for (uint256 i; i < claims.length; ++i) {
                string memory path = string.concat(".claims[", vm.toString(i), "]");
                claims[i].claimable = ExecutingRecipe.query(_fundingQuery(source, string.concat(path, ".claimable")));
                if (source.keyExists(string.concat(path, ".maxAmount"))) {
                    claims[i].maxAmount = source.readUint(string.concat(path, ".maxAmount"));
                }
                if (source.keyExists(string.concat(path, ".claimable.bindings"))) {
                    claims[i].claimable.bindings = source.readUintArray(string.concat(path, ".claimable.bindings"));
                }
                claims[i].leaves = source.readBytes32Array(string.concat(path, ".leaves"));
                claims[i].amountOffsets = _amountOffsets(source, path);
                claims[i].outputs = new ClaimRecipe.Output[](_length(source, string.concat(path, ".outputs")));
                for (uint256 j; j < claims[i].outputs.length; ++j) {
                    string memory output = string.concat(path, ".outputs[", vm.toString(j), "]");
                    claims[i].outputs[j] = ClaimRecipe.Output({
                        token: source.keyExists(string.concat(output, ".token"))
                            ? source.readAddress(string.concat(output, ".token"))
                            : address(0),
                        balance: source.keyExists(string.concat(output, ".balance"))
                            ? _fundingQuery(source, string.concat(output, ".balance"))
                            : ExecutingRecipe.Read({target: address(0), data: "", offset: 0}),
                        minNumerator: source.readUint(string.concat(output, ".minNumerator")),
                        denominator: source.readUint(string.concat(output, ".denominator"))
                    });
                }
            }
            uint256[] memory claimCalls;
            (recipe, claimCalls) = ClaimRecipe.build(IMerkleAdapter(adapter).account(), claims);
            _stages = "[";
            for (uint256 i; i < claimCalls.length; ++i) {
                if (i > 0) _stages = string.concat(_stages, ",");
                string memory path = string.concat(".claims[", vm.toString(i), "].name");
                _stages = string.concat(
                    _stages,
                    _stage(
                        source.keyExists(path) ? source.readString(path) : "Claim settled operation",
                        claimCalls[i],
                        claimCalls[i] + 1
                    )
                );
            }
            _stages = string.concat(_stages, "]");
            vm.serializeUint(outputPath, "claimCalls", claimCalls);
        } else {
            RecoveryRecipe.Config memory config = _recoveryConfig(source, adapter);
            if (templateId == keccak256("health-recovery")) {
                (recipe, layout) = RecoveryRecipe.recovery(config);
            } else if (templateId == keccak256("health-repay")) {
                (recipe, layout) = RecoveryRecipe.repay(config, source.readUint(".limits.minCashBalance"));
            } else {
                (recipe, layout) = RecoveryRecipe.claim(config);
            }
            _stages = _recoveryStages(templateId == keccak256("health-recovery"), layout);
        }

        bytes memory constructorArgs = abi.encode(curator, IMerkleAdapter(adapter).account());
        vm.serializeString(outputPath, "template", template);
        vm.serializeAddress(outputPath, "curator", curator);
        vm.serializeAddress(outputPath, "provider", provider);
        vm.serializeAddress(outputPath, "adapter", adapter);
        vm.serializeAddress(outputPath, "account", IMerkleAdapter(adapter).account());
        vm.serializeBytes(outputPath, "recipe", abi.encode(recipe.queries, recipe.steps));
        vm.serializeBytes32(outputPath, "recipeHash", keccak256(abi.encode(recipe.queries, recipe.steps)));
        vm.serializeUint(outputPath, "runtimeSteps", ExecutingRecipe.runtimeSteps(recipe));
        vm.serializeUint(outputPath, "stepCount", recipe.steps.length);
        vm.serializeBool(outputPath, "skipUnusedReads", _optimization(source, "skipUnusedReads"));
        vm.serializeBool(outputPath, "skipZeroApprovals", _optimization(source, "skipZeroApprovals"));
        vm.serializeBool(outputPath, "reuseTupleReads", _optimization(source, "reuseTupleReads"));
        vm.serializeBytes(
            outputPath, "setRecipeCalldata", abi.encodeCall(IRecipeExecutor.setRecipe, (recipe.queries, recipe.steps))
        );
        vm.serializeBytes(outputPath, "setCallerCalldata", abi.encodeCall(IRecipeExecutor.setCaller, (provider)));
        if (
            templateId == keccak256("health-recovery") || templateId == keccak256("health-claim")
                || templateId == keccak256("health-repay")
        ) {
            vm.serializeUint(outputPath, "sourceCalls", layout.sourceCalls);
            vm.serializeUint(outputPath, "requestCalls", layout.requestCalls);
            vm.serializeUint(outputPath, "claimCalls", layout.claimCalls);
            vm.serializeUint(outputPath, "approveStep", layout.approve);
            vm.serializeUint(outputPath, "repayStep", layout.repay);
            vm.serializeUint(outputPath, "clearApprovalStep", layout.clearApproval);
        }
        if (source.keyExists(".factory")) {
            vm.serializeAddress(outputPath, "factory", source.readAddress(".factory"));
            vm.serializeBytes(
                outputPath, "factoryCreateCalldata", abi.encodeCall(IImmutableFactory.create, (constructorArgs))
            );
        }
        vm.writeJson(vm.serializeBytes(outputPath, "constructorArgs", constructorArgs), outputPath);
        vm.writeJson(_instructionStages(recipe), outputPath, ".stages");
        vm.writeJson(RecipeManifest.render(recipe), outputPath, ".manifest");
        vm.writeJson('"build"', outputPath, ".manifestContext");
        if (bytes(guardedMintManifest).length > 0) {
            vm.writeJson(guardedMintManifest, outputPath, ".guardedMintManifest");
        }
    }

    /**
     * @notice Adds readable manifests to an existing recipe artifact without rebuilding its instructions.
     * @dev Accepts current-format encoded recipe bytes or packed queries/steps arrays from SetRecipe logs.
     * Renders against the selected inspection context; does not recover historical deployment provenance.
     * Supplied hashes and configuration calldata must match. All decoding completes before writing output.
     * @param inputPath Existing JSON artifact containing recipe or queries and steps.
     * @param outputPath Destination JSON file; may equal inputPath for an in-place update.
     */
    function inspect(string memory inputPath, string memory outputPath) public {
        string memory source = vm.readFile(inputPath);
        ExecutingRecipe.Recipe memory recipe;
        if (source.keyExists(".recipe")) {
            (recipe.queries, recipe.steps) = abi.decode(source.readBytes(".recipe"), (bytes[], bytes[]));
        } else {
            recipe.queries = source.readBytesArray(".queries");
            recipe.steps = source.readBytesArray(".steps");
        }
        bytes memory encoded = abi.encode(recipe.queries, recipe.steps);
        bytes32 recipeHash = keccak256(encoded);
        if (source.keyExists(".recipe") && keccak256(source.readBytes(".recipe")) != recipeHash) {
            revert InvalidRecipeArtifact();
        }
        if (source.keyExists(".queries") || source.keyExists(".steps")) {
            if (keccak256(abi.encode(source.readBytesArray(".queries"), source.readBytesArray(".steps"))) != recipeHash)
            {
                revert InvalidRecipeArtifact();
            }
        }
        if (source.keyExists(".recipeHash") && source.readBytes32(".recipeHash") != recipeHash) {
            revert InvalidRecipeArtifact();
        }
        if (
            source.keyExists(".setRecipeCalldata")
                && keccak256(source.readBytes(".setRecipeCalldata"))
                    != keccak256(abi.encodeCall(IRecipeExecutor.setRecipe, (recipe.queries, recipe.steps)))
        ) revert InvalidRecipeArtifact();
        string memory manifest = RecipeManifest.render(recipe);
        string memory guardedMintManifest;
        if (source.keyExists(".guardedMint") && source.readBool(".guardedMint")) {
            bytes memory data = source.readBytes(".mintLeafData");
            if (data.length < 4 || bytes4(data) != IRecipeCapability.execute.selector) revert InvalidRecipeArtifact();
            bytes32 mintLeafHash = source.readBytes32(".mintLeafHash");
            if (
                MerkleAdapterVerifier.leaf(
                        source.readAddress(".mintLeafTarget"), 0, data, source.readBytes(".mintLeafMask")
                    ) != mintLeafHash
            ) revert InvalidRecipeArtifact();
            bool referenced;
            uint256 stepsLength = recipe.steps.length;
            for (uint256 i; i < stepsLength && !referenced; ++i) {
                if (uint8(recipe.steps[i][0]) != OP_MANAGE) continue;
                (, bytes32[] memory leaves,) =
                    abi.decode(Bytes.slice(recipe.steps[i], 1), (uint256, bytes32[], uint256[][]));
                uint256 leavesLength = leaves.length;
                for (uint256 j; j < leavesLength; ++j) {
                    if (leaves[j] == mintLeafHash) {
                        referenced = true;
                        break;
                    }
                }
            }
            if (!referenced) revert InvalidRecipeArtifact();
            ExecutingRecipe.Recipe memory nested;
            (nested.queries, nested.steps,) = abi.decode(Bytes.slice(data, 4), (bytes[], bytes[], uint256[]));
            guardedMintManifest = RecipeManifest.render(nested);
        } else if (source.keyExists(".guardedMintManifest")) {
            revert InvalidRecipeArtifact();
        }
        vm.serializeJson(outputPath, source);
        vm.serializeBytes(outputPath, "recipe", encoded);
        vm.serializeBytes32(outputPath, "recipeHash", recipeHash);
        vm.serializeUint(outputPath, "runtimeSteps", ExecutingRecipe.runtimeSteps(recipe));
        vm.serializeUint(outputPath, "stepCount", recipe.steps.length);
        vm.writeJson(vm.serializeString(outputPath, "manifestContext", "inspection"), outputPath);
        vm.writeJson(manifest, outputPath, ".manifest");
        if (bytes(guardedMintManifest).length > 0) {
            vm.writeJson(guardedMintManifest, outputPath, ".guardedMintManifest");
        }
    }

    /* INTERNAL FUNCTIONS */

    // Layout action indices refer to runtime payloads. Stages cover the full instruction sequence.
    function _instructionStages(ExecutingRecipe.Recipe memory recipe) internal returns (string memory stages) {
        uint256[] memory calls = ExecutingRecipe.runtimeSteps(recipe);
        uint256 callsLength = calls.length;
        uint256 stepsLength = recipe.steps.length;
        stages = "[";
        uint256 start;
        for (uint256 i; _stages.keyExists(string.concat("[", vm.toString(i), "]")); ++i) {
            string memory path = string.concat("[", vm.toString(i), "]");
            uint256 next = _stages.readUint(string.concat(path, ".endStep"));
            uint256 end = next < callsLength ? calls[next] : stepsLength;
            if (next > 0 && next < callsLength) {
                // Preparation and policy-consumption calls belong to the following managed action.
                for (uint256 j = calls[next - 1] + 1; j < end; ++j) {
                    if (uint8(recipe.steps[j][0]) == OP_CALL) {
                        end = j;
                        break;
                    }
                }
            }
            if (i > 0) stages = string.concat(stages, ",");
            stages = string.concat(stages, _stage(_stages.readString(string.concat(path, ".name")), start, end));
            start = end;
        }
        return string.concat(stages, "]");
    }

    function _amountOffsets(string memory source, string memory path)
        internal
        view
        returns (uint256[][] memory offsets)
    {
        string memory key = string.concat(path, ".amountOffsets");
        uint256 length = _length(source, key);
        offsets = new uint256[][](length);
        for (uint256 i; i < length; ++i) {
            offsets[i] = source.readUintArray(string.concat(key, "[", vm.toString(i), "]"));
        }
    }

    function _stage(string memory name, uint256 start, uint256 end) internal returns (string memory) {
        vm.serializeJson("recipe.stage", "{}");
        vm.serializeString("recipe.stage", "name", name);
        vm.serializeUint("recipe.stage", "startStep", start);
        return vm.serializeUint("recipe.stage", "endStep", end);
    }

    function _executionStages(
        string memory source,
        uint256[] memory calls,
        uint256 approve,
        uint256 operation,
        uint256 clear,
        bool ll
    ) internal returns (string memory stages) {
        stages = "[";
        bool push = source.keyExists(".leaves.push") && source.readBytes32(".leaves.push") != bytes32(0);
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            string memory name = "Fund strategy";
            if (!push || i > 0) {
                string memory path = string.concat(".sources[", vm.toString(push ? i - 1 : i), "].name");
                name = source.keyExists(path) ? source.readString(path) : "Obtain liquidity";
            }
            stages = string.concat(stages, _stage(name, calls[i], calls[i] + 1), ",");
        }
        return string.concat(
            stages,
            _stage(ll ? "Approve connector" : "Approve request", approve, approve + 1),
            ",",
            _stage(ll ? "Execute LL swap" : "Mint 3F position", operation, operation + 1),
            ",",
            _stage("Clear approval", clear, clear + 1)
        );
    }

    function _llStages(string memory source, LLExecuting.Layout memory layout) internal returns (string memory stages) {
        stages =
            _executionStages(source, layout.sourceCalls, layout.approve, layout.operation, layout.clearApproval, true);
        if (layout.redeem > 0) {
            if (layout.redeemApprove > 0) {
                stages = string.concat(
                    stages, ",", _stage("Approve redemption", layout.redeemApprove, layout.redeemApprove + 1)
                );
            }
            stages = string.concat(stages, ",", _stage("Redeem RWA", layout.redeem, layout.redeem + 1));
            if (layout.redeemClearApproval > 0) {
                stages = string.concat(
                    stages,
                    ",",
                    _stage("Clear redemption approval", layout.redeemClearApproval, layout.redeemClearApproval + 1)
                );
            }
        }
        return string.concat(stages, "]");
    }

    function _recoveryStages(bool recovery, RecoveryRecipe.Layout memory layout)
        internal
        returns (string memory stages)
    {
        stages = "[";
        uint256[] memory calls = recovery ? layout.sourceCalls : layout.claimCalls;
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            stages = string.concat(
                stages, _stage(recovery ? "Obtain liquidity" : "Claim redemption", calls[i], calls[i] + 1), ","
            );
        }
        stages = string.concat(
            stages,
            _stage("Approve repayment", layout.approve, layout.approve + 1),
            ",",
            _stage("Repay debt", layout.repay, layout.repay + 1),
            ",",
            _stage("Clear approval", layout.clearApproval, layout.clearApproval + 1)
        );
        uint256 requestCallsLength = layout.requestCalls.length;
        for (uint256 i; i < requestCallsLength; ++i) {
            stages = string.concat(
                stages, ",", _stage("Request RWA redemption", layout.requestCalls[i], layout.requestCalls[i] + 1)
            );
        }
        return string.concat(stages, "]");
    }

    function _funding(string memory source, address adapter)
        internal
        view
        returns (ExecutingRecipe.Funding memory funding)
    {
        funding.adapter = adapter;
        funding.account = IMerkleAdapter(adapter).account();
        if (source.keyExists(".leaves.push")) funding.pushLeaf = source.readBytes32(".leaves.push");
        funding.asset = source.readAddress(".addresses.asset");
        funding.skipUnusedReads = _optimization(source, "skipUnusedReads");
        uint256 length = _length(source, ".sources");
        funding.sources = new ExecutingRecipe.Source[](length);
        for (uint256 i; i < length; ++i) {
            string memory path = string.concat(".sources[", vm.toString(i), "]");
            funding.sources[i] = ExecutingRecipe.Source({
                prepare: ExecutingRecipe.Call({target: address(0), data: ""}),
                capacity: source.keyExists(string.concat(path, ".skipCapacity"))
                    && source.readBool(string.concat(path, ".skipCapacity"))
                    ? ExecutingRecipe.Read({target: address(0), data: "", offset: 0})
                    : _fundingQuery(source, string.concat(path, ".capacity")),
                leaves: source.readBytes32Array(string.concat(path, ".leaves")),
                amountOffsets: _amountOffsets(source, path)
            });
            if (source.keyExists(string.concat(path, ".prepare"))) {
                funding.sources[i].prepare = ExecutingRecipe.Call({
                    target: source.readAddress(string.concat(path, ".prepare.target")),
                    data: source.readBytes(string.concat(path, ".prepare.data"))
                });
            }
        }
    }

    function _fundingQuery(string memory source, string memory path)
        internal
        pure
        returns (ExecutingRecipe.Read memory readConfig)
    {
        readConfig = ExecutingRecipe.Read({
            target: source.readAddress(string.concat(path, ".target")),
            data: source.readBytes(string.concat(path, ".data")),
            offset: source.readUint(string.concat(path, ".offset"))
        });
        if (readConfig.target == address(0)) revert ExecutingRecipe.InvalidConfiguration();
    }

    function _recoveryConfig(string memory source, address adapter)
        internal
        view
        returns (RecoveryRecipe.Config memory config)
    {
        config.account = IMerkleAdapter(adapter).account();
        config.asset = source.readAddress(".addresses.asset");
        config.repayTarget = source.readAddress(".addresses.repayTarget");
        config.approvalLeaf = source.readBytes32(".leaves.approval");
        config.repayLeaf = source.readBytes32(".leaves.repay");
        config.repayAmountOffsets = source.readUintArray(".amountOffsets.repay");
        config.healthFactor = _query(source, ".reads.healthFactor");
        config.debt = _query(source, ".reads.debt");
        config.triggerHealthFactor = source.readUint(".limits.triggerHealthFactor");
        config.targetHealthFactor = source.readUint(".limits.targetHealthFactor");
        config.maxRepayment = source.readUint(".limits.maxRepayment");
        config.debtTolerance = source.readUint(".limits.debtTolerance");
        config.skipUnusedReads = _optimization(source, "skipUnusedReads");
        config.skipZeroApprovals = _optimization(source, "skipZeroApprovals");

        uint256 sourcesLength = _length(source, ".sources");
        config.sources = new RecoveryRecipe.Source[](sourcesLength);
        for (uint256 i; i < sourcesLength; ++i) {
            string memory path = string.concat(".sources[", vm.toString(i), "]");
            config.sources[i] = RecoveryRecipe.Source({
                capacity: _query(source, string.concat(path, ".capacity")),
                leaves: source.readBytes32Array(string.concat(path, ".leaves")),
                amountOffsets: _amountOffsets(source, path)
            });
        }
        uint256 redemptionsLength = _length(source, ".redemptions");
        config.redemptions = new RecoveryRecipe.Redemption[](redemptionsLength);
        for (uint256 i; i < redemptionsLength; ++i) {
            string memory path = string.concat(".redemptions[", vm.toString(i), "]");
            config.redemptions[i] = RecoveryRecipe.Redemption({
                token: source.readAddress(string.concat(path, ".token")),
                spender: source.readAddress(string.concat(path, ".spender")),
                capacity: _query(source, string.concat(path, ".capacity")),
                pending: _query(source, string.concat(path, ".pending")),
                maxTokenPerAssetWad: source.readUint(string.concat(path, ".maxTokenPerAssetWad")),
                leaves: source.readBytes32Array(string.concat(path, ".leaves"))
            });
        }
        uint256 claimsLength = _length(source, ".claims");
        config.claims = new RecoveryRecipe.Claim[](claimsLength);
        for (uint256 i; i < claimsLength; ++i) {
            string memory path = string.concat(".claims[", vm.toString(i), "]");
            config.claims[i] = RecoveryRecipe.Claim({
                claimable: _query(source, string.concat(path, ".claimable")),
                maxAmount: source.keyExists(string.concat(path, ".maxAmount"))
                    ? source.readUint(string.concat(path, ".maxAmount"))
                    : 0,
                pending: source.keyExists(string.concat(path, ".pending"))
                    ? _query(source, string.concat(path, ".pending"))
                    : RecoveryRecipe.Read({target: address(0), data: "", offset: 0}),
                minAssetPerClaimWad: source.readUint(string.concat(path, ".minAssetPerClaimWad")),
                leaves: source.readBytes32Array(string.concat(path, ".leaves"))
            });
        }
    }

    function _optimization(string memory source, string memory name) internal view returns (bool) {
        string memory path = string.concat(".optimizations.", name);
        return source.keyExists(path) && source.readBool(path);
    }

    function _query(string memory source, string memory path) internal pure returns (RecoveryRecipe.Read memory) {
        return RecoveryRecipe.Read({
            target: source.readAddress(string.concat(path, ".target")),
            data: source.readBytes(string.concat(path, ".data")),
            offset: source.readUint(string.concat(path, ".offset"))
        });
    }

    function _length(string memory source, string memory path) internal view returns (uint256 length) {
        while (source.keyExists(string.concat(path, "[", vm.toString(length), "]"))) {
            ++length;
        }
    }

    /// @dev Publishes policy configuration and the selected guarded or native mint leaf.
    function _serializeThreeFPolicy(
        string memory source,
        string memory outputPath,
        ThreeFExecuting.Config memory config
    ) private returns (bytes32 mintLeafHash, string memory guardedMintManifest) {
        vm.serializeAddress(outputPath, "policy", config.policy);
        if (!IThreeFRequestFactory(IThreeFPolicy(config.policy).REQUESTS_FACTORY()).isRequest(config.request)) {
            revert IThreeFPolicy.InvalidRequest();
        }
        string memory name = IThreeFRequestName(config.request).name();
        if (bytes(name).length <= REQUEST_NAME_PREFIX_LENGTH) revert IThreeFPolicy.InvalidRequestName();
        (IThreeFFacility.IntentProperties memory properties,, address boundRequest,) = IThreeFFacility(
                IThreeFPolicy(config.policy).FACILITY()
            )
            .getIntent(Strings.parseUint(name, REQUEST_NAME_PREFIX_LENGTH, bytes(name).length));
        if (boundRequest != config.request) revert IThreeFPolicy.RequestMismatch();
        if (!properties.targetAsset.isPositionManager) revert IThreeFPolicy.UnsupportedTarget();
        (address underlyingAsset,) = IThreeFPositionManager(properties.targetAsset.asset).assets();
        underlyingAsset = IThreeFUnderlyingAsset(underlyingAsset).underlying();
        if (underlyingAsset == address(0)) revert IThreeFPolicy.InvalidAsset();
        vm.serializeAddress(outputPath, "underlyingAsset", underlyingAsset);
        bytes memory data;
        bytes memory mask;
        address target;
        address consumer;
        if (config.guardedMint) {
            ThreeFGuardedMint.Leaf memory mintLeaf = ThreeFGuardedMint.build(
                ThreeFGuardedMint.Config({
                    account: config.funding.account,
                    asset: config.funding.asset,
                    policy: config.policy,
                    request: config.request
                }),
                config.reuseTupleReads
            );
            data = mintLeaf.data;
            mask = mintLeaf.dataMask;
            ExecutingRecipe.Recipe memory guardedRecipe;
            (guardedRecipe.queries, guardedRecipe.steps,) =
                abi.decode(Bytes.slice(data, 4), (bytes[], bytes[], uint256[]));
            guardedMintManifest = RecipeManifest.render(guardedRecipe);
            target = config.funding.account;
            consumer = config.funding.account;
        } else {
            data = abi.encodeCall(IThreeFPushRequest.mint, (0, 0));
            uint256 length = data.length;
            mask = new bytes(length);
            for (uint256 i = 4; i < length; ++i) {
                mask[i] = 0xff;
            }
            target = config.request;
            consumer = source.readAddress(".executor");
            if (consumer == address(0)) revert InvalidPolicyConsumer();
        }
        vm.serializeBool(outputPath, "guardedMint", config.guardedMint);
        vm.serializeAddress(outputPath, "mintLeafTarget", target);
        vm.serializeBytes(outputPath, "mintLeafData", data);
        vm.serializeBytes(outputPath, "mintLeafMask", mask);
        mintLeafHash = MerkleAdapterVerifier.leaf(target, 0, data, mask);
        vm.serializeBytes32(outputPath, "mintLeafHash", mintLeafHash);
        vm.serializeBytes(outputPath, "setConsumerCalldata", abi.encodeCall(IThreeFPolicy.setConsumer, (consumer)));
        vm.serializeBytes(
            outputPath,
            "setMaxAssetsPerDurationCalldata",
            abi.encodeCall(
                IThreeFPolicy.setMaxAssetsPerDuration,
                (
                    underlyingAsset,
                    source.readUint(".policy.maxAssets"),
                    SafeCast.toUint48(source.readUint(".policy.duration"))
                )
            )
        );
        vm.serializeBytes(
            outputPath,
            "setMinYieldPerRequestCalldata",
            abi.encodeCall(
                IThreeFPolicy.setMinYieldPerRequest, (underlyingAsset, source.readUint(".policy.minYieldPerRequest"))
            )
        );
    }
}
