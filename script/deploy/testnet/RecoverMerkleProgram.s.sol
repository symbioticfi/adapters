// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ActivityPhaseScript} from "./activity/ActivityContext.sol";
import {MerkleProgram} from "./activity/MerkleProgram.sol";
import {TestnetMidnightLender} from "./protocols/TestnetNativeLending.sol";
import {TestnetPermissions} from "./TestnetPermissions.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {OP_EQUAL, OP_READ, SRC_RESULT} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Market, Offer} from "morpho-midnight/src/interfaces/IMidnight.sol";

/// @title RecoverMerkleProgramScript
/// @notice Restores a saved testnet market's base authorization and explicitly selected residual permissions.
/// @dev Economic actions and journal disposition require separate operator review; run() only restores root/recipe.
contract RecoverMerkleProgramScript is ActivityPhaseScript {
    using Strings for uint256;

    error InvalidRecovery();

    /* PUBLIC FUNCTIONS */

    /// @notice Restores authorization for TESTNET_ACTIVITY_MARKET from the existing TESTNET_MANIFEST.
    function run() public returns (bytes32 baseRoot) {
        baseRoot = runBase(_context(), _broadcast());
    }

    /// @notice Restores changed authorization fields and returns the base root without repeating completed writes.
    function runBase(MerkleProgram.Context memory context, bool broadcast) public returns (bytes32 baseRoot) {
        if (block.chainid != 31_337 && block.chainid != 11_155_111) revert InvalidRecovery();
        MerkleProgram.validateAuthority(context);
        _start(context.owner, broadcast);
        baseRoot = MerkleProgram.restore(context);
        _stop(broadcast);
    }

    /// @notice Clears one explicitly selected account-to-spender allowance and restores base authorization.
    function clearApproval(address token, address spender) public {
        MerkleProgram.Context memory context = _context();
        MerkleProgram.validateAuthority(context);
        if (token.code.length == 0 || spender == address(0)) revert InvalidRecovery();
        _start(context.owner, _broadcast());
        MerkleProgram.restore(context);
        if (IERC20(token).allowance(context.account, spender) > 0) {
            MerkleProgram.Program memory program = MerkleProgram.Program({
                actions: new IMerkleAccount.Action[](1),
                queries: new bytes[](1),
                steps: new bytes[](3),
                groups: new uint256[][](1),
                inputs: new uint256[](0)
            });
            program.actions[0] = TestnetPermissions.action(token, abi.encodeCall(IERC20.approve, (spender, 0)), 0);
            program.queries[0] = abi.encode(
                token, abi.encodeCall(IERC20.allowance, (context.account, spender)), new uint256[](0), uint256(0)
            );
            program.groups[0] = new uint256[](1);
            uint256[][] memory bindings = new uint256[][](1);
            bindings[0] = new uint256[](0);
            program.steps[0] = MerkleProgram.step(program.actions, program.groups[0], bindings);
            program.steps[1] = bytes.concat(bytes1(OP_READ), abi.encode(uint256(0)));
            program.steps[2] = bytes.concat(bytes1(OP_EQUAL), abi.encode((uint256(SRC_RESULT) << 216) | 1, uint256(0)));
            MerkleProgram.execute(context, program);
        }
        _stop(_broadcast());
    }

    /// @notice Revokes one explicitly selected ERC1271 digest as the account owner and restores base authorization.
    function revokeSignature(bytes32 digest) public {
        MerkleProgram.Context memory context = _context();
        MerkleProgram.validateAuthority(context);
        _start(context.owner, _broadcast());
        if (IMerkleAccount(context.account).signatures(digest)) {
            IMerkleAccount(context.account).revokeSignature(digest);
        }
        MerkleProgram.restore(context);
        if (IMerkleAccount(context.account).signatures(digest)) revert InvalidRecovery();
        _stop(_broadcast());
    }

    /// @notice Disables the selected market's testnet Midnight lender offer without withdrawing its credit or cash.
    function clearMidnightOffer() public {
        MerkleProgram.Context memory context = _context();
        MerkleProgram.validateAuthority(context);
        string memory json = vm.readFile(vm.envString("TESTNET_MANIFEST"));
        string memory market = string.concat(".markets[", vm.envUint("TESTNET_ACTIVITY_MARKET").toString(), "]");
        address lender = vm.parseJsonAddress(json, string.concat(market, ".midnightLender"));
        address pool = vm.parseJsonAddress(json, string.concat(market, ".morphoMidnight"));
        Market memory params =
            abi.decode(vm.parseJsonBytes(json, string.concat(market, ".morphoMidnightParams")), (Market));
        if (
            Ownable(lender).owner() != context.owner || TestnetMidnightLender(lender).midnight() != pool
                || params.midnight != pool || params.chainId != block.chainid
                || params.loanToken != vm.parseJsonAddress(json, string.concat(market, ".asset"))
        ) revert InvalidRecovery();
        Offer memory disabled = Offer({
            market: params,
            buy: true,
            maker: lender,
            start: 0,
            expiry: 0,
            tick: 0,
            group: keccak256("testnet-manual-offer-cleanup"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: lender,
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: 0,
            continuousFeeCap: 0
        });
        _start(context.owner, _broadcast());
        TestnetMidnightLender(lender).approveOffer(disabled, address(0));
        if (
            TestnetMidnightLender(lender).taker() != address(0)
                || TestnetMidnightLender(lender).approvedOffer() != keccak256(abi.encode(disabled))
                || IERC20(params.loanToken).allowance(lender, pool) > 0
        ) revert InvalidRecovery();
        MerkleProgram.restore(context);
        _stop(_broadcast());
    }

    /* INTERNAL FUNCTIONS */

    function _context() internal view returns (MerkleProgram.Context memory context) {
        string memory json = vm.readFile(vm.envString("TESTNET_MANIFEST"));
        uint256 index = vm.envUint("TESTNET_ACTIVITY_MARKET");
        if (
            vm.parseJsonUint(json, ".schemaVersion") != 2 || vm.parseJsonUint(json, ".chainId") != block.chainid
                || (block.chainid != 31_337 && block.chainid != 11_155_111) || index >= 7
        ) revert InvalidRecovery();
        string memory market = string.concat(".markets[", index.toString(), "]");
        context = MerkleProgram.Context({
            owner: vm.parseJsonAddress(json, ".owner"),
            account: vm.parseJsonAddress(json, string.concat(market, ".account")),
            rootRegistry: vm.parseJsonAddress(json, string.concat(market, ".rootRegistry")),
            executor: vm.parseJsonAddress(json, string.concat(market, ".executor")),
            baseActions: abi.decode(
                vm.parseJsonBytes(json, string.concat(market, ".merkleActions")), (IMerkleAccount.Action[])
            ),
            baseRecipe: abi.decode(vm.parseJsonBytes(json, string.concat(market, ".recipeSteps")), (bytes[]))
        });
    }

    function _broadcast() internal view virtual returns (bool) {
        return true;
    }
}
