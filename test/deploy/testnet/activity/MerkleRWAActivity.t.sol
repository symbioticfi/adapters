// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {LiquidLaneAdapter} from "src/contracts/LiquidLaneAdapter.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {AccountRegistry} from "src/contracts/ll-adapter/AccountRegistry.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {ActivityContext} from "script/deploy/testnet/activity/ActivityContext.sol";
import {
    IMerkleRWAActivityScript,
    MerkleRWAActivityScript
} from "script/deploy/testnet/activity/MerkleRWAActivity.s.sol";
import {YieldActivityScript} from "script/deploy/testnet/activity/YieldActivity.s.sol";
import {TestnetPermissions} from "script/deploy/testnet/TestnetPermissions.sol";
import {TestnetCatalog} from "script/deploy/testnet/catalog/TestnetCatalog.sol";
import {TestnetToken} from "script/deploy/testnet/protocols/TestnetAssets.sol";
import {TestnetCowSettlement} from "script/deploy/testnet/protocols/TestnetServices.sol";
import {TestnetYieldDeploymentScript} from "script/deploy/testnet/protocols/TestnetYieldRedemptions.sol";
import {MerkleAdapterOracleMock, MerkleAdapterVaultRegistry} from "test/adapters/MerkleAdapter.t.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {IAdapter} from "src/interfaces/IAdapter.sol";
import {ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {IChainlinkOracle} from "src/interfaces/ll-adapter/oracles/IChainlinkOracle.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";
import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title MerkleRWAActivityTest
/// @notice Verifies actual funded custody and native signing through production Merkle and Liquid Lane contracts.
contract MerkleRWAActivityTest is Test {
    /* STATE VARIABLES */

    address internal _asset;
    address internal _vault;
    address internal _registry;
    address internal _lane;
    address internal _account;
    address internal _rootRegistry;
    address internal _executor;
    address internal _settlement;
    address internal _activity;
    address internal _yieldDeployment;
    address internal _yieldActivity;
    address internal _previousMaker;
    IMerkleAccount.Action[] internal _baseActions;
    bytes32 internal _baseRoot;

    /* PUBLIC FUNCTIONS */

    function setUp() public {
        vm.chainId(31_337);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        _asset = address(new TestnetToken("Funded testnet cash", "USDC", 6, address(this)));
        _vault = address(new MerkleRWAAssetVault(_asset));
        MerkleRWAAssetVault(_vault).setDelegator(address(new MerkleRWAFundedDelegator(_vault)));
        address vaultRegistry = address(new MerkleAdapterVaultRegistry());
        MerkleAdapterVaultRegistry(vaultRegistry).add(_vault);
        address factory = address(new AdapterFactory(address(this)));
        address oracleFactory = address(new MigratablesFactory(address(this)));
        MigratablesFactory(oracleFactory).whitelist(address(new MerkleAdapterOracleMock(oracleFactory)));
        _rootRegistry = address(new RootRegistry(address(this)));
        address capabilities = address(new CapabilitiesRegistry(address(this)));
        AdapterFactory(factory)
            .whitelist(
                address(
                    new MerkleAdapter(
                        vaultRegistry,
                        factory,
                        oracleFactory,
                        createMerkleAccountFactory(address(this), factory, _rootRegistry, capabilities)
                    )
                )
            );
        address adapter = AdapterFactory(factory)
            .create(1, address(this), abi.encode(_vault, abi.encode(merkleAdapterInitParams(address(this)))));
        _account = IMerkleAdapter(adapter).account();
        _executor = address(new RecipeExecutor(address(this), _account));
        RecipeExecutor(_executor).setCaller(address(this));
        RecipeExecutor(_executor).setRecipe(new bytes[](0), new bytes[](0));
        _baseActions.push(TestnetPermissions.action(_asset, abi.encodeCall(IERC20.approve, (adapter, 0)), 0));
        (_baseRoot,) = TestnetPermissions.authorize(_baseActions);
        RootRegistry(_rootRegistry).setRoot(_account, _baseRoot);
        IMerkleAccount(_account).acceptRoot(_baseRoot);
        _registry = address(new AccountRegistry(address(this)));
        AdapterFactory(factory).whitelist(address(new LiquidLaneAdapter(vaultRegistry, factory, _registry)));
        _lane = AdapterFactory(factory)
            .create(
                2,
                address(this),
                abi.encode(
                    _vault, abi.encode(ILiquidLaneAdapter.InitParams({pauser: address(this), unpauser: address(this)}))
                )
            );
        _previousMaker = makeAddr("original funded market maker");
        ILiquidLaneAdapter(_lane).setMarketMaker(_previousMaker, true);
        _settlement = address(new TestnetCowSettlement());
        _activity = address(new MerkleRWAActivityScript());
        _yieldDeployment = address(new TestnetYieldDeploymentScript(address(this), false));
        _yieldActivity = address(new YieldActivityScript());
        TestnetToken(_asset).mint(address(this), 2_000_000e6);
        IERC20(_asset).transfer(_vault, 100_000e6);
        IERC20(_asset).transfer(_account, 1000e6);
    }

    function testEveryNativeYieldProfileBuysAndSellsFromProductionMerkleCustody() public {
        for (uint8 variant; variant < 11; ++variant) {
            (uint256 profile, address token) = _yield(variant);
            uint256 ownerShares = IERC20(token).balanceOf(address(this));
            uint256 accountCash = IERC20(_asset).balanceOf(_account);
            uint256 ownerCash = IERC20(_asset).balanceOf(address(this));
            uint256 vaultCash = IERC20(_asset).balanceOf(_vault);
            uint256 realizedCash = IAdapter(_lane).freeAssets();
            vm.recordLogs();
            IMerkleRWAActivityScript.Result memory result = MerkleRWAActivityScript(_activity)
                .runBase(_json(profile, token), ".markets[0]", profile, address(this), variant, false);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(result.executed, TestnetCatalog.profile(profile).symbol);
            assertGt(result.bought, 0);
            assertEq(result.sold, result.bought);
            assertEq(IERC20(token).balanceOf(address(this)), ownerShares - result.bought);
            assertEq(IERC20(token).balanceOf(_account), 0);
            assertEq(IERC20(_asset).balanceOf(_account), accountCash - result.cashSpent + result.cashReceived);
            assertEq(IERC20(_asset).balanceOf(address(this)), ownerCash + result.cashSpent);
            assertEq(IERC20(_asset).balanceOf(_vault), vaultCash + realizedCash - result.cashReceived);
            assertGt(IAccount(ILiquidLaneAdapter(_lane).accounts(token)).totalAssets(), 0);
            _assertCustodyLogs(logs, token, result);
            _assertRestored(token, result);
        }
    }

    function testPreviousLiquidRedemptionIsSweptBeforeNextQueuedSwap() public {
        (uint256 liquidProfile, address liquidToken) = _yield(4);
        IMerkleRWAActivityScript.Result memory first = MerkleRWAActivityScript(_activity)
            .runBase(_json(liquidProfile, liquidToken), ".markets[0]", liquidProfile, address(this), 0, false);
        address liquidAccount = ILiquidLaneAdapter(_lane).accounts(liquidToken);
        assertEq(IERC20(_asset).balanceOf(liquidAccount), first.cashSpent);
        assertEq(IAdapter(_lane).freeAssets(), first.cashSpent);
        (uint256 queuedProfile, address queuedToken) = _yield(0);
        uint256 vaultCash = IERC20(_asset).balanceOf(_vault);
        vm.recordLogs();
        IMerkleRWAActivityScript.Result memory second = MerkleRWAActivityScript(_activity)
            .runBase(_json(queuedProfile, queuedToken), ".markets[0]", queuedProfile, address(this), 0, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(second.executed);
        assertEq(IERC20(_asset).balanceOf(liquidAccount), 0);
        assertEq(IERC20(_asset).balanceOf(_vault), vaultCash + first.cashSpent - second.cashReceived);
        assertEq(IAdapter(_lane).freeAssets(), 0);
        uint256 sweptToAdapter;
        uint256 sweptToVault;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != _asset || logs[i].topics[0] != keccak256("Transfer(address,address,uint256)")) {
                continue;
            }
            if (
                logs[i].topics[1] == bytes32(uint256(uint160(liquidAccount)))
                    && logs[i].topics[2] == bytes32(uint256(uint160(_lane)))
            ) sweptToAdapter += abi.decode(logs[i].data, (uint256));
            if (
                logs[i].topics[1] == bytes32(uint256(uint160(_lane)))
                    && logs[i].topics[2] == bytes32(uint256(uint160(_vault)))
            ) sweptToVault += abi.decode(logs[i].data, (uint256));
        }
        assertEq(sweptToAdapter, first.cashSpent);
        assertEq(sweptToVault, first.cashSpent);
        _assertCustodyLogs(logs, queuedToken, second);
        _assertRestored(queuedToken, second);
    }

    function testNativeCoWDigestIsRevokedAndNeitherPresignNorReplayCanSpendCash() public {
        (uint256 profile, address token) = _yield(4);
        vm.recordLogs();
        IMerkleRWAActivityScript.Result memory result = MerkleRWAActivityScript(_activity)
            .runBase(_json(profile, token), ".markets[0]", profile, address(this), 7, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        GPv2Order.Data memory order;
        bool signed;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == _account
                    && logs[i].topics[0] == keccak256("Sign(bytes32,bytes32,bytes,(uint256,uint256,uint256)[])")
            ) {
                (bytes memory buffer,) = abi.decode(logs[i].data, (bytes, IMerkleAccount.Hash[]));
                (bytes32 typeHash, GPv2Order.Data memory value) = abi.decode(buffer, (bytes32, GPv2Order.Data));
                assertEq(typeHash, GPv2Order.TYPE_HASH);
                assertEq(logs[i].topics[1], result.digest);
                assertEq(logs[i].topics[2], TestnetCowSettlement(_settlement).domainSeparator());
                order = value;
                signed = true;
            }
        }
        assertTrue(signed);
        assertEq(order.receiver, _account);
        assertEq(address(order.sellToken), _asset);
        assertEq(address(order.buyToken), token);
        assertFalse(order.partiallyFillable);
        assertEq(TestnetCowSettlement(_settlement).preSignature(result.orderUid), 0);
        assertEq(IMerkleAccount(_account).isValidSignature(result.digest, ""), bytes4(0xffffffff));
        uint256 cash = IERC20(_asset).balanceOf(_account);
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        TestnetCowSettlement(_settlement).fillContract(order, result.orderUid, result.cashSpent, result.bought, "");
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        TestnetCowSettlement(_settlement).fill(order, result.orderUid, result.cashSpent, result.bought);
        assertEq(IERC20(_asset).balanceOf(_account), cash);
        assertNotEq(IERC1271.isValidSignature.selector, bytes4(0xffffffff));
    }

    function testFuzzPurchaseNeverExceedsLiveLaneCapacity(uint96 capacity) public {
        capacity = uint96(bound(capacity, 1e6, 30e6));
        (uint256 profile, address token) = _yield(4);
        ILiquidLaneAdapter(_lane).setLimit(token, capacity);
        IMerkleRWAActivityScript.Result memory result = MerkleRWAActivityScript(_activity)
            .runBase(_json(profile, token), ".markets[0]", profile, address(this), 0, false);
        assertTrue(result.executed);
        assertLe(result.cashSpent, capacity);
        assertLe(result.cashReceived, capacity);
        assertLe(IAccount(ILiquidLaneAdapter(_lane).accounts(token)).totalAssets(), capacity);
        _assertRestored(token, result);
    }

    function testZeroAccountCashDoesNotBorrowVaultReservesOrCreateAnOrder() public {
        (uint256 profile, address token) = _yield(4);
        _drainAccount(0);
        uint256 shares = IERC20(token).balanceOf(address(this));
        uint256 reserves = IERC20(_asset).balanceOf(_vault);
        vm.recordLogs();
        IMerkleRWAActivityScript.Result memory result = MerkleRWAActivityScript(_activity)
            .runBase(_json(profile, token), ".markets[0]", profile, address(this), 0, false);
        assertFalse(result.executed);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(IERC20(token).balanceOf(address(this)), shares);
        assertEq(IERC20(_asset).balanceOf(_vault), reserves);
        _assertRestored(token, result);
    }

    function testPurchaseUsesOnlyAccountCashAndHonorsConfiguredDiscount() public {
        (uint256 profile, address token) = _yield(4);
        _drainAccount(5e6);
        ILiquidLaneAdapter(_lane).setMinDiscount(token, 100_000);
        IMerkleRWAActivityScript.Result memory result = MerkleRWAActivityScript(_activity)
            .runBase(_json(profile, token), ".markets[0]", profile, address(this), 0, false);
        assertTrue(result.executed);
        assertEq(result.cashSpent, 5e6);
        assertEq(result.cashReceived, 45e5);
        assertEq(IERC20(_asset).balanceOf(_account), result.cashReceived);
        _assertRestored(token, result);
    }

    function testZeroCapacityLeavesSolverInventoryAndAccountCashUntouched() public {
        (uint256 profile, address token) = _yield(4);
        ILiquidLaneAdapter(_lane).setLimit(token, 0);
        uint256 shares = IERC20(token).balanceOf(address(this));
        uint256 cash = IERC20(_asset).balanceOf(_account);
        IMerkleRWAActivityScript.Result memory result = MerkleRWAActivityScript(_activity)
            .runBase(_json(profile, token), ".markets[0]", profile, address(this), 0, false);
        assertFalse(result.executed);
        assertEq(IERC20(token).balanceOf(address(this)), shares);
        assertEq(IERC20(_asset).balanceOf(_account), cash);
        _assertRestored(token, result);
    }

    function testRejectsWrongOwnerBeforeAnyMutation() public {
        (uint256 profile, address token) = _yield(4);
        string memory json = _json(profile, token);
        vm.expectRevert(IMerkleRWAActivityScript.InvalidContext.selector);
        MerkleRWAActivityScript(_activity).runBase(json, ".markets[0]", profile, makeAddr("wrong owner"), 0, false);
        assertEq(IMerkleAccount(_account).root(), _baseRoot);
        assertEq(ILiquidLaneAdapter(_lane).marketMaker(), _previousMaker);
    }

    /* INTERNAL FUNCTIONS */

    function _yield(uint8 variant) internal returns (uint256 profile, address token) {
        for (uint256 i; i < TestnetCatalog.count(); ++i) {
            TestnetCatalog.Profile memory candidate = TestnetCatalog.profile(i);
            if (candidate.mechanism == 5 && candidate.variant == variant) profile = i;
        }
        address factory = address(new MigratablesFactory(address(this)));
        address oracle;
        address endpoint;
        address implementation;
        (token, oracle, endpoint, implementation) =
            TestnetYieldDeploymentScript(_yieldDeployment).deploy(factory, _settlement, _asset, variant);
        MigratablesFactory(factory).whitelist(implementation);
        AccountRegistry(_registry).setAccountFactory(_asset, token, factory);
        ILiquidLaneAdapter(_lane).addTokenToRedeem(token);
        ILiquidLaneAdapter(_lane).setLimit(token, 10_000e6);
        TestnetYieldDeploymentScript(_yieldDeployment).seed(token, endpoint, variant, 1000e6, address(this));
        YieldActivityScript(_yieldActivity)
            .runBase(
                ActivityContext({
                    owner: address(this),
                    asset: _asset,
                    token: token,
                    endpoint: endpoint,
                    feed: variant == 8 || variant == 9 ? IChainlinkOracle(oracle).AGGREGATOR_0() : address(0),
                    oracle: oracle,
                    account: ILiquidLaneAdapter(_lane).accounts(token),
                    profile: profile,
                    kind: 5,
                    variant: variant,
                    assets: 0,
                    seed: 0,
                    cursor: 0
                }),
                false
            );
    }

    function _json(uint256 profile, address token) internal returns (string memory json) {
        vm.serializeJson("merkle-rwa-market", "{}");
        vm.serializeAddress("merkle-rwa-market", "asset", _asset);
        vm.serializeAddress("merkle-rwa-market", "vault", _vault);
        vm.serializeAddress("merkle-rwa-market", "liquidLaneAdapter", _lane);
        vm.serializeAddress("merkle-rwa-market", "account", _account);
        vm.serializeAddress("merkle-rwa-market", "rootRegistry", _rootRegistry);
        vm.serializeAddress("merkle-rwa-market", "executor", _executor);
        vm.serializeBytes("merkle-rwa-market", "merkleActions", abi.encode(_baseActions));
        vm.serializeBytes("merkle-rwa-market", "recipeSteps", abi.encode(new bytes[](0)));
        uint256[] memory profiles = new uint256[](1);
        profiles[0] = profile;
        vm.serializeUint("merkle-rwa-market", "rwaProfiles", profiles);
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        string memory row = vm.serializeAddress("merkle-rwa-market", "rwaTokens", tokens);
        json = string.concat(
            '{"schemaVersion":1,"chainId":',
            vm.toString(block.chainid),
            ',"seedAssets":100000,"owner":"',
            vm.toString(address(this)),
            '","cowSettlement":"',
            vm.toString(_settlement),
            '","markets":[',
            row,
            "]}"
        );
    }

    function _assertCustodyLogs(Vm.Log[] memory logs, address token, IMerkleRWAActivityScript.Result memory result)
        internal
        view
    {
        uint256 trades;
        uint256 swaps;
        uint256 accountTransfers;
        uint256 manages;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == _settlement
                    && logs[i].topics[0] == keccak256("Trade(address,address,address,uint256,uint256,uint256,bytes)")
            ) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(_account))));
                ++trades;
            } else if (
                logs[i].emitter == _lane && logs[i].topics[0] == keccak256("DoSwap((address,address,uint256,uint256))")
            ) {
                ILiquidLaneAdapter.Swap memory swap = abi.decode(logs[i].data, (ILiquidLaneAdapter.Swap));
                assertEq(swap.recipient, _account);
                assertEq(swap.tokenIn, token);
                assertEq(swap.amountIn, result.sold);
                assertEq(swap.amountOut, result.cashReceived);
                ++swaps;
            } else if (logs[i].emitter == token && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)"))
            {
                if (
                    logs[i].topics[1] == bytes32(uint256(uint160(_account)))
                        && logs[i].topics[2] == bytes32(uint256(uint160(_lane)))
                ) {
                    assertEq(abi.decode(logs[i].data, (uint256)), result.sold);
                    ++accountTransfers;
                }
            } else if (
                logs[i].emitter == _account
                    && logs[i].topics[0] == keccak256("Manage((address,uint96,bytes,bytes,bytes32[])[])")
            ) {
                ++manages;
            }
        }
        assertEq(trades, 1);
        assertEq(swaps, 1);
        assertEq(accountTransfers, 1);
        assertEq(manages, 2);
    }

    function _assertRestored(address token, IMerkleRWAActivityScript.Result memory result) internal view {
        assertEq(IMerkleAccount(_account).root(), _baseRoot);
        assertEq(RecipeExecutor(_executor).recipeHash(), keccak256(abi.encode(new bytes[](0), new bytes[](0))));
        assertEq(ILiquidLaneAdapter(_lane).marketMaker(), _previousMaker);
        assertTrue(ILiquidLaneAdapter(_lane).marketMakerCanAcquire());
        assertEq(IERC20(_asset).allowance(_account, TestnetCowSettlement(_settlement).vaultRelayer()), 0);
        assertEq(IERC20(token).allowance(address(this), _settlement), 0);
        assertFalse(IMerkleAccount(_account).signatures(result.digest));
    }

    function _drainAccount(uint256 remaining) internal {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = TestnetPermissions.action(
            _asset, abi.encodeCall(IERC20.transfer, (address(this), IERC20(_asset).balanceOf(_account) - remaining)), 0
        );
        (bytes32 root, bytes32[] memory leaves) = TestnetPermissions.authorize(actions);
        RootRegistry(_rootRegistry).setRoot(_account, root);
        IMerkleAccount(_account).acceptRoot(root);
        IMerkleAccount(_account).grantRole(leaves[0], address(this));
        IMerkleAccount(_account).manage(actions);
        RootRegistry(_rootRegistry).setRoot(_account, _baseRoot);
        IMerkleAccount(_account).acceptRoot(_baseRoot);
    }
}

/// @title MerkleRWAAssetVault
/// @notice Test-only vault custody used by production adapters without synthetic allocation cash.
contract MerkleRWAAssetVault {
    error InvalidCaller();
    error InvalidTransfer();

    address public immutable asset;
    address public delegator;

    constructor(address newAsset) {
        asset = newAsset;
    }

    function setDelegator(address newDelegator) public {
        delegator = newDelegator;
    }

    function withdrawable() public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function pull(uint256 amount, address receiver) public {
        if (delegator != msg.sender) revert InvalidCaller();
        if (!IERC20(asset).transfer(receiver, amount)) revert InvalidTransfer();
    }

    function push(uint256 amount, address provider) public {
        if (delegator != msg.sender) revert InvalidCaller();
        if (!IERC20(asset).transferFrom(provider, address(this), amount)) revert InvalidTransfer();
    }
}

/// @title MerkleRWAFundedDelegator
/// @notice Test-only delegated allocation that transfers existing vault cash and sweeps actual realized proceeds.
contract MerkleRWAFundedDelegator {
    address public immutable vault;

    constructor(address newVault) {
        vault = newVault;
    }

    function allocatable(address) public view returns (uint256) {
        return MerkleRWAAssetVault(vault).withdrawable();
    }

    function limitOf(address) public pure returns (uint256) {
        return 100_000e6;
    }

    function sweepPending() public pure returns (uint256) {
        return 0;
    }

    function allocateExact(address adapter, uint256 amount) public returns (uint256) {
        uint256 cash = IAdapter(adapter).freeAssets();
        if (cash > 0) {
            uint256 realized = IAdapter(adapter).deallocate(cash);
            MerkleRWAAssetVault(vault).push(realized, adapter);
        }
        MerkleRWAAssetVault(vault).pull(amount, adapter);
        return IAdapter(adapter).allocate(amount);
    }
}
