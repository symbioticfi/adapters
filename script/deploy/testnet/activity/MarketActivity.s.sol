// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ACTIVITY_TRANSACTION_GAS_LIMIT} from "./ActivityContext.sol";
import {ActivityManifestScript} from "./ActivityManifest.sol";
import {MerkleMarketActivityScript} from "./MerkleMarketActivity.s.sol";
import {TestnetCowSettlement, TestnetMerklDistributor} from "../protocols/TestnetServices.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {IAppAdapter} from "src/interfaces/IAppAdapter.sol";
import {ICoWSwapConverter, COW_SWAP_ORDER_TYPEHASH} from "src/interfaces/common/ICoWSwapConverter.sol";
import {IRestakingAppAdapter} from "src/interfaces/IRestakingAppAdapter.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MarketActivityScript
/// @notice Exercises funded protocol round trips using only the human-readable deployment manifest.
/// @dev Family counters count completed native mutations, not signatures, elapsed time or simulated balance injection.
contract MarketActivityScript is ActivityManifestScript {
    using Math for uint256;
    using SafeERC20 for IERC20;

    struct MarketRun {
        address owner;
        address asset;
        address vault;
        uint256 amount;
        uint256 seed;
    }

    /* STATE VARIABLES */

    uint256 public lastAmount;
    bool public midnightWaiting;
    bytes public midnightParams;
    bytes public cowUid;
    uint256[13] public familyCounts;

    /* PUBLIC FUNCTIONS */

    function run() public {
        (string memory json, string memory market, address owner, uint256 seed) = _manifest();
        uint256[13] memory counts = runBase(json, market, owner, seed, _broadcast());
        uint256[] memory evidence = new uint256[](counts.length);
        uint256 executed;
        for (uint256 i; i < counts.length; ++i) {
            evidence[i] = counts[i];
            executed += counts[i];
        }
        _result(
            executed > 0,
            0,
            0,
            lastAmount == 0 ? "asset balance" : midnightWaiting ? "midnight funding or collateral" : ""
        );
        vm.serializeUint("activity-result", "families", evidence);
        vm.serializeUint("activity-result", "amount", lastAmount);
        vm.serializeBytes("activity-result", "cowUid", cowUid);
        string memory result = vm.serializeBytes("activity-result", "midnightParams", midnightParams);
        vm.writeJson(result, vm.envString("TESTNET_ACTIVITY_RESULT"));
    }

    /// @notice Returns completed operations for core, Aave3, Euler, MorphoVault, ERC4626, Blue, Midnight, Aave4,
    /// Merkle, App rewards, restaking rewards, Merkl and CoW, respectively.
    function runBase(string memory json, string memory market, address owner, uint256 seed, bool broadcast)
        public
        returns (uint256[13] memory counts)
    {
        if (
            vm.parseJsonUint(json, ".chainId") != block.chainid || vm.parseJsonAddress(json, ".owner") != owner
                || owner == address(0)
        ) revert InvalidActivity();
        address asset = _address(json, market, "asset");
        address vault = _address(json, market, "vault");
        if (IERC4626(vault).asset() != asset) revert InvalidActivity();
        bytes32 symbol = keccak256(bytes(IERC20Metadata(asset).symbol()));
        uint256 price = symbol == keccak256("WETH")
            ? 3000
            : symbol == keccak256("tBTC") || symbol == keccak256("WBTC") || symbol == keccak256("cbBTC") ? 60_000 : 1;
        uint256 amount = vm.parseJsonUint(json, ".seedAssets") * 10 ** IERC20Metadata(asset).decimals() / price / 1000
            * (25 + seed % 76) / 100;
        // Reserve three service budgets and one share's asset value for CoW's rounded share conversion.
        amount = Math.min(
            amount, IERC20(asset).balanceOf(owner).saturatingSub(IERC4626(vault).previewMint(1)).mulDiv(20, 23)
        );
        lastAmount = amount;
        midnightWaiting = false;
        midnightParams = "";
        cowUid = "";
        if (amount < 20) {
            lastAmount = 0;
            familyCounts = counts;
            return counts;
        }
        MarketRun memory context = MarketRun({owner: owner, asset: asset, vault: vault, amount: amount, seed: seed});
        // Fund owner services before account custody consumes its budget. Fill CoW before the long recipe batch.
        _start(owner, broadcast);
        counts[9] = _appReward(context, _address(json, market, "appAdapter"), false);
        counts[10] = _appReward(context, _address(json, market, "restakingAdapter"), true);
        counts[11] = _merkl(context, vm.parseJsonAddress(json, ".merklDistributor"));
        (counts[12], cowUid) = _cow(
            context,
            _address(json, market, "appAdapter"),
            vm.parseJsonAddress(json, ".cowSettlement"),
            context.amount / 20
        );
        _stop(broadcast);
        address helper = address(new MerkleMarketActivityScript());
        uint256[8] memory accountCounts =
            MerkleMarketActivityScript(helper).runBase(json, market, owner, amount, broadcast);
        midnightWaiting = MerkleMarketActivityScript(helper).midnightWaiting();
        midnightParams = MerkleMarketActivityScript(helper).midnightParams();
        for (uint256 i; i < accountCounts.length; ++i) {
            counts[i] = accountCounts[i];
            if (accountCounts[i] > 0) ++counts[8];
        }
        familyCounts = counts;
    }

    /* INTERNAL FUNCTIONS */

    function _appReward(MarketRun memory context, address adapter, bool restaking) internal returns (uint256) {
        IERC20(context.asset).forceApprove(adapter, context.amount / 20);
        IAppAdapter(adapter).reward{gas: ACTIVITY_TRANSACTION_GAS_LIMIT}(context.asset, context.amount / 20);
        if (restaking) IRestakingAppAdapter(adapter).syncReward();
        return restaking ? 2 : 1;
    }

    function _merkl(MarketRun memory context, address distributor) internal returns (uint256) {
        if (Ownable(distributor).owner() != context.owner) revert InvalidActivity();
        uint256 reward = context.amount / 20;
        uint256 cumulative = TestnetMerklDistributor(distributor).claimed(context.owner, context.asset) + reward;
        IERC20(context.asset).safeTransfer(distributor, reward);
        TestnetMerklDistributor(distributor).setRoot(keccak256(abi.encode(context.owner, context.asset, cumulative)));
        address[] memory users = new address[](1);
        users[0] = context.owner;
        address[] memory tokens = new address[](1);
        tokens[0] = context.asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = cumulative;
        TestnetMerklDistributor(distributor).claim(users, tokens, amounts, new bytes32[][](1));
        return 3;
    }

    function _cow(MarketRun memory context, address adapter, address settlement, uint256 amount)
        internal
        returns (uint256 count, bytes memory uid)
    {
        if (Ownable(adapter).owner() != context.owner || ICoWSwapConverter(adapter).COW_SWAP_SETTLEMENT() != settlement)
        {
            revert InvalidActivity();
        }
        address[] memory saved = new address[](32);
        uint256 length;
        for (; length <= saved.length; ++length) {
            (bool success, bytes memory result) =
                adapter.staticcall(abi.encodeCall(ICoWSwapConverter.converters, (length)));
            if (!success) {
                if (
                    result.length > 0
                        && keccak256(result) != keccak256(abi.encodeWithSignature("Panic(uint256)", uint256(0x32)))
                ) {
                    assembly ("memory-safe") { revert(add(result, 0x20), mload(result)) }
                }
                break;
            }
            if (length == saved.length) revert InvalidActivity();
            saved[length] = abi.decode(result, (address));
        }
        address[] memory original = new address[](length);
        for (uint256 i; i < length; ++i) {
            original[i] = saved[i];
        }
        uint256 shares =
            Math.min(IERC4626(context.vault).previewWithdraw(amount), IERC20(context.vault).balanceOf(context.owner));
        uint256 buyAmount = IERC4626(context.vault).convertToAssets(shares);
        if (shares == 0 || buyAmount == 0 || buyAmount > IERC20(context.asset).balanceOf(context.owner)) {
            return (0, "");
        }
        IERC20(context.vault).forceApprove(adapter, shares);
        IAppAdapter(adapter).reward{gas: ACTIVITY_TRANSACTION_GAS_LIMIT}(context.vault, shares);
        address[] memory converters = new address[](1);
        converters[0] = context.owner;
        ICoWSwapConverter(adapter).setConverters(converters);
        ICoWSwapConverter.OrderParams memory params = ICoWSwapConverter.OrderParams({
            buyAmount: buyAmount,
            validTo: uint32(block.timestamp + 30 minutes),
            appData: keccak256(abi.encode("market-activity", context.seed, block.number))
        });
        ICoWSwapConverter(adapter).convert{gas: ACTIVITY_TRANSACTION_GAS_LIMIT}(
            context.vault, shares, context.asset, abi.encode(params)
        );
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(context.vault),
            buyToken: IERC20(context.asset),
            receiver: adapter,
            sellAmount: shares,
            buyAmount: buyAmount,
            validTo: params.validTo,
            appData: params.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: true,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                TestnetCowSettlement(settlement).domainSeparator(),
                keccak256(bytes.concat(COW_SWAP_ORDER_TYPEHASH, abi.encode(order)))
            )
        );
        uid = abi.encodePacked(digest, adapter, params.validTo);
        IERC20(context.asset).forceApprove(settlement, buyAmount);
        TestnetCowSettlement(settlement).fill(order, uid, shares, buyAmount);
        ICoWSwapConverter(adapter).setConverters(original);
        if (TestnetCowSettlement(settlement).filledAmount(uid) != shares) revert InvalidActivity();
        return (5, uid);
    }
}
