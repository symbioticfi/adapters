// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {CapabilityManifestTestHelper} from "./CapabilityTestBase.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/RecipeCapabilityMocks.sol";
import {
    MerkleAdapterDelegatorMock,
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "test/adapters/MerkleAdapter.t.sol";
import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";
import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

interface IRecipeCapabilityAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IRecipeCapabilityAaveDebtToken is IERC20 {
    function approveDelegation(address delegatee, uint256 amount) external;
    function borrowAllowance(address fromUser, address toUser) external view returns (uint256);
}

/// @notice Exercises Aave's deployed Pool and tokens through real Merkle adapter self-calls and installed borrowing code.
/// @dev Only the initial 10 WETH collateral is funded with a fork-local ERC-20 deal. The supply,
///      debt minting, USDC reserve transfer and health calculations run against the actual pinned contracts.
contract RecipeMainnetTest is Test, CapabilityManifestTestHelper {
    uint256 internal constant FORK_BLOCK = 25_892_000;

    // Verified against https://github.com/bgd-labs/aave-address-book/blob/main/src/AaveV3Ethereum.sol.
    address internal constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_ATOKEN = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant USDC_DEBT = 0x72E95b8931767C79bA4EeE721354d6E99a61D004;
    uint256 internal constant BORROW_AMOUNT = 1000e6;

    MerkleAdapter internal adapter;
    address internal account;
    RecipeCapability internal capability;
    address internal implementation;
    RootRegistry internal roots;
    BorrowTestCall internal health;

    /// @dev Creates the fixed adapter-bound health query and supplies real Aave collateral through exact leaves.
    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ETH_RPC_URL is required for the Aave borrow capability integration");
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("MAINNET_FORK_BLOCK", FORK_BLOCK));
        assertEq(block.chainid, 1);
        assertGt(POOL.code.length, 0);
        assertGt(USDC_DEBT.code.length, 0);
        _deployAdapter();
        account = adapter.account();

        implementation =
            IImmutableFactory(address(new ImmutableFactory(type(RecipeCapability).creationCode))).create("");
        _installCapability(adapter, implementation, _recipeSelectors());
        capability = RecipeCapability(account);
        health = BorrowTestCall({
            target: address(new AaveHealthFactor()),
            data: abi.encodeCall(AaveHealthFactor.getHealthFactor, (POOL, account))
        });
        _minimum = 1.2e18;

        deal(WETH, account, 10e18);
        _manage(WETH, abi.encodeCall(IERC20.approve, (POOL, 10e18)));
        _manage(POOL, abi.encodeCall(IRecipeCapabilityAavePool.supply, (WETH, 10e18, account, 0)));
    }

    function test_MainnetBorrowsFromAaveFromAdapterWithoutDelegation() public {
        uint256 reserveBalance = IERC20(USDC).balanceOf(USDC_ATOKEN);

        _manage(address(capability), _checkedCallData(POOL, health.target, _borrowData(), health.data));

        assertEq(IERC20(USDC).balanceOf(account), BORROW_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(implementation), 0);
        assertEq(IERC20(USDC).balanceOf(USDC_ATOKEN), reserveBalance - BORROW_AMOUNT);
        uint256 recordedDebt = IERC20(USDC_DEBT).balanceOf(account);
        assertApproxEqAbs(recordedDebt, BORROW_AMOUNT, 1);
        assertEq(IERC20(USDC_DEBT).balanceOf(implementation), 0);
        assertEq(IRecipeCapabilityAaveDebtToken(USDC_DEBT).borrowAllowance(account, implementation), 0);
        (, uint256 debtBase,,,, uint256 healthFactor) = IRecipeCapabilityAavePool(POOL).getUserAccountData(account);
        assertGt(debtBase, 0);
        assertGe(healthFactor, 1.2e18);
        assertEq(_healthValue(health.target, health.data), healthFactor);
    }

    function test_MainnetCuratorFloorRevertsAaveDebtAndReserveTransfer() public {
        _minimum = type(uint256).max;
        uint256 reserveBalance = IERC20(USDC).balanceOf(USDC_ATOKEN);
        IMerkleAccount.Action[] memory actions =
            _publishCall(address(capability), _checkedCallData(POOL, health.target, _borrowData(), health.data));

        vm.expectPartialRevert(IRecipes.CheckFailed.selector);
        MerkleAccount(payable(account)).manage(actions);

        assertEq(IERC20(USDC).balanceOf(account), 0);
        assertEq(IERC20(USDC).balanceOf(implementation), 0);
        assertEq(IERC20(USDC).balanceOf(USDC_ATOKEN), reserveBalance);
        assertEq(IERC20(USDC_DEBT).balanceOf(account), 0);
        assertEq(IERC20(USDC_DEBT).balanceOf(implementation), 0);
        assertEq(IRecipeCapabilityAaveDebtToken(USDC_DEBT).borrowAllowance(account, implementation), 0);
        (, uint256 debtBase,,,, uint256 healthFactor) = IRecipeCapabilityAavePool(POOL).getUserAccountData(account);
        assertEq(debtBase, 0);
        assertEq(healthFactor, type(uint256).max);
    }

    /// @dev Uses the production adapter and factories with local vault and oracle fixtures for isolated permissions.
    function _deployAdapter() internal {
        MerkleAdapterVaultRegistry vaultFactory = new MerkleAdapterVaultRegistry();
        MerkleAdapterVaultMock vault = new MerkleAdapterVaultMock(USDC);
        MerkleAdapterDelegatorMock delegator = new MerkleAdapterDelegatorMock(address(vault));
        vault.setDelegator(address(delegator));
        vaultFactory.add(address(vault));
        AdapterFactory adapterFactory = new AdapterFactory(address(this));
        MigratablesFactory oracleFactory = new MigratablesFactory(address(this));
        oracleFactory.whitelist(address(new MerkleAdapterOracleMock(address(oracleFactory))));
        roots = new RootRegistry(address(this));
        adapterFactory.whitelist(
            address(
                new MerkleAdapter(
                    address(vaultFactory),
                    address(adapterFactory),
                    address(oracleFactory),
                    createMerkleAccountFactory(
                        address(this),
                        address(adapterFactory),
                        address(roots),
                        address(new CapabilitiesRegistry(address(this)))
                    )
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapterFactory.create(
                    1,
                    address(this),
                    abi.encode(address(vault), abi.encode(merkleAdapterInitParams(address(this), address(0))))
                ))
        );
    }

    /// @dev Binds the asset, interest mode and adapter debt owner in the underlying Aave borrow calldata.
    function _borrowData() internal view returns (bytes memory) {
        return abi.encodeCall(IRecipeCapabilityAavePool.borrow, (USDC, BORROW_AMOUNT, 2, 0, account));
    }

    /// @dev Calls each protocol or action entrypoint through an exact Merkle permission.
    function _manage(address target, bytes memory data) internal {
        MerkleAccount(payable(account)).manage(_publishCall(target, data));
    }

    /// @dev Independently encodes and grants a single-leaf tree with every calldata byte fixed.
    function _publishCall(address target, bytes memory data) internal returns (IMerkleAccount.Action[] memory actions) {
        bytes memory mask = new bytes(data.length);
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(target, bytes1(0), keccak256(mask), keccak256(data)))));
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(this));
        actions = new IMerkleAccount.Action[](1);
        actions[0] =
            IMerkleAccount.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }
}
