// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ActivityManifestScript} from "./ActivityManifest.sol";
import {MerkleProgram} from "./MerkleProgram.sol";
import {SepoliaInfrastructure} from "../SepoliaInfrastructure.sol";
import {ThreeFGuardedMint} from "script/recipes/ThreeFGuardedMint.sol";

import {TestnetPermissions} from "../TestnetPermissions.sol";
import {TestnetThreeFFacility, TestnetThreeFRequest} from "../protocols/TestnetThreeF.sol";

import {OP_EQUAL, OP_READ, SRC_RESULT} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {
    IThreeFFacility,
    IThreeFPositionManager,
    IThreeFRequestName,
    IThreeFUnderlyingAsset
} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {
    IThreeFPolicy,
    REQUEST_NAME_PREFIX_LENGTH
} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFRequest} from "src/interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title MerkleThreeFActivityScript
/// @notice Executes finite funded 3F investments and mature withdrawals from the production Merkle account.
/// @dev Only local issuer administration originates outside the account. Public-chain minting requires a real
/// request with existing account authorization and configured policy limits; no official administration is simulated.
contract MerkleThreeFActivityScript is ActivityManifestScript {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    struct ThreeFContext {
        MerkleProgram.Context program;
        address asset;
        address policy;
        address requestsFactory;
        address facility;
        address whitelist;
    }

    /* STATE VARIABLES */

    address public lastRequest;
    uint256 public lastAmount;
    uint256 public lastYield;
    uint256 public nextCursor;
    uint256 public withdrawn;
    address[] public settledRequests;

    /* PUBLIC FUNCTIONS */

    /// @notice Processes at most eight recorded positions and executes one authorized account-funded investment.
    function run() public {
        (string memory json, string memory market, address owner, uint256 seed) = _manifest();
        ThreeFContext memory context = ThreeFContext({
            program: MerkleProgram.Context({
                owner: owner,
                account: _address(json, market, "account"),
                rootRegistry: _address(json, market, "rootRegistry"),
                executor: _address(json, market, "executor"),
                baseActions: abi.decode(
                    vm.parseJsonBytes(json, string.concat(market, ".merkleActions")), (IMerkleAccount.Action[])
                ),
                baseRecipe: abi.decode(vm.parseJsonBytes(json, string.concat(market, ".recipeSteps")), (bytes[]))
            }),
            asset: _address(json, market, "asset"),
            policy: _address(json, market, "threeFPolicy"),
            requestsFactory: address(0),
            facility: _address(json, market, "threeFFacility"),
            whitelist: block.chainid == 31_337
                ? _address(json, market, "threeFFacility")
                : vm.parseJsonAddress(json, ".threeFWhitelist")
        });
        MerkleProgram.validate(context.program);
        context.requestsFactory = IThreeFPolicy(context.policy).REQUESTS_FACTORY();
        if (
            IThreeFPolicy(context.policy).FACILITY() != context.facility
                || IThreeFPolicy(context.policy).account() != context.program.account
        ) {
            revert InvalidActivity();
        }
        if (
            block.chainid == SepoliaInfrastructure.CHAIN_ID
                && (context.requestsFactory != SepoliaInfrastructure.REQUESTS_FACTORY
                    || context.facility != SepoliaInfrastructure.FACILITY
                    || context.whitelist != SepoliaInfrastructure.WHITELIST)
        ) {
            revert InvalidActivity();
        }
        lastRequest = address(0);
        lastAmount = 0;
        lastYield = 0;
        withdrawn = 0;
        delete settledRequests;
        string memory recorded = vm.envOr("TESTNET_MERKLE_THREEF_REQUESTS", string(""));
        address[] memory requests =
            bytes(recorded).length > 0 ? vm.envAddress("TESTNET_MERKLE_THREEF_REQUESTS", ",") : new address[](0);
        address initial = _address(json, market, "threeFRequest");
        bool included;
        for (uint256 i; i < requests.length; ++i) {
            if (requests[i] == initial) included = true;
        }
        if (initial != address(0) && !included) {
            address[] memory expanded = new address[](requests.length + 1);
            for (uint256 i; i < requests.length; ++i) {
                expanded[i] = requests[i];
            }
            expanded[requests.length] = initial;
            requests = expanded;
        }
        nextCursor = requests.length > 0 ? vm.envOr("TESTNET_ACTIVITY_CURSOR", uint256(0)) % requests.length : 0;
        uint256 count = Math.min(requests.length, 8);
        _start(owner, _broadcast());
        for (uint256 i; i < count; ++i) {
            address request = requests[nextCursor];
            nextCursor = nextCursor + 1 == requests.length ? 0 : nextCursor + 1;
            _validateRequest(context, request);
            (uint256 principal, uint256 yieldAssets) =
                IThreeFVaultController(request).balancesOf(context.program.account);
            if ((principal > 0 || yieldAssets > 0) && IThreeFVaultController(request).canWithdraw()) {
                _redeem(context, request);
                settledRequests.push(request);
            }
        }
        if (block.chainid == 31_337) {
            uint256 index = vm.envUint("TESTNET_ACTIVITY_MARKET");
            uint256 price = index == 5 ? 3000 : index >= 2 && index <= 4 ? 60_000 : 1;
            uint256 amount = vm.parseJsonUint(json, ".seedAssets") * 10
                ** vm.parseJsonUint(json, string.concat(market, ".decimals")) / price / 1000;
            amount = amount * (25 + seed % 76) / 100;
            amount = Math.min(amount, IERC20(context.asset).balanceOf(context.program.account));
            amount = Math.min(
                amount,
                IThreeFPolicy(context.policy).remainingAssets(context.asset, vm.parseJsonAddress(json, ".collateral"))
            );
            amount = Math.min(amount, type(uint128).max);
            uint256 cash = IERC20(context.asset).balanceOf(owner);
            if (amount / 100 > cash) amount = cash * 100;
            if (amount >= 100) {
                lastRequest = TestnetThreeFFacility(context.facility).createRequest(uint48(block.timestamp + 7 days));
                IERC20(context.asset).safeTransfer(lastRequest, amount / 100);
                TestnetThreeFRequest(lastRequest)
                    .authorizeMinting(context.program.account, uint128(amount), uint128(amount / 100));
                _mint(context, lastRequest, amount, amount / 100);
            }
        } else {
            string memory index = vm.envUint("TESTNET_ACTIVITY_MARKET").toString();
            address request = vm.envOr(string.concat("TESTNET_MERKLE_THREEF_REQUEST_", index), address(0));
            if (request != address(0)) {
                _mint(
                    context,
                    request,
                    vm.envUint(string.concat("TESTNET_MERKLE_THREEF_AMOUNT_", index)),
                    vm.envUint(string.concat("TESTNET_MERKLE_THREEF_YIELD_", index))
                );
            }
        }
        _stop(_broadcast());
        _result(
            lastRequest != address(0) || settledRequests.length > 0,
            settledRequests.length,
            nextCursor,
            lastRequest != address(0)
                ? ""
                : block.chainid == 31_337
                    ? "strategy cash, issuer yield funding or native policy capacity unavailable"
                    : "official account mint authorization and configured policy limits required"
        );
        vm.serializeAddress("activity-result", "request", lastRequest);
        vm.serializeUint("activity-result", "amount", lastAmount);
        vm.serializeUint("activity-result", "yieldAssets", lastYield);
        vm.serializeUint("activity-result", "withdrawn", withdrawn);
        string memory result = vm.serializeAddress("activity-result", "settledRequests", settledRequests);
        vm.writeJson(result, vm.envString("TESTNET_ACTIVITY_RESULT"));
    }

    /* INTERNAL FUNCTIONS */

    function _validateRequest(ThreeFContext memory context, address request) internal view {
        if (
            request == address(0) || !IThreeFRequestFactory(context.requestsFactory).isRequest(request)
                || IThreeFRequest(request).asset() != context.asset
        ) {
            revert InvalidActivity();
        }
    }

    // Each selected request uses the same atomic native withdrawal program; no owner balance receives the proceeds.
    function _redeem(ThreeFContext memory context, address request) internal {
        uint256 cash = IERC20(context.asset).balanceOf(context.program.account);
        MerkleProgram.Program memory program;
        program.actions = new IMerkleAccount.Action[](1);
        program.actions[0] = TestnetPermissions.action(
            request,
            abi.encodeCall(IThreeFVaultController.burnAll, (context.program.account, context.program.account)),
            0
        );
        program.groups = new uint256[][](1);
        program.groups[0] = new uint256[](1);
        program.queries = new bytes[](2);
        program.queries[0] = abi.encode(
            request,
            abi.encodeCall(IThreeFVaultController.balancesOf, (context.program.account)),
            new uint256[](0),
            uint256(0)
        );
        program.queries[1] = abi.encode(
            request,
            abi.encodeCall(IThreeFVaultController.balancesOf, (context.program.account)),
            new uint256[](0),
            uint256(32)
        );
        program.steps = new bytes[](5);
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](0);
        program.steps[0] = MerkleProgram.step(program.actions, program.groups[0], bindings);
        program.steps[1] = bytes.concat(bytes1(OP_READ), abi.encode(uint256(0)));
        program.steps[2] = bytes.concat(bytes1(OP_EQUAL), abi.encode((uint256(SRC_RESULT) << 216) | 1, uint256(0)));
        program.steps[3] = bytes.concat(bytes1(OP_READ), abi.encode(uint256(1)));
        program.steps[4] = bytes.concat(bytes1(OP_EQUAL), abi.encode((uint256(SRC_RESULT) << 216) | 3, uint256(0)));
        program.inputs = new uint256[](0);
        MerkleProgram.execute(context.program, program);
        withdrawn += IERC20(context.asset).balanceOf(context.program.account) - cash;
    }

    // Both local and official minting use the same account program and account-bound policy.
    function _mint(ThreeFContext memory context, address request, uint256 amount, uint256 yieldAssets) internal {
        _validateRequest(context, request);
        if (
            IThreeFWhitelist(context.whitelist).isWhitelisted(request) != IThreeFWhitelist.WhitelistStatus.Whitelisted
                || IThreeFVaultController(request).canWithdraw() || amount == 0 || yieldAssets == 0
                || amount > type(uint128).max || yieldAssets > type(uint128).max
                || amount > IERC20(context.asset).balanceOf(context.program.account)
        ) {
            revert InvalidActivity();
        }
        (uint128 authorizedPrincipal, uint128 authorizedYield) =
            IThreeFPushRequest(request).mintAuthorization(context.program.account);
        if (authorizedPrincipal != amount || authorizedYield != yieldAssets) revert InvalidActivity();
        string memory name = IThreeFRequestName(request).name();
        if (bytes(name).length <= REQUEST_NAME_PREFIX_LENGTH) revert InvalidActivity();
        (IThreeFFacility.IntentProperties memory properties,, address intentRequest,) = IThreeFFacility(
                context.facility
            )
            .getIntent(Strings.parseUint(name, REQUEST_NAME_PREFIX_LENGTH, bytes(name).length));
        if (
            intentRequest != request || properties.depositAsset.asset != context.asset
                || properties.depositAsset.isPositionManager || !properties.targetAsset.isPositionManager
        ) revert InvalidActivity();
        (address collateral,) = IThreeFPositionManager(properties.targetAsset.asset).assets();
        address budgetAsset = IThreeFUnderlyingAsset(collateral).underlying();
        if (amount > IThreeFPolicy(context.policy).remainingAssets(context.asset, budgetAsset)) {
            revert InvalidActivity();
        }
        MerkleProgram.Program memory program;
        program.actions = new IMerkleAccount.Action[](3);
        program.actions[0] =
            TestnetPermissions.action(context.asset, abi.encodeCall(IERC20.approve, (request, amount)), 0);
        ThreeFGuardedMint.Leaf memory mintLeaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                asset: context.asset, resetApproval: true, policy: context.policy, request: request
            })
        );
        ThreeFGuardedMint.write(mintLeaf.data, mintLeaf.assets, amount);
        ThreeFGuardedMint.write(mintLeaf.data, mintLeaf.yieldAssets, yieldAssets);
        program.actions[1] = IMerkleAccount.Action({
            target: context.program.account,
            value: 0,
            data: mintLeaf.data,
            dataMask: mintLeaf.dataMask,
            proof: new bytes32[](0)
        });
        program.actions[2] =
            TestnetPermissions.action(context.asset, abi.encodeCall(IERC20.approve, (request, uint256(0))), 0);
        program.queries = new bytes[](0);
        program.groups = new uint256[][](1);
        program.groups[0] = new uint256[](3);
        program.groups[0][1] = 1;
        program.groups[0][2] = 2;
        uint256[][] memory bindings = new uint256[][](3);
        for (uint256 i; i < bindings.length; ++i) {
            bindings[i] = new uint256[](0);
        }
        program.steps = new bytes[](1);
        program.steps[0] = MerkleProgram.step(program.actions, program.groups[0], bindings);
        program.inputs = new uint256[](0);
        MerkleProgram.execute(context.program, program);
        lastRequest = request;
        lastAmount = amount;
        lastYield = yieldAssets;
    }
}
