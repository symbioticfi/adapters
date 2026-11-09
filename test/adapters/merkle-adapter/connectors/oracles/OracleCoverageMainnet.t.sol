// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {AsyncRedeemOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/AsyncRedeemOracle.sol";
import {ERC4626Oracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/ERC4626Oracle.sol";
import {FigureOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/FigureOracle.sol";
import {MidasOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/MidasOracle.sol";
import {NoonOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/NoonOracle.sol";
import {OpenEdenOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/OpenEdenOracle.sol";
import {
    OpenEdenTBILLOracle
} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/OpenEdenTBILLOracle.sol";
import {ParetoOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/ParetoOracle.sol";

import {IAsyncRedeemVault} from "../../../../../src/interfaces/ll-adapter/IAsyncRedeemVault.sol";
import {IERC7575Share} from "../../../../../src/interfaces/ll-adapter/IERC7575Share.sol";
import {IMidasRedemptionVault} from "../../../../../src/interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";
import {IOpenEdenExpress} from "../../../../../src/interfaces/ll-adapter/openeden/IOpenEdenExpress.sol";
import {IOpenEdenTBILL} from "../../../../../src/interfaces/merkle-adapter/connectors/openeden/IOpenEdenTBILL.sol";
import {IOracle} from "../../../../../src/interfaces/ll-adapter/IOracle.sol";
import {IParetoCDO} from "../../../../../src/interfaces/ll-adapter/pareto/IParetoCDO.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Replays the 43-token source capture through the actual oracle implementations.
contract OracleCoverageMainnetTest is Test {
    string internal _fixture;
    bool internal _enabled;

    function setUp() public {
        _fixture = vm.readFile(
            string.concat(
                vm.projectRoot(), "/test/adapters/merkle-adapter/connectors/oracles/fixtures/oracle-mainnet.json"
            )
        );
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.parseJsonUint(_fixture, ".block"));
        _enabled = true;
    }

    function testNativeMidasPayments() public view {
        string[3] memory ids = ["mbtc", "mhyperbtc", "mre7btc"];
        address[3] memory payments = [
            address(0x18084fbA666a33d37592fA2633fD49a74DD93a88), // tBTC
            address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf), // cbBTC
            address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599) // WBTC
        ];
        uint256 count;
        for (uint256 i; i < vm.parseJsonArrayLength(_fixture, ".tokens"); ++i) {
            string memory row = string.concat(".tokens[", vm.toString(i), "]");
            string memory id = vm.parseJsonString(_fixture, string.concat(row, ".id"));
            for (uint256 j; j < ids.length; ++j) {
                if (keccak256(bytes(id)) != keccak256(bytes(ids[j]))) continue;
                ++count;
                assertEq(vm.parseJsonAddress(_fixture, string.concat(row, ".paymentToken")), payments[j], id);
            }
        }
        assertEq(count, ids.length);
    }

    function testMainnetMidas19Tokens() public {
        _checkFamily(1, 19);
    }

    function testMainnetCentrifuge6Tokens() public {
        _checkFamily(2, 6);
    }

    function testMainnetPareto5AATranches() public {
        _checkFamily(3, 5);
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
        assertEq(length, 43);
        for (uint256 i; i < length; ++i) {
            string memory row = string.concat(".tokens[", vm.toString(i), "]");
            if (vm.parseJsonUint(_fixture, string.concat(row, ".kind")) != family) continue;
            ++count;
            address token = vm.parseJsonAddress(_fixture, string.concat(row, ".token"));
            address source = vm.parseJsonAddress(_fixture, string.concat(row, ".source"));
            address paymentToken = vm.parseJsonAddress(_fixture, string.concat(row, ".paymentToken"));
            assertEq(IERC20Metadata(token).decimals(), vm.parseJsonUint(_fixture, string.concat(row, ".decimals")));
            address oracle;
            if (family == 1) {
                address venue = vm.parseJsonAddress(_fixture, string.concat(row, ".venue"));
                assertEq(IMidasRedemptionVault(venue).mToken(), token);
                assertEq(IMidasRedemptionVault(venue).mTokenDataFeed(), source);
                oracle = address(new MidasOracle(1, type(uint256).max, source));
            }
            if (family == 2) {
                assertEq(IERC7575Share(token).vault(paymentToken), source);
                assertEq(IAsyncRedeemVault(source).asset(), paymentToken);
                oracle = address(new AsyncRedeemOracle(1, type(uint256).max, token, source));
            }
            if (family == 3) {
                assertEq(IParetoCDO(source).token(), paymentToken);
                oracle = address(new ParetoOracle(1, type(uint256).max, token, source));
            }
            if (family == 5) {
                assertEq(IERC4626(IERC4626(token).asset()).asset(), paymentToken);
                oracle = address(new FigureOracle(1, type(uint256).max, token));
            }
            if (family == 7) {
                assertEq(IOpenEdenExpress(source).redeemAsset(), paymentToken);
                oracle = address(new OpenEdenOracle(1, type(uint256).max, token, source));
            }
            if (family == 8) {
                assertEq(IOpenEdenTBILL(token).underlying(), paymentToken);
                oracle = address(new OpenEdenTBILLOracle(1, type(uint256).max, token));
            }
            if (family == 9) {
                oracle = address(new NoonOracle(1, type(uint256).max, token, source, paymentToken));
            }
            if (family == 20) {
                assertEq(IERC4626(token).asset(), paymentToken);
                oracle = address(new ERC4626Oracle(1, type(uint256).max, token));
            }
            string memory id = vm.parseJsonString(_fixture, string.concat(row, ".id"));
            assertEq(IOracle(oracle).getPrice(), vm.parseJsonUint(_fixture, string.concat(row, ".nativePrice")), id);
            if (family == 1) {
                bytes32 denomination =
                    keccak256(bytes(vm.parseJsonString(_fixture, string.concat(row, ".denomination"))));
                if (denomination != keccak256("usd")) {
                    (address paymentFeed,,, bool stable) = IMidasRedemptionVault(
                            vm.parseJsonAddress(_fixture, string.concat(row, ".venue"))
                        )
                        .tokensConfig(paymentToken);
                    assertNotEq(paymentFeed, address(0), "payment token must be admitted by the issuer");
                    assertTrue(stable, "native payment token must use the issuer's 1:1 rate");
                    assertNotEq(paymentToken, address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
                }
            }
        }
        assertEq(count, expectedCount);
    }
}
