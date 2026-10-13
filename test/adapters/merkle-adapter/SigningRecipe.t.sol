// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";
import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {
    ILiquidLaneReactor,
    LIQUID_LANE_OUTPUT_TYPEHASH,
    LIQUID_LANE_REQUEST_TYPEHASH
} from "src/interfaces/merkle-adapter/ILiquidLaneReactor.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {
    IRecipes,
    OP_LESS_OR_EQUAL,
    OP_MANAGE,
    OP_MUL_DIV,
    OP_SUB,
    SRC_INPUT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {SigningRecipe} from "script/recipes/SigningRecipe.sol";

import {Token} from "test/mocks/Token.sol";
import {flatPlan} from "test/helpers/HashPlan.sol";

contract SigningRecipeTest is CapabilityTestBase {
    using ExecutingRecipe for ExecutingRecipe.Builder;
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

    /// forge-config: default.isolate = true
    function test_GasO10CoW() public {
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _prepareO10(_config);
        uint256[] memory inputs = _inputsO10(false);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, inputs, runtime);
        vm.snapshotGasLastCall("SigningRecipe", "O10CoW");
        _assertDigestO10(_digestO10(false, inputs));
    }

    /// forge-config: default.isolate = true
    function test_GasO10LiquidLane() public {
        (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) = _prepareO10(_liquidLaneConfigO10());
        uint256[] memory inputs = _inputsO10(true);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, inputs, runtime);
        vm.snapshotGasLastCall("SigningRecipe", "O10LiquidLane");
        _assertDigestO10(_digestO10(true, inputs));
    }

    function test_O10PriceGuardReducesInstructions() public {
        for (uint256 lane; lane < 2; ++lane) {
            SigningRecipe.Config memory config = lane == 0 ? _config : _liquidLaneConfigO10();
            (ExecutingRecipe.Recipe memory recipe, IMerkleAccount.Action memory authorization) =
                SigningRecipe.build(config);
            _assertAuthorizationO10(config, recipe, authorization);
            ExecutingRecipe.Recipe memory frozen = _referenceO10(config, recipe);
            assertEq(frozen.steps.length, lane == 0 ? 15 : 14, "frozen baseline instruction count");
            assertEq(recipe.steps.length, lane == 0 ? 14 : 13, "omit exactly the implied price guard");
            assertEq(
                abi.encode(frozen.queries, frozen.steps).length - abi.encode(recipe.queries, recipe.steps).length, 160
            );
            assertEq(abi.encode(recipe.queries), abi.encode(frozen.queries));
            assertEq(ExecutingRecipe.runtimeSteps(recipe).length, 1);
            assertEq(ExecutingRecipe.runtimeSteps(recipe)[0], lane == 0 ? 13 : 12);
            assertEq(recipe.steps[recipe.steps.length - 1], frozen.steps[frozen.steps.length - 1]);
            uint256 products;
            uint256 floors;
            uint256 minimumProducer;
            for (uint256 i; i < recipe.steps.length; ++i) {
                if (uint8(recipe.steps[i][0]) == OP_SUB) {
                    minimumProducer = ExecutingRecipe.result(i);
                    break;
                }
            }
            bytes memory priceGuard =
                abi.encodePacked(OP_LESS_OR_EQUAL, abi.encode(uint256(1), ExecutingRecipe.result(2)));
            for (uint256 i; i < recipe.steps.length; ++i) {
                assertTrue(keccak256(recipe.steps[i]) != keccak256(priceGuard), "explicit price guard absent");
                if (uint8(recipe.steps[i][0]) == OP_MUL_DIV) ++products;
                if (uint8(recipe.steps[i][0]) == OP_LESS_OR_EQUAL) {
                    (uint256 a, uint256 b) = abi.decode(Bytes.slice(recipe.steps[i], 1), (uint256, uint256));
                    if (a == 1 && b == minimumProducer) ++floors;
                }
            }
            assertEq(products, 2, "both checked products retained");
            assertEq(floors, 1, "positive minimum remains");
        }
    }

    function test_O10SemanticLiveZeroAndStalePrices() public {
        for (uint256 lane; lane < 2; ++lane) {
            SigningRecipe.Config memory config = lane == 0 ? _config : _liquidLaneConfigO10();
            uint256[] memory inputs = _inputsO10(lane > 0);
            SigningReads(_reads).setPrice(3e18);
            _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            inputs[1] = 297e6;
            _compareO10(config, inputs, "");
            SigningReads(_reads).setPrice(0);
            _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            SigningReads(_reads).setPrice(2e18);
            vm.warp(block.timestamp + 61);
            _compareO10(config, inputs, abi.encodeWithSelector(SigningReads.StalePrice.selector));
        }
    }

    function test_O10SemanticAmountAndFloorBoundaries() public {
        for (uint256 lane; lane < 2; ++lane) {
            SigningRecipe.Config memory config = lane == 0 ? _config : _liquidLaneConfigO10();
            uint256[] memory inputs = _inputsO10(lane > 0);
            inputs[0] = 1e18 - 1;
            _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            inputs[0] = 100e18 + 1;
            _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            inputs[0] = 1e18;
            inputs[1] = 1_979_999;
            _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            inputs[1] = 1_980_000;
            _compareO10(config, inputs, "");
            inputs[0] = 100e18;
            inputs[1] = 197_999_999;
            _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            inputs[1] = 198_000_000;
            _compareO10(config, inputs, "");
        }
    }

    function test_O10SemanticSlippageAndOneUnitRounding() public {
        uint256[4] memory slippages = [uint256(0), 1, 100, 9999];
        uint256[4] memory floors = [uint256(200e6), 199_980_000, 198e6, 20_000];
        for (uint256 lane; lane < 2; ++lane) {
            for (uint256 i; i < slippages.length; ++i) {
                SigningRecipe.Config memory config = lane == 0 ? _config : _liquidLaneConfigO10();
                config.slippageBps = slippages[i];
                uint256[] memory inputs = _inputsO10(lane > 0);
                inputs[1] = floors[i] - 1;
                _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
                inputs[1] = floors[i];
                _compareO10(config, inputs, "");
                config.minAmount = 1;
                config.priceDenominator = 1;
                inputs[0] = 1;
                inputs[1] = 1;
                SigningReads(_reads).setPrice(1);
                _compareO10(config, inputs, "");
                config.priceDenominator = 2;
                _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
                SigningReads(_reads).setPrice(2e18);
            }
        }
    }

    function test_O10SemanticDeadlineAndUint32Boundaries() public {
        for (uint256 lane; lane < 2; ++lane) {
            SigningRecipe.Config memory config = lane == 0 ? _config : _liquidLaneConfigO10();
            vm.warp(1000);
            SigningReads(_reads).setPrice(2e18);
            uint256[] memory inputs = _inputsO10(lane > 0);
            inputs[2] = 999;
            _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            inputs[2] = 1000;
            _compareO10(config, inputs, "");
            inputs[2] = 1300;
            _compareO10(config, inputs, "");
            inputs[2] = 1301;
            _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            vm.warp(uint256(type(uint32).max) - 100);
            SigningReads(_reads).setPrice(2e18);
            inputs[2] = type(uint32).max;
            _compareO10(config, inputs, "");
            inputs[2] = uint256(type(uint32).max) + 1;
            _compareO10(config, inputs, lane == 0 ? abi.encodeWithSelector(IRecipes.CheckFailed.selector) : bytes(""));
        }
    }

    function test_O10SemanticBothCheckedMultiplicationsOverflow() public {
        for (uint256 lane; lane < 2; ++lane) {
            SigningRecipe.Config memory config = lane == 0 ? _config : _liquidLaneConfigO10();
            uint256[] memory inputs = _inputsO10(lane > 0);
            SigningReads(_reads).setPrice(type(uint256).max);
            _compareO10(config, inputs, abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
            config.priceDenominator = 1;
            inputs[0] = 1e18;
            SigningReads(_reads).setPrice(type(uint256).max / 1e18);
            _compareO10(config, inputs, abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        }
    }

    function test_O10SemanticMissingInputsPreservePanicAndZeroPriceOrder() public {
        for (uint256 lane; lane < 2; ++lane) {
            SigningRecipe.Config memory config = lane == 0 ? _config : _liquidLaneConfigO10();
            uint256[] memory full = _inputsO10(lane > 0);
            SigningReads(_reads).setPrice(2e18);
            for (uint256 size; size < full.length; ++size) {
                uint256[] memory inputs = new uint256[](size);
                for (uint256 i; i < size; ++i) {
                    inputs[i] = full[i];
                }
                _compareO10(config, inputs, abi.encodeWithSignature("Panic(uint256)", uint256(0x32)));
            }
            SigningReads(_reads).setPrice(0);
            uint256[] memory amountOnly = new uint256[](1);
            amountOnly[0] = 100e18;
            _compareO10(config, amountOnly, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
            config.clock.data = abi.encodeCall(SigningReads.revertingClock, ());
            (ExecutingRecipe.Recipe memory recipe, IMerkleAccount.Action memory authorization) =
                SigningRecipe.build(config);
            bytes[] memory runtime = new bytes[](1);
            runtime[0] = hex"ff";
            _compareRuntimeO10(
                config,
                recipe,
                authorization,
                amountOnly,
                runtime,
                abi.encodeWithSelector(IRecipes.CheckFailed.selector)
            );
        }
    }

    function test_O10SemanticForgedRuntimeAndFixedAuthorizationBytes() public {
        for (uint256 lane; lane < 2; ++lane) {
            SigningRecipe.Config memory config = lane == 0 ? _config : _liquidLaneConfigO10();
            (ExecutingRecipe.Recipe memory recipe, IMerkleAccount.Action memory authorization) =
                SigningRecipe.build(config);
            uint256[] memory inputs = _inputsO10(lane > 0);
            IMerkleAccount.Action memory forged = IMerkleAccount.Action({
                target: authorization.target,
                value: 0,
                data: bytes.concat(authorization.data),
                dataMask: authorization.dataMask,
                proof: authorization.proof
            });
            for (uint256 i; i < forged.data.length; ++i) {
                if (forged.dataMask[i] == 0xff) forged.data[i] = 0xff;
            }
            _compareRuntimeO10(config, recipe, authorization, inputs, _runtimeO10(forged), "");
            uint256[4] memory fixedOffsets = [uint256(4), 164, lane == 0 ? 228 : 452, authorization.data.length - 1];
            for (uint256 i; i < fixedOffsets.length; ++i) {
                forged.data = bytes.concat(authorization.data);
                forged.data[fixedOffsets[i]] = bytes1(uint8(forged.data[fixedOffsets[i]]) ^ 1);
                _compareRuntimeO10(
                    config,
                    recipe,
                    authorization,
                    inputs,
                    _runtimeO10(forged),
                    abi.encodeWithSelector(IRecipeExecutor.InvalidAction.selector)
                );
            }
        }
    }

    function test_O10SemanticProviderCannotBypassBothPrograms() public {
        for (uint256 lane; lane < 2; ++lane) {
            SigningRecipe.Config memory config = lane == 0 ? _config : _liquidLaneConfigO10();
            (ExecutingRecipe.Recipe memory recipe, IMerkleAccount.Action memory authorization) =
                SigningRecipe.build(config);
            ExecutingRecipe.Recipe memory frozen = _referenceO10(config, recipe);
            IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
            actions[0] = authorization;
            bytes32 leaf = MerkleAdapterVerifier.leaf(account, 0, authorization.data, authorization.dataMask);
            for (uint256 version; version < 2; ++version) {
                uint256 snapshot = vm.snapshotState();
                _authorizeO10(version == 0 ? frozen : recipe, authorization);
                (bool success, bytes memory result) = account.call(abi.encodeCall(IMerkleAccount.manage, (actions)));
                assertFalse(success);
                assertEq(
                    result,
                    abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", address(this), leaf)
                );
                assertTrue(vm.revertToStateAndDelete(snapshot));
            }
        }
    }

    function testFuzz_O10SemanticExactRevertsAndDigests(
        uint256 amount,
        uint256 price,
        uint256 slippage,
        bool liquidLane
    ) public {
        amount = bound(amount, 1e18, 100e18);
        price = bound(price, 0, 4e18);
        SigningRecipe.Config memory config = liquidLane ? _liquidLaneConfigO10() : _config;
        config.slippageBps = bound(slippage, 0, 9999);
        SigningReads(_reads).setPrice(price);
        uint256[] memory inputs = _inputsO10(liquidLane);
        inputs[0] = amount;
        uint256 quote = amount * price / 1e30;
        uint256 floor = quote - quote * config.slippageBps / 10_000;
        inputs[1] = floor;
        _compareO10(config, inputs, floor == 0 ? abi.encodeWithSelector(IRecipes.CheckFailed.selector) : bytes(""));
        if (floor > 0) {
            inputs[1] = floor - 1;
            _compareO10(config, inputs, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
        }
    }

    function _liquidLaneConfigO10() internal view returns (SigningRecipe.Config memory config) {
        config = _config;
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
    }

    // Freeze the original numerical program, including its explicit positive-price check.
    // The independently verified Manage payload uses only input/literal operands.
    function _referenceO10(SigningRecipe.Config memory config, ExecutingRecipe.Recipe memory recipe)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(16);
        uint256 amount = builder.input(0);
        uint256 output = builder.input(1);
        uint256 deadline = builder.input(2);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(config.minAmount), amount);
        builder.check(OP_LESS_OR_EQUAL, amount, builder.literal(config.maxAmount));
        uint256 price = builder.read(config.price);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), price);
        uint256 quote = builder.mulDiv(amount, price, builder.literal(config.priceDenominator));
        uint256 minimum = builder.binary(
            OP_SUB, quote, builder.mulDiv(quote, builder.literal(config.slippageBps), builder.literal(10_000))
        );
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), minimum);
        builder.check(OP_LESS_OR_EQUAL, minimum, output);
        uint256 timestamp = builder.read(config.clock);
        builder.check(OP_LESS_OR_EQUAL, timestamp, deadline);
        builder.check(
            OP_LESS_OR_EQUAL, builder.binary(OP_SUB, deadline, timestamp), builder.literal(config.maxDuration)
        );
        if (config.deadlineBytes == 4) builder.check(OP_LESS_OR_EQUAL, deadline, builder.literal(type(uint32).max));
        builder.instruction(OP_MANAGE, Bytes.slice(recipe.steps[recipe.steps.length - 1], 1));
        return builder.finish();
    }

    function _assertAuthorizationO10(
        SigningRecipe.Config memory config,
        ExecutingRecipe.Recipe memory recipe,
        IMerkleAccount.Action memory authorization
    ) internal view {
        assertEq(recipe.queries.length, 2);
        assertEq(
            recipe.queries[0], abi.encode(config.price.target, config.price.data, new uint256[](0), config.price.offset)
        );
        assertEq(
            recipe.queries[1], abi.encode(config.clock.target, config.clock.data, new uint256[](0), config.clock.offset)
        );
        assertEq(authorization.target, account);
        assertEq(authorization.value, 0);
        assertEq(authorization.data, config.signData);
        assertEq(authorization.proof.length, 0);
        bytes memory mask = new bytes(config.signData.length);
        for (uint256 i; i < 32; ++i) {
            mask[config.amountOffset + i] = 0xff;
            mask[config.outputOffset + i] = 0xff;
            if (i >= 32 - config.deadlineBytes) mask[config.deadlineOffset + i] = 0xff;
            if (config.nonceOffset > 0) mask[config.nonceOffset + i] = 0xff;
        }
        assertEq(authorization.dataMask, mask);
        bytes memory maskedData = bytes.concat(config.signData);
        for (uint256 i; i < mask.length; ++i) {
            maskedData[i] &= ~mask[i];
        }
        bytes32 expectedLeaf =
            keccak256(bytes.concat(keccak256(abi.encode(account, bytes1(0), keccak256(mask), keccak256(maskedData)))));
        (uint256 gate, bytes32[] memory leaves, uint256[][] memory bindings) =
            abi.decode(Bytes.slice(recipe.steps[recipe.steps.length - 1], 1), (uint256, bytes32[], uint256[][]));
        assertEq(uint8(recipe.steps[recipe.steps.length - 1][0]), OP_MANAGE);
        assertEq(gate, 1);
        assertEq(leaves.length, 1);
        assertEq(leaves[0], expectedLeaf);
        assertEq(bindings.length, 1);
        assertEq(bindings[0].length, config.nonceOffset == 0 ? 3 : 4);
        uint256[4] memory offsets =
            config.nonceOffset == 0 ? [uint256(260), 292, 324, 0] : [uint256(196), 260, 292, 420];
        uint256[4] memory indices = config.nonceOffset == 0 ? [uint256(0), 1, 2, 0] : [uint256(0), 2, 3, 1];
        for (uint256 i; i < bindings[0].length; ++i) {
            assertEq(bindings[0][i], offsets[i] << 224 | uint256(SRC_INPUT) << 216 | indices[i]);
        }
    }

    function _inputsO10(bool liquidLane) internal view returns (uint256[] memory inputs) {
        inputs = new uint256[](liquidLane ? 4 : 3);
        inputs[0] = 100e18;
        inputs[1] = 198e6;
        inputs[2] = block.timestamp + 300;
        if (liquidLane) inputs[3] = 7;
    }

    function _runtimeO10(IMerkleAccount.Action memory authorization) internal pure returns (bytes[] memory runtime) {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = authorization;
        runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
    }

    function _authorizeO10(ExecutingRecipe.Recipe memory recipe, IMerkleAccount.Action memory authorization) internal {
        bytes32 leaf = MerkleAdapterVerifier.leaf(account, 0, authorization.data, authorization.dataMask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, _executor);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
    }

    function _prepareO10(SigningRecipe.Config memory config)
        internal
        returns (ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime)
    {
        IMerkleAccount.Action memory authorization;
        (recipe, authorization) = SigningRecipe.build(config);
        _authorizeO10(recipe, authorization);
        runtime = _runtimeO10(authorization);
    }

    function _compareO10(SigningRecipe.Config memory config, uint256[] memory inputs, bytes memory errorData) internal {
        (ExecutingRecipe.Recipe memory recipe, IMerkleAccount.Action memory authorization) = SigningRecipe.build(config);
        _compareRuntimeO10(config, recipe, authorization, inputs, _runtimeO10(authorization), errorData);
    }

    function _compareRuntimeO10(
        SigningRecipe.Config memory config,
        ExecutingRecipe.Recipe memory recipe,
        IMerkleAccount.Action memory authorization,
        uint256[] memory inputs,
        bytes[] memory runtime,
        bytes memory errorData
    ) internal {
        _assertAuthorizationO10(config, recipe, authorization);
        ExecutingRecipe.Recipe memory frozen = _referenceO10(config, recipe);
        for (uint256 version; version < 2; ++version) {
            uint256 snapshot = vm.snapshotState();
            ExecutingRecipe.Recipe memory selected = version == 0 ? frozen : recipe;
            _authorizeO10(selected, authorization);
            vm.recordLogs();
            (bool success, bytes memory result) = _executor.call(
                abi.encodeCall(RecipeExecutor.execute, (selected.queries, selected.steps, inputs, runtime))
            );
            if (errorData.length > 0) {
                assertFalse(success);
                assertEq(result, errorData, "exact original revert bytes");
                assertEq(vm.getRecordedLogs().length, 0, "failed execution has no event effects");
                bytes32 unsignedDigest = _digestO10(
                    config.nonceOffset > 0,
                    inputs.length == (config.nonceOffset > 0 ? 4 : 3) ? inputs : _inputsO10(config.nonceOffset > 0)
                );
                assertFalse(IMerkleAccount(account).signatures(unsignedDigest));
            } else {
                assertTrue(success);
                _assertDigestO10(_digestO10(config.nonceOffset > 0, inputs));
                if (config.nonceOffset > 0) {
                    uint256 nonce = inputs[3];
                    inputs[3] = nonce + 1;
                    assertFalse(
                        IMerkleAccount(account).signatures(_digestO10(true, inputs)), "only the checked nonce is signed"
                    );
                    inputs[3] = nonce;
                }
                assertEq(vm.getRecordedLogs().length, 2, "native Sign and Manage events");
            }
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function _digestO10(bool liquidLane, uint256[] memory inputs) internal view returns (bytes32) {
        if (!liquidLane) return GPv2Order.hash(_order(inputs[0], inputs[1], uint32(inputs[2])), _domain);
        ILiquidLaneReactor.Output memory output =
            ILiquidLaneReactor.Output({token: address(0x5678), amount: inputs[1], recipient: account});
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
        return keccak256(abi.encodePacked(hex"1901", _domain, structHash));
    }

    function _assertDigestO10(bytes32 digest) internal view {
        assertTrue(IMerkleAccount(account).signatures(digest));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
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

    function revertingClock() public pure returns (uint256) {
        revert StalePrice();
    }
}
