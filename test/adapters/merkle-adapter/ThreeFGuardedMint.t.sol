// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/automations/policies/ThreeFPolicy.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ThreeFGuardedMint} from "script/recipes/ThreeFGuardedMint.sol";

import {ThreeFRequestMock, ThreeFRequestFactoryMock} from "test/mocks/ThreeFRequestMocks.sol";
import {Token} from "test/mocks/Token.sol";
import {createThreeFPolicy} from "test/helpers/ThreeFPolicyFactory.sol";

/// @dev A curator holding the leaf role executes the guarded mint without any RecipeExecutor.
/// The leaf itself has to meter the charge and bind it to what the protocol actually did.
contract ThreeFGuardedMintTest is CapabilityTestBase {
    uint128 internal constant PRINCIPAL = 100;
    uint128 internal constant YIELD = 10;

    address internal _asset;
    address internal _policy;
    address internal _request;
    address internal _requestsFactory;
    IMerkleAccount.Action internal _approval;
    IMerkleAccount.Action internal _mint;

    function setUp() public {
        _asset = address(new Token("Funding"));
        _deployAdapter(_asset);
        _installCapability(adapter, address(new GuardedCallsCapability()), _guardedSelectors());
        _requestsFactory = address(new ThreeFRequestFactoryMock());
        _request = address(new ThreeFRequestMock(_asset, "request"));
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, true);
        ThreeFRequestMock(_request).authorizeMinting(account, PRINCIPAL, YIELD);
        _policy = address(createThreeFPolicy(address(this), account));
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, 1000, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 100_000);
        IERC20(_asset).transfer(account, PRINCIPAL);
        _approval = _raw(_asset, abi.encodeCall(IERC20.approve, (_request, PRINCIPAL)));
        _mint = _guardedMint(_request);
        _publish();
    }

    function test_DirectManageChargesTheBudgetWithoutAnExecutor() public {
        _execute(PRINCIPAL, YIELD);
        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(pt, PRINCIPAL);
        assertEq(yt, YIELD);
        assertEq(IERC20(_asset).balanceOf(_request), PRINCIPAL);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 1000 - PRINCIPAL);
    }

    function test_UnderstatedPrincipalCannotUnderchargeTheBudget() public {
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        _executeWith(1, YIELD, PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    function test_UnderstatedYieldCannotSatisfyTheMinimum() public {
        ThreeFRequestMock(_request).authorizeMinting(account, PRINCIPAL, 5);
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        _executeWith(PRINCIPAL, YIELD, PRINCIPAL, 5);
        _assertNothingHappened();
    }

    function test_OverstatedPrincipalCannotPadTheCharge() public {
        // The declared pair still clears the yield floor, so the balance delta is what rejects it.
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        _executeWith(PRINCIPAL + 1, YIELD + 1, PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    function testFuzz_DeclaredAmountsMustMatchTheMintedAmounts(uint8 declaredPrincipal, uint8 declaredYield) public {
        vm.assume(declaredPrincipal != PRINCIPAL || declaredYield != YIELD);
        vm.assume(declaredPrincipal > 0);
        vm.expectRevert();
        _executeWith(declaredPrincipal, declaredYield, PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    function test_FactoryMembershipIsCheckedOnTheDirectPath() public {
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, false);
        vm.expectRevert(IGuardedCallsCapability.CheckFailed.selector);
        _execute(PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    function test_PeriodBudgetStopsTheDirectPath() public {
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, PRINCIPAL - 1, 1 days);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        _execute(PRINCIPAL, YIELD);
        _assertUnminted(PRINCIPAL - 1);
    }

    function test_YieldMinimumStopsTheDirectPath() public {
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 100_001);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _execute(PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    function test_RepointedConsumerStopsTheDirectPath() public {
        ThreeFPolicy(_policy).setConsumer(address(0));
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        _execute(PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    function test_CapabilityCannotBeReachedWithoutTheLeafRole() public {
        MerkleAccount(payable(account)).revokeRole(_leaf(_mint), address(this));
        vm.expectRevert();
        _execute(PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    /* INTERNAL FUNCTIONS */

    function _execute(uint128 principal, uint128 yieldAssets) internal {
        _executeWith(principal, yieldAssets, principal, yieldAssets);
    }

    /// @dev Declared amounts go to the policy, minted amounts to the request; the leaf must tie them together.
    function _executeWith(uint256 declaredPrincipal, uint256 declaredYield, uint128 mintPrincipal, uint128 mintYield)
        internal
    {
        ThreeFGuardedMint.Leaf memory leaf = _leafTemplate(_request);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = _approval;
        actions[1] = _mint;
        ThreeFGuardedMint.write(actions[1].data, leaf.consumeAssets, declaredPrincipal);
        ThreeFGuardedMint.write(actions[1].data, leaf.consumeYield, declaredYield);
        ThreeFGuardedMint.write(actions[1].data, leaf.mintPrincipal, mintPrincipal);
        ThreeFGuardedMint.write(actions[1].data, leaf.mintYield, mintYield);
        MerkleAccount(payable(account)).manage(actions);
    }

    function _assertNothingHappened() internal view {
        _assertUnminted(1000);
    }

    function _assertUnminted(uint256 remaining) internal view {
        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(pt, 0);
        assertEq(yt, 0);
        assertEq(IERC20(_asset).balanceOf(account), PRINCIPAL);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), remaining);
    }

    function _leafTemplate(address request) internal view returns (ThreeFGuardedMint.Leaf memory) {
        return ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                account: account, asset: _asset, policy: _policy, request: request, requestsFactory: _requestsFactory
            })
        );
    }

    function _guardedMint(address request) internal view returns (IMerkleAccount.Action memory) {
        ThreeFGuardedMint.Leaf memory leaf = _leafTemplate(request);
        return IMerkleAccount.Action({
            target: account, value: 0, data: leaf.data, dataMask: leaf.dataMask, proof: new bytes32[](0)
        });
    }

    function _raw(address target, bytes memory data) internal pure returns (IMerkleAccount.Action memory) {
        return IMerkleAccount.Action({
            target: target, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
    }

    function _leaf(IMerkleAccount.Action memory action) internal pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
    }

    function _publish() internal {
        bytes32 a = _leaf(_approval);
        bytes32 b = _leaf(_mint);
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        MerkleAccount(payable(account)).grantRole(a, address(this));
        MerkleAccount(payable(account)).grantRole(b, address(this));
        _approval.proof = new bytes32[](1);
        _approval.proof[0] = b;
        _mint.proof = new bytes32[](1);
        _mint.proof[0] = a;
    }
}
