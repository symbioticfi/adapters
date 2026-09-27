// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Adapter} from "./Adapter.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {IMerkleAdapterOracle} from "../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../interfaces/IMerkleAdapter.sol";

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";

/// @title MerkleAdapter
/// @notice Contract for bridging vault capital and a strategy account with flow-adjusted oracle accounting.
contract MerkleAdapter is Adapter, IMerkleAdapter {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using Checkpoints for Checkpoints.Trace208;
    using SafeCast for uint256;
    using SafeCast for int256;

    /* IMMUTABLES */

    /// @inheritdoc IMerkleAdapter
    address public immutable override ORACLE_FACTORY;

    /// @inheritdoc IMerkleAdapter
    address public immutable override ACCOUNT_FACTORY;

    /* STATE VARIABLES */

    /// @inheritdoc IMerkleAdapter
    address public override oracle;

    /// @inheritdoc IMerkleAdapter
    uint256 public pendingDeallocation;

    /// @inheritdoc IMerkleAdapter
    uint256 public releasedLiquidity;

    /// @inheritdoc IMerkleAdapter
    uint256 public stagedLiquidity;

    /// @inheritdoc IMerkleAdapter
    address public account;

    /// @inheritdoc IMerkleAdapter
    uint48 public stagedBlock;

    // Values preserve the two's-complement bits of int208; each block/value checkpoint occupies one slot.
    Checkpoints.Trace208 private _netFlow;

    /* CONSTRUCTOR */

    /// @dev Initializes the immutable factory dependencies for the implementation.
    constructor(address newVaultFactory, address newAdapterFactory, address newOracleFactory, address newAccountFactory)
        Adapter(newVaultFactory, newAdapterFactory)
    {
        ORACLE_FACTORY = newOracleFactory;
        ACCOUNT_FACTORY = newAccountFactory;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleAdapter
    function push(uint256 amount) public {
        if (account != msg.sender) revert InvalidCaller();
        address asset = IERC4626(vault).asset();
        if (
            amount
                > IERC20(asset)
                    .balanceOf(address(this))
                    .saturatingSub(Math.max(pendingDeallocation, releasedLiquidity + stagedLiquidity))
        ) {
            revert InsufficientIdleAssets();
        }

        IERC20(asset).safeTransfer(account, amount);
        emit Push(amount);
    }

    /// @inheritdoc IMerkleAdapter
    function pull(uint256 amount) public {
        if (account != msg.sender) revert InvalidCaller();

        IERC20(IERC4626(vault).asset()).safeTransferFrom(account, address(this), amount);
        stageLiquidity();
        emit Pull(amount);
    }

    /// @inheritdoc IMerkleAdapter
    function stageLiquidity() public {
        if (stagedLiquidity > 0 || pendingDeallocation <= releasedLiquidity) return;

        uint256 amount = Math.min(freeAssets(), pendingDeallocation).saturatingSub(releasedLiquidity);
        if (amount == 0) return;

        stagedLiquidity = amount;
        stagedBlock = block.number.toUint48();
        emit StageLiquidity(amount, stagedBlock);
    }

    /// @inheritdoc IMerkleAdapter
    function settleReport(uint48 snapshotBlock, uint256 assets) public {
        if (oracle != msg.sender) revert InvalidCaller();

        if (stagedLiquidity > 0 && stagedBlock <= snapshotBlock) {
            releasedLiquidity += stagedLiquidity;
            delete stagedLiquidity;
            delete stagedBlock;
        }
        releasedLiquidity = Math.min(releasedLiquidity, assets);
        pendingDeallocation = Math.min(pendingDeallocation, assets);
        // Later arrivals enter a new batch at delivery time and need a later covering snapshot.
        stageLiquidity();
        emit SettleReport(releasedLiquidity);
    }

    /// @inheritdoc IMerkleAdapter
    function netFlow() public view returns (int256) {
        return int208(_netFlow.latest());
    }

    /// @inheritdoc IMerkleAdapter
    function netFlowAt(uint48 snapshotBlock) public view returns (int256) {
        if (snapshotBlock >= block.number) revert InvalidSnapshotBlock();
        return int208(_netFlow.upperLookupRecent(snapshotBlock));
    }

    /// @inheritdoc IAdapter
    function totalAssets() public view override(Adapter, IAdapter) returns (uint256) {
        return IMerkleAdapterOracle(oracle).validate();
    }

    /// @inheritdoc IAdapter
    function allocatable() public view override(Adapter, IAdapter) returns (uint256) {
        totalAssets();
        return type(uint256).max;
    }

    /// @inheritdoc IMerkleAdapter
    function deallocatable() public view returns (uint256) {
        uint256 released = releasedLiquidity;
        if (released == 0) return 0;
        return Math.min(released, Math.min(freeAssets(), IMerkleAdapterOracle(oracle).totalAssets()));
    }

    /// @inheritdoc IAdapter
    function deallocate(uint256 amount) public override(Adapter, IAdapter) onlyDelegator returns (uint256 deallocated) {
        // The delegator validates NAV through totalAssets() before completing deallocation.
        deallocated = Math.min(amount, deallocatable());
        if (deallocated == 0) return 0;
        releasedLiquidity -= deallocated;
        pendingDeallocation = pendingDeallocation.saturatingSub(deallocated);
        _recordFlow(-deallocated.toInt256());
        // The vault takes the tokens after this call: staging here would count outgoing cash again.
    }

    /* INTERNAL FUNCTIONS */

    function _allocate(uint256 amount) internal override returns (uint256) {
        _recordFlow(amount.toInt256());
        stageLiquidity();
        return amount;
    }

    /// @dev The delegator supplies cumulative outstanding demand after draining immediately available liquidity.
    function _requestDeallocate(uint256 amount) internal override {
        pendingDeallocation = amount;
        stageLiquidity();
    }

    /// @dev The delegator's token transfers and this checkpoint commit or revert in the same transaction.
    function _recordFlow(int256 delta) internal {
        if (delta == 0) return;
        _netFlow.push(block.number.toUint48(), uint208((netFlow() + delta).toInt208()));
    }

    /// @dev Creates the latest strategy account and accounting oracle owned by the adapter owner.
    function __initialize(address, bytes memory data) internal override {
        InitParams memory params = abi.decode(data, (InitParams));
        account = IMigratablesFactory(ACCOUNT_FACTORY)
            .create(
                IMigratablesFactory(ACCOUNT_FACTORY).lastVersion(),
                owner(),
                abi.encode(address(this), params.merkleAccountData)
            );
        emit SetAccount(account);
        oracle = IMigratablesFactory(ORACLE_FACTORY)
            .create(
                IMigratablesFactory(ORACLE_FACTORY).lastVersion(), owner(), abi.encode(address(this), params.oracleData)
            );
        emit SetOracle(oracle);
    }
}
