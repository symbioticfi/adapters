// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {MorphoLiquidity} from "src/contracts/merkle-adapter/automations/liquidity/MorphoLiquidity.sol";
import {VaultV2LiquidityLib} from "src/contracts/merkle-adapter/automations/liquidity/VaultV2LiquidityLib.sol";

import {IVaultV2} from "src/interfaces/merkle-adapter/automations/liquidity/IMorphoLiquidity.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Test} from "forge-std/Test.sol";

contract MorphoLiquidityReference {
    function liquidity(address vault, address owner) public view returns (uint256) {
        if (!IVaultV2(vault).canSendShares(owner) || !IVaultV2(vault).canReceiveAssets(owner)) return 0;
        uint256 shares = IVaultV2(vault).balanceOf(owner);
        if (shares == 0) return 0;
        uint256 ownerAssets = IVaultV2(vault).previewRedeem(shares);
        uint256 available = IERC20(IVaultV2(vault).asset()).balanceOf(vault);
        address adapter = IVaultV2(vault).liquidityAdapter();
        if (adapter != address(0)) {
            available += VaultV2LiquidityLib.adapterAvailableLiquidity(adapter, IVaultV2(vault).liquidityData(), 0);
        }
        return Math.min(ownerAssets, available);
    }

    function atDepth(address vault, address owner, uint256 depth) public view returns (uint256) {
        return VaultV2LiquidityLib.maxWithdrawView(vault, owner, depth);
    }
}

contract MorphoLiquidityOptimizationMainnetTest is Test {
    /// forge-config: default.isolate = true
    function test_MainnetIdleCapacityMatchesOriginalAndWithdraws() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 25_892_000);
        address vault = 0x5e577eFb2807D106e2A8BDDE3fC5FCFffFC9ec13;
        address asset = IERC4626(vault).asset();
        address morpho = address(new MorphoLiquidity());
        address originalHelper = address(new MorphoLiquidityReference());
        // Seed only the starting USDC. Deposit, donation and withdrawal use the native vault and token.
        deal(asset, address(this), 3000e6);
        IERC20(asset).approve(vault, 1000e6);
        IERC4626(vault).deposit(1000e6, address(this));
        IERC20(asset).transfer(vault, 2000e6);

        uint256 original = MorphoLiquidityReference(originalHelper).liquidity(vault, address(this));
        uint256 referenceGas = vm.snapshotGasLastCall("MorphoLiquidityOptimizationMainnet", "idle_unbounded");
        uint256 optimized = MorphoLiquidity(morpho).liquidity(vault, address(this));
        uint256 optimizedGas = vm.snapshotGasLastCall("MorphoLiquidityOptimizationMainnet", "idle_bounded");
        assertEq(optimized, original);
        assertGt(optimized, 0);
        assertLe(optimized, IERC20(asset).balanceOf(vault));
        assertLt(optimizedGas, referenceGas);
        IERC4626(vault).withdraw(optimized, address(this), address(this));
        assertEq(IERC20(asset).balanceOf(address(this)), optimized);
        emit log_named_uint("Unbounded mainnet capacity", referenceGas);
        emit log_named_uint("Owner-bounded mainnet capacity", optimizedGas);
    }
}

contract MorphoLiquidityOptimizationTest is Test {
    address internal constant ACCOUNT = address(0x301);
    address internal constant ASSET = address(0x201);
    address internal constant EXIT = address(0x901);
    address internal constant UNDERLYING = address(0x902);
    address internal constant VAULT = address(0x801);

    address internal _morpho;
    address internal _reference;

    function setUp() public {
        _morpho = address(new MorphoLiquidity());
        _reference = address(new MorphoLiquidityReference());
    }

    function test_IdleCoversOwnerSkipsUnavailableExitData() public {
        _vault(VAULT, ACCOUNT, 100, 100, EXIT);
        vm.mockCallRevert(VAULT, abi.encodeWithSignature("liquidityData()"), "unused exit");
        assertEq(MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT), 100);
    }

    function test_InsufficientIdleStillRequiresExitData() public {
        _vault(VAULT, ACCOUNT, 100, 99, EXIT);
        vm.mockCallRevert(VAULT, abi.encodeWithSignature("liquidityData()"), "required exit");
        vm.expectRevert(bytes("required exit"));
        MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT);
    }

    function test_IdleSurplusIsCappedByAccruedOwnerAssets() public {
        _vault(VAULT, ACCOUNT, 83, 100, EXIT);
        vm.mockCallRevert(VAULT, abi.encodeWithSignature("liquidityAdapter()"), "unused exit");
        assertEq(MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT), 83);
    }

    function test_ZeroSharesAndClosedGatesSkipValuation() public {
        _vault(VAULT, ACCOUNT, 100, 100, EXIT);
        vm.mockCallRevert(VAULT, abi.encodeWithSignature("previewRedeem(uint256)", 1), "valuation unavailable");
        _mock(VAULT, abi.encodeWithSignature("balanceOf(address)", ACCOUNT), abi.encode(0));
        assertEq(MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT), 0);
        _mock(VAULT, abi.encodeWithSignature("balanceOf(address)", ACCOUNT), abi.encode(1));
        _mock(VAULT, abi.encodeWithSignature("canSendShares(address)", ACCOUNT), abi.encode(false));
        assertEq(MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT), 0);
        _mock(VAULT, abi.encodeWithSignature("canSendShares(address)", ACCOUNT), abi.encode(true));
        _mock(VAULT, abi.encodeWithSignature("canReceiveAssets(address)", ACCOUNT), abi.encode(false));
        assertEq(MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT), 0);
    }

    function test_IdleStillRequiresSuccessfulShareValuation() public {
        _vault(VAULT, ACCOUNT, 100, 100, EXIT);
        vm.mockCallRevert(VAULT, abi.encodeWithSignature("previewRedeem(uint256)", 1), "valuation unavailable");
        vm.expectRevert(bytes("valuation unavailable"));
        MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT);
    }

    function test_DepthBoundIsCheckedBeforeReadingIdle() public view {
        assertEq(MorphoLiquidityReference(_reference).atDepth(VAULT, ACCOUNT, 4), 0);
    }

    function test_NestedIdleBoundPreservesNestedOwnerAndExitGates() public {
        _vault(VAULT, ACCOUNT, 100, 10, EXIT);
        _wrappedVault(EXIT, UNDERLYING);
        _vault(UNDERLYING, EXIT, 30, 40, address(0x903));
        vm.mockCallRevert(UNDERLYING, abi.encodeWithSignature("liquidityData()"), "unused nested exit");
        assertEq(MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT), 40);
        _mock(UNDERLYING, abi.encodeWithSignature("canReceiveAssets(address)", EXIT), abi.encode(false));
        assertEq(MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT), 10);
    }

    function testFuzz_MatchesUnboundedCapacity(uint128 ownerAssets, uint128 idle, uint128 adapterAssets) public {
        _vault(VAULT, ACCOUNT, ownerAssets, idle, EXIT);
        _wrappedVault(EXIT, UNDERLYING);
        vm.mockCallRevert(UNDERLYING, abi.encodeWithSignature("liquidityAdapter()"), "V1 vault");
        _mock(UNDERLYING, abi.encodeWithSignature("maxWithdraw(address)", EXIT), abi.encode(adapterAssets));
        uint256 expected = Math.min(ownerAssets, uint256(idle) + adapterAssets);
        assertEq(MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT), expected);
        assertEq(MorphoLiquidityReference(_reference).liquidity(VAULT, ACCOUNT), expected);
    }

    /// forge-config: default.isolate = true
    function test_GasIdleCapacitySkipsV1ExitTraversal() public {
        _vault(VAULT, ACCOUNT, 100, 100, EXIT);
        _wrappedVault(EXIT, UNDERLYING);
        vm.mockCallRevert(UNDERLYING, abi.encodeWithSignature("liquidityAdapter()"), "V1 vault");
        _mock(UNDERLYING, abi.encodeWithSignature("maxWithdraw(address)", EXIT), abi.encode(60));
        uint256 original = MorphoLiquidityReference(_reference).liquidity(VAULT, ACCOUNT);
        uint256 referenceGas = vm.snapshotGasLastCall("MorphoLiquidityOptimization", "idle_unbounded");
        uint256 optimized = MorphoLiquidity(_morpho).liquidity(VAULT, ACCOUNT);
        uint256 optimizedGas = vm.snapshotGasLastCall("MorphoLiquidityOptimization", "idle_bounded");
        assertEq(original, 100);
        assertEq(optimized, original);
        assertLt(optimizedGas, referenceGas);
        emit log_named_uint("Unbounded local V1 exit", referenceGas);
        emit log_named_uint("Owner-bounded local V1 exit", optimizedGas);
    }

    function _vault(address vault, address owner, uint256 ownerAssets, uint256 idle, address exit) internal {
        _mock(vault, abi.encodeWithSignature("canSendShares(address)", owner), abi.encode(true));
        _mock(vault, abi.encodeWithSignature("canReceiveAssets(address)", owner), abi.encode(true));
        _mock(vault, abi.encodeWithSignature("balanceOf(address)", owner), abi.encode(1));
        _mock(vault, abi.encodeWithSignature("previewRedeem(uint256)", 1), abi.encode(ownerAssets));
        _mock(vault, abi.encodeWithSignature("asset()"), abi.encode(ASSET));
        _mock(vault, abi.encodeWithSignature("liquidityAdapter()"), abi.encode(exit));
        _mock(vault, abi.encodeWithSignature("liquidityData()"), abi.encode(bytes("")));
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", vault), abi.encode(idle));
    }

    function _wrappedVault(address exit, address underlying) internal {
        vm.mockCallRevert(exit, abi.encodeWithSignature("morpho()"), "vault adapter");
        _mock(exit, abi.encodeWithSignature("morphoVaultV1()"), abi.encode(underlying));
    }

    function _mock(address target, bytes memory data, bytes memory result) internal {
        vm.mockCall(target, data, result);
    }
}
