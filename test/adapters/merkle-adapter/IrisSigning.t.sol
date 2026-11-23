// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IIris, IRIS_DOMAIN_TYPEHASH, IRIS_QUOTE_TYPEHASH} from "src/interfaces/merkle-adapter/IIris.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {IrisSigning} from "script/recipes/IrisSigning.sol";

import {Token} from "test/mocks/Token.sol";

contract IrisSigningTest is CapabilityTestBase {
    using stdJson for string;

    address internal _executor;
    address internal _iris;
    address internal _usdc;
    IrisSigning.Config internal _config;
    ExecutingRecipe.Recipe internal _recipe;
    IMerkleAccount.Action internal _authorization;
    IMerkleAccount.Action internal _approval;

    function setUp() public {
        _deployAdapter(address(new Token("asset")));
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        _iris = address(new IrisMock());
        _usdc = address(new Token("usdc"));
        deal(_usdc, account, 1_000_000e6);
        _config = IrisSigning.Config({
            account: account,
            iris: _iris,
            chainId: block.chainid,
            clock: ExecutingRecipe.Read({target: _iris, data: abi.encodeCall(IrisMock.timestamp, ()), offset: 0}),
            blm: address(0xB1),
            collateralToken: address(0xC0),
            debtToken: _usdc,
            overdueRate: 0.05e18,
            overduePeriod: 7 days,
            bondLltv: 0.9e18,
            venueId: 1,
            data: abi.encode(keccak256("morpho market")),
            minDebt: 1000e6,
            maxDebt: 1_000_000e6,
            minFixedRate: 0.05e18,
            minDuration: 1 days,
            maxDuration: 90 days,
            maxBondPerDebt: 0.01e18,
            maxLifetime: 180,
            maxPendingBond: 50_000e6
        });
        _prepare(_config);
    }

    function test_SignsTheIrisDigestAndIrisPullsTheBond() public {
        IIris.Quote memory quote = _quote();
        _run(quote);
        assertEq(IERC20(_usdc).allowance(account, _iris), quote.bond);
        assertEq(MerkleAccount(payable(account)).isValidSignature(_digest(quote), ""), bytes4(0x1626ba7e));

        // The RFQ requires a 65-byte signature; the account ignores its contents.
        IrisMock(_iris).take(quote, new bytes(65));
        assertEq(IERC20(_usdc).balanceOf(_iris), quote.bond);
        assertTrue(IrisMock(_iris).isQuoteNonceUsed(account, quote.nonce));
    }

    function test_RejectsQuotesOutsideLimits() public {
        IIris.Quote memory quote = _quote();
        quote.fixedRate = 0.0499e18;
        _expectCheckFailed(quote);
        quote = _quote();
        quote.debt = 999e6;
        _expectCheckFailed(quote);
        quote = _quote();
        quote.debt = 1_000_001e6;
        _expectCheckFailed(quote);
        quote = _quote();
        quote.duration = 1 days - 1;
        _expectCheckFailed(quote);
        quote = _quote();
        quote.duration = 90 days + 1;
        _expectCheckFailed(quote);
        quote = _quote();
        quote.bond = quote.debt / 100 + 1;
        _expectCheckFailed(quote);
        quote = _quote();
        quote.deadline = block.timestamp + 181;
        _expectCheckFailed(quote);
        quote = _quote();
        quote.deadline = block.timestamp - 1;
        vm.expectRevert();
        _run(quote);
    }

    function test_PendingAllowanceAccumulatesUpToTheCap() public {
        IIris.Quote memory quote = _quote();
        _run(quote);
        quote.nonce = 2;
        _run(quote);
        assertEq(IERC20(_usdc).allowance(account, _iris), 2 * quote.bond);

        vm.prank(account);
        IERC20(_usdc).approve(_iris, type(uint256).max);
        quote.nonce = 3;
        _run(quote);
        assertEq(IERC20(_usdc).allowance(account, _iris), _config.maxPendingBond);

        IrisSigning.Config memory config = _config;
        config.maxPendingBond = quote.bond - 1;
        _prepare(config);
        _expectCheckFailed(quote);
    }

    function test_PinnedTermsAreNotSigned() public {
        IIris.Quote memory quote = _quote();
        _run(quote);
        IIris.Quote memory changed = _quote();
        changed.debtToken = address(0xD0);
        vm.expectRevert(IrisMock.InvalidSignature.selector);
        IrisMock(_iris).take(changed, new bytes(65));
        changed = _quote();
        changed.overduePeriod = 0;
        vm.expectRevert(IrisMock.InvalidSignature.selector);
        IrisMock(_iris).take(changed, new bytes(65));
        changed = _quote();
        changed.data = "";
        vm.expectRevert(IrisMock.InvalidSignature.selector);
        IrisMock(_iris).take(changed, new bytes(65));
    }

    function test_BuildScriptProducesTheSameProgramAndLeaves() public {
        string memory input = "out/IrisSigning.input.json";
        string memory output = "out/IrisSigning.output.json";
        vm.writeFile(
            input,
            string.concat(
                '{"template":"iris-signing","curator":"',
                vm.toString(address(this)),
                '","provider":"',
                vm.toString(address(this)),
                '","adapter":"',
                vm.toString(address(adapter)),
                '","addresses":{"iris":"',
                vm.toString(_iris),
                '","blm":"0x00000000000000000000000000000000000000B1","collateralToken":"0x00000000000000000000000000000000000000C0","debtToken":"',
                vm.toString(_usdc),
                '"},"clock":{"target":"',
                vm.toString(_iris),
                '","data":"',
                vm.toString(_config.clock.data),
                '","offset":0},"quote":{"overdueRate":"50000000000000000","overduePeriod":604800,"bondLltv":"900000000000000000","venueId":1,"data":"',
                vm.toString(_config.data),
                '"},"limits":{"minDebt":"1000000000","maxDebt":"1000000000000","minFixedRate":"50000000000000000","minDuration":86400,"maxDuration":7776000,"maxBondPerDebt":"10000000000000000","maxLifetime":180,"maxPendingBond":"50000000000"}}'
            )
        );
        BuildRecipe(deployCode("BuildRecipe.s.sol:BuildRecipe")).run(input, output);
        string memory built = vm.readFile(output);
        assertEq(built.readBytes32(".recipeHash"), keccak256(abi.encode(_recipe.queries, _recipe.steps)));
        assertEq(built.readBytes(".signData"), _authorization.data);
        assertEq(built.readBytes(".signMask"), _authorization.dataMask);
        assertEq(
            built.readBytes32(".approvalLeaf"),
            ActionMasker.mask(_approval.target, 0, _approval.data, _approval.dataMask)
        );
        vm.removeFile(input);
        vm.removeFile(output);
    }

    function _expectCheckFailed(IIris.Quote memory quote) internal {
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _run(quote);
    }

    function _quote() internal view returns (IIris.Quote memory) {
        return IIris.Quote({
            borrower: address(0xB0B),
            solver: account,
            receiver: address(0xB0B),
            blm: _config.blm,
            collateralToken: _config.collateralToken,
            debtToken: _usdc,
            collateral: 1e8,
            debt: 10_000e6,
            fixedRate: 0.06e18,
            duration: 30 days,
            overdueRate: _config.overdueRate,
            overduePeriod: _config.overduePeriod,
            bond: 30e6,
            bondLltv: _config.bondLltv,
            venueBitmap: 2,
            venueId: _config.venueId,
            deadline: block.timestamp + 120,
            nonce: 1,
            data: _config.data
        });
    }

    function _digest(IIris.Quote memory quote) internal view returns (bytes32) {
        return IrisMock(_iris).digest(quote);
    }

    function _run(IIris.Quote memory quote) internal {
        uint256[] memory inputs = new uint256[](10);
        inputs[0] = uint256(uint160(quote.borrower));
        inputs[1] = uint256(uint160(quote.receiver));
        inputs[2] = quote.collateral;
        inputs[3] = quote.debt;
        inputs[4] = quote.fixedRate;
        inputs[5] = quote.duration;
        inputs[6] = quote.bond;
        inputs[7] = quote.venueBitmap;
        inputs[8] = quote.deadline;
        inputs[9] = quote.nonce;
        bytes32 signLeaf = ActionMasker.mask(account, 0, _authorization.data, _authorization.dataMask);
        bytes32 approvalLeaf = ActionMasker.mask(_approval.target, 0, _approval.data, _approval.dataMask);
        // Two-leaf root: each leaf's proof is the other leaf.
        bytes32[] memory signProof = new bytes32[](1);
        signProof[0] = approvalLeaf;
        bytes32[] memory approvalProof = new bytes32[](1);
        approvalProof[0] = signLeaf;
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _authorization;
        actions[0].proof = signProof;
        bytes[] memory runtime = new bytes[](2);
        runtime[0] = abi.encode(actions);
        runtime[1] = abi.encode(_approval.dataMask, approvalProof);
        RecipeExecutor(_executor).execute(_recipe.queries, _recipe.steps, inputs, runtime);
    }

    function _prepare(IrisSigning.Config memory config) internal {
        (_recipe, _authorization, _approval) = IrisSigning.build(config);
        bytes32 signLeaf = ActionMasker.mask(account, 0, _authorization.data, _authorization.dataMask);
        bytes32 approvalLeaf = ActionMasker.mask(_approval.target, 0, _approval.data, _approval.dataMask);
        bytes32 root = signLeaf < approvalLeaf
            ? keccak256(abi.encodePacked(signLeaf, approvalLeaf))
            : keccak256(abi.encodePacked(approvalLeaf, signLeaf));
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        MerkleAccount(payable(account)).grantRole(signLeaf, _executor);
        MerkleAccount(payable(account)).grantRole(approvalLeaf, _executor);
        RecipeExecutor(_executor).setRecipe(_recipe.queries, _recipe.steps);
    }
}

/// @dev Mirrors Iris.take's digest, signature check, nonce and bond pull (iris-core src/Iris.sol:360-452).
contract IrisMock {
    error InvalidSignature();
    error QuoteExpired();
    error QuoteNonceUsed();

    mapping(address solver => mapping(uint256 nonce => bool)) public isQuoteNonceUsed;

    // forge-lint: disable-next-item(mixed-case-function)
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(IRIS_DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    function timestamp() public view returns (uint256) {
        return block.timestamp;
    }

    function digest(IIris.Quote memory quote) public view returns (bytes32) {
        bytes32 hashStruct = keccak256(
            bytes.concat(
                abi.encode(
                    IRIS_QUOTE_TYPEHASH,
                    quote.borrower,
                    quote.solver,
                    quote.receiver,
                    quote.blm,
                    quote.collateralToken,
                    quote.debtToken,
                    quote.collateral,
                    quote.debt,
                    quote.fixedRate
                ),
                abi.encode(
                    quote.duration,
                    quote.overdueRate,
                    quote.overduePeriod,
                    quote.bond,
                    quote.bondLltv,
                    quote.venueBitmap,
                    quote.venueId,
                    quote.deadline,
                    quote.nonce,
                    keccak256(quote.data)
                )
            )
        );
        return keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR(), hashStruct));
    }

    function take(IIris.Quote memory quote, bytes memory signature) public returns (address) {
        if (block.timestamp > quote.deadline) revert QuoteExpired();
        if (!SignatureChecker.isValidSignatureNow(quote.solver, digest(quote), signature)) revert InvalidSignature();
        if (isQuoteNonceUsed[quote.solver][quote.nonce]) revert QuoteNonceUsed();
        isQuoteNonceUsed[quote.solver][quote.nonce] = true;
        IERC20(quote.debtToken).transferFrom(quote.solver, address(this), quote.bond);
        return address(0);
    }
}
