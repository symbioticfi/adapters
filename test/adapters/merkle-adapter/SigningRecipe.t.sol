// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";
import {GPv2Order} from "src/libraries/GPv2Order.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {
    ILiquidLaneReactor,
    LIQUID_LANE_OUTPUT_TYPEHASH,
    LIQUID_LANE_REQUEST_TYPEHASH
} from "src/interfaces/merkle-adapter/ILiquidLaneReactor.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {SigningRecipe} from "script/recipes/SigningRecipe.sol";
import {Token} from "test/mocks/Token.sol";
import {flatPlan} from "test/helpers/HashPlan.sol";

contract SigningRecipeTest is CapabilityTestBase {
    using stdJson for string;
    address internal _executor;
    address internal _reads;
    bytes32 internal _domain = keccak256("settlement domain");
    SigningRecipe.Config internal _config;
    ExecutingRecipe.Recipe internal _recipe;
    IMerkleAccount.Action internal _authorization;

    function setUp() public {
        _deployAdapter(address(new Token("asset")));
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        _reads = address(new SigningReads());
        bytes memory buffer = abi.encode(GPv2Order.TYPE_HASH, _order(0, 0, 0));
        _config = SigningRecipe.Config({
            account: account,
            signData: abi.encodeCall(IMerkleAccount.sign, (_domain, buffer, flatPlan(buffer))),
            price: ExecutingRecipe.Read({target: _reads, data: abi.encodeCall(SigningReads.price, ()), offset: 0}),
            clock: ExecutingRecipe.Read({target: _reads, data: abi.encodeCall(SigningReads.timestamp, ()), offset: 0}),
            minAmount: 1e18,
            maxAmount: 100e18,
            priceDenominator: 1e30,
            slippageBps: 100,
            maxDuration: 300,
            amountOffset: 260,
            outputOffset: 292,
            deadlineOffset: 324,
            deadlineBytes: 4,
            nonceOffset: 0
        });
        (_recipe, _authorization) = SigningRecipe.build(_config);
        bytes32 leaf = MerkleAdapterVerifier.leaf(account, 0, _authorization.data, _authorization.dataMask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, _executor);
        RecipeExecutor(_executor).setRecipe(_recipe.queries, _recipe.steps);
    }

    function test_BuildScriptProducesTheSameSigningProgramAndAuthorization() public {
        string memory key = "SigningRecipe.build";
        vm.serializeString(key, "template", "signing");
        vm.serializeAddress(key, "curator", address(this));
        vm.serializeAddress(key, "provider", address(this));
        vm.serializeAddress(key, "adapter", address(adapter));
        vm.serializeBytes(key, "signData", _config.signData);
        vm.serializeAddress("price", "target", _reads);
        vm.serializeBytes("price", "data", _config.price.data);
        string memory priceJson = vm.serializeUint("price", "offset", 0);
        vm.serializeAddress("clock", "target", _reads);
        vm.serializeBytes("clock", "data", _config.clock.data);
        string memory clockJson = vm.serializeUint("clock", "offset", 0);
        string memory input = "out/SigningRecipe.input.json";
        string memory output = "out/SigningRecipe.output.json";
        vm.writeJson(vm.serializeUint(key, "deadlineBytes", 4), input);
        vm.writeJson(priceJson, input, ".price");
        vm.writeJson(clockJson, input, ".clock");
        vm.writeJson(
            '{"minAmount":"1000000000000000000","maxAmount":"100000000000000000000","priceDenominator":"1000000000000000000000000000000","slippageBps":100,"maxDuration":300}',
            input,
            ".limits"
        );
        vm.writeJson('{"input":260,"output":292,"deadline":324}', input, ".amountOffsets");
        BuildRecipe(deployCode("BuildRecipe.s.sol:BuildRecipe")).run(input, output);
        string memory built = vm.readFile(output);
        assertEq(built.readBytes32(".recipeHash"), keccak256(abi.encode(_recipe.queries, _recipe.steps)));
        assertEq(built.readBytes(".signData"), _authorization.data);
        assertEq(built.readBytes(".signMask"), _authorization.dataMask);
        vm.removeFile(input);
        vm.removeFile(output);
    }

    function test_LiquidLaneNonceAndEconomicsAreBoundAndHashPlanIsFixed() public {
        SigningRecipe.Config memory config = _config;
        ILiquidLaneReactor.Output memory output =
            ILiquidLaneReactor.Output({token: address(0x5678), amount: 0, recipient: account});
        bytes memory buffer = abi.encode(
            LIQUID_LANE_REQUEST_TYPEHASH,
            address(0x1234),
            uint256(0),
            bytes32(0),
            uint256(0),
            uint256(0),
            address(0x7890),
            LIQUID_LANE_OUTPUT_TYPEHASH,
            output
        );
        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](3);
        plan[0] = IMerkleAccount.Hash({offset: 224, length: 128, destination: 224});
        plan[1] = IMerkleAccount.Hash({offset: 224, length: 32, destination: 96});
        plan[2] = IMerkleAccount.Hash({offset: 0, length: 224, destination: 0});
        config.signData = abi.encodeCall(IMerkleAccount.sign, (_domain, buffer, plan));
        config.amountOffset = 196;
        config.outputOffset = 420;
        config.deadlineOffset = 260;
        config.deadlineBytes = 32;
        config.nonceOffset = 292;
        (ExecutingRecipe.Recipe memory recipe, IMerkleAccount.Action memory authorization) = SigningRecipe.build(config);
        bytes32 leaf = MerkleAdapterVerifier.leaf(account, 0, authorization.data, authorization.dataMask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, _executor);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        uint256[] memory inputs = new uint256[](4);
        inputs[0] = 100e18;
        inputs[1] = 198e6;
        inputs[2] = block.timestamp + 300;
        inputs[3] = 7;
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = authorization;
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, inputs, runtime);
        output.amount = inputs[1];
        bytes32 outputsHash = keccak256(abi.encodePacked(keccak256(abi.encode(LIQUID_LANE_OUTPUT_TYPEHASH, output))));
        bytes32 structHash = keccak256(
            abi.encode(
                LIQUID_LANE_REQUEST_TYPEHASH,
                address(0x1234),
                inputs[0],
                outputsHash,
                inputs[2],
                inputs[3],
                address(0x7890)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domain, structHash));
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function test_ForgedRuntimeAmountsAreReplacedByCheckedInputs() public {
        bytes memory buffer = abi.encode(GPv2Order.TYPE_HASH, _order(type(uint128).max, 1, 0));
        _authorization.data = abi.encodeCall(IMerkleAccount.sign, (_domain, buffer, flatPlan(buffer)));
        _execute(100e18, 198e6, block.timestamp + 300);
        bytes32 digest = GPv2Order.hash(_order(100e18, 198e6, uint32(block.timestamp + 300)), _domain);
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
    }

    function testFuzz_AmountAndOracleFloor(uint256 amount) public {
        amount = bound(amount, 1e18, 100e18);
        uint256 quote = amount * 2e18 / 1e30;
        uint256 floor = quote - quote * 100 / 10_000;
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(amount, floor - 1, block.timestamp + 1);
        _execute(amount, floor, block.timestamp + 1);
        bytes32 digest = GPv2Order.hash(_order(amount, floor, uint32(block.timestamp + 1)), _domain);
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function test_AmountAndDeadlineBounds() public {
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1e18 - 1, 198e6, block.timestamp + 300);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(100e18 + 1, 198e6, block.timestamp + 300);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(100e18, 198e6, block.timestamp - 1);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(100e18, 198e6, block.timestamp + 301);
        _execute(100e18, 198e6, block.timestamp);
    }

    function test_CoWDeadlineCannotOverflowItsUint32Word() public {
        vm.warp(uint256(type(uint32).max) - 100);
        SigningReads(_reads).setPrice(2e18);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(100e18, 198e6, uint256(type(uint32).max) + 1);
        _execute(100e18, 198e6, type(uint32).max);
    }

    function test_RoundingCannotAuthorizeAZeroOutputFloor() public {
        SigningRecipe.Config memory config = _config;
        config.minAmount = 1;
        (_recipe,) = SigningRecipe.build(config);
        RecipeExecutor(_executor).setRecipe(_recipe.queries, _recipe.steps);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(1, 1, block.timestamp + 1);
    }

    function test_PriceIsReadAtExecutionAndStaleOrZeroPricesFail() public {
        SigningReads(_reads).setPrice(3e18);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(100e18, 198e6, block.timestamp + 1);
        _execute(100e18, 297e6, block.timestamp + 1);
        SigningReads(_reads).setPrice(0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(100e18, 297e6, block.timestamp + 1);
        SigningReads(_reads).setPrice(3e18);
        vm.warp(block.timestamp + 61);
        vm.expectRevert(SigningReads.StalePrice.selector);
        _execute(100e18, 297e6, block.timestamp + 1);
    }

    function test_ProviderCannotSignDirectlyOrChangeCommittedSlippage() public {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _authorization;
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
        SigningRecipe.Config memory changed = _config;
        changed.slippageBps = 9900;
        (ExecutingRecipe.Recipe memory other,) = SigningRecipe.build(changed);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
        uint256[] memory inputs = new uint256[](3);
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        RecipeExecutor(_executor).execute(other.queries, other.steps, inputs, runtime);
    }

    function test_InvalidConfigurationRejectsOverlappingOrHeaderBindings() public {
        SigningRecipe.Config memory config = _config;
        config.outputOffset = config.amountOffset;
        vm.expectRevert(SigningRecipe.InvalidConfiguration.selector);
        this.build(config);
        config = _config;
        config.amountOffset = 4;
        vm.expectRevert(SigningRecipe.InvalidConfiguration.selector);
        this.build(config);
        config = _config;
        config.slippageBps = 10_000;
        vm.expectRevert(SigningRecipe.InvalidConfiguration.selector);
        this.build(config);
    }

    function build(SigningRecipe.Config memory config) public pure {
        SigningRecipe.build(config);
    }

    function _execute(uint256 amount, uint256 output, uint256 deadline) internal {
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = amount;
        inputs[1] = output;
        inputs[2] = deadline;
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _authorization;
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
        RecipeExecutor(_executor).execute(_recipe.queries, _recipe.steps, inputs, runtime);
    }

    function _order(uint256 amount, uint256 output, uint32 deadline) internal view returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: IERC20(address(0x1234)),
            buyToken: IERC20(address(0x5678)),
            receiver: account,
            sellAmount: amount,
            buyAmount: output,
            validTo: deadline,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
}

contract SigningReads {
    error StalePrice();
    uint256 internal _price = 2e18;
    uint256 internal _updatedAt = block.timestamp;

    function setPrice(uint256 newPrice) public {
        _price = newPrice;
        _updatedAt = block.timestamp;
    }

    function price() public view returns (uint256) {
        if (block.timestamp > _updatedAt + 60) revert StalePrice();
        return _price;
    }

    function timestamp() public view returns (uint256) {
        return block.timestamp;
    }
}
