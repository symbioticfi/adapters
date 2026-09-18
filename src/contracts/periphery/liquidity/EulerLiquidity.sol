// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.36;

import {IExecutorLiquidityLens} from "src/interfaces/periphery/IExecutorLiquidityLens.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ILiquidityEulerVault {
    function asset() external view returns (address);
    function cash() external view returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function accountLiquidity(address account, bool liquidation) external view returns (uint256, uint256);
    function EVC() external view returns (address);
    function caps() external view returns (uint16, uint16);
    function hookConfig() external view returns (address, uint32);
    function oracle() external view returns (address);
    function unitOfAccount() external view returns (address);
}

interface ILiquidityEVC {
    function getControllers(address account) external view returns (address[] memory);
}

interface ILiquidityEulerOracle {
    function getQuotes(uint256 amount, address base, address quote) external view returns (uint256, uint256);
}

/// @title EulerLiquidity
/// @notice Scalar liquidity calculations for supported Euler vaults.
abstract contract EulerLiquidity is IExecutorLiquidityLens {
    using Math for uint256;

    struct EulerState {
        address asset;
        address unit;
        address oracle;
        uint256 collateral;
        uint256 debt;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IExecutorLiquidityLens
    /// @dev Only an already enabled, sole EVault controller is supported. Custom borrow/status hooks return zero.
    function eulerBorrow(address vault, address account) public view returns (uint256) {
        address[] memory controllers = ILiquidityEVC(ILiquidityEulerVault(vault).EVC()).getControllers(account);
        if (controllers.length != 1 || controllers[0] != vault) return 0;
        (, uint32 hooks) = ILiquidityEulerVault(vault).hookConfig();
        if (hooks & ((1 << 6) | (1 << 14)) > 0) return 0;
        (, uint16 cap) = ILiquidityEulerVault(vault).caps();
        uint256 totalDebt = ILiquidityEulerVault(vault).totalBorrows();
        uint256 headroom = _eulerCap(cap).saturatingSub(totalDebt + 1);
        headroom = Math.min(headroom, uint256(type(uint112).max).saturatingSub(totalDebt + 1));
        uint256 high = Math.min(headroom, ILiquidityEulerVault(vault).cash());
        if (high == 0) return 0;
        EulerState memory state;
        (state.collateral,) = ILiquidityEulerVault(vault).accountLiquidity(account, false);
        if (state.collateral == 0) return 0;
        state.asset = ILiquidityEulerVault(vault).asset();
        state.unit = ILiquidityEulerVault(vault).unitOfAccount();
        state.oracle = ILiquidityEulerVault(vault).oracle();
        state.debt = ILiquidityEulerVault(vault).debtOf(account);
        // Search uses the same ask-side oracle quote as EVK account-status validation, in native asset units.
        uint256 low;
        for (uint256 i; i < 64 && low < high; ++i) {
            uint256 mid = low + (high - low + 1) / 2;
            uint256 quote = _eulerDebtValue(state, state.debt + mid + 1);
            if (quote > 0 && quote < state.collateral) low = mid;
            else high = mid - 1;
        }
        return low;
    }

    /* INTERNAL FUNCTIONS */

    function _eulerDebtValue(EulerState memory state, uint256 debt) internal view returns (uint256 value) {
        if (state.asset == state.unit) return debt;
        (, value) = ILiquidityEulerOracle(state.oracle).getQuotes(debt, state.asset, state.unit);
    }

    function _eulerCap(uint16 cap) internal pure returns (uint256) {
        return cap == 0 ? type(uint256).max : 10 ** (uint256(cap) & 63) * (uint256(cap) >> 6) / 100;
    }
}
