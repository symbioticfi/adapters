// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ActivityContext, ActivityPhaseScript} from "script/deploy/testnet/activity/ActivityContext.sol";
import {
    TestnetFigureYieldVault,
    TestnetParetoCDO,
    TestnetParetoQueue,
    TestnetYieldVault
} from "script/deploy/testnet/protocols/TestnetYieldRedemptions.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {IFigureAccount} from "src/interfaces/ll-adapter/figure/IFigureAccount.sol";
import {IParetoAccount} from "src/interfaces/ll-adapter/pareto/IParetoAccount.sol";
import {IParetoCreditVault} from "src/interfaces/ll-adapter/pareto/IParetoCreditVault.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IYieldActivityFaucet
 * @notice Interface for the deployed owner-mintable fixtures and official 3F Sepolia testnet faucet.
 */
interface IYieldActivityFaucet {
    /* FUNCTIONS */

    /**
     * @notice Mints base testnet assets to fund a bounded, actual native deposit.
     */
    function mint(address receiver, uint256 assets) external;
}

/**
 * @title IYieldActivityScript
 * @notice Interface for bounded real-time maintenance of funded native yield profiles.
 */
interface IYieldActivityScript {
    /* ERRORS */

    /**
     * @notice Raised when context identities do not match the deployed fixture and account.
     */
    error InvalidContext();
    /**
     * @notice Raised when an indexed queue getter violates its expected ABI.
     */
    error InvalidQueue();

    /* EVENTS */

    /**
     * @notice Emitted after real backing, inventory, settlement and permissionless account synchronization.
     */
    event RunBase(
        uint256 indexed profile,
        address indexed account,
        uint256 settled,
        uint256 inventoryAssets,
        uint256 repaidAssets,
        uint256 liquidAssets,
        uint256 nextCursor
    );

    /* FUNCTIONS */

    /**
     * @notice Returns the next queue position for the caller's persistent activity ledger.
     */
    function nextCursor() external view returns (uint256);

    /**
     * @notice Replenishes owner inventory and settles at most eight selected native pending entries.
     * @dev Context kind must be 5 and variant 0..10. Funding and principal repayments together use at most
     * context.assets underlying units. Native clocks are read without modification. Settled counts newly
     * finalized requests, released InfiniFi positions, or a direct/partial liquid exit; cash paid is emitted separately.
     * InfiniFi's live backlog must stay at most eight because production sync completes all ready positions.
     */
    function runBase(ActivityContext memory context, bool broadcast) external returns (uint256 settled);

    /**
     * @notice Returns the live array length or single-slot request count for a native variant.
     * @dev The parent should admit new swaps only below eight live entries, especially for InfiniFi.
     * Indexed getters are probed logarithmically; native empty reverts or out-of-bounds Panic(0x32) end an array.
     */
    function pendingEntries(address account, uint8 variant) external view returns (uint256);
}

/// @title YieldActivityScript
/// @notice Foundry activity helper for funded native yield settlement, inventory and freshness.
contract YieldActivityScript is ActivityPhaseScript, IYieldActivityScript {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /* STATE VARIABLES */

    /// @inheritdoc IYieldActivityScript
    uint256 public nextCursor;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IYieldActivityScript
    function runBase(ActivityContext memory context, bool broadcast) public returns (uint256 settled) {
        bool figure = context.variant < 2;
        if (
            context.kind != 5 || (!figure && context.variant != 10) || context.owner == address(0)
                || context.asset.code.length == 0 || context.token.code.length == 0 || context.endpoint.code.length == 0
                || context.account.code.length == 0 || context.oracle.code.length == 0
                || IAccount(context.account).TOKEN_TO_REDEEM() != context.token
                || IAccount(context.account).ORACLE() != context.oracle
                || IERC4626(IAccount(context.account).vault()).asset() != context.asset
                || Ownable(context.token).owner() != context.owner || Ownable(context.endpoint).owner() != context.owner
        ) revert InvalidContext();
        uint256 length = pendingEntries(context.account, context.variant);
        uint256 count = Math.min(length, 8);
        uint256 cursor = length > 0 ? context.cursor % length : 0;
        uint256 liquidBefore = IERC20(context.asset).balanceOf(context.account);
        _start(context.owner, broadcast);
        uint256 repaid;
        if (figure) {
            repaid = _repay(context.endpoint, context.owner, context.asset, context.assets);
        }
        repaid += _repay(context.token, context.owner, context.asset, context.assets - repaid);

        uint256 value = IERC4626(context.token).convertToAssets(IERC20(context.token).balanceOf(context.owner));
        if (figure) value = IERC4626(context.endpoint).convertToAssets(value);
        uint256 inventoryAssets = Math.min(context.assets.saturatingSub(value), context.assets - repaid);
        if (inventoryAssets > 0) {
            uint256 balance = IERC20(context.asset).balanceOf(context.owner);
            if (inventoryAssets > balance) {
                IYieldActivityFaucet(context.asset).mint(context.owner, inventoryAssets - balance);
            }
            if (figure) {
                IERC20(context.asset).forceApprove(context.endpoint, inventoryAssets);
                uint256 shares = IERC4626(context.endpoint).deposit(inventoryAssets, context.owner);
                IERC20(context.endpoint).forceApprove(context.token, shares);
                IERC4626(context.token).deposit(shares, context.owner);
            } else {
                IERC20(context.asset).forceApprove(context.token, inventoryAssets);
                IERC4626(context.token).deposit(inventoryAssets, context.owner);
            }
        }
        if (figure) {
            for (uint256 i; i < count; ++i) {
                address holder = IFigureAccount(context.account).subAccounts((cursor + i) % length);
                (uint256 shares, uint256 assets, uint256 timestamp) =
                    TestnetFigureYieldVault(context.endpoint).pendingRedemptions(holder);
                if (
                    shares > 0
                        && block.timestamp >= timestamp + TestnetFigureYieldVault(context.endpoint).settlementDelay()
                        && assets <= TestnetYieldVault(context.endpoint).cash()
                ) {
                    TestnetFigureYieldVault(context.endpoint).finalize(holder);
                    ++settled;
                }
            }
        } else {
            address cdo = TestnetParetoQueue(context.endpoint).idleCDOEpoch();
            if (!TestnetParetoCDO(cdo).isWalletAllowed(context.account)) {
                TestnetParetoCDO(cdo).setWalletAllowed(context.account, true);
            }
            if (TestnetParetoCDO(cdo).isEpochRunning() && block.timestamp >= TestnetParetoCDO(cdo).epochMaturity()) {
                TestnetParetoCDO(cdo).stopEpoch();
            }
            if (!TestnetParetoCDO(cdo).isEpochRunning()) {
                uint256 epochNumber = IParetoCreditVault(TestnetParetoCDO(cdo).strategy()).epochNumber();
                for (uint256 i; i < count; ++i) {
                    uint256 epoch = IParetoAccount(context.account).queueEpochs((cursor + i) % length);
                    if (epoch > epochNumber || TestnetParetoQueue(context.endpoint).settled(epoch)) continue;
                    if (TestnetParetoQueue(context.endpoint).epochWithdrawPrice(epoch) == 0) {
                        TestnetParetoQueue(context.endpoint).processEpoch(epoch);
                    }
                    uint256 assets = TestnetParetoQueue(context.endpoint).epochPendingClaims(epoch);
                    if (IERC4626(context.token).maxWithdraw(context.endpoint) >= assets) {
                        TestnetParetoQueue(context.endpoint).settleEpoch(epoch);
                        ++settled;
                    }
                }
                if (!TestnetParetoCDO(cdo).defaulted()) TestnetParetoCDO(cdo).startEpoch();
            }
        }
        if (
            !figure
                || IERC20(context.token).balanceOf(context.account)
                    <= IERC4626(context.token).maxRedeem(context.account)
        ) {
            IAccount(context.account).sync();
        }
        _stop(broadcast);
        length = pendingEntries(context.account, context.variant);
        nextCursor = length > 0 ? (cursor + count) % length : 0;
        emit RunBase(
            context.profile,
            context.account,
            settled,
            inventoryAssets,
            repaid,
            IERC20(context.asset).balanceOf(context.account).saturatingSub(liquidBefore),
            nextCursor
        );
    }

    /// @inheritdoc IYieldActivityScript
    function pendingEntries(address account, uint8 variant) public view returns (uint256 length) {
        if ((variant > 1 && variant != 10) || account.code.length == 0) revert InvalidContext();
        bytes4 selector = variant < 2 ? IFigureAccount.subAccounts.selector : IParetoAccount.queueEpochs.selector;
        (bool exists,) = _entry(account, selector, 0);
        if (!exists) return 0;
        uint256 lower;
        uint256 upper = 1;
        (exists,) = _entry(account, selector, upper);
        while (exists) {
            if (upper > type(uint256).max / 2) revert InvalidQueue();
            lower = upper;
            upper *= 2;
            (exists,) = _entry(account, selector, upper);
        }
        while (upper > lower + 1) {
            uint256 middle = lower + (upper - lower) / 2;
            (exists,) = _entry(account, selector, middle);
            if (exists) lower = middle;
            else upper = middle;
        }
        return upper;
    }

    /* INTERNAL FUNCTIONS */

    function _repay(address vault, address owner, address asset, uint256 budget) internal returns (uint256 used) {
        if (budget == 0) return 0;
        address denomination = IERC4626(vault).asset();
        uint256 principal = Math.min(
            TestnetYieldVault(vault).receivable(),
            Math.min(
                IERC20(denomination).balanceOf(owner),
                denomination == asset ? budget : IERC4626(denomination).convertToShares(budget)
            )
        );
        if (principal > 0) {
            used = denomination == asset ? principal : IERC4626(denomination).convertToAssets(principal);
            IERC20(denomination).forceApprove(vault, principal);
            TestnetYieldVault(vault).repayCapital(principal, 0);
        }
    }

    function _entry(address account, bytes4 selector, uint256 index)
        internal
        view
        returns (bool exists, uint256 value)
    {
        (bool success, bytes memory result) = account.staticcall(abi.encodeWithSelector(selector, index));
        if (success) {
            if (result.length != 32) revert InvalidQueue();
            return (true, abi.decode(result, (uint256)));
        }
        // Compiler-generated array getters revert empty on out-of-bounds access; other array paths use Panic(0x32).
        if (result.length == 0) return (false, 0);
        if (result.length == 36) {
            bytes4 panic;
            uint256 code;
            assembly ("memory-safe") {
                panic := mload(add(result, 32))
                code := mload(add(result, 36))
            }
            if (panic == 0x4e487b71 && code == 0x32) return (false, 0);
        }
        assembly ("memory-safe") {
            revert(add(result, 32), mload(result))
        }
    }
}
