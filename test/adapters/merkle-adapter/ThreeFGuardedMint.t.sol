// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";

import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {OP_CALL, SRC_INPUT} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ThreeFGuardedMint} from "script/recipes/ThreeFGuardedMint.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {
    ThreeFFacilityMock,
    ThreeFPositionManagerMock,
    ThreeFRequestFactoryMock,
    ThreeFRequestMock,
    ThreeFUnderlyingAssetMock
} from "test/mocks/ThreeFRequestMocks.sol";
import {Token} from "test/mocks/Token.sol";
import {createThreeFPolicy} from "test/helpers/ThreeFPolicyFactory.sol";

/// @dev A curator holding the leaf role executes the guarded mint without any RecipeExecutor.
/// The leaf shares principal/yield inputs across policy consumption, approval and native mint.
contract ThreeFGuardedMintTest is CapabilityTestBase {
    using stdJson for string;
    uint128 internal constant PRINCIPAL = 100;
    uint128 internal constant YIELD = 10;

    address internal _asset;
    address internal _rwa;
    address internal _facility;
    address internal _positionManager;
    address internal _policy;
    address internal _request;
    address internal _requestsFactory;
    IMerkleAccount.Action internal _approval;
    IMerkleAccount.Action internal _mint;

    function setUp() public virtual {
        _asset = address(new Token("Funding"));
        _rwa = address(new Token("RWA"));
        _facility = address(new ThreeFFacilityMock());
        _positionManager = address(new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(_rwa)), _asset));
        _deployAdapter(_asset);
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        _requestsFactory = address(new ThreeFRequestFactoryMock());
        _request = address(new ThreeFRequestMock(_asset, "request-1"));
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, true);
        ThreeFFacilityMock(_facility).setIntent(1, _request, _positionManager, true);
        ThreeFRequestMock(_request).authorizeMinting(account, PRINCIPAL, YIELD);
        _policy = createThreeFPolicy(address(this), account, _requestsFactory, _facility);
        _manage(_policy, abi.encodeCall(IThreeFPolicy.setMaxAssetsPerDuration, (_asset, _rwa, 1000, 1 days)));
        _manage(_policy, abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (_rwa, 10_000_000)));
        IERC20(_asset).transfer(account, PRINCIPAL);
        _approval = _raw(_asset, abi.encodeCall(IERC20.approve, (_request, PRINCIPAL)));
        _mint = _guardedMint(_request);
        _publish();
    }

    function test_LeafMatchesFrontendEncodingWithAndWithoutReset() public view {
        string memory fixture = vm.readFile("test/fixtures/recipes/three-f-mint.json");
        for (uint256 i; i < 2; ++i) {
            string memory path = string.concat(".cases[", vm.toString(i), "]");
            ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
                ThreeFGuardedMint.Config({
                    asset: fixture.readAddress(string.concat(path, ".asset")),
                    policy: fixture.readAddress(string.concat(path, ".policy")),
                    request: fixture.readAddress(string.concat(path, ".request")),
                    resetApproval: fixture.readBool(string.concat(path, ".resetApproval"))
                })
            );
            assertEq(
                ActionMasker.mask(fixture.readAddress(string.concat(path, ".account")), 0, leaf.data, leaf.dataMask),
                fixture.readBytes32(string.concat(path, ".hash"))
            );
        }
    }

    function test_ConfigurationRequiresApprovedLeafAndRole() public {
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_rwa, 0);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, _rwa, type(uint256).max, 1);

        IMerkleAccount.Action[] memory actions =
            _publishCall(_policy, abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (_rwa, 5_000_000)));
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, _leaf(actions[0]))
        );
        IMerkleAccount(account).manage(actions);
        actions[0].data = abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (_rwa, 0));
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        IMerkleAccount(account).manage(actions);
        assertEq(ThreeFPolicy(_policy).minYieldPerRequest(_rwa), 10_000_000);

        actions[0].data = abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (_rwa, 5_000_000));
        IMerkleAccount(account).manage(actions);
        _manage(_policy, abi.encodeCall(IThreeFPolicy.setMaxAssetsPerDuration, (_asset, _rwa, 200, 1 days)));
        assertEq(ThreeFPolicy(_policy).minYieldPerRequest(_rwa), 5_000_000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 200);
        _publish();
        _execute(PRINCIPAL, YIELD);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 200 - PRINCIPAL);
    }

    function test_DirectManageChargesCollateralBudgetWithoutAnExecutor() public {
        _execute(PRINCIPAL, YIELD);
        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(pt, PRINCIPAL);
        assertEq(yt, YIELD);
        assertEq(IERC20(_asset).balanceOf(_request), PRINCIPAL);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 1000 - PRINCIPAL);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _asset), 0);
    }

    function test_PrincipalCapIsEnforcedByNativeMint() public {
        vm.expectRevert(ThreeFRequestMock.SlippageExceeded.selector);
        _execute(PRINCIPAL - 1, YIELD);
        _assertNothingHappened();
    }

    function test_YieldFloorIsEnforcedByNativeMint() public {
        vm.expectRevert(ThreeFRequestMock.SlippageExceeded.selector);
        _execute(PRINCIPAL, YIELD + 1);
        _assertNothingHappened();
    }

    function test_NativeMintFailureRollsBackBudgetAndApproval() public {
        ThreeFRequestMock(_request).setFailMint(true);
        vm.expectRevert(ThreeFRequestMock.MintFailed.selector);
        _execute(PRINCIPAL, YIELD);
        _assertNothingHappened();
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }

    function testFuzz_CallSequenceSharesTheSameInputs(bool resetApproval) public view {
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({asset: _asset, policy: _policy, request: _request, resetApproval: resetApproval})
        );
        (bytes[] memory queries, bytes[] memory steps, uint256[] memory inputs) =
            abi.decode(Bytes.slice(leaf.data, 4), (bytes[], bytes[], uint256[]));
        assertEq(queries.length, 0);
        assertEq(steps.length, resetApproval ? 5 : 4);
        assertEq(inputs.length, 3);
        for (uint256 i; i < steps.length; ++i) {
            assertEq(uint8(steps[i][0]), OP_CALL);
        }
        (,, uint256[] memory consumeBindings) = abi.decode(Bytes.slice(steps[0], 1), (address, bytes, uint256[]));
        (,, uint256[] memory mintBindings) =
            abi.decode(Bytes.slice(steps[steps.length - 2], 1), (address, bytes, uint256[]));
        assertEq(uint224(consumeBindings[1]), uint256(SRC_INPUT) << 216);
        assertEq(uint224(consumeBindings[2]), uint256(SRC_INPUT) << 216 | 1);
        assertEq(uint224(mintBindings[0]), uint224(consumeBindings[1]));
        assertEq(uint224(mintBindings[1]), uint224(consumeBindings[2]));
    }

    function test_FactoryMembershipIsCheckedOnTheDirectPath() public {
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, false);
        vm.expectRevert(IThreeFPolicy.InvalidRequest.selector);
        _execute(PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    function test_FacilityRequestMismatchRollsBackApprovalAndMint() public {
        ThreeFFacilityMock(_facility).setIntent(1, address(1), _positionManager, true);
        vm.expectRevert(IThreeFPolicy.RequestMismatch.selector);
        _execute(PRINCIPAL, YIELD);
        _assertNothingHappened();
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }

    function test_RetargetBeforeFirstMintCannotUseUnconfiguredPair() public {
        address other = address(new Token("Other RWA"));
        ThreeFFacilityMock(_facility)
            .setIntent(
                1,
                _request,
                address(new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(other)), _asset)),
                true
            );
        ThreeFRequestMock(_request).authorizeMinting(account, PRINCIPAL, 1);

        vm.expectRevert(AssetRateLimits.UnconfiguredAsset.selector);
        _execute(PRINCIPAL, 1);

        _assertNothingHappened();
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, other), 0);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }

    function test_RetargetAfterMintCannotUseUnconfiguredPair() public {
        _execute(PRINCIPAL, YIELD);
        address other = address(new Token("Other RWA"));
        ThreeFFacilityMock(_facility)
            .setIntent(
                1,
                _request,
                address(new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(other)), _asset)),
                true
            );
        ThreeFRequestMock(_request).authorizeMinting(account, PRINCIPAL, YIELD);
        IERC20(_asset).transfer(account, PRINCIPAL);

        vm.expectRevert(AssetRateLimits.UnconfiguredAsset.selector);
        _execute(PRINCIPAL, YIELD);

        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(pt, PRINCIPAL);
        assertEq(yt, YIELD);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 1000 - PRINCIPAL);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, other), 0);
        assertEq(IERC20(_asset).balanceOf(account), PRINCIPAL);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }

    function testFuzz_RetargetChargesTheSelectedEnabledPair(bool alreadyMinted) public {
        if (alreadyMinted) {
            _execute(PRINCIPAL, YIELD);
            ThreeFRequestMock(_request).authorizeMinting(account, PRINCIPAL, YIELD);
            IERC20(_asset).transfer(account, PRINCIPAL);
        }
        address other = address(new Token("Other RWA"));
        vm.prank(account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, other, 1000, 1 days);
        ThreeFFacilityMock(_facility)
            .setIntent(
                1,
                _request,
                address(new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(other)), _asset)),
                true
            );

        _execute(PRINCIPAL, YIELD);

        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(pt, alreadyMinted ? 2 * PRINCIPAL : PRINCIPAL);
        assertEq(yt, alreadyMinted ? 2 * YIELD : YIELD);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), alreadyMinted ? 1000 - PRINCIPAL : 1000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, other), 1000 - PRINCIPAL);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }

    function test_RetargetWithSameCollateralUnderlyingPreservesUsage() public {
        _execute(PRINCIPAL, YIELD);
        ThreeFFacilityMock(_facility)
            .setIntent(
                1,
                _request,
                address(new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(_rwa)), _asset)),
                true
            );
        ThreeFRequestMock(_request).authorizeMinting(account, PRINCIPAL, YIELD);
        IERC20(_asset).transfer(account, PRINCIPAL);

        _execute(PRINCIPAL, YIELD);

        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(pt, 2 * PRINCIPAL);
        assertEq(yt, 2 * YIELD);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 1000 - 2 * PRINCIPAL);
    }

    function testFuzz_BudgetDebitMatchesAcrossPeriodRollover(uint8 periods) public {
        periods = uint8(bound(periods, 1, 30));
        _execute(PRINCIPAL, YIELD);
        vm.warp(block.timestamp + uint256(periods) * 1 days);
        ThreeFRequestMock(_request).authorizeMinting(account, PRINCIPAL, YIELD);
        IERC20(_asset).transfer(account, PRINCIPAL);

        _execute(PRINCIPAL, YIELD);

        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 1000 - PRINCIPAL);
        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(pt, 2 * PRINCIPAL);
        assertEq(yt, 2 * YIELD);
    }

    function test_FundingTokenCannotBeChangedInTheAuthorizedLeaf() public {
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                asset: makeAddr("otherFunding"), resetApproval: true, policy: _policy, request: _request
            })
        );
        _mint.data = leaf.data;
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        _execute(PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    function test_TokenWithoutResetUsesShorterLeafAndClearsAllowance() public {
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({asset: _asset, policy: _policy, request: _request, resetApproval: false})
        );
        (bytes[] memory queries, bytes[] memory steps,) =
            abi.decode(Bytes.slice(leaf.data, 4), (bytes[], bytes[], uint256[]));
        assertEq(queries.length, 0);
        assertEq(steps.length, 4);
        assertEq(leaf.requestOffsets.length, 2);
        _mint.data = leaf.data;
        _mint.dataMask = leaf.dataMask;
        _publish();
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _mint;
        ThreeFGuardedMint.write(actions[0].data, leaf.assets, PRINCIPAL);
        ThreeFGuardedMint.write(actions[0].data, leaf.yieldAssets, YIELD);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 1000 - PRINCIPAL);
    }

    function test_PeriodBudgetStopsTheDirectPath() public {
        vm.prank(account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, _rwa, PRINCIPAL - 1, 1 days);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        _execute(PRINCIPAL, YIELD);
        _assertUnminted(PRINCIPAL - 1);
    }

    function test_YieldMinimumStopsTheDirectPath() public {
        vm.prank(account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_rwa, 10_000_001);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _execute(PRINCIPAL, YIELD);
        _assertNothingHappened();
    }

    function test_ForeignAccountPolicyRejectsGuardedMint() public {
        _policy = createThreeFPolicy(address(this), address(0xBAD), _requestsFactory, _facility);
        vm.prank(address(0xBAD));
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, _rwa, 1000, 1 days);
        _mint = _guardedMint(_request);
        _publish();
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

    function test_NewAuctionUsesTheSameLeafAndAccumulatesBudget() public {
        _execute(PRINCIPAL, YIELD);
        bytes32 root = MerkleAccount(payable(account)).root();
        bytes32 leafHash = _leaf(_mint);
        _request = address(new ThreeFRequestMock(_asset, "request-2"));
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, true);
        ThreeFFacilityMock(_facility).setIntent(2, _request, _positionManager, true);
        ThreeFRequestMock(_request).authorizeMinting(account, PRINCIPAL, YIELD);
        IERC20(_asset).transfer(account, PRINCIPAL);
        ThreeFGuardedMint.Leaf memory leaf = _leafTemplate(_request);
        _mint.data = leaf.data;
        assertEq(_leaf(_mint), leafHash);
        _execute(PRINCIPAL, YIELD);
        assertEq(MerkleAccount(payable(account)).root(), root);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 1000 - 2 * PRINCIPAL);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(pt, PRINCIPAL);
        assertEq(yt, YIELD);
    }

    /* INTERNAL FUNCTIONS */

    function _execute(uint128 principal, uint128 yieldAssets) internal {
        ThreeFGuardedMint.Leaf memory leaf = _leafTemplate(_request);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _mint;
        ThreeFGuardedMint.write(actions[0].data, leaf.assets, principal);
        ThreeFGuardedMint.write(actions[0].data, leaf.yieldAssets, yieldAssets);
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
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), remaining);
    }

    function _leafTemplate(address request) internal view returns (ThreeFGuardedMint.Leaf memory) {
        return ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({asset: _asset, resetApproval: true, policy: _policy, request: request})
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
        return ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
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
