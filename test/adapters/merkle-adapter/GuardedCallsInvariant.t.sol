// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {GuardedCallsPoolMock, GuardedCallsTokenMock} from "./mocks/GuardedCallsMocks.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

contract GuardedCallsInvariantTest is CapabilityTestBase {
    address internal asset;
    address internal pool;
    address internal helper;
    IMerkleAdapter.Action[] internal actions;

    function setUp() public {
        asset = address(new GuardedCallsTokenMock());
        pool = address(new GuardedCallsPoolMock(asset));
        helper = address(new AaveHealthFactor());
        _deployAdapter(asset);
        _installCapability(adapter, address(new GuardedCallsCapability()), _guardedSelectors());
        GuardedCallsTokenMock(asset).mint(pool, 10_000e18);
        GuardedCallsPoolMock(pool).setCollateral(account, 240e18);
        bytes memory healthData = abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, account));
        _minimum = 1.2e18;
        bytes memory data = _guardedData(
            pool, helper, abi.encodeCall(GuardedCallsPoolMock.borrow, (asset, uint256(0), 2, 0, account)), healthData
        );
        bytes memory mask = new bytes(data.length);
        for (uint256 i = 264; i < 296; ++i) {
            mask[i] = 0xff;
        }
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(account, bytes1(0), keccak256(mask), keccak256(data)))));
        roots.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, address(this));
        actions.push(
            IMerkleAdapter.Action({target: account, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)})
        );
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = this.stepBorrow.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    function stepBorrow(uint256 amount) public {
        amount = bound(amount, 1, 250e18);
        IMerkleAdapter.Action[] memory calls = actions;
        bytes memory data = calls[0].data;
        assembly ("memory-safe") { mstore(add(data, 296), amount) }
        try adapter.manage(calls) {} catch {}
    }

    function invariant_HealthFloorAndAdapterCustodyAlwaysHold() public view {
        uint256 debt = GuardedCallsPoolMock(pool).debt(account);
        assertLe(debt, 200e18);
        assertEq(GuardedCallsTokenMock(asset).balanceOf(account), debt);
        assertEq(GuardedCallsTokenMock(asset).balanceOf(pool), 10_000e18 - debt);
        assertGe(AaveHealthFactor(helper).getHealthFactor(pool, account), 1.2e18);
    }
}
