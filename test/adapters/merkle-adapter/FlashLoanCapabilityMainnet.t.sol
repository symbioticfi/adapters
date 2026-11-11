// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {FlashLoanCapability} from "src/contracts/merkle-adapter/capabilities/FlashLoanCapability.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";

import {IFlashLoanCapability} from "src/interfaces/merkle-adapter/capabilities/IFlashLoanCapability.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {OP_CALL, OP_EQUAL, OP_READ, SRC_RESULT} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAaveFlashLoanPremium {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

contract FlashLoanCapabilityMainnetTest is CapabilityTestBase {
    // https://github.com/bgd-labs/aave-address-book/blob/main/src/AaveV3Ethereum.sol
    address internal constant AAVE = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    // https://docs.morpho.org/developers/contracts/addresses/
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant AMOUNT = 1 ether;
    uint256 internal constant PREFUND = 0.01 ether;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ETH_RPC_URL is required for flash loan mainnet integration");
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("MAINNET_FORK_BLOCK", uint256(25_892_000)));
        assertEq(block.chainid, 1);
        assertGt(AAVE.code.length, 0);
        assertGt(MORPHO.code.length, 0);
        _deployAdapter(WETH);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = IFlashLoanCapability.flashLoan.selector;
        selectors[1] = IFlashLoanCapability.executeOperation.selector;
        selectors[2] = IFlashLoanCapability.onMorphoFlashLoan.selector;
        _installCapability(adapter, address(new FlashLoanCapability(AAVE, MORPHO)), selectors);
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        deal(WETH, account, PREFUND);
    }

    function test_AaveRepaysPrincipalAndPremium() public {
        // AMOUNT is divisible by 10_000, so Aave's percentage rounding is exact.
        uint256 premium = AMOUNT * IAaveFlashLoanPremium(AAVE).FLASHLOAN_PREMIUM_TOTAL() / 10_000;
        _executeLoan(IFlashLoanCapability.Type.Aave);
        assertEq(IERC20(WETH).balanceOf(account), PREFUND - premium);
        assertEq(IERC20(WETH).allowance(account, AAVE), 0);
    }

    function test_MorphoRepaysPrincipalWithoutFee() public {
        uint256 lenderBalance = IERC20(WETH).balanceOf(MORPHO);
        _executeLoan(IFlashLoanCapability.Type.Morpho);
        assertEq(IERC20(WETH).balanceOf(account), PREFUND);
        assertEq(IERC20(WETH).balanceOf(MORPHO), lenderBalance);
        assertEq(IERC20(WETH).allowance(account, MORPHO), 0);
    }

    function _executeLoan(IFlashLoanCapability.Type providerType) internal {
        bytes[] memory queries = new bytes[](1);
        queries[0] = abi.encode(WETH, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0));
        bytes[] memory steps = new bytes[](3);
        steps[0] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        steps[1] = abi.encodePacked(OP_EQUAL, abi.encode(uint256(SRC_RESULT) << 216, AMOUNT + PREFUND));
        steps[2] = abi.encodePacked(
            OP_CALL, abi.encode(WETH, abi.encodeCall(IERC20.approve, (address(this), uint256(1))), new uint256[](0))
        );
        _manage(
            account,
            abi.encodeCall(
                IFlashLoanCapability.flashLoan,
                (
                    providerType,
                    WETH,
                    AMOUNT,
                    abi.encodeCall(IRecipeCapability.execute, (queries, steps, new uint256[](0)))
                )
            )
        );
        // The committed callback both observed the principal and called WETH as the account.
        assertEq(IERC20(WETH).allowance(account, address(this)), 1);
    }
}
