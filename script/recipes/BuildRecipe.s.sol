// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";
import {IThreeFPolicy} from "src/interfaces/periphery/IThreeFPolicy.sol";

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {LLExecuting} from "script/recipes/LLExecuting.sol";
import {LendingRecipe} from "script/recipes/LendingRecipe.sol";
import {LiquidityRecipe} from "script/recipes/LiquidityRecipe.sol";
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
            templateId != keccak256("lending") && templateId != keccak256("liquid-lane")
                && templateId != keccak256("health-recovery") && templateId != keccak256("health-claim")
                && templateId != keccak256("ll-executing") && templateId != keccak256("3f-executing")
        ) revert UnknownTemplate();
        address curator = source.readAddress(".curator");
        address provider = source.readAddress(".provider");
        address adapter = source.readAddress(".adapter");
        IRecipeExecutor.Step[] memory recipe;
        RecoveryRecipe.Layout memory layout;
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
            LendingRecipe.Limits memory limits;
            limits.maxSupplyLbtc = source.readUint(".limits.maxSupplyLbtc");
            limits.maxTotalDebtUsdc = source.readUint(".limits.maxTotalDebtUsdc");
            limits.minRwaPerUsdcWad = source.readUint(".limits.minRwaPerUsdcWad");
            recipe = LendingRecipe.build(config, limits);
        } else if (templateId == keccak256("liquid-lane")) {
            LiquidityRecipe.Configuration memory config;
            config.adapter = adapter;
            config.executor = source.readAddress(".addresses.executor");
            config.connector = source.readAddress(".addresses.connector");
            config.rwa = source.readAddress(".addresses.rwa");
            config.receiptToken = source.readAddress(".addresses.receiptToken");
            config.maxAmountIn = source.readUint(".limits.maxAmountIn");
            config.maxFundingAmount = source.readUint(".limits.maxFundingAmount");
            config.minReceiptNumerator = source.readUint(".limits.minReceiptNumerator");
            config.receiptDenominator = source.readUint(".limits.receiptDenominator");
            config.maxReceiptBalance = source.readUint(".limits.maxReceiptBalance");
            recipe = LiquidityRecipe.liquidLane(config);
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
            vm.serializeUint(outputPath, "sourceCalls", execution.sourceCalls);
            vm.serializeUint(outputPath, "sourceAmounts", execution.sourceAmounts);
            vm.serializeUint(outputPath, "principalStep", execution.principal);
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
            vm.serializeUint(outputPath, "sourceCalls", execution.sourceCalls);
            vm.serializeUint(outputPath, "sourceAmounts", execution.sourceAmounts);
            vm.serializeUint(outputPath, "amountInStep", execution.amountIn);
            vm.serializeUint(outputPath, "amountOutStep", execution.amountOut);
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
    }

    /* INTERNAL FUNCTIONS */

    function _funding(string memory source, address adapter)
        internal
        view
        returns (ExecutingRecipe.Funding memory funding)
    {
        funding.adapter = adapter;
        funding.vault = source.readAddress(".addresses.vault");
        funding.asset = source.readAddress(".addresses.asset");
        funding.sources = new ExecutingRecipe.Source[](_length(source, ".sources"));
        for (uint256 i; i < funding.sources.length; ++i) {
            string memory path = string.concat(".sources[", vm.toString(i), "]");
            funding.sources[i] = ExecutingRecipe.Source(
                _fundingQuery(source, string.concat(path, ".capacity")),
                source.readBytes32Array(string.concat(path, ".leaves"))
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
                source.readBytes32Array(string.concat(path, ".leaves"))
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
