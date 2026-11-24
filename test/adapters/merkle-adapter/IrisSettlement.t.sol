// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IIris} from "src/interfaces/merkle-adapter/IIris.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {IrisSettlement} from "script/recipes/IrisSettlement.sol";

import {Token} from "test/mocks/Token.sol";

contract IrisSettlementTest is CapabilityTestBase {
    using stdJson for string;

    address internal constant POD = address(0x90D);

    address internal _executor;
    address internal _iris;
    address internal _usdc;
    address internal _weth;
    ExecutingRecipe.Recipe internal _recipe;
    IMerkleAccount.Action[] internal _actions;
    bytes32[3] internal _leaves;

    function setUp() public {
        _deployAdapter(address(new Token("asset")));
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        _usdc = address(new Token("usdc"));
        _weth = address(new Token("weth"));
        _iris = address(new IrisSettlementMock(_usdc));
        deal(_usdc, _iris, 1000e6);
        deal(_weth, _iris, 1e18);
        IrisSettlementMock(_iris).credit(_usdc, account, 70e6);
        IrisSettlementMock(_iris).credit(_weth, account, 0.1e18);
        IrisSettlementMock(_iris).setBond(POD, account, 300e6);

        IMerkleAccount.Action[] memory actions;
        (_recipe, actions) = IrisSettlement.build(
            IrisSettlement.Config({account: account, iris: _iris, debtToken: _usdc, collateralToken: _weth})
        );
        for (uint256 i; i < 3; ++i) {
            _actions.push(actions[i]);
            _leaves[i] = ActionMasker.mask(actions[i].target, 0, actions[i].data, actions[i].dataMask);
        }
        bytes32 root = _hashPair(_hashPair(_leaves[0], _leaves[1]), _leaves[2]);
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        for (uint256 i; i < 3; ++i) {
            MerkleAccount(payable(account)).grantRole(_leaves[i], _executor);
        }
        RecipeExecutor(_executor).setRecipe(_recipe.queries, _recipe.steps);
    }

    function test_ClaimsBothTokensAndWithdrawsBondToTheAccount() public {
        _run(70e6, 0.1e18, POD, 100e6);
        assertEq(IERC20(_usdc).balanceOf(account), 170e6);
        assertEq(IERC20(_weth).balanceOf(account), 0.1e18);
        assertEq(IrisSettlementMock(_iris).claimable(_usdc, account), 0);
        assertEq(IrisSettlementMock(_iris).bond(POD), 200e6);
    }

    function test_ZeroAmountsSkipTheirCalls() public {
        _run(0, 0, POD, 100e6);
        assertEq(IERC20(_usdc).balanceOf(account), 100e6);
        assertEq(IERC20(_weth).balanceOf(account), 0);
        _run(30e6, 0, address(0), 0);
        assertEq(IERC20(_usdc).balanceOf(account), 130e6);
        assertEq(IrisSettlementMock(_iris).bond(POD), 200e6);
    }

    function test_RejectsAnotherReceiver() public {
        _actions[0].data = abi.encodeCall(IIris.claim, (_usdc, 0, account, address(0xBAD)));
        vm.expectRevert();
        _run(70e6, 0, address(0), 0);
        _actions[0].data = abi.encodeCall(IIris.claim, (_usdc, 0, address(0xBAD), account));
        vm.expectRevert();
        _run(70e6, 0, address(0), 0);
    }

    function test_BuildScriptProducesTheSameProgramAndLeaves() public {
        string memory input = "out/IrisSettlement.input.json";
        string memory output = "out/IrisSettlement.output.json";
        vm.writeFile(
            input,
            string.concat(
                '{"template":"iris-settlement","curator":"',
                vm.toString(address(this)),
                '","provider":"',
                vm.toString(address(this)),
                '","adapter":"',
                vm.toString(address(adapter)),
                '","addresses":{"iris":"',
                vm.toString(_iris),
                '","debtToken":"',
                vm.toString(_usdc),
                '","collateralToken":"',
                vm.toString(_weth),
                '"}}'
            )
        );
        BuildRecipe(deployCode("BuildRecipe.s.sol:BuildRecipe")).run(input, output);
        string memory built = vm.readFile(output);
        assertEq(built.readBytes32(".recipeHash"), keccak256(abi.encode(_recipe.queries, _recipe.steps)));
        assertEq(built.readBytes32(".claimDebtLeaf"), _leaves[0]);
        assertEq(built.readBytes32(".claimCollateralLeaf"), _leaves[1]);
        assertEq(built.readBytes32(".withdrawBondLeaf"), _leaves[2]);
        assertEq(built.readBytes(".withdrawBondMask"), _actions[2].dataMask);
        vm.removeFile(input);
        vm.removeFile(output);
    }

    function _run(uint256 debtClaim, uint256 collateralClaim, address pod, uint256 bond) internal {
        uint256[] memory inputs = new uint256[](4);
        inputs[0] = debtClaim;
        inputs[1] = collateralClaim;
        inputs[2] = uint256(uint160(pod));
        inputs[3] = bond;
        bytes32 upper = _hashPair(_leaves[0], _leaves[1]);
        bytes32[][3] memory proofs;
        proofs[0] = new bytes32[](2);
        (proofs[0][0], proofs[0][1]) = (_leaves[1], _leaves[2]);
        proofs[1] = new bytes32[](2);
        (proofs[1][0], proofs[1][1]) = (_leaves[0], _leaves[2]);
        proofs[2] = new bytes32[](1);
        proofs[2][0] = upper;
        bytes[] memory runtime = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            if (inputs[i == 2 ? 3 : i] == 0) continue;
            IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
            actions[0] = _actions[i];
            actions[0].proof = proofs[i];
            runtime[i] = abi.encode(actions);
        }
        RecipeExecutor(_executor).execute(_recipe.queries, _recipe.steps, inputs, runtime);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

/// @dev Mirrors Iris.claim and Iris.withdrawBond authorization and balances (iris-core src/Iris.sol:660-680, 970-979).
contract IrisSettlementMock {
    error Unauthorized();

    address public immutable debtToken;

    mapping(address token => mapping(address account => uint256)) public claimable;
    mapping(address pod => address) public solver;
    mapping(address pod => uint256) public bond;

    constructor(address newDebtToken) {
        debtToken = newDebtToken;
    }

    function credit(address token, address account, uint256 amount) public {
        claimable[token][account] += amount;
    }

    function setBond(address pod, address newSolver, uint256 amount) public {
        solver[pod] = newSolver;
        bond[pod] = amount;
    }

    function claim(address token, uint256 amount, address onBehalf, address receiver) public {
        if (onBehalf != msg.sender) revert Unauthorized();
        claimable[token][onBehalf] -= amount;
        IERC20(token).transfer(receiver, amount);
    }

    function withdrawBond(address pod, uint256 amount, address receiver) public {
        if (solver[pod] != msg.sender) revert Unauthorized();
        bond[pod] -= amount;
        IERC20(debtToken).transfer(receiver, amount);
    }
}
