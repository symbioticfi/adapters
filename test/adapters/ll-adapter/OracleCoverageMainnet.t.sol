// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {AsyncRedeemOracle} from "../../../src/contracts/ll-adapter/oracles/AsyncRedeemOracle.sol";
import {ChainlinkOracle} from "../../../src/contracts/ll-adapter/oracles/ChainlinkOracle.sol";
import {CompositeOracle} from "../../../src/contracts/ll-adapter/oracles/CompositeOracle.sol";
import {ERC4626Oracle} from "../../../src/contracts/ll-adapter/oracles/ERC4626Oracle.sol";
import {FigureOracle} from "../../../src/contracts/ll-adapter/oracles/FigureOracle.sol";
import {MidasOracle} from "../../../src/contracts/ll-adapter/oracles/MidasOracle.sol";
import {NoonRedemptionOracle} from "../../../src/contracts/ll-adapter/oracles/NoonRedemptionOracle.sol";
import {OpenEdenOracle} from "../../../src/contracts/ll-adapter/oracles/OpenEdenOracle.sol";
import {OpenEdenTBILLOracle} from "../../../src/contracts/ll-adapter/oracles/OpenEdenTBILLOracle.sol";
import {ParetoOracle} from "../../../src/contracts/ll-adapter/oracles/ParetoOracle.sol";

import {IAsyncRedeemVault} from "../../../src/interfaces/ll-adapter/IAsyncRedeemVault.sol";
import {IERC7575Share} from "../../../src/interfaces/ll-adapter/IERC7575Share.sol";
import {IMidasRedemptionVault} from "../../../src/interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";
import {IOpenEdenExpress} from "../../../src/interfaces/ll-adapter/openeden/IOpenEdenExpress.sol";
import {IOpenEdenTBILL} from "../../../src/interfaces/ll-adapter/openeden/IOpenEdenTBILL.sol";
import {IOracle} from "../../../src/interfaces/ll-adapter/IOracle.sol";
import {IParetoCDO} from "../../../src/interfaces/ll-adapter/pareto/IParetoCDO.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Replays the 55-token source capture through the actual oracle implementations.
contract OracleCoverageMainnetTest is Test {
    string internal _fixture;
    bool internal _enabled;
    address internal _usdcUsd;
    address internal _btcUsd;
    address internal _ethUsd;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        _fixture =
            vm.readFile(string.concat(vm.projectRoot(), "/test/adapters/ll-adapter/fixtures/oracle-mainnet.json"));
        vm.createSelectFork(rpc, vm.parseJsonUint(_fixture, ".block"));
        _enabled = true;
        _usdcUsd = address(
            new ChainlinkOracle(
                1,
                type(uint256).max,
                [address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6), address(0)],
                [uint48(82_800), uint48(0)]
            )
        );
        _btcUsd = address(
            new ChainlinkOracle(
                1,
                type(uint256).max,
                [address(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c), address(0)],
                [uint48(3600), uint48(0)]
            )
        );
        _ethUsd = address(
            new ChainlinkOracle(
                1,
                type(uint256).max,
                [address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419), address(0)],
                [uint48(3600), uint48(0)]
            )
        );
        assertEq(IOracle(_usdcUsd).getPrice(), vm.parseJsonUint(_fixture, ".fx.usdc"));
        assertEq(IOracle(_btcUsd).getPrice(), vm.parseJsonUint(_fixture, ".fx.btc"));
        assertEq(IOracle(_ethUsd).getPrice(), vm.parseJsonUint(_fixture, ".fx.eth"));
    }

    function testMainnetMidas24Tokens() public {
        _checkFamily(1, 24);
    }

    function testMainnetCentrifuge6Tokens() public {
        _checkFamily(2, 6);
    }

    function testMainnetPareto12Tranches() public {
        _checkFamily(3, 12);
    }

    function testMainnetHastra2Tokens() public {
        _checkFamily(5, 2);
    }

    function testMainnetOpenEdenHybond() public {
        _checkFamily(7, 1);
    }

    function testMainnetOpenEdenTbill() public {
        _checkFamily(8, 1);
    }

    function testMainnetNoonSusn() public {
        _checkFamily(9, 1);
    }

    function testMainnetLagoon8Vaults() public {
        _checkFamily(20, 8);
    }

    function _checkFamily(uint256 family, uint256 expectedCount) internal {
        vm.skip(!_enabled);
        uint256 count;
        uint256 length = vm.parseJsonArrayLength(_fixture, ".tokens");
        assertEq(length, 55);
        for (uint256 i; i < length; ++i) {
            string memory row = string.concat(".tokens[", vm.toString(i), "]");
            if (vm.parseJsonUint(_fixture, string.concat(row, ".kind")) != family) continue;
            ++count;
            address token = vm.parseJsonAddress(_fixture, string.concat(row, ".token"));
            address source = vm.parseJsonAddress(_fixture, string.concat(row, ".source"));
            address usdc = vm.parseJsonAddress(_fixture, ".quoteToken");
            assertEq(IERC20Metadata(token).decimals(), vm.parseJsonUint(_fixture, string.concat(row, ".decimals")));
            address oracle;
            if (family == 1) {
                address venue = vm.parseJsonAddress(_fixture, string.concat(row, ".venue"));
                assertEq(IMidasRedemptionVault(venue).mToken(), token);
                assertEq(IMidasRedemptionVault(venue).mTokenDataFeed(), source);
                oracle = address(new MidasOracle(1, type(uint256).max, source));
            }
            if (family == 2) {
                assertEq(IERC7575Share(token).vault(usdc), source);
                assertEq(IAsyncRedeemVault(source).asset(), usdc);
                oracle = address(new AsyncRedeemOracle(1, type(uint256).max, token, source));
            }
            if (family == 3) {
                assertEq(IParetoCDO(source).token(), usdc);
                oracle = address(new ParetoOracle(1, type(uint256).max, token, source));
            }
            if (family == 5) {
                assertEq(IERC4626(IERC4626(token).asset()).asset(), usdc);
                oracle = address(new FigureOracle(1, type(uint256).max, token));
            }
            if (family == 7) {
                assertEq(IOpenEdenExpress(source).redeemAsset(), usdc);
                oracle = address(new OpenEdenOracle(1, type(uint256).max, token, source));
            }
            if (family == 8) {
                assertEq(IOpenEdenTBILL(token).underlying(), usdc);
                oracle = address(new OpenEdenTBILLOracle(1, type(uint256).max, token));
            }
            if (family == 9) {
                oracle = address(
                    new NoonRedemptionOracle(
                        1, type(uint256).max, token, source, vm.parseJsonAddress(_fixture, ".quoteToken")
                    )
                );
            }
            if (family == 20) {
                assertEq(IERC4626(token).asset(), usdc);
                oracle = address(new ERC4626Oracle(1, type(uint256).max, token));
            }
            string memory id = vm.parseJsonString(_fixture, string.concat(row, ".id"));
            assertEq(IOracle(oracle).getPrice(), vm.parseJsonUint(_fixture, string.concat(row, ".nativePrice")), id);
            if (family == 1) {
                bytes32 denomination =
                    keccak256(bytes(vm.parseJsonString(_fixture, string.concat(row, ".denomination"))));
                oracle = address(
                    new CompositeOracle(
                        1,
                        type(uint256).max,
                        oracle,
                        denomination == keccak256("btc")
                            ? _btcUsd
                            : denomination == keccak256("eth") ? _ethUsd : address(0),
                        _usdcUsd
                    )
                );
            }
            assertEq(IOracle(oracle).getPrice(), vm.parseJsonUint(_fixture, string.concat(row, ".paymentPrice")), id);
        }
        assertEq(count, expectedCount);
    }
}
