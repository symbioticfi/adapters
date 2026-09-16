// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CapabilityManifestTestHelper} from "./CapabilityTestBase.sol";

import {CapabilitiesRegistry} from "src/contracts/merkle_adapter/CapabilitiesRegistry.sol";
import {CapabilitiesRegistryProposer} from "src/contracts/merkle_adapter/CapabilitiesRegistryProposer.sol";
import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {BorrowCapability} from "src/contracts/merkle_adapter/BorrowCapability.sol";
import {RootRegistry} from "src/contracts/merkle_adapter/RootRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";
import {
    MerkleAdapterDelegatorMock,
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "test/adapters/MerkleAdapter.t.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

interface IBorrowCapabilityAavePool {
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

interface IBorrowCapabilityAaveDebtToken is IERC20 {
    function approveDelegation(address delegatee, uint256 amount) external;
    function borrowAllowance(address fromUser, address toUser) external view returns (uint256);
}

/// @notice Exercises Aave's deployed Pool and tokens through real Merkle adapter self-calls and installed borrowing code.
/// @dev Only the initial 10 WETH collateral is funded with a fork-local ERC-20 deal. The supply,
///      debt minting, USDC reserve transfer and health calculations run against the actual pinned contracts.
contract BorrowCapabilityMainnetTest is Test, CapabilityManifestTestHelper {
    uint256 internal constant FORK_BLOCK = 25_892_000;

    // Verified against https://github.com/bgd-labs/aave-address-book/blob/main/src/AaveV3Ethereum.sol.
    address internal constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_ATOKEN = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant USDC_DEBT = 0x72E95b8931767C79bA4EeE721354d6E99a61D004;
    uint256 internal constant BORROW_AMOUNT = 1000e6;

    MerkleAdapter internal adapter;
    BorrowCapability internal capability;
    address internal implementation;
    RootRegistry internal roots;

    /// @dev Creates the fixed adapter-bound health query and supplies real Aave collateral through exact leaves.
    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ETH_RPC_URL is required for the Aave borrow capability integration");
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 1);
        assertGt(POOL.code.length, 0);
        assertGt(USDC_DEBT.code.length, 0);
        _deployAdapter();

        implementation = address(new BorrowCapability());
        _installCapability(adapter, implementation, _borrowSelectors());
        IBorrowCapability.InitParams memory params = IBorrowCapability.InitParams({
            borrowTarget: POOL,
            borrowSelector: IBorrowCapabilityAavePool.borrow.selector,
            borrowAsset: USDC,
            healthFactorTarget: POOL,
            healthFactorData: abi.encodeCall(IBorrowCapabilityAavePool.getUserAccountData, (address(adapter))),
            healthFactorOffset: 160,
            minHealthFactor: 1.2e18
        });
        capability = BorrowCapability(address(adapter));
        _manage(address(adapter), abi.encodeCall(IBorrowCapability.initializeBorrow, (params)));

        deal(WETH, address(adapter), 10e18);
        _manage(WETH, abi.encodeCall(IERC20.approve, (POOL, 10e18)));
        _manage(POOL, abi.encodeCall(IBorrowCapabilityAavePool.supply, (WETH, 10e18, address(adapter), 0)));
    }

    function test_MainnetBorrowsFromAaveFromAdapterWithoutDelegation() public {
        uint256 reserveBalance = IERC20(USDC).balanceOf(USDC_ATOKEN);

        _manage(address(capability), abi.encodeCall(IBorrowCapability.borrow, (_borrowData())));

        assertEq(IERC20(USDC).balanceOf(address(adapter)), BORROW_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(implementation), 0);
        assertEq(IERC20(USDC).balanceOf(USDC_ATOKEN), reserveBalance - BORROW_AMOUNT);
        uint256 recordedDebt = IERC20(USDC_DEBT).balanceOf(address(adapter));
        assertApproxEqAbs(recordedDebt, BORROW_AMOUNT, 1);
        assertEq(IERC20(USDC_DEBT).balanceOf(implementation), 0);
        assertEq(IBorrowCapabilityAaveDebtToken(USDC_DEBT).borrowAllowance(address(adapter), implementation), 0);
        (, uint256 debtBase,,,, uint256 healthFactor) =
            IBorrowCapabilityAavePool(POOL).getUserAccountData(address(adapter));
        assertGt(debtBase, 0);
        assertGe(healthFactor, 1.2e18);
        assertEq(capability.getHealthFactor(), healthFactor);
    }

    function test_MainnetCuratorFloorRevertsAaveDebtAndReserveTransfer() public {
        _manage(address(capability), abi.encodeCall(IBorrowCapability.setMinHealthFactor, (type(uint256).max)));
        uint256 reserveBalance = IERC20(USDC).balanceOf(USDC_ATOKEN);
        IMerkleAdapter.Action[] memory actions =
            _publishCall(address(capability), abi.encodeCall(IBorrowCapability.borrow, (_borrowData())));

        vm.expectPartialRevert(IBorrowCapability.HealthFactorTooLow.selector);
        adapter.manage(actions);

        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(implementation), 0);
        assertEq(IERC20(USDC).balanceOf(USDC_ATOKEN), reserveBalance);
        assertEq(IERC20(USDC_DEBT).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC_DEBT).balanceOf(implementation), 0);
        assertEq(IBorrowCapabilityAaveDebtToken(USDC_DEBT).borrowAllowance(address(adapter), implementation), 0);
        (, uint256 debtBase,,,, uint256 healthFactor) =
            IBorrowCapabilityAavePool(POOL).getUserAccountData(address(adapter));
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
                    address(roots),
                    address(
                        new CapabilitiesRegistry(
                            address(this), address(new CapabilitiesRegistryProposer(address(this)))
                        )
                    )
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapterFactory.create(
                    1, address(this), abi.encode(address(vault), abi.encode(IMerkleAdapter.InitParams(address(this))))
                ))
        );
    }

    /// @dev Binds the asset, interest mode and adapter debt owner in the underlying Aave borrow calldata.
    function _borrowData() internal view returns (bytes memory) {
        return abi.encodeCall(IBorrowCapabilityAavePool.borrow, (USDC, BORROW_AMOUNT, 2, 0, address(adapter)));
    }

    /// @dev Calls each protocol or action entrypoint through an exact Merkle permission.
    function _manage(address target, bytes memory data) internal {
        adapter.manage(_publishCall(target, data));
    }

    /// @dev Independently encodes and grants a single-leaf tree with every calldata byte fixed.
    function _publishCall(address target, bytes memory data) internal returns (IMerkleAdapter.Action[] memory actions) {
        bytes memory mask = new bytes(data.length);
        for (uint256 i; i < mask.length; ++i) {
            mask[i] = 0xff;
        }
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(target, uint96(0), keccak256(mask), keccak256(data)))));
        roots.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, address(this));
        actions = new IMerkleAdapter.Action[](1);
        actions[0] = IMerkleAdapter.Action(target, 0, data, mask, new bytes32[](0));
    }
}
