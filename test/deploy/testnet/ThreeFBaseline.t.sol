// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {SepoliaInfrastructure} from "script/deploy/testnet/SepoliaInfrastructure.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {Test} from "forge-std/Test.sol";

contract ThreeFBaselineHarness is DeployRealisticTestnetScript {
    function baseline() public view returns (uint256) {
        return _threeFFirstRequest();
    }
}

contract ThreeFBaselineTest is Test {
    function test_CapturesFactoryNextIndexWithCanonicalBoundary() public {
        vm.chainId(11_155_111);
        vm.etch(SepoliaInfrastructure.REQUESTS_FACTORY, hex"00");
        vm.setNonce(SepoliaInfrastructure.REQUESTS_FACTORY, 7 + 3 * 3758);
        vm.mockCall(
            SepoliaInfrastructure.REQUESTS_FACTORY,
            abi.encodeCall(
                IThreeFRequestFactory.isRequest,
                (vm.computeCreateAddress(SepoliaInfrastructure.REQUESTS_FACTORY, 7 + 3 * 3757))
            ),
            abi.encode(true)
        );
        vm.mockCall(
            SepoliaInfrastructure.REQUESTS_FACTORY,
            abi.encodeCall(
                IThreeFRequestFactory.isRequest,
                (vm.computeCreateAddress(SepoliaInfrastructure.REQUESTS_FACTORY, 7 + 3 * 3758))
            ),
            abi.encode(false)
        );
        assertEq(new ThreeFBaselineHarness().baseline(), 3758);
    }

    function test_RejectsNonceThatDoesNotMatchCanonicalFactoryBoundary() public {
        vm.chainId(11_155_111);
        vm.etch(SepoliaInfrastructure.REQUESTS_FACTORY, hex"00");
        vm.setNonce(SepoliaInfrastructure.REQUESTS_FACTORY, 7 + 3 * 3758);
        vm.mockCall(
            SepoliaInfrastructure.REQUESTS_FACTORY,
            abi.encodeWithSelector(IThreeFRequestFactory.isRequest.selector),
            abi.encode(false)
        );
        ThreeFBaselineHarness harness = new ThreeFBaselineHarness();
        vm.expectRevert(DeployRealisticTestnetScript.InvalidConfiguration.selector);
        harness.baseline();
    }
}
