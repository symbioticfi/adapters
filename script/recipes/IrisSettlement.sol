// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IIris} from "src/interfaces/merkle-adapter/IIris.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

/**
 * @title IrisSettlement
 * @notice Library for compiling the recipe that returns Iris solver capital to the account.
 * @dev Inputs are the debt-token claim, the collateral-token claim, the pod and the bond withdrawal; a zero
 * amount skips its call. Every call pays the account. Iris bounds claims by the claimable balance and bond
 * withdrawals by the loan's requirement and health, and only lets the account withdraw from pods it solves.
 */
library IrisSettlement {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    /* CONSTANTS */

    /// @dev Calldata offsets of the free words: the first argument and the uint256 amount after it.
    uint256 internal constant FIRST_WORD = 4;
    uint256 internal constant AMOUNT_WORD = 36;

    struct Config {
        address account;
        address iris;
        address debtToken;
        address collateralToken;
    }

    /**
     * @notice Compiles the settlement program.
     * @return recipe Executor program.
     * @return actions Debt-token claim, collateral-token claim and bond withdrawal, with the free words masked.
     */
    function build(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, IMerkleAccount.Action[] memory actions)
    {
        if (
            config.account == address(0) || config.iris == address(0) || config.debtToken == address(0)
                || config.collateralToken == address(0)
        ) revert InvalidConfiguration();

        actions = new IMerkleAccount.Action[](3);
        actions[0] = _action(
            config.iris, abi.encodeCall(IIris.claim, (config.debtToken, 0, config.account, config.account)), AMOUNT_WORD
        );
        actions[1] = _action(
            config.iris,
            abi.encodeCall(IIris.claim, (config.collateralToken, 0, config.account, config.account)),
            AMOUNT_WORD
        );
        actions[2] =
            _action(config.iris, abi.encodeCall(IIris.withdrawBond, (address(0), 0, config.account)), FIRST_WORD);

        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(3);
        for (uint256 i; i < 2; ++i) {
            uint256[][] memory bindings = new uint256[][](1);
            bindings[0] = new uint256[](1);
            bindings[0][0] = ExecutingRecipe.binding(AMOUNT_WORD, builder.input(i));
            builder.manage(builder.input(i), _leaf(actions[i]), bindings);
        }
        uint256[][] memory withdrawal = new uint256[][](1);
        withdrawal[0] = new uint256[](2);
        withdrawal[0][0] = ExecutingRecipe.binding(FIRST_WORD, builder.input(2));
        withdrawal[0][1] = ExecutingRecipe.binding(AMOUNT_WORD, builder.input(3));
        builder.manage(builder.input(3), _leaf(actions[2]), withdrawal);
        recipe = builder.finish();
    }

    function _action(address target, bytes memory data, uint256 maskStart)
        private
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = IMerkleAccount.Action({
            target: target, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
        for (uint256 i = maskStart; i < AMOUNT_WORD + 32; ++i) {
            action.dataMask[i] = 0xff;
        }
    }

    function _leaf(IMerkleAccount.Action memory action) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](1);
        leaves[0] = ActionMasker.mask(action.target, 0, action.data, action.dataMask);
    }
}
