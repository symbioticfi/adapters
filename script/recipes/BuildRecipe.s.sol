// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/IThreeFPolicy.sol";

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {LLExecuting} from "script/recipes/LLExecuting.sol";
import {LendingRecipe} from "script/recipes/LendingRecipe.sol";
import {RecoveryRecipe} from "script/recipes/RecoveryRecipe.sol";
import {ThreeFExecuting} from "script/recipes/ThreeFExecuting.sol";

/**
 * @title BuildRecipe
 * @notice Script for encoding a named recipe and curator transactions from a JSON configuration.
 * @dev Offline only: no RPC reads, signing or broadcasting. Addresses, permissions and economic limits
 * must be verified separately. A supplied factory must contain RecipeExecutor creation bytecode.
 */
contract BuildRecipe is Script {
    using stdJson for string;

    string internal _stages;

    /* ERRORS */

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
                && templateId != keccak256("health-claim") && templateId != keccak256("ll-executing")
                && templateId != keccak256("3f-executing")
        ) revert UnknownTemplate();
        address curator = source.readAddress(".curator");
        address provider = source.readAddress(".provider");
        address adapter = source.readAddress(".adapter");
        IRecipeExecutor.Step[] memory recipe;
        RecoveryRecipe.Layout memory layout;
        _stages = "";
        vm.serializeJson(outputPath, "{}");

        if (templateId == keccak256("lending")) {
            LendingRecipe.Config memory config;
            config.adapter = adapter;
            config.lbtc = source.readAddress(".addresses.lbtc");
            config.usdc = source.readAddress(".addresses.usdc");
            config.rwa = source.readAddress(".addresses.rwa");
            config.collateralReceipt = source.readAddress(".addresses.collateralReceipt");
            config.variableDebt = source.readAddress(".addresses.variableDebt");
            config.pool = source.readAddress(".addresses.pool");
            config.issuer = source.readAddress(".addresses.issuer");
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
            config.funding = _funding(source, adapter);
            config.request = source.readAddress(".addresses.request");
            config.approvalLeaf = source.readBytes32(".leaves.approval");
            config.mintLeaf = source.readBytes32(".leaves.mint");
            config.maxPrincipal = source.readUint(".limits.maxPrincipal");
            config.requestsFactory = source.readAddress(".addresses.requestsFactory");
            config.policy = source.readAddress(".addresses.policy");
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
            vm.serializeUint(outputPath, "principalResult", execution.principal.value);
            vm.serializeUint(outputPath, "consumeStep", execution.consume);
            vm.serializeUint(outputPath, "approveStep", execution.approve);
            vm.serializeUint(outputPath, "operationStep", execution.operation);
            vm.serializeUint(outputPath, "clearApprovalStep", execution.clearApproval);
            vm.serializeAddress(outputPath, "policy", config.policy);
            vm.serializeBytes(
                outputPath,
                "setMaxAssetsPerDurationCalldata",
                abi.encodeCall(
                    IThreeFPolicy.setMaxAssetsPerDuration,
                    (source.readUint(".policy.maxAssets"), source.readUint(".policy.duration"))
                )
            );
            vm.serializeBytes(
                outputPath,
                "setMinYieldPerRequestCalldata",
                abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (source.readUint(".policy.minYieldPerRequest")))
            );
        } else if (templateId == keccak256("ll-executing")) {
            LLExecuting.Config memory config;
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
                    config.redemption.spender = source.readAddress(".redemption.spender");
                    config.redemption.approvalLeaf = source.readBytes32(".redemption.approvalLeaf");
                    config.redemption.receipt = _fundingQuery(source, ".redemption.receipt");
                    config.redemption.minReceiptNumerator = source.readUint(".redemption.minReceiptNumerator");
                    config.redemption.receiptDenominator = source.readUint(".redemption.receiptDenominator");
                    config.redemption.maxReceiptBalance = source.readUint(".redemption.maxReceiptBalance");
                }
            }
            LLExecuting.Layout memory execution;
            (recipe, execution) = LLExecuting.build(config);
            _stages = _llStages(source, execution, recipe.length);
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
        } else {
            RecoveryRecipe.Config memory config = _recoveryConfig(source, adapter);
            if (templateId == keccak256("health-recovery")) (recipe, layout) = RecoveryRecipe.recovery(config);
            else (recipe, layout) = RecoveryRecipe.claim(config);
            _stages = _recoveryStages(templateId == keccak256("health-recovery"), layout, recipe.length);
        }

        bytes memory constructorArgs = abi.encode(curator, adapter);
        vm.serializeString(outputPath, "template", template);
        vm.serializeAddress(outputPath, "curator", curator);
        vm.serializeAddress(outputPath, "provider", provider);
        vm.serializeAddress(outputPath, "adapter", adapter);
        vm.serializeBytes(outputPath, "recipe", abi.encode(recipe));
        vm.serializeBytes(outputPath, "setRecipeCalldata", abi.encodeCall(IRecipeExecutor.setRecipe, (recipe)));
        vm.serializeBytes(outputPath, "setCallerCalldata", abi.encodeCall(IRecipeExecutor.setCaller, (provider)));
        if (templateId == keccak256("health-recovery") || templateId == keccak256("health-claim")) {
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
        vm.writeJson(_stages, outputPath, ".stages");
    }

    /* INTERNAL FUNCTIONS */

    function _amountOffsets(string memory source, string memory path)
        internal
        view
        returns (uint256[][] memory offsets)
    {
        string memory key = string.concat(path, ".amountOffsets");
        offsets = new uint256[][](_length(source, key));
        for (uint256 i; i < offsets.length; ++i) {
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
        uint256 start = calls.length > 0 ? calls[0] : approve;
        if (start > 0) stages = string.concat(stages, _stage("Check request and charge budget", 0, start), ",");
        for (uint256 i; i < calls.length; ++i) {
            string memory path = string.concat(".sources[", vm.toString(i), "].name");
            string memory name = source.keyExists(path) ? source.readString(path) : "Obtain liquidity";
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

    function _llStages(string memory source, LLExecuting.Layout memory layout, uint256)
        internal
        returns (string memory stages)
    {
        stages = _executionStages(
            source, layout.sourceCalls, layout.approve, layout.operation, layout.clearApproval, true
        );
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

    function _recoveryStages(bool recovery, RecoveryRecipe.Layout memory layout, uint256)
        internal
        returns (string memory stages)
    {
        stages = "[";
        uint256[] memory calls = recovery ? layout.sourceCalls : layout.claimCalls;
        for (uint256 i; i < calls.length; ++i) {
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
        for (uint256 i; i < layout.requestCalls.length; ++i) {
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
        funding.asset = source.readAddress(".addresses.asset");
        funding.sources = new ExecutingRecipe.Source[](_length(source, ".sources"));
        for (uint256 i; i < funding.sources.length; ++i) {
            string memory path = string.concat(".sources[", vm.toString(i), "]");
            funding.sources[i] = ExecutingRecipe.Source(
                _fundingQuery(source, string.concat(path, ".capacity")),
                source.readBytes32Array(string.concat(path, ".leaves")),
                _amountOffsets(source, path)
            );
        }
    }

    function _fundingQuery(string memory source, string memory path)
        internal
        pure
        returns (ExecutingRecipe.Read memory)
    {
        return ExecutingRecipe.Read(
            source.readAddress(string.concat(path, ".target")),
            source.readBytes(string.concat(path, ".data")),
            source.readUint(string.concat(path, ".offset"))
        );
    }

    function _recoveryConfig(string memory source, address adapter)
        internal
        view
        returns (RecoveryRecipe.Config memory config)
    {
        config.adapter = adapter;
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

        config.sources = new RecoveryRecipe.Source[](_length(source, ".sources"));
        for (uint256 i; i < config.sources.length; ++i) {
            string memory path = string.concat(".sources[", vm.toString(i), "]");
            config.sources[i] = RecoveryRecipe.Source(
                _query(source, string.concat(path, ".capacity")),
                source.readBytes32Array(string.concat(path, ".leaves")),
                _amountOffsets(source, path)
            );
        }
        config.redemptions = new RecoveryRecipe.Redemption[](_length(source, ".redemptions"));
        for (uint256 i; i < config.redemptions.length; ++i) {
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
        config.claims = new RecoveryRecipe.Claim[](_length(source, ".claims"));
        for (uint256 i; i < config.claims.length; ++i) {
            string memory path = string.concat(".claims[", vm.toString(i), "]");
            config.claims[i] = RecoveryRecipe.Claim({
                claimable: _query(source, string.concat(path, ".claimable")),
                pending: _query(source, string.concat(path, ".pending")),
                minAssetPerClaimWad: source.readUint(string.concat(path, ".minAssetPerClaimWad")),
                leaves: source.readBytes32Array(string.concat(path, ".leaves"))
            });
        }
    }

    function _query(string memory source, string memory path) internal pure returns (RecoveryRecipe.Read memory) {
        return RecoveryRecipe.Read(
            source.readAddress(string.concat(path, ".target")),
            source.readBytes(string.concat(path, ".data")),
            source.readUint(string.concat(path, ".offset"))
        );
    }

    function _length(string memory source, string memory path) internal view returns (uint256 length) {
        while (source.keyExists(string.concat(path, "[", vm.toString(length), "]"))) {
            ++length;
        }
    }
}
