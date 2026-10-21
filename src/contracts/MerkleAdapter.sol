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
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";

/// @title MerkleAdapter
/// @notice Contract for bridging vault capital and a strategy account with flow-adjusted oracle accounting.
contract MerkleAdapter is Adapter, IMerkleAdapter {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using Checkpoints for Checkpoints.Trace208;

    /* IMMUTABLES */

    /// @inheritdoc IMerkleAdapter
    address public immutable override ORACLE_FACTORY;

    /// @inheritdoc IMerkleAdapter
    address public immutable override ACCOUNT_FACTORY;

    /* STATE VARIABLES */

    /// @inheritdoc IMerkleAdapter
    address public override oracle;

    /// @inheritdoc IMerkleAdapter
    uint256 public releasedLiquidity;

    /// @inheritdoc IMerkleAdapter
    address public account;

    /// @inheritdoc IMerkleAdapter
    uint48 public syncedSnapshotBlock;

    // Values preserve the two's-complement bits of int208; each block/value checkpoint occupies one slot.
    Checkpoints.Trace208 private _netFlow;

    Checkpoints.Trace208 private _stagedLiquidity;

    /* CONSTRUCTOR */

    /// @dev Initializes the immutable factory dependencies for the implementation.
    constructor(address newVaultFactory, address newAdapterFactory, address newOracleFactory, address newAccountFactory)
        Adapter(newVaultFactory, newAdapterFactory)
    {
        ORACLE_FACTORY = newOracleFactory;
        ACCOUNT_FACTORY = newAccountFactory;
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc IMerkleAdapter
    function netFlow() public view returns (int256) {
        return int208(_netFlow.latest());
    }

    /// @inheritdoc IMerkleAdapter
    function netFlowAt(uint48 snapshotBlock) public view returns (int256) {
        return int208(_netFlow.upperLookupRecent(snapshotBlock));
    }

    /// @inheritdoc IMerkleAdapter
    function stagedLiquidity() public view returns (uint256) {
        return _stagedLiquidity.latest() - stagedLiquidityAt(syncedSnapshotBlock);
    }

    /// @inheritdoc IMerkleAdapter
    function lockedLiquidity() public view returns (uint256) {
        return releasedLiquidity + stagedLiquidity();
    }

    /// @inheritdoc IMerkleAdapter
    function stagedLiquidityAt(uint48 snapshotBlock) public view returns (uint256) {
        return _stagedLiquidity.upperLookupRecent(snapshotBlock);
    }

    /// @inheritdoc IAdapter
    function totalAssets() public view override(Adapter, IAdapter) returns (uint256) {
        (uint48 snapshotBlock, uint256 snapshotTotalAssets) = IMerkleAdapterOracle(oracle).latestSnapshot();
        return uint256(int256(snapshotTotalAssets) - netFlowAt(snapshotBlock) + netFlow());
    }

    /// @inheritdoc IMerkleAdapter
    function freeAssets() public view override(Adapter, IMerkleAdapter) returns (uint256) {
        uint48 snapshotBlock = IMerkleAdapterOracle(oracle).snapshotBlock();
        uint256 covered = releasedLiquidity;
        if (snapshotBlock > syncedSnapshotBlock) {
            covered += stagedLiquidityAt(snapshotBlock) - stagedLiquidityAt(syncedSnapshotBlock);
        }
        return Math.min(covered, totalAssets());
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleAdapter
    function pull(uint256 amount) public {
        if (account != msg.sender) revert InvalidCaller();

        IERC20(IERC4626(vault).asset()).safeTransferFrom(account, address(this), amount);
        uint256 staged = IERC20(IERC4626(vault).asset()).balanceOf(address(this)).saturatingSub(lockedLiquidity());
        if (staged > 0) {
            _stagedLiquidity.push(uint48(block.number), uint208(_stagedLiquidity.latest() + staged));
        }
        emit Pull(amount);
    }

    /// @inheritdoc IAdapter
    function deallocate(uint256 amount) public override(Adapter, IAdapter) onlyDelegator returns (uint256 deallocated) {
        uint48 snapshotBlock = IMerkleAdapterOracle(oracle).snapshotBlock();
        if (snapshotBlock > syncedSnapshotBlock) {
            uint256 curTotalAssets = totalAssets();
            releasedLiquidity += stagedLiquidityAt(snapshotBlock) - stagedLiquidityAt(syncedSnapshotBlock);
            syncedSnapshotBlock = snapshotBlock;
            if (releasedLiquidity > curTotalAssets) {
                releasedLiquidity = curTotalAssets;
            }
        }
        uint256 released = releasedLiquidity;
        // The delegator validates NAV through totalAssets() even when nothing is released.
        if (released == 0) return 0;
        deallocated = Math.min(amount, Math.min(released, totalAssets()));
        if (deallocated == 0) return 0;
        releasedLiquidity = released - deallocated;
        _netFlow.push(uint48(block.number), uint208(int208(netFlow() - int256(deallocated))));
        // The vault takes the tokens after this call: staging here would count outgoing cash again.
    }

    /* INTERNAL FUNCTIONS */

    function _allocate(uint256 amount) internal override returns (uint256) {
        IERC20(IERC4626(vault).asset()).safeTransfer(account, amount);
        _netFlow.push(uint48(block.number), uint208(int208(netFlow() + int256(amount))));
        return amount;
    }

    /* INITIALIZATION */

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
