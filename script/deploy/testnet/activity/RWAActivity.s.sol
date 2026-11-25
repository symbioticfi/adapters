// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ActivityContext} from "./ActivityContext.sol";
import {ActivityManifestScript} from "./ActivityManifest.sol";
import {IssuerActivityScript} from "./IssuerActivity.s.sol";
import {MerkleRWAActivityScript, IMerkleRWAActivityScript} from "./MerkleRWAActivity.s.sol";
import {YieldActivityScript} from "./YieldActivity.s.sol";
import {TestnetCatalog} from "../catalog/TestnetCatalog.sol";

import {ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RWAActivityScript
/// @notice Maintains native redemption lifecycles and submits bounded inventory through every production LL account.
contract RWAActivityScript is ActivityManifestScript {
    function run() public {
        _run(_context(), false);
    }

    function runMaintenance() public {
        _run(_context(), true);
    }

    function _context() internal view returns (ActivityContext memory context) {
        (string memory json, string memory market, address owner, uint256 seed) = _manifest();
        context.owner = owner;
        context.seed = seed;
        context.profile = vm.envUint("TESTNET_ACTIVITY_PROFILE");
        uint256[] memory profiles = vm.parseJsonUintArray(json, string.concat(market, ".rwaProfiles"));
        uint256 index = type(uint256).max;
        for (uint256 i; i < profiles.length; ++i) {
            if (profiles[i] == context.profile) index = i;
        }
        if (index == type(uint256).max) revert InvalidActivity();
        TestnetCatalog.Profile memory profile = TestnetCatalog.profile(context.profile);
        context.kind = profile.mechanism;
        context.variant = profile.variant;
        context.asset = _address(json, market, "asset");
        context.token = vm.parseJsonAddressArray(json, string.concat(market, ".rwaTokens"))[index];
        context.endpoint = vm.parseJsonAddressArray(json, string.concat(market, ".redemptionEndpoints"))[index];
        context.feed = vm.parseJsonAddressArray(json, string.concat(market, ".priceFeeds"))[index];
        context.oracle = vm.parseJsonAddressArray(json, string.concat(market, ".rwaOracles"))[index];
        context.account = ILiquidLaneAdapter(_address(json, market, "liquidLaneAdapter")).accounts(context.token);
        uint256 price = profile.market == 5 ? 3000 : profile.market >= 2 && profile.market <= 4 ? 60_000 : 1;
        uint256 budget = vm.parseJsonUint(json, ".seedAssets") * 10
            ** vm.parseJsonUint(json, string.concat(market, ".decimals")) / price / 100;
        context.assets = Math.min(budget, IERC20(context.asset).balanceOf(owner));
        context.cursor = vm.envOr("TESTNET_ACTIVITY_CURSOR", uint256(0));
    }

    function _run(ActivityContext memory context, bool maintenanceOnly) internal {
        uint256 settled;
        uint256 cursor;
        uint256 pending;
        if (context.kind < 5) {
            address helper = address(new IssuerActivityScript());
            settled = IssuerActivityScript(helper).runBase(context, _broadcast());
            cursor = IssuerActivityScript(helper).nextCursor();
            pending = IssuerActivityScript(helper).pendingEntries(context);
        } else if (context.kind == 5) {
            address helper = address(new YieldActivityScript());
            settled = YieldActivityScript(helper).runBase(context, _broadcast());
            cursor = YieldActivityScript(helper).nextCursor();
            pending = YieldActivityScript(helper).pendingEntries(context.account, context.variant);
        }
        uint256 maximumPending = context.kind == 3 ? 1 : 8;
        if (maintenanceOnly) {
            _result(false, settled, cursor, "native maintenance complete");
            return;
        }
        if (pending >= maximumPending) {
            _result(false, settled, cursor, "native redemption queue at capacity");
            return;
        }
        (string memory json, string memory market,,) = _manifest();
        address helper = address(new MerkleRWAActivityScript());
        IMerkleRWAActivityScript.Result memory result = MerkleRWAActivityScript(helper)
            .runBase(json, market, context.profile, context.owner, context.seed, _broadcast());
        _result(result.executed, settled, cursor, result.executed ? "" : "account cash, inventory or LL capacity");
        string memory output = vm.readFile(vm.envString("TESTNET_ACTIVITY_RESULT"));
        vm.serializeJson("rwa-strategy-result", output);
        vm.serializeUint("rwa-strategy-result", "bought", result.bought);
        vm.serializeUint("rwa-strategy-result", "cashSpent", result.cashSpent);
        vm.serializeUint("rwa-strategy-result", "sold", result.sold);
        vm.serializeUint("rwa-strategy-result", "cashReceived", result.cashReceived);
        vm.serializeBytes32("rwa-strategy-result", "digest", result.digest);
        output = vm.serializeBytes("rwa-strategy-result", "orderUid", result.orderUid);
        vm.writeJson(output, vm.envString("TESTNET_ACTIVITY_RESULT"));
    }
}
