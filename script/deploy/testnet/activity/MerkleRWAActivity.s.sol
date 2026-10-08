// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ACTIVITY_TRANSACTION_GAS_LIMIT, ActivityPhaseScript} from "./ActivityContext.sol";
import {MerkleProgram} from "./MerkleProgram.sol";
import {TestnetPermissions} from "../TestnetPermissions.sol";
import {TestnetCatalog} from "../catalog/TestnetCatalog.sol";
import {TestnetCowSettlement} from "../protocols/TestnetServices.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {DISCOUNT_PRECISION, ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {OP_LESS_OR_EQUAL, OP_MIN, OP_READ, OP_SUB, SRC_RESULT} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IMerkleRWAActivityScript
 * @notice Interface for finite funded RWA purchases and exits from production Merkle account custody.
 */
interface IMerkleRWAActivityScript {
    /* ERRORS */

    /**
     * @notice Raised when the manifest, owner or deployed account identities are inconsistent.
     */
    error InvalidContext();
    /**
     * @notice Raised when actual settlement balances differ from the committed purchase or exit.
     */
    error InvalidSettlement();

    /* STRUCTS */

    /**
     * @notice Actual token and cash movements from one completed finite action.
     * @dev A direct ERC-4626 deposit and redeem has no CoW digest or UID. An unexecuted action has zero amounts.
     */
    struct Result {
        bool executed;
        uint256 bought;
        uint256 cashSpent;
        uint256 sold;
        uint256 cashReceived;
        bytes32 digest;
        bytes orderUid;
    }

    /* EVENTS */

    /**
     * @notice Emitted when actual account custody completes a funded purchase and exit.
     * @dev Production account Manage/Sign, settlement Trade and adapter DoSwap events provide transaction evidence.
     */
    event RunBase(
        uint256 indexed profile,
        address indexed account,
        address indexed token,
        uint256 bought,
        uint256 cashSpent,
        uint256 sold,
        uint256 cashReceived,
        bytes32 digest,
        bytes orderUid
    );

    /* FUNCTIONS */

    /**
     * @notice Executes one account-held purchase and production exit using existing funded solver inventory.
     * @dev Native issuer maintenance runs before this helper. The purchase is bounded by account cash, seed budget,
     * owner inventory and live Liquid Lane capacity. Exact full-fill orders expire after fifteen minutes and use
     * canonical CoW ERC-1271 approval through an account self-call. All recipients remain the Merkle account.
     * The owner is the funded solver; no auction status is fabricated. The intrinsic ERC-4626 profile deposits
     * account cash and redeems only newly minted shares bounded by fresh recipe balance and maxRedeem reads.
     */
    function runBase(
        string memory json,
        string memory market,
        uint256 profile,
        address owner,
        uint256 seed,
        bool broadcast
    ) external returns (Result memory result);
}

/// @title MerkleRWAActivityScript
/// @notice Executes finite RWA purchases and exits through production Merkle account recipes.
contract MerkleRWAActivityScript is ActivityPhaseScript, IMerkleRWAActivityScript {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /* STRUCTS */

    struct Context {
        MerkleProgram.Context merkle;
        address asset;
        address token;
        address lane;
        address settlement;
        uint256 budget;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleRWAActivityScript
    function runBase(
        string memory json,
        string memory market,
        uint256 profile,
        address owner,
        uint256 seed,
        bool broadcast
    ) public returns (Result memory result) {
        Context memory context = _context(json, market, profile, owner, seed);
        if (context.budget == 0) return result;
        if (TestnetCatalog.profile(profile).mechanism == 7) {
            _start(owner, broadcast);
            result = _erc4626(context);
            _stop(broadcast);
        } else {
            uint256 shares = IERC20(context.token).balanceOf(owner).mulDiv(5 + seed % 11, 100);
            if (shares == 0) return result;
            uint256 quote = ILiquidLaneAdapter(context.lane).getAmountOut(context.token, shares);
            if (quote == 0) return result;
            _start(owner, broadcast);
            address previousMaker = ILiquidLaneAdapter(context.lane).marketMaker();
            bool previousAcquire = ILiquidLaneAdapter(context.lane).marketMakerCanAcquire();
            ILiquidLaneAdapter(context.lane).setMarketMaker(context.merkle.account, false);
            uint256 capacity =
                ILiquidLaneAdapter(context.lane).getMaxAssets{gas: ACTIVITY_TRANSACTION_GAS_LIMIT}(context.token);
            shares = shares.mulDiv(Math.min(context.budget, capacity), quote);
            shares = Math.min(shares, IERC20(context.token).balanceOf(owner).mulDiv(5 + seed % 11, 100));
            quote = ILiquidLaneAdapter(context.lane).getAmountOut(context.token, shares);
            uint256 discount = Math.max(10_000, ILiquidLaneAdapter(context.lane).minDiscount(context.token));
            uint256 proceeds = quote.mulDiv(DISCOUNT_PRECISION - discount, DISCOUNT_PRECISION);
            if (shares > 0 && quote > 0 && proceeds > 0) {
                result = _trade(context, profile, seed, shares, quote, proceeds);
            }
            ILiquidLaneAdapter(context.lane).setMarketMaker(previousMaker, previousAcquire);
            _stop(broadcast);
        }
        if (result.executed) {
            emit RunBase(
                profile,
                context.merkle.account,
                context.token,
                result.bought,
                result.cashSpent,
                result.sold,
                result.cashReceived,
                result.digest,
                result.orderUid
            );
        }
    }

    /* INTERNAL FUNCTIONS */

    function _context(string memory json, string memory market, uint256 profile, address owner, uint256 seed)
        internal
        view
        returns (Context memory context)
    {
        if (
            vm.parseJsonUint(json, ".schemaVersion") != 2 || vm.parseJsonUint(json, ".chainId") != block.chainid
                || (block.chainid != 31_337 && block.chainid != 11_155_111)
                || vm.parseJsonAddress(json, ".owner") != owner || owner == address(0)
        ) revert InvalidContext();
        uint256[] memory profiles = vm.parseJsonUintArray(json, string.concat(market, ".rwaProfiles"));
        address[] memory tokens = vm.parseJsonAddressArray(json, string.concat(market, ".rwaTokens"));
        if (profiles.length != tokens.length) revert InvalidContext();
        for (uint256 i; i < profiles.length; ++i) {
            if (profiles[i] == profile) {
                if (context.token != address(0)) revert InvalidContext();
                context.token = tokens[i];
            }
        }
        context.asset = vm.parseJsonAddress(json, string.concat(market, ".asset"));
        context.lane = vm.parseJsonAddress(json, string.concat(market, ".liquidLaneAdapter"));
        context.settlement = vm.parseJsonAddress(json, ".cowSettlement");
        if (!TestnetCowSettlement(context.settlement).supportsContractSignatures()) revert InvalidContext();
        context.merkle = MerkleProgram.Context({
            owner: owner,
            account: vm.parseJsonAddress(json, string.concat(market, ".account")),
            rootRegistry: vm.parseJsonAddress(json, string.concat(market, ".rootRegistry")),
            executor: vm.parseJsonAddress(json, string.concat(market, ".executor")),
            baseActions: abi.decode(
                vm.parseJsonBytes(json, string.concat(market, ".merkleActions")), (IMerkleAccount.Action[])
            ),
            baseRecipe: abi.decode(vm.parseJsonBytes(json, string.concat(market, ".recipeSteps")), (bytes[]))
        });
        MerkleProgram.validate(context.merkle);
        if (
            context.token.code.length == 0 || context.settlement.code.length == 0
                || Ownable(context.merkle.account).owner() != owner
                || IMerkleAccount(context.merkle.account).ROOT_REGISTRY() != context.merkle.rootRegistry
                || Ownable(context.lane).owner() != owner
                || IERC4626(ILiquidLaneAdapter(context.lane).vault()).asset() != context.asset
                || IMerkleAdapter(IMerkleAccount(context.merkle.account).adapter()).vault()
                    != ILiquidLaneAdapter(context.lane).vault()
                || IAccount(ILiquidLaneAdapter(context.lane).accounts(context.token)).TOKEN_TO_REDEEM() != context.token
        ) revert InvalidContext();
        if (
            (IAccount(ILiquidLaneAdapter(context.lane).accounts(context.token)).ORACLE() == address(0))
                != (TestnetCatalog.profile(profile).mechanism == 7)
        ) revert InvalidContext();
        bytes32 symbol = keccak256(bytes(IERC20Metadata(context.asset).symbol()));
        uint256 price = symbol == keccak256("WETH")
            ? 3000
            : symbol == keccak256("tBTC") || symbol == keccak256("WBTC") || symbol == keccak256("cbBTC") ? 60_000 : 1;
        context.budget = vm.parseJsonUint(json, ".seedAssets") * 10 ** IERC20Metadata(context.asset).decimals() / price
            / 100 * (25 + seed % 76) / 100;
        context.budget = Math.min(context.budget, IERC20(context.asset).balanceOf(context.merkle.account));
    }

    function _trade(
        Context memory context,
        uint256 profile,
        uint256 seed,
        uint256 shares,
        uint256 quote,
        uint256 proceeds
    ) internal returns (Result memory result) {
        address account = context.merkle.account;
        address relayer = TestnetCowSettlement(context.settlement).vaultRelayer();
        uint256 cashBefore = IERC20(context.asset).balanceOf(account);
        uint256 tokenBefore = IERC20(context.token).balanceOf(account);
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(context.asset),
            buyToken: IERC20(context.token),
            receiver: account,
            sellAmount: quote,
            buyAmount: shares,
            validTo: uint32(block.timestamp + 15 minutes),
            appData: keccak256(abi.encode("merkle-rwa-activity", profile, seed, block.number, tokenBefore, cashBefore)),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        bytes32 domain = TestnetCowSettlement(context.settlement).domainSeparator();
        bytes memory buffer = abi.encode(GPv2Order.TYPE_HASH, order);
        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](1);
        plan[0] = IMerkleAccount.Hash({offset: 0, length: buffer.length, destination: 0});
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](3);
        actions[0] = TestnetPermissions.action(context.asset, abi.encodeCall(IERC20.approve, (relayer, 0)), 0);
        actions[1] = TestnetPermissions.action(context.asset, abi.encodeCall(IERC20.approve, (relayer, quote)), 0);
        actions[2] = TestnetPermissions.action(account, abi.encodeCall(IMerkleAccount.sign, (domain, buffer, plan)), 0);
        MerkleProgram.execute(context.merkle, _boundedGroup(actions, context.asset, quote, account));
        result.digest = keccak256(abi.encodePacked("\x19\x01", domain, keccak256(buffer)));
        result.orderUid = abi.encodePacked(result.digest, account, order.validTo);
        IERC20(context.token).forceApprove(context.settlement, shares);
        TestnetCowSettlement(context.settlement).fillContract(order, result.orderUid, quote, shares, "");
        IERC20(context.token).forceApprove(context.settlement, 0);
        IMerkleAccount(account).revokeSignature(result.digest);
        if (
            TestnetCowSettlement(context.settlement).filledAmount(result.orderUid) != quote
                || IERC20(context.asset).balanceOf(account) != cashBefore - quote
                || IERC20(context.token).balanceOf(account) != tokenBefore + shares
        ) revert InvalidSettlement();
        actions[0] = TestnetPermissions.action(context.asset, abi.encodeCall(IERC20.approve, (relayer, 0)), 0);
        actions[1] =
            TestnetPermissions.action(context.token, abi.encodeCall(IERC20.transfer, (context.lane, shares)), 0);
        actions[2] = TestnetPermissions.action(
            context.lane,
            abi.encodeWithSignature(
                "swap((address,address,uint256,uint256))",
                ILiquidLaneAdapter.Swap({
                    recipient: account, tokenIn: context.token, amountIn: shares, amountOut: proceeds
                })
            ),
            0
        );
        MerkleProgram.execute(context.merkle, _boundedGroup(actions, context.token, shares, account));
        if (
            IERC20(context.token).balanceOf(account) != tokenBefore
                || IERC20(context.asset).balanceOf(account) != cashBefore - quote + proceeds
                || IERC20(context.asset).allowance(account, relayer) > 0
                || IERC20(context.token).allowance(context.merkle.owner, context.settlement) > 0
                || IMerkleAccount(account).signatures(result.digest)
        ) revert InvalidSettlement();
        result.executed = true;
        result.bought = shares;
        result.cashSpent = quote;
        result.sold = shares;
        result.cashReceived = proceeds;
    }

    function _erc4626(Context memory context) internal returns (Result memory result) {
        address account = context.merkle.account;
        if (IERC4626(context.token).asset() != context.asset) revert InvalidContext();
        uint256 amount = Math.min(context.budget, IERC4626(context.token).maxDeposit(account));
        uint256 shareBound = IERC4626(context.token).previewDeposit(amount);
        if (amount == 0 || shareBound == 0) return result;
        uint256 cashBefore = IERC20(context.asset).balanceOf(account);
        uint256 tokenBefore = IERC20(context.token).balanceOf(account);
        MerkleProgram.Program memory program;
        program.actions = new IMerkleAccount.Action[](5);
        program.actions[0] =
            TestnetPermissions.action(context.asset, abi.encodeCall(IERC20.approve, (context.token, 0)), 0);
        program.actions[1] =
            TestnetPermissions.action(context.asset, abi.encodeCall(IERC20.approve, (context.token, amount)), 0);
        program.actions[2] =
            TestnetPermissions.action(context.token, abi.encodeCall(IERC4626.deposit, (amount, account)), 0);
        program.actions[3] = program.actions[0];
        program.actions[4] =
            TestnetPermissions.action(context.token, abi.encodeCall(IERC4626.redeem, (0, account, account)), 4);
        program.queries = new bytes[](2);
        program.queries[0] =
            abi.encode(context.token, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0));
        program.queries[1] =
            abi.encode(context.token, abi.encodeCall(IERC4626.maxRedeem, (account)), new uint256[](0), uint256(0));
        program.groups = new uint256[][](2);
        program.groups[0] = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            program.groups[0][i] = i;
        }
        program.groups[1] = new uint256[](1);
        program.groups[1][0] = 4;
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](1);
        bindings[0][0] = (uint256(4) << 224) | _result(6);
        program.steps = new bytes[](8);
        program.steps[0] = bytes.concat(bytes1(OP_READ), abi.encode(uint256(0)));
        program.steps[1] = MerkleProgram.step(program.actions, program.groups[0], new uint256[][](4));
        program.steps[2] = program.steps[0];
        program.steps[3] = bytes.concat(bytes1(OP_SUB), abi.encode(_result(2), _result(0)));
        program.steps[4] = bytes.concat(bytes1(OP_READ), abi.encode(uint256(1)));
        program.steps[5] = bytes.concat(bytes1(OP_MIN), abi.encode(_result(3), _result(4)));
        program.steps[6] = bytes.concat(bytes1(OP_MIN), abi.encode(_result(5), shareBound));
        program.steps[7] = MerkleProgram.step(program.actions, program.groups[1], bindings);
        program.inputs = new uint256[](0);
        uint256[] memory values = MerkleProgram.execute(context.merkle, program);
        result.executed = true;
        result.bought = values[3];
        result.cashSpent = amount;
        result.sold = values[6];
        result.cashReceived = IERC20(context.asset).balanceOf(account) + amount - cashBefore;
        if (
            IERC20(context.token).balanceOf(account) != tokenBefore + result.bought - result.sold
                || IERC20(context.asset).allowance(account, context.token) > 0 || result.sold > result.bought
                || result.sold > shareBound
        ) revert InvalidSettlement();
    }

    function _boundedGroup(IMerkleAccount.Action[] memory actions, address token, uint256 amount, address account)
        internal
        pure
        returns (MerkleProgram.Program memory program)
    {
        program.actions = actions;
        program.queries = new bytes[](1);
        program.queries[0] =
            abi.encode(token, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0));
        program.steps = new bytes[](3);
        program.steps[0] = bytes.concat(bytes1(OP_READ), abi.encode(uint256(0)));
        program.steps[1] = bytes.concat(bytes1(OP_LESS_OR_EQUAL), abi.encode(amount, _result(0)));
        program.groups = new uint256[][](1);
        program.groups[0] = new uint256[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            program.groups[0][i] = i;
        }
        program.steps[2] = MerkleProgram.step(actions, program.groups[0], new uint256[][](actions.length));
        program.inputs = new uint256[](0);
    }

    function _result(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_RESULT) << 216) | index;
    }
}
