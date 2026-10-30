// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {AsyncClaimTokenMock, AsyncClaimVaultMock} from "./AsyncClaimMocks.sol";

import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @dev Executes Curator's unchanged encoded programs in production contracts with a local async-vault fixture.
contract RecipeERC7540Test is CapabilityTestBase {
    using stdJson for string;

    string internal _fixture;
    address internal _asset;
    address internal _vault;
    address internal _executor;

    function setUp() public {
        _fixture = vm.readFile("test/adapters/merkle-adapter/fixtures/erc7540-curator.json");
        _asset = _fixture.readAddress(".asset");
        _vault = _fixture.readAddress(".vault");
        vm.etch(_asset, address(new AsyncClaimTokenMock(6)).code);
        vm.etch(_vault, address(new ERC7540VaultFixture(_asset)).code);
        _deployAdapter(_asset);
        // The fixture commits its account in every recipient/controller word and leaf hash.
        address fixedAccount = _fixture.readAddress(".account");
        vm.cloneAccount(account, fixedAccount);
        account = fixedAccount;
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));

        address capability = address(new RecipeCapability());
        bytes4[] memory selectors = _recipeSelectors();
        CapabilitiesRegistry(IMerkleAccount(account).CAPABILITIES_REGISTRY())
            .whitelistCapability(account, capability, selectors);
        IMerkleAccount(account).addCapability(capability, keccak256(abi.encode(selectors)));
        bytes32 root = _fixture.readBytes32(".root");
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        bytes32[] memory leaves = _fixture.readBytes32Array(".leaves");
        for (uint256 i; i < leaves.length; ++i) {
            MerkleAccount(payable(account)).grantRole(leaves[i], _executor);
        }
        AsyncClaimTokenMock(_asset).mint(account, 117e6);
    }

    function test_RequestThenSettledMintUsesFreshAmountsAndNoSecondPayment() public {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 7e6;
        _execute("requestDeposit", inputs);
        assertEq(IERC20(_asset).balanceOf(account), 110e6);
        assertEq(AsyncClaimVaultMock(_vault).pendingDeposit(account), 7e6);
        assertEq(IERC20(_asset).allowance(account, _vault), 0);

        AsyncClaimVaultMock(_vault).settleDeposit(account, 3e6);
        _execute("claimPurchaseByShares", new uint256[](0));
        assertEq(IERC20(_asset).balanceOf(account), 110e6);
        assertEq(IERC20(_vault).balanceOf(account), 3e18);
        assertEq(AsyncClaimVaultMock(_vault).pendingDeposit(account), 4e6);

        AsyncClaimVaultMock(_vault).settleDeposit(account, 4e6);
        _execute("claimPurchaseByShares", new uint256[](0));
        assertEq(IERC20(_vault).balanceOf(account), 7e18);
        assertEq(IERC20(_asset).balanceOf(account), 110e6);
    }

    function test_SettledRedemptionClaimsAllLiveAssetsAndLeavesPendingAlone() public {
        AsyncClaimVaultMock(_vault).seedShares(account, 20e18);
        vm.prank(account);
        AsyncClaimVaultMock(_vault).requestRedeem(20e18, account, account);
        AsyncClaimTokenMock(_asset).mint(_vault, 20e6);
        AsyncClaimVaultMock(_vault).settleRedeem(account, 8e18);
        _execute("claimRedemptionByAssets", new uint256[](0));
        assertEq(IERC20(_asset).balanceOf(account), 125e6);
        assertEq(AsyncClaimVaultMock(_vault).maxWithdraw(account), 0);
        assertEq(AsyncClaimVaultMock(_vault).pendingRedeem(account), 12e18);

        AsyncClaimVaultMock(_vault).settleRedeem(account, 12e18);
        _execute("claimRedemptionByAssets", new uint256[](0));
        assertEq(IERC20(_asset).balanceOf(account), 137e6);
        assertEq(AsyncClaimVaultMock(_vault).pendingRedeem(account), 0);
    }

    function test_AllPendingClaimsSkipWithoutTouchingWalletBalances() public {
        _execute("claimPurchaseByShares", new uint256[](0));
        _execute("claimRedemptionByAssets", new uint256[](0));
        assertEq(IERC20(_asset).balanceOf(account), 117e6);
        assertEq(IERC20(_vault).balanceOf(account), 0);
    }

    function test_ClosedVaultHeldOnlyLimitCannotBecomeAnInstantRedemption() public {
        AsyncClaimVaultMock(_vault).seedShares(account, 20e18);
        AsyncClaimTokenMock(_asset).mint(_vault, 20e6);
        // Lagoon's closed-vault fallback advertises wallet shares through maxWithdraw.
        ERC7540VaultFixture(_vault).setClosed();
        _execute("claimRedemptionByAssets", new uint256[](0));
        assertEq(IERC20(_asset).balanceOf(account), 117e6);
        assertEq(IERC20(_vault).balanceOf(account), 20e18);
    }

    function test_ClosedVaultCannotBypassRecipeGateThroughItsApprovedClaimLeaf() public {
        AsyncClaimVaultMock(_vault).seedShares(account, 20e18);
        AsyncClaimTokenMock(_asset).mint(_vault, 20e6);
        ERC7540VaultFixture(_vault).setClosed();
        (,, bytes[] memory runtime) = _installProgram("claimRedemptionByAssets");
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[0], (IMerkleAccount.Action[]));
        uint256 offset;
        while (actions[0].dataMask[offset] == 0) ++offset;
        bytes memory data = actions[0].data;
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), 20000000)
        }
        // Supplying a positive approved amount directly still runs the committed entitlement guard.
        vm.prank(_executor);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(IERC20(_asset).balanceOf(account), 117e6);
        assertEq(IERC20(_vault).balanceOf(account), 20e18);
    }

    function test_RequestAboveCommittedLimitRevertsWithoutMovingFunds() public {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 10e6 + 1;
        (bytes[] memory queries, bytes[] memory steps, bytes[] memory runtime) = _installProgram("requestDeposit");
        vm.expectRevert(IRecipes.CheckFailed.selector);
        RecipeExecutor(_executor).execute(queries, steps, inputs, runtime);
        assertEq(IERC20(_asset).balanceOf(account), 117e6);
        assertEq(AsyncClaimVaultMock(_vault).pendingDeposit(account), 0);
    }

    function test_ChangingPinnedRecipientFailsBeforeClaim() public {
        AsyncClaimTokenMock(_asset).mint(_vault, 8e6);
        AsyncClaimVaultMock(_vault).seedShares(account, 8e18);
        vm.prank(account);
        AsyncClaimVaultMock(_vault).requestRedeem(8e18, account, account);
        AsyncClaimVaultMock(_vault).settleRedeem(account, 8e18);
        (bytes[] memory queries, bytes[] memory steps, bytes[] memory runtime) =
            _installProgram("claimRedemptionByAssets");
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[0], (IMerkleAccount.Action[]));
        bytes memory data = actions[0].data;
        bool found;
        for (uint256 i; i + 100 <= data.length; ++i) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(add(data, 32), i))
            }
            if (selector == AsyncClaimVaultMock.withdraw.selector) {
                assembly ("memory-safe") {
                    mstore(add(add(data, 68), i), 0xbad)
                }
                found = true;
                break;
            }
        }
        assertTrue(found, "nested withdraw receiver");
        runtime[0] = abi.encode(actions);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        RecipeExecutor(_executor).execute(queries, steps, new uint256[](0), runtime);
        assertEq(AsyncClaimVaultMock(_vault).maxWithdraw(account), 8e6);
        assertEq(IERC20(_asset).balanceOf(account), 117e6);
    }

    function _execute(string memory name, uint256[] memory inputs) internal {
        (bytes[] memory queries, bytes[] memory steps, bytes[] memory runtime) = _installProgram(name);
        RecipeExecutor(_executor).execute(queries, steps, inputs, runtime);
    }

    function _installProgram(string memory name)
        internal
        returns (bytes[] memory queries, bytes[] memory steps, bytes[] memory runtime)
    {
        string memory path = string.concat(".recipes.", name);
        bytes memory encoded = _fixture.readBytes(string.concat(path, ".recipe"));
        assertEq(keccak256(encoded), _fixture.readBytes32(string.concat(path, ".recipeHash")));
        (queries, steps) = abi.decode(encoded, (bytes[], bytes[]));
        runtime = _fixture.readBytesArray(string.concat(path, ".executionRuntime"));
        RecipeExecutor(_executor).setRecipe(queries, steps);
    }
}

contract ERC7540VaultFixture is AsyncClaimVaultMock {
    bool internal _closed;

    constructor(address newAsset) AsyncClaimVaultMock(newAsset) {}

    function setClosed() public {
        _closed = true;
    }

    function claimableRedeemRequest(uint256, address controller) public view returns (uint256) {
        return _claimableRedeem[controller];
    }

    function maxWithdraw(address controller) public view override returns (uint256) {
        if (_closed && _claimableRedeem[controller] == 0) return balanceOf(controller) / 1e12;
        return super.maxWithdraw(controller);
    }

    function withdraw(uint256 assets, address receiver, address controller) public override returns (uint256 shares) {
        if (_closed && _claimableRedeem[controller] == 0) {
            require(controller == msg.sender);
            shares = assets * 1e12;
            _burn(controller, shares);
            IERC20(asset).transfer(receiver, assets);
        } else {
            return super.withdraw(assets, receiver, controller);
        }
    }
}
