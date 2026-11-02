// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipePoolMock, RecipeTokenMock} from "./mocks/RecipeCapabilityMocks.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RecipeInvariantTest is CapabilityTestBase {
    address internal asset;
    address internal pool;
    address internal helper;
    uint256 internal amountOffset;
    IMerkleAccount.Action[] internal actions;
    IMerkleAccount.Action[] internal repayments;

    function setUp() public {
        asset = address(new RecipeTokenMock());
        pool = address(new RecipePoolMock(asset));
        helper = address(new AaveHealthFactor());
        _deployAdapter(asset);
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        _manage(asset, abi.encodeCall(IERC20.approve, (pool, type(uint256).max)));
        RecipeTokenMock(asset).mint(pool, 10_000e18);
        RecipePoolMock(pool).setCollateral(account, 240e18);
        bytes memory healthData = abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, account));
        _minimum = 1.2e18;
        bytes memory data = _checkedCallData(
            pool, helper, abi.encodeCall(RecipePoolMock.borrow, (asset, uint256(0), 2, 0, account)), healthData
        );
        bytes memory mask = new bytes(data.length);
        amountOffset = _checkedCallWordOffset(
            pool, helper, abi.encodeCall(RecipePoolMock.borrow, (asset, uint256(0), 2, 0, account)), healthData, 36
        );
        for (uint256 i = amountOffset; i < amountOffset + 32; ++i) {
            mask[i] = 0xff;
        }
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(account, bytes1(0), keccak256(mask), keccak256(data)))));
        IMerkleAccount.Action memory repayment;
        repayment.target = pool;
        repayment.data = abi.encodeCall(RecipePoolMock.repay, (uint256(0), account));
        repayment.dataMask = new bytes(repayment.data.length);
        repayment.proof = new bytes32[](1);
        repayment.proof[0] = leaf;
        for (uint256 i = 4; i < 36; ++i) {
            repayment.dataMask[i] = 0xff;
        }
        bytes32 repayLeaf = keccak256(
            bytes.concat(
                keccak256(abi.encode(pool, bytes1(0), keccak256(repayment.dataMask), keccak256(repayment.data)))
            )
        );
        bytes32 root = Hashes.commutativeKeccak256(leaf, repayLeaf);
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        MerkleAccount(payable(account)).grantRole(leaf, address(this));
        MerkleAccount(payable(account)).grantRole(repayLeaf, address(this));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = repayLeaf;
        actions.push(IMerkleAccount.Action({target: account, value: 0, data: data, dataMask: mask, proof: proof}));
        repayments.push(repayment);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = this.stepBorrow.selector;
        selectors[1] = this.stepRepay.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    function stepBorrow(uint256 amount) public {
        amount = bound(amount, 1, 250e18);
        IMerkleAccount.Action[] memory calls = actions;
        bytes memory data = calls[0].data;
        uint256 offset = amountOffset;
        assembly ("memory-safe") { mstore(add(add(data, 32), offset), amount) }
        try MerkleAccount(payable(account)).manage(calls) {} catch {}
    }

    function stepRepay(uint256 amount) public {
        uint256 debt = RecipePoolMock(pool).debt(account);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        IMerkleAccount.Action[] memory calls = repayments;
        calls[0].data = abi.encodeCall(RecipePoolMock.repay, (amount, account));
        MerkleAccount(payable(account)).manage(calls);
    }

    function test_BorrowRepayBorrowCyclePreservesHealthAndCustody() public {
        stepBorrow(200e18);
        assertEq(RecipePoolMock(pool).debt(account), 200e18);
        invariant_HealthFloorAndAdapterCustodyAlwaysHold();
        stepRepay(75e18);
        assertEq(RecipePoolMock(pool).debt(account), 125e18);
        invariant_HealthFloorAndAdapterCustodyAlwaysHold();
        stepRepay(125e18);
        assertEq(RecipePoolMock(pool).debt(account), 0);
        invariant_HealthFloorAndAdapterCustodyAlwaysHold();
        stepBorrow(200e18);
        assertEq(RecipePoolMock(pool).debt(account), 200e18);
        invariant_HealthFloorAndAdapterCustodyAlwaysHold();
    }

    function invariant_HealthFloorAndAdapterCustodyAlwaysHold() public view {
        uint256 debt = RecipePoolMock(pool).debt(account);
        assertLe(debt, 200e18);
        assertEq(RecipeTokenMock(asset).balanceOf(account), debt);
        assertEq(RecipeTokenMock(asset).balanceOf(pool), 10_000e18 - debt);
        assertGe(AaveHealthFactor(helper).getHealthFactor(pool, account), 1.2e18);
    }
}
