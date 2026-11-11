// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {FlashLoanLenderMock, FlashLoanSubjectMock, FlashLoanTokenMock} from "./mocks/FlashLoanCapabilityMocks.sol";
import {FlashLoanCapability} from "src/contracts/merkle-adapter/capabilities/FlashLoanCapability.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";

import {IFlashLoanCapability} from "src/interfaces/merkle-adapter/capabilities/IFlashLoanCapability.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {OP_CALL} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FlashLoanCapabilityTest is CapabilityTestBase {
    address internal _token;
    address internal _aave;
    address internal _morpho;
    address internal _subject;
    address internal _implementation;
    uint256 internal constant _AMOUNT = 1000;

    function setUp() public {
        _token = address(new FlashLoanTokenMock());
        _aave = address(new FlashLoanLenderMock());
        _morpho = address(new FlashLoanLenderMock());
        _subject = address(new FlashLoanSubjectMock());
        _deployAdapter(_token);
        _implementation = address(new FlashLoanCapability(_aave, _morpho));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = IFlashLoanCapability.flashLoan.selector;
        selectors[1] = IFlashLoanCapability.executeOperation.selector;
        selectors[2] = IFlashLoanCapability.onMorphoFlashLoan.selector;
        _installCapability(adapter, _implementation, selectors);
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        FlashLoanTokenMock(_token).mint(_aave, 1e24);
        FlashLoanTokenMock(_token).mint(_morpho, 1e24);
        FlashLoanTokenMock(_token).mint(account, 7);
    }

    function test_ImmutableProviders() public view {
        assertEq(IFlashLoanCapability(_implementation).AAVE_V3_POOL(), _aave);
        assertEq(IFlashLoanCapability(_implementation).MORPHO_BLUE(), _morpho);
    }

    /// forge-config: default.isolate = true
    function test_AaveExecutesCommittedRecipeAndRepaysPremium() public {
        _manage(account, _loan(true, _AMOUNT, _body(_AMOUNT)));
        vm.snapshotGasLastCall("FlashLoanCapability", "aaveFlashLoanAndCallback");
        _assertRepaid(true, _AMOUNT);
    }

    /// forge-config: default.isolate = true
    function test_MorphoExecutesCommittedRecipeAndRepaysPrincipal() public {
        _manage(account, _loan(false, _AMOUNT, _body(_AMOUNT)));
        vm.snapshotGasLastCall("FlashLoanCapability", "morphoFlashLoanAndCallback");
        _assertRepaid(false, _AMOUNT);
    }

    function testFuzz_FlashLoans(bool aave, uint96 amount) public {
        amount = uint96(bound(amount, 1, 1e23));
        _manage(account, _loan(aave, amount, _body(amount)));
        _assertRepaid(aave, amount);
    }

    function testFuzz_DirectStartIsRejected(bool aave) public {
        bytes memory body = _body(_AMOUNT);
        vm.expectRevert(IFlashLoanCapability.InvalidCaller.selector);
        IFlashLoanCapability(account)
            .flashLoan(aave ? IFlashLoanCapability.Type.Aave : IFlashLoanCapability.Type.Morpho, _token, _AMOUNT, body);
    }

    function test_ImplementationCannotBeStartedDirectly() public {
        bytes memory body = _body(_AMOUNT);
        vm.expectRevert(IFlashLoanCapability.InvalidCaller.selector);
        IFlashLoanCapability(_implementation).flashLoan(IFlashLoanCapability.Type.Aave, _token, _AMOUNT, body);
    }

    function test_ValidProofWithoutCallerRoleIsRejected() public {
        IMerkleAccount.Action[] memory actions = _publishCall(account, _loan(true, _AMOUNT, _body(_AMOUNT)));
        address stranger = address(0xBAD);
        bytes32 role = IMerkleAccount(account).root();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        vm.prank(stranger);
        IMerkleAccount(account).manage(actions);
        assertEq(FlashLoanSubjectMock(_subject).calls(), 0);
    }

    function test_ChangedInnerActionBreaksProof() public {
        IMerkleAccount.Action[] memory actions = _publishCall(account, _loan(true, _AMOUNT, _body(_AMOUNT)));
        actions[0].data = _loan(true, _AMOUNT, _body(_AMOUNT + 1));
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        IMerkleAccount(account).manage(actions);
        assertEq(FlashLoanSubjectMock(_subject).calls(), 0);
    }

    function test_RootChangeRevokesLoan() public {
        IMerkleAccount.Action[] memory actions = _publishCall(account, _loan(false, _AMOUNT, _body(_AMOUNT)));
        IMerkleAccount(account).acceptRoot(bytes32(0));
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        IMerkleAccount(account).manage(actions);
    }

    function test_AaveCallbackWithoutRequestIsRejected() public {
        bytes memory body = _body(_AMOUNT);
        vm.expectRevert(IFlashLoanCapability.UnexpectedFlashLoan.selector);
        vm.prank(_aave);
        IFlashLoanCapability(account).executeOperation(_token, _AMOUNT, 7, account, body);
    }

    function test_MorphoCallbackWithoutRequestIsRejected() public {
        bytes memory data = abi.encode(_token, _body(_AMOUNT));
        vm.expectRevert(IFlashLoanCapability.UnexpectedFlashLoan.selector);
        vm.prank(_morpho);
        IFlashLoanCapability(account).onMorphoFlashLoan(_AMOUNT, data);
    }

    function test_ThirdPartyAaveInitiatorIsRejected() public {
        bytes memory body = _body(_AMOUNT);
        vm.expectRevert(IFlashLoanCapability.UnexpectedFlashLoan.selector);
        FlashLoanLenderMock(_aave).flashLoanSimple(account, _token, _AMOUNT, body, 0);
    }

    function testFuzz_ChangedCallbackCommitmentIsRejected(bool aave, uint8 mutation) public {
        mutation = uint8(bound(mutation, 1, 3));
        _expectMutationRejected(
            aave, FlashLoanLenderMock.Mutation(mutation), IFlashLoanCapability.UnexpectedFlashLoan.selector
        );
    }

    function test_ForeignInitiatorDuringActiveAaveLoanIsRejected() public {
        _expectMutationRejected(
            true, FlashLoanLenderMock.Mutation.Initiator, IFlashLoanCapability.UnexpectedFlashLoan.selector
        );
    }

    function testFuzz_WrongProviderDuringActiveLoanIsRejected(bool aave) public {
        _expectMutationRejected(
            aave, FlashLoanLenderMock.Mutation.Sender, IFlashLoanCapability.UnexpectedFlashLoan.selector
        );
    }

    function testFuzz_LenderMustInvokeCallback(bool aave) public {
        _expectMutationRejected(
            aave, FlashLoanLenderMock.Mutation.Skip, IFlashLoanCapability.UnexpectedFlashLoan.selector
        );
    }

    function testFuzz_ProviderCannotReplayCallback(bool aave) public {
        _expectMutationRejected(
            aave, FlashLoanLenderMock.Mutation.Replay, IFlashLoanCapability.UnexpectedFlashLoan.selector
        );
    }

    function testFuzz_CallbackCannotReplayDuringAction(bool aave) public {
        address lender = aave ? _aave : _morpho;
        bytes memory body = _recipe(lender, abi.encodeCall(FlashLoanLenderMock.replay, ()));
        IMerkleAccount.Action[] memory actions = _publishCall(account, _loan(aave, _AMOUNT, body));
        vm.expectRevert(IFlashLoanCapability.UnexpectedFlashLoan.selector);
        IMerkleAccount(account).manage(actions);
        assertEq(IERC20(_token).balanceOf(account), 7);
    }

    function testFuzz_CallbackCannotReplayDuringApproval(bool aave) public {
        address lender = aave ? _aave : _morpho;
        FlashLoanTokenMock(_token).setApprovalCallback(lender);
        IMerkleAccount.Action[] memory actions = _publishCall(account, _loan(aave, _AMOUNT, _body(_AMOUNT)));
        vm.expectRevert();
        IMerkleAccount(account).manage(actions);
        assertEq(FlashLoanSubjectMock(_subject).calls(), 0);
        assertEq(IERC20(_token).balanceOf(account), 7);
    }

    function testFuzz_CallbackCannotReplayAfterLoan(bool aave) public {
        _manage(account, _loan(aave, _AMOUNT, _body(_AMOUNT)));
        vm.expectRevert(IFlashLoanCapability.UnexpectedFlashLoan.selector);
        FlashLoanLenderMock(aave ? _aave : _morpho).replay();
        assertEq(FlashLoanSubjectMock(_subject).calls(), 1);
    }

    function testFuzz_ActionFailureRollsBackLoan(bool aave) public {
        bytes memory body = _recipe(_subject, abi.encodeCall(FlashLoanSubjectMock.fail, ()));
        IMerkleAccount.Action[] memory actions = _publishCall(account, _loan(aave, _AMOUNT, body));
        vm.expectRevert(FlashLoanSubjectMock.ActionFailed.selector);
        IMerkleAccount(account).manage(actions);
        assertEq(IERC20(_token).balanceOf(account), 7);
        assertEq(IERC20(_token).allowance(account, aave ? _aave : _morpho), 0);
        _manage(account, _loan(aave, _AMOUNT, _body(_AMOUNT)));
        _assertRepaid(aave, _AMOUNT);
    }

    function test_InsufficientPremiumRollsBackActions() public {
        vm.prank(account);
        IERC20(_token).transfer(address(0xBAD), 7);
        IMerkleAccount.Action[] memory actions = _publishCall(account, _loan(true, _AMOUNT, _body(_AMOUNT)));
        vm.expectRevert();
        IMerkleAccount(account).manage(actions);
        assertEq(FlashLoanSubjectMock(_subject).calls(), 0);
        assertEq(IERC20(_token).balanceOf(account), 0);
        assertEq(IERC20(_token).allowance(account, _aave), 0);
    }

    function test_NestedLoansUseCommittedInnerLoan() public {
        bytes memory inner = _loan(false, _AMOUNT, _body(_AMOUNT));
        _manage(account, _loan(true, _AMOUNT, inner));
        assertEq(FlashLoanSubjectMock(_subject).calls(), 1);
        assertEq(IERC20(_token).balanceOf(account), 0);
        assertEq(IERC20(_token).balanceOf(_aave), 1e24 + 7);
        assertEq(IERC20(_token).balanceOf(_morpho), 1e24);
        assertEq(IERC20(_token).allowance(account, _aave), 0);
        assertEq(IERC20(_token).allowance(account, _morpho), 0);
    }

    function test_InnerManageRemainsBlocked() public {
        bytes memory body = abi.encodeCall(IMerkleAccount.manage, (new IMerkleAccount.Action[](0)));
        IMerkleAccount.Action[] memory actions = _publishCall(account, _loan(true, _AMOUNT, body));
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        IMerkleAccount(account).manage(actions);
        assertEq(IERC20(_token).balanceOf(account), 7);
    }

    function test_SequentialLoansInOneManageCall() public {
        bytes[] memory steps = new bytes[](2);
        steps[0] =
            abi.encodePacked(OP_CALL, abi.encode(account, _loan(true, _AMOUNT, _body(_AMOUNT)), new uint256[](0)));
        steps[1] =
            abi.encodePacked(OP_CALL, abi.encode(account, _loan(false, _AMOUNT, _body(_AMOUNT)), new uint256[](0)));
        _manage(account, abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), steps, new uint256[](0))));
        assertEq(FlashLoanSubjectMock(_subject).calls(), 2);
        assertEq(FlashLoanSubjectMock(_subject).borrowed(), 2 * _AMOUNT);
        assertEq(IERC20(_token).balanceOf(account), 0);
    }

    function _expectMutationRejected(bool aave, FlashLoanLenderMock.Mutation mutation, bytes4 errorSelector) internal {
        address lender = aave ? _aave : _morpho;
        FlashLoanLenderMock(lender).configure(mutation, aave ? _morpho : _aave);
        IMerkleAccount.Action[] memory actions = _publishCall(account, _loan(aave, _AMOUNT, _body(_AMOUNT)));
        vm.expectRevert(errorSelector);
        IMerkleAccount(account).manage(actions);
        assertEq(FlashLoanSubjectMock(_subject).calls(), 0);
        assertEq(IERC20(_token).balanceOf(account), 7);
        assertEq(IERC20(_token).allowance(account, lender), 0);
    }

    function _assertRepaid(bool aave, uint256 amount) internal view {
        assertEq(FlashLoanSubjectMock(_subject).calls(), 1);
        assertEq(FlashLoanSubjectMock(_subject).borrowed(), amount);
        assertEq(FlashLoanSubjectMock(_subject).caller(), account);
        assertEq(IERC20(_token).balanceOf(account), aave ? 0 : 7);
        assertEq(IERC20(_token).balanceOf(_aave), 1e24 + (aave ? 7 : 0));
        assertEq(IERC20(_token).balanceOf(_morpho), 1e24);
        assertEq(IERC20(_token).allowance(account, aave ? _aave : _morpho), 0);
    }

    function _loan(bool aave, uint256 amount, bytes memory body) internal view returns (bytes memory) {
        return abi.encodeCall(
            IFlashLoanCapability.flashLoan,
            (aave ? IFlashLoanCapability.Type.Aave : IFlashLoanCapability.Type.Morpho, _token, amount, body)
        );
    }

    function _body(uint256 amount) internal view returns (bytes memory) {
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodePacked(
            OP_CALL, abi.encode(_token, abi.encodeCall(IERC20.transfer, (_subject, amount)), new uint256[](0))
        );
        steps[1] = abi.encodePacked(
            OP_CALL,
            abi.encode(_subject, abi.encodeCall(FlashLoanSubjectMock.returnTokens, (_token, amount)), new uint256[](0))
        );
        return abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), steps, new uint256[](0)));
    }

    function _recipe(address target, bytes memory data) internal pure returns (bytes memory) {
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_CALL, abi.encode(target, data, new uint256[](0)));
        return abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), steps, new uint256[](0)));
    }
}
