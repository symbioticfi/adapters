// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IMidnight} from "morpho-midnight/src/interfaces/IMidnight.sol";

import {ActivityManifestScript} from "./ActivityManifest.sol";
import {MerkleProgram} from "./MerkleProgram.sol";
import {IUpstreamAavePool, IUpstreamSpoke} from "../protocols/UpstreamAave.sol";
import {IUpstreamEVault, IUpstreamEVC} from "../protocols/UpstreamEuler.sol";
import {TestnetCollateralOracle, TestnetMidnightLender} from "../protocols/TestnetNativeLending.sol";
import {TestnetPermissions} from "../TestnetPermissions.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {OP_EQUAL, OP_READ, OP_SUB, OP_ADD, OP_MUL_DIV, SRC_RESULT} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Id, IMorpho, IMorphoBase, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";

import {IdLib} from "morpho-midnight/src/libraries/IdLib.sol";
import {Market, Offer} from "morpho-midnight/src/interfaces/IMidnight.sol";
import {TickLib} from "morpho-midnight/src/libraries/TickLib.sol";

/// @title MerkleMarketActivityScript
/// @notice Executes finite funded protocol loops from production Merkle-account custody.
/// @dev Reads and binds changed balances within each atomic RecipeExecutor transaction.
contract MerkleMarketActivityScript is ActivityManifestScript {
    using Math for uint256;
    using SafeERC20 for IERC20;

    struct AccountRun {
        MerkleProgram.Context program;
        address asset;
        address collateral;
        uint256 amount;
        uint256 collateralAmount;
        uint256 loan;
    }

    struct Build {
        MerkleProgram.Program program;
        uint256 actions;
        uint256 queries;
        uint256 steps;
        uint256 groups;
    }

    /* STATE VARIABLES */

    bool public collateralWaiting;
    bool public midnightWaiting;
    bytes public midnightParams;
    uint256 public fundedAssets;
    uint256 public fundedCollateral;
    uint256[7] public familyCounts;
    bool[7] public occupiedDebt;

    /* PUBLIC FUNCTIONS */

    function run() public {
        (string memory json, string memory market, address owner, uint256 seed) = _manifest();
        address asset = _address(json, market, "asset");
        bytes32 symbol = keccak256(bytes(IERC20Metadata(asset).symbol()));
        uint256 price = symbol == keccak256("WETH")
            ? 3000
            : symbol == keccak256("tBTC") || symbol == keccak256("WBTC") || symbol == keccak256("cbBTC") ? 60_000 : 1;
        uint256 amount = vm.envOr(
            "TESTNET_MERKLE_AMOUNT",
            vm.parseJsonUint(json, ".seedAssets") * 10 ** IERC20Metadata(asset).decimals() / price / 1000
                * (25 + seed % 76) / 100
        );
        uint256[7] memory counts = runBase(json, market, owner, amount, _broadcast());
        uint256[] memory evidence = new uint256[](counts.length);
        bool[] memory occupied = new bool[](counts.length);
        uint256 executed;
        for (uint256 i; i < counts.length; ++i) {
            evidence[i] = counts[i];
            occupied[i] = occupiedDebt[i];
            executed += counts[i];
        }
        _result(
            executed > 0,
            0,
            0,
            fundedAssets == 0
                ? "asset funding"
                : collateralWaiting ? "collateral funding" : midnightWaiting ? "midnight funding" : ""
        );
        vm.serializeUint("activity-result", "families", evidence);
        vm.serializeBool("activity-result", "occupiedDebt", occupied);
        vm.serializeUint("activity-result", "fundedAssets", fundedAssets);
        vm.serializeUint("activity-result", "fundedCollateral", fundedCollateral);
        string memory result = vm.serializeBytes("activity-result", "midnightParams", midnightParams);
        vm.writeJson(result, vm.envString("TESTNET_ACTIVITY_RESULT"));
    }

    /// @notice Returns account-originated operation counts for core, Aave3, Euler, MorphoVault, Blue,
    /// Midnight and Aave4. Funds custody from existing owner balances and restores the original root and recipe.
    function runBase(string memory json, string memory market, address owner, uint256 amount, bool broadcast)
        public
        returns (uint256[7] memory counts)
    {
        if (
            owner == address(0) || vm.parseJsonAddress(json, ".owner") != owner
                || vm.parseJsonUint(json, ".chainId") != block.chainid
        ) revert InvalidActivity();
        AccountRun memory context;
        context.program = MerkleProgram.Context({
            owner: owner,
            account: _address(json, market, "account"),
            rootRegistry: _address(json, market, "rootRegistry"),
            executor: _address(json, market, "executor"),
            baseActions: abi.decode(
                vm.parseJsonBytes(json, string.concat(market, ".merkleActions")), (IMerkleAccount.Action[])
            ),
            baseRecipe: abi.decode(vm.parseJsonBytes(json, string.concat(market, ".recipeSteps")), (bytes[]))
        });
        MerkleProgram.validate(context.program);
        context.asset = _address(json, market, "asset");
        context.collateral = vm.parseJsonAddress(json, ".collateral");
        context.amount = Math.min(amount, IERC20(context.asset).balanceOf(owner));
        fundedAssets = 0;
        fundedCollateral = 0;
        collateralWaiting = false;
        midnightWaiting = false;
        midnightParams = "";
        delete occupiedDebt;
        if (context.amount < 20) {
            familyCounts = counts;
            return counts;
        }
        {
            address midnightPool = _address(json, market, "morphoMidnight");
            Market memory midnight =
                abi.decode(vm.parseJsonBytes(json, string.concat(market, ".morphoMidnightParams")), (Market));
            occupiedDebt[5] = IMidnight(midnightPool).debt(IdLib.toId(midnight), context.program.account) > 0;
            if (block.timestamp >= midnight.maturity) {
                midnight.maturity = block.timestamp + 30 days;
                occupiedDebt[5] =
                    occupiedDebt[5] || IMidnight(midnightPool).debt(IdLib.toId(midnight), context.program.account) > 0;
            }
        }
        MarketParams memory blue =
            abi.decode(vm.parseJsonBytes(json, string.concat(market, ".morphoBlueParams")), (MarketParams));
        if (blue.loanToken != context.asset || blue.collateralToken != context.collateral) revert InvalidActivity();
        occupiedDebt[1] = IERC20(
                IUpstreamAavePool(_address(json, market, "aavePool")).getReserveVariableDebtToken(context.asset)
            )
            .balanceOf(context.program.account) > 0;
        occupiedDebt[2] = IUpstreamEVault(_address(json, market, "eulerVault")).debtOf(context.program.account) > 0;
        occupiedDebt[4] = IMorpho(_address(json, market, "morphoBlue"))
            .position(Id.wrap(keccak256(abi.encode(blue))), context.program.account)
            .borrowShares > 0;
        uint256 collateralFamilies = (occupiedDebt[2] ? 0 : 1) + (occupiedDebt[4] && occupiedDebt[5] ? 0 : 1);
        uint256 collateralPrice = TestnetCollateralOracle(blue.oracle).price();
        context.collateralAmount = Math.min(
            context.amount.mulDiv(2e36, collateralPrice, Math.Rounding.Ceil),
            IERC20(context.collateral).balanceOf(owner) / 3
        );
        context.loan = Math.min(context.amount / 4, context.collateralAmount.mulDiv(collateralPrice, 2e36));
        collateralWaiting = context.loan < 2;
        _start(owner, broadcast);
        IERC20(context.asset).safeTransfer(context.program.account, context.amount);
        fundedAssets = context.amount;
        if (!collateralWaiting && collateralFamilies > 0) {
            fundedCollateral = context.collateralAmount * collateralFamilies;
            IERC20(context.collateral).safeTransfer(context.program.account, fundedCollateral);
        }
        counts[0] = _vault(context, _address(json, market, "vault"));
        counts[1] = _aave(context, _address(json, market, "aavePool"));
        if (!collateralWaiting) {
            counts[2] = _euler(
                context,
                _address(json, market, "eulerVault"),
                _address(json, market, "eulerCollateralVault"),
                _address(json, market, "eulerEVC")
            );
        }
        counts[3] = _vault(context, _address(json, market, "morphoVault"));
        if (!collateralWaiting) {
            counts[4] = _blue(context, _address(json, market, "morphoBlue"), blue);
            counts[5] = _midnight(
                context,
                _address(json, market, "morphoMidnight"),
                _address(json, market, "midnightLender"),
                vm.parseJsonBytes(json, string.concat(market, ".morphoMidnightParams"))
            );
        }
        counts[6] = _aaveV4Reserve(
            context, _address(json, market, "aaveV4"), vm.parseJsonUint(json, string.concat(market, ".aaveV4ReserveId"))
        );
        _stop(broadcast);
        familyCounts = counts;
    }

    /* INTERNAL FUNCTIONS */

    function _vault(AccountRun memory context, address pool) internal returns (uint256) {
        if (IERC4626(pool).asset() != context.asset) revert InvalidActivity();
        Build memory build = _newBuild();
        uint256 balances = _query(build, pool, abi.encodeCall(IERC20.balanceOf, (context.program.account)), 0);
        uint256 beforeShares = _read(build, balances);
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, context.amount)), 0));
        _manage(
            build, _action(build, pool, abi.encodeCall(IERC4626.deposit, (context.amount, context.program.account)), 0)
        );
        uint256 delta = _binary(build, OP_SUB, _result(_read(build, balances)), _result(beforeShares));
        _manageBound(
            build,
            _action(
                build, pool, abi.encodeCall(IERC4626.redeem, (0, context.program.account, context.program.account)), 4
            ),
            4,
            delta
        );
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, uint256(0))), 0));
        _binary(build, OP_EQUAL, _result(_read(build, balances)), _result(beforeShares));
        MerkleProgram.execute(context.program, _finish(build));
        return 2;
    }

    function _aave(AccountRun memory context, address pool) internal returns (uint256) {
        address debtToken = IUpstreamAavePool(pool).getReserveVariableDebtToken(context.asset);
        if (IERC20(debtToken).balanceOf(context.program.account) > 0) return 0;
        Build memory build = _newBuild();
        uint256 receipts = _query(
            build,
            IUpstreamAavePool(pool).getReserveAToken(context.asset),
            abi.encodeCall(IERC20.balanceOf, (context.program.account)),
            0
        );
        uint256 debt = _query(build, debtToken, abi.encodeCall(IERC20.balanceOf, (context.program.account)), 0);
        uint256 cash = _query(build, context.asset, abi.encodeCall(IERC20.balanceOf, (context.program.account)), 0);
        uint256 beforeShares = _read(build, receipts);
        _binary(build, OP_EQUAL, _result(_read(build, debt)), 0);
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, type(uint256).max)), 0));
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IUpstreamAavePool.supply, (context.asset, context.amount, context.program.account, uint16(0))
                ),
                0
            )
        );
        uint256 beforeCash = _read(build, cash);
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IUpstreamAavePool.borrow,
                    (context.asset, context.amount / 4, uint256(2), uint16(0), context.program.account)
                ),
                0
            )
        );
        uint256 borrowed = _binary(build, OP_SUB, _result(_read(build, cash)), _result(beforeCash));
        _manageBound(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IUpstreamAavePool.supply, (context.asset, uint256(0), context.program.account, uint16(0))
                ),
                36
            ),
            36,
            borrowed
        );
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IUpstreamAavePool.borrow,
                    (context.asset, context.amount / 4, uint256(2), uint16(0), context.program.account)
                ),
                0
            )
        );
        uint256 repayCash = _binary(build, OP_ADD, _result(_read(build, debt)), 1);
        _manageBound(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(IUpstreamAavePool.withdraw, (context.asset, uint256(0), context.program.account)),
                36
            ),
            36,
            repayCash
        );
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IUpstreamAavePool.repay, (context.asset, type(uint256).max, uint256(2), context.program.account)
                ),
                0
            )
        );
        uint256 delta = _binary(build, OP_SUB, _result(_read(build, receipts)), _result(beforeShares));
        _manageBound(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(IUpstreamAavePool.withdraw, (context.asset, uint256(0), context.program.account)),
                36
            ),
            36,
            delta
        );
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, uint256(0))), 0));
        _binary(build, OP_EQUAL, _result(_read(build, debt)), 0);
        MerkleProgram.execute(context.program, _finish(build));
        return 7;
    }

    function _euler(AccountRun memory context, address pool, address collateralVault, address evc)
        internal
        returns (uint256)
    {
        if (IERC4626(pool).asset() != context.asset || IERC4626(collateralVault).asset() != context.collateral) revert InvalidActivity();
        if (
            IUpstreamEVault(pool).debtOf(context.program.account) > 0
                || IUpstreamEVC(evc).getControllers(context.program.account).length > 0
        ) return 0;
        Build memory build = _newBuild();
        uint256 receipts = _query(build, pool, abi.encodeCall(IERC20.balanceOf, (context.program.account)), 0);
        uint256 collateralShares =
            _query(build, collateralVault, abi.encodeCall(IERC20.balanceOf, (context.program.account)), 0);
        uint256 debt = _query(build, pool, abi.encodeCall(IUpstreamEVault.debtOf, (context.program.account)), 0);
        uint256 beforeShares = _read(build, receipts);
        uint256 beforeCollateral = _read(build, collateralShares);
        _binary(build, OP_EQUAL, _result(_read(build, debt)), 0);
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, type(uint256).max)), 0));
        _manage(
            build,
            _action(
                build,
                context.collateral,
                abi.encodeCall(IERC20.approve, (collateralVault, context.collateralAmount)),
                0
            )
        );
        _manage(
            build,
            _action(
                build,
                collateralVault,
                abi.encodeCall(IERC4626.deposit, (context.collateralAmount, context.program.account)),
                0
            )
        );
        _manage(
            build,
            _action(
                build, evc, abi.encodeCall(IUpstreamEVC.enableCollateral, (context.program.account, collateralVault)), 0
            )
        );
        _manage(
            build,
            _action(build, evc, abi.encodeCall(IUpstreamEVC.enableController, (context.program.account, pool)), 0)
        );
        _manage(
            build, _action(build, pool, abi.encodeCall(IERC4626.deposit, (context.amount, context.program.account)), 0)
        );
        _manage(
            build,
            _action(build, pool, abi.encodeCall(IUpstreamEVault.borrow, (context.loan, context.program.account)), 0)
        );
        _manage(
            build,
            _action(build, pool, abi.encodeCall(IUpstreamEVault.repay, (type(uint256).max, context.program.account)), 0)
        );
        uint256 delta = _binary(build, OP_SUB, _result(_read(build, receipts)), _result(beforeShares));
        _manageBound(
            build,
            _action(
                build, pool, abi.encodeCall(IERC4626.redeem, (0, context.program.account, context.program.account)), 4
            ),
            4,
            delta
        );
        uint256 collateralDelta =
            _binary(build, OP_SUB, _result(_read(build, collateralShares)), _result(beforeCollateral));
        _manageBound(
            build,
            _action(
                build,
                collateralVault,
                abi.encodeCall(IERC4626.redeem, (0, context.program.account, context.program.account)),
                4
            ),
            4,
            collateralDelta
        );
        _manage(build, _action(build, pool, abi.encodeCall(IUpstreamEVault.disableController, ()), 0));
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, uint256(0))), 0));
        _manage(
            build, _action(build, context.collateral, abi.encodeCall(IERC20.approve, (collateralVault, uint256(0))), 0)
        );
        _binary(build, OP_EQUAL, _result(_read(build, debt)), 0);
        _binary(build, OP_EQUAL, _result(_read(build, receipts)), _result(beforeShares));
        _binary(build, OP_EQUAL, _result(_read(build, collateralShares)), _result(beforeCollateral));
        MerkleProgram.execute(context.program, _finish(build));
        return 8;
    }

    function _blue(AccountRun memory context, address pool, MarketParams memory params) internal returns (uint256) {
        Id id = Id.wrap(keccak256(abi.encode(params)));
        if (IMorpho(pool).position(id, context.program.account).borrowShares > 0) return 0;
        Build memory build = _newBuild();
        uint256 supplyShares = _query(build, pool, abi.encodeCall(IMorpho.position, (id, context.program.account)), 0);
        uint256 borrowShares = _query(build, pool, abi.encodeCall(IMorpho.position, (id, context.program.account)), 32);
        uint256 cash = _query(build, context.asset, abi.encodeCall(IERC20.balanceOf, (context.program.account)), 0);
        uint256 beforeShares = _read(build, supplyShares);
        _binary(build, OP_EQUAL, _result(_read(build, borrowShares)), 0);
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, type(uint256).max)), 0));
        _manage(
            build,
            _action(build, context.collateral, abi.encodeCall(IERC20.approve, (pool, context.collateralAmount)), 0)
        );
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(IMorphoBase.supply, (params, context.amount, 0, context.program.account, bytes(""))),
                0
            )
        );
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IMorphoBase.supplyCollateral, (params, context.collateralAmount, context.program.account, bytes(""))
                ),
                0
            )
        );
        uint256 beforeCash = _read(build, cash);
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IMorphoBase.borrow, (params, context.loan, 0, context.program.account, context.program.account)
                ),
                0
            )
        );
        uint256 borrowed = _binary(build, OP_SUB, _result(_read(build, cash)), _result(beforeCash));
        _manageBound(
            build,
            _action(
                build, pool, abi.encodeCall(IMorphoBase.supply, (params, 0, 0, context.program.account, bytes(""))), 164
            ),
            164,
            borrowed
        );
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IMorphoBase.borrow, (params, context.loan / 2, 0, context.program.account, context.program.account)
                ),
                0
            )
        );
        uint256 delta = _binary(build, OP_SUB, _result(_read(build, supplyShares)), _result(beforeShares));
        _manageBound(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(IMorphoBase.withdraw, (params, 0, 0, context.program.account, context.program.account)),
                196
            ),
            196,
            delta
        );
        uint256 repayShares = _read(build, borrowShares);
        _manageBound(
            build,
            _action(
                build, pool, abi.encodeCall(IMorphoBase.repay, (params, 0, 0, context.program.account, bytes(""))), 196
            ),
            196,
            repayShares
        );
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IMorphoBase.withdrawCollateral,
                    (params, context.collateralAmount, context.program.account, context.program.account)
                ),
                0
            )
        );
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, uint256(0))), 0));
        _manage(build, _action(build, context.collateral, abi.encodeCall(IERC20.approve, (pool, uint256(0))), 0));
        _binary(build, OP_EQUAL, _result(_read(build, borrowShares)), 0);
        _binary(build, OP_EQUAL, _result(_read(build, supplyShares)), _result(beforeShares));
        MerkleProgram.execute(context.program, _finish(build));
        return 8;
    }

    function _midnight(AccountRun memory context, address pool, address lender, bytes memory encoded)
        internal
        returns (uint256)
    {
        Market memory params = abi.decode(encoded, (Market));
        if (
            params.midnight != pool || params.loanToken != context.asset || params.chainId != block.chainid
                || params.collateralParams.length != 1 || params.collateralParams[0].token != context.collateral
                || TestnetMidnightLender(lender).midnight() != pool
        ) revert InvalidActivity();
        // An occupied original market remains occupied after maturity; do not silently roll its debt into a new loop.
        if (IMidnight(pool).debt(IdLib.toId(params), context.program.account) > 0) {
            occupiedDebt[5] = true;
            return 0;
        }
        if (block.timestamp >= params.maturity) params.maturity = block.timestamp + 30 days;
        midnightParams = abi.encode(params);
        if (IMidnight(pool).debt(IdLib.toId(params), context.program.account) > 0) {
            occupiedDebt[5] = true;
            return 0;
        }
        uint256 loan = Math.min(context.loan, IERC20(context.asset).balanceOf(lender));
        if (loan < 2) {
            midnightWaiting = true;
            return 0;
        }
        Offer memory offer = Offer({
            market: params,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: params.maturity,
            tick: TickLib.priceToTick(99e16, 4),
            group: keccak256(
                abi.encode(
                    "merkle-account-loop",
                    context.program.account,
                    TestnetMidnightLender(lender).approvedOffer(),
                    block.number
                )
            ),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: lender,
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: uint128(loan),
            continuousFeeCap: type(uint256).max
        });
        TestnetMidnightLender(lender).approveOffer(offer, context.program.account);
        Build memory build = _newBuild();
        bytes32 id = IdLib.toId(params);
        uint256 debt = _query(build, pool, abi.encodeCall(IMidnight.debt, (id, context.program.account)), 0);
        _binary(build, OP_EQUAL, _result(_read(build, debt)), 0);
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, type(uint256).max)), 0));
        _manage(
            build,
            _action(build, context.collateral, abi.encodeCall(IERC20.approve, (pool, context.collateralAmount)), 0)
        );
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IMidnight.supplyCollateral, (params, uint256(0), context.collateralAmount, context.program.account)
                ),
                0
            )
        );
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IMidnight.take,
                    (offer, bytes(""), loan, context.program.account, context.program.account, address(0), bytes(""))
                ),
                0
            )
        );
        uint256 units = _read(build, debt);
        _manageBound(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(IMidnight.repay, (params, uint256(0), context.program.account, address(0), bytes(""))),
                36
            ),
            36,
            units
        );
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(
                    IMidnight.withdrawCollateral,
                    (params, uint256(0), context.collateralAmount, context.program.account, context.program.account)
                ),
                0
            )
        );
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, uint256(0))), 0));
        _manage(build, _action(build, context.collateral, abi.encodeCall(IERC20.approve, (pool, uint256(0))), 0));
        _binary(build, OP_EQUAL, _result(_read(build, debt)), 0);
        MerkleProgram.execute(context.program, _finish(build));
        // Reserve pending continuous fees and limit recycling to current net credit and actual repaid cash.
        (uint128 credit, uint128 pendingFee,) = IMidnight(pool).updatePositionView(params, id, lender);
        (bool success, bytes memory state) = pool.staticcall(abi.encodeWithSignature("marketState(bytes32)", id));
        if (!success) revert InvalidActivity();
        (,, uint256 withdrawable) = abi.decode(state, (uint256, uint256, uint256));
        uint256 recyclable = Math.min(loan, Math.min(uint256(credit).saturatingSub(pendingFee), withdrawable));
        if (recyclable > 0) TestnetMidnightLender(lender).withdraw(params, recyclable, lender);
        return 4;
    }

    function _aaveV4Reserve(AccountRun memory context, address pool, uint256 reserveId) internal returns (uint256) {
        Build memory build = _newBuild();
        uint256 assets = _query(
            build, pool, abi.encodeCall(IUpstreamSpoke.getUserSuppliedAssets, (reserveId, context.program.account)), 0
        );
        uint256 beforeAssets = _read(build, assets);
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, context.amount)), 0));
        _manage(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(IUpstreamSpoke.supply, (reserveId, context.amount, context.program.account)),
                0
            )
        );
        uint256 delta = _binary(build, OP_SUB, _result(_read(build, assets)), _result(beforeAssets));
        _manageBound(
            build,
            _action(
                build,
                pool,
                abi.encodeCall(IUpstreamSpoke.withdraw, (reserveId, uint256(0), context.program.account)),
                36
            ),
            36,
            delta
        );
        _manage(build, _action(build, context.asset, abi.encodeCall(IERC20.approve, (pool, uint256(0))), 0));
        MerkleProgram.execute(context.program, _finish(build));
        return 2;
    }

    function _newBuild() internal pure returns (Build memory build) {
        build.program = MerkleProgram.Program({
            actions: new IMerkleAccount.Action[](24),
            queries: new bytes[](8),
            steps: new bytes[](48),
            groups: new uint256[][](24),
            inputs: new uint256[](0)
        });
    }

    function _action(Build memory build, address target, bytes memory data, uint256 offset)
        internal
        pure
        returns (uint256 index)
    {
        index = build.actions++;
        build.program.actions[index] = TestnetPermissions.action(target, data, offset);
    }

    function _query(Build memory build, address target, bytes memory data, uint256 offset)
        internal
        pure
        returns (uint256 index)
    {
        index = build.queries++;
        build.program.queries[index] = abi.encode(target, data, new uint256[](0), offset);
    }

    function _read(Build memory build, uint256 query) internal pure returns (uint256 index) {
        index = build.steps++;
        build.program.steps[index] = bytes.concat(bytes1(OP_READ), abi.encode(query));
    }

    function _binary(Build memory build, uint8 operation, uint256 a, uint256 b) internal pure returns (uint256 index) {
        index = build.steps++;
        build.program.steps[index] = bytes.concat(bytes1(operation), abi.encode(a, b));
    }

    function _manage(Build memory build, uint256 action) internal pure {
        uint256[] memory indices = new uint256[](1);
        indices[0] = action;
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](0);
        build.program.groups[build.groups++] = indices;
        build.program.steps[build.steps++] = MerkleProgram.step(build.program.actions, indices, bindings);
    }

    function _manageBound(Build memory build, uint256 action, uint256 offset, uint256 resultIndex) internal pure {
        uint256[] memory indices = new uint256[](1);
        indices[0] = action;
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](1);
        bindings[0][0] = (offset << 224) | _result(resultIndex);
        build.program.groups[build.groups++] = indices;
        build.program.steps[build.steps++] = MerkleProgram.step(build.program.actions, indices, bindings);
    }

    function _result(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_RESULT) << 216) | index;
    }

    function _finish(Build memory build) internal pure returns (MerkleProgram.Program memory program) {
        program = MerkleProgram.Program({
            actions: new IMerkleAccount.Action[](build.actions),
            queries: new bytes[](build.queries),
            steps: new bytes[](build.steps),
            groups: new uint256[][](build.groups),
            inputs: new uint256[](0)
        });
        for (uint256 i; i < build.actions; ++i) {
            program.actions[i] = build.program.actions[i];
        }
        for (uint256 i; i < build.queries; ++i) {
            program.queries[i] = build.program.queries[i];
        }
        for (uint256 i; i < build.steps; ++i) {
            program.steps[i] = build.program.steps[i];
        }
        for (uint256 i; i < build.groups; ++i) {
            program.groups[i] = build.program.groups[i];
        }
    }
}
