// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;
import {Script} from "forge-std/Script.sol";
import {MerkleProgram} from "script/deploy/testnet/activity/MerkleProgram.sol";
import {TestnetPermissions} from "script/deploy/testnet/TestnetPermissions.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMorpho, IMorphoBase, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";

import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

contract BlueWitness {
    using MorphoBalancesLib for IMorpho;

    function debt(address blue, bytes calldata parameters, address owner) external view returns (uint256) {
        return IMorpho(blue).expectedBorrowAssets(abi.decode(parameters, (MarketParams)), owner);
    }
}

interface IProbePool {
    function supply(address, uint256, address, uint16) external;
    function borrow(address, uint256, uint256, uint16, address) external;
}

interface IProbeVault {
    function borrow(uint256, address) external returns (uint256);
}

interface IProbeEVC {
    function enableCollateral(address, address) external;
    function enableController(address, address) external;
    function call(address, address, uint256, bytes calldata) external payable returns (bytes memory);
}

interface IProbeSpoke {
    function supply(uint256, uint256, address) external returns (uint256, uint256);
    function borrow(uint256, uint256, address) external returns (uint256, uint256);
    function setUsingAsCollateral(uint256, bool, address) external;
}

/// @notice Disposable acceptance fixture: persistent real lending exposure for the USDC account.
contract OpenPositions is Script {
    IMerkleAccount.Action[] private _actions;

    function add(address target, bytes memory data) private {
        _actions.push(TestnetPermissions.action(target, data, 0));
    }

    function run() public {
        string memory j = vm.readFile(vm.envString("TESTNET_MANIFEST"));
        string memory m = ".markets[0]";
        address owner = vm.parseJsonAddress(j, ".owner");
        address account = vm.parseJsonAddress(j, string.concat(m, ".account"));
        address asset = vm.parseJsonAddress(j, string.concat(m, ".asset"));
        address collateral = vm.parseJsonAddress(j, ".collateral");
        address weth = vm.parseJsonAddress(j, ".markets[5].asset");
        address pool = vm.parseJsonAddress(j, string.concat(m, ".aavePool"));
        address evault = vm.parseJsonAddress(j, string.concat(m, ".eulerVault"));
        address cvault = vm.parseJsonAddress(j, string.concat(m, ".eulerCollateralVault"));
        address evc = vm.parseJsonAddress(j, string.concat(m, ".eulerEVC"));
        address sub = address(uint160(account) ^ 1);
        MerkleProgram.Context memory context = MerkleProgram.Context(
            owner,
            account,
            vm.parseJsonAddress(j, string.concat(m, ".rootRegistry")),
            vm.parseJsonAddress(j, string.concat(m, ".executor")),
            abi.decode(vm.parseJsonBytes(j, string.concat(m, ".merkleActions")), (IMerkleAccount.Action[])),
            abi.decode(vm.parseJsonBytes(j, string.concat(m, ".recipeSteps")), (bytes[]))
        );
        add(weth, abi.encodeCall(IERC20.approve, (pool, 1e18)));
        add(pool, abi.encodeCall(IProbePool.supply, (weth, 1e18, account, 0)));
        add(weth, abi.encodeCall(IERC20.approve, (pool, 0)));
        add(pool, abi.encodeCall(IProbePool.borrow, (asset, 200e6, 2, 0, account)));
        add(collateral, abi.encodeCall(IERC20.approve, (cvault, 1e18)));
        add(cvault, abi.encodeCall(IERC4626.deposit, (1e18, sub)));
        add(collateral, abi.encodeCall(IERC20.approve, (cvault, 0)));
        add(evc, abi.encodeCall(IProbeEVC.enableCollateral, (sub, cvault)));
        add(evc, abi.encodeCall(IProbeEVC.enableController, (sub, evault)));
        add(evc, abi.encodeCall(IProbeEVC.call, (evault, sub, 0, abi.encodeCall(IProbeVault.borrow, (200e6, account)))));
        address blue = vm.parseJsonAddress(j, string.concat(m, ".morphoBlue"));
        MarketParams memory params =
            abi.decode(vm.parseJsonBytes(j, string.concat(m, ".morphoBlueParams")), (MarketParams));
        add(collateral, abi.encodeCall(IERC20.approve, (blue, 1e18)));
        add(blue, abi.encodeCall(IMorphoBase.supplyCollateral, (params, 1e18, account, bytes(""))));
        add(collateral, abi.encodeCall(IERC20.approve, (blue, 0)));
        add(blue, abi.encodeCall(IMorphoBase.borrow, (params, 200e6, 0, account, account)));
        address vault = vm.parseJsonAddress(j, string.concat(m, ".morphoVault"));
        add(asset, abi.encodeCall(IERC20.approve, (vault, 1000e6)));
        add(vault, abi.encodeCall(IERC4626.deposit, (1000e6, account)));
        add(asset, abi.encodeCall(IERC20.approve, (vault, 0)));
        address spoke = vm.parseJsonAddress(j, string.concat(m, ".aaveV4"));
        uint256 reserve = vm.parseJsonUint(j, string.concat(m, ".aaveV4ReserveId"));
        add(asset, abi.encodeCall(IERC20.approve, (spoke, 1000e6)));
        add(spoke, abi.encodeCall(IProbeSpoke.supply, (reserve, 1000e6, account)));
        add(asset, abi.encodeCall(IERC20.approve, (spoke, 0)));
        add(weth, abi.encodeCall(IERC20.approve, (spoke, 1e18)));
        add(spoke, abi.encodeCall(IProbeSpoke.supply, (5, 1e18, account)));
        add(weth, abi.encodeCall(IERC20.approve, (spoke, 0)));
        add(spoke, abi.encodeCall(IProbeSpoke.setUsingAsCollateral, (5, true, account)));
        add(spoke, abi.encodeCall(IProbeSpoke.borrow, (reserve, 100e6, account)));
        MerkleProgram.Program memory program;
        program.actions = _actions;
        program.queries = new bytes[](0);
        program.inputs = new uint256[](0);
        program.groups = new uint256[][](1);
        program.groups[0] = new uint256[](_actions.length);
        for (uint256 i; i < _actions.length; i++) {
            program.groups[0][i] = i;
        }
        program.steps = new bytes[](1);
        program.steps[0] = MerkleProgram.step(program.actions, program.groups[0], new uint256[][](_actions.length));
        vm.startBroadcast(owner);
        IERC20(collateral).transfer(account, 2e18);
        IERC20(weth).transfer(account, 2e18);
        MerkleProgram.execute(context, program);
        address witness = address(new BlueWitness());
        vm.stopBroadcast();
        vm.writeJson(vm.serializeAddress("witness", "blue", witness), "cache/production-acceptance/witness.json");
    }
}
