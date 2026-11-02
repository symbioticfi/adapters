// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeTokenMock, RecipePoolMock} from "./mocks/RecipeCapabilityMocks.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {
    LIQUID_LANE_REQUEST_TYPEHASH,
    LIQUID_LANE_OUTPUT_TYPEHASH
} from "src/interfaces/merkle-adapter/ILiquidLaneReactor.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/RecipeCapabilityMocks.sol";
import {ThreeFRequestMock} from "test/mocks/ThreeFRequestMocks.sol";
import {Token} from "test/mocks/Token.sol";
import {flatPlan} from "test/helpers/HashPlan.sol";

contract CapabilityIntegrationTest is CapabilityTestBase {
    function test_CapabilitiesAndSignatureApprovalsCoexistWithoutOverwritingAdapterOrEachOther() public {
        RecipeTokenMock asset = new RecipeTokenMock();
        Token rwa = new Token("RWA");
        _deployAdapter(address(asset));
        address vault = adapter.vault();
        asset.mint(account, 1000e18);
        RecipePoolMock pool = new RecipePoolMock(address(asset));
        asset.mint(address(pool), 1000e18);
        pool.setCollateral(account, 240e18);
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        BorrowTestCall memory healthFactor = BorrowTestCall({
            target: address(new AaveHealthFactor()),
            data: abi.encodeCall(AaveHealthFactor.getHealthFactor, (address(pool), account))
        });
        _minimum = 1.2e18;

        ThreeFRequestMock request = new ThreeFRequestMock(address(asset), "request-1");
        request.authorizeMinting(account, 10e18, 1e18);
        _manage(address(asset), abi.encodeCall(IERC20.approve, (address(request), 10e18)));
        _manage(address(request), abi.encodeCall(request.mint, (uint128(10e18), uint128(1e18))));

        bytes32 typedDigest;
        {
            bytes memory encodedStruct = abi.encode(keccak256("Order(address token)"), address(asset));
            bytes32 domainSeparator = keccak256("EIP-712 domain");
            typedDigest = MessageHashUtils.toTypedDataHash(domainSeparator, keccak256(encodedStruct));
            _manage(
                account, abi.encodeCall(IMerkleAccount.sign, (domainSeparator, encodedStruct, flatPlan(encodedStruct)))
            );
        }

        bytes32 digest = _signRedemption(address(rwa), address(asset));
        _manage(
            account,
            _checkedCallData(
                address(pool),
                healthFactor.target,
                abi.encodeCall(pool.borrow, (address(asset), uint256(200e18), 2, 0, account)),
                healthFactor.data
            )
        );
        assertEq(_healthValue(healthFactor.target, healthFactor.data), 1.2e18);
        (uint256 pt, uint256 yt) = request.balancesOf(account);
        assertEq(pt, 10e18);
        assertEq(yt, 1e18);
        assertEq(IMerkleAccount(account).isValidSignature(typedDigest, bytes("")), IERC1271.isValidSignature.selector);
        assertEq(IMerkleAccount(account).isValidSignature(digest, bytes("")), IERC1271.isValidSignature.selector);
        assertEq(adapter.owner(), address(this));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.totalAssets(), 0);
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 1);
        assertTrue(MerkleAccount(payable(account)).supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertEq(MerkleAccount(payable(account)).getRoleMemberCount(bytes32(0)), 1);
        assertEq(MerkleAccount(payable(account)).getRoleMember(bytes32(0), 0), address(this));
        assertEq(asset.balanceOf(account), 1190e18);
    }

    function _signRedemption(address rwa, address asset) internal returns (bytes32) {
        bytes32 domain = keccak256("Reactor domain");
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            domain,
            keccak256(
                abi.encode(
                    LIQUID_LANE_REQUEST_TYPEHASH,
                    rwa,
                    uint256(100e18),
                    keccak256(
                        abi.encode(keccak256(abi.encode(LIQUID_LANE_OUTPUT_TYPEHASH, asset, uint256(95e18), account)))
                    ),
                    block.timestamp + 1 hours,
                    uint256(7),
                    address(0xBEEF)
                )
            )
        );
        _manage(
            account,
            abi.encodeCall(
                IMerkleAccount.sign,
                (
                    domain,
                    abi.encode(
                        LIQUID_LANE_REQUEST_TYPEHASH,
                        rwa,
                        uint256(100e18),
                        keccak256(
                            abi.encode(
                                keccak256(abi.encode(LIQUID_LANE_OUTPUT_TYPEHASH, asset, uint256(95e18), account))
                            )
                        ),
                        block.timestamp + 1 hours,
                        uint256(7),
                        address(0xBEEF)
                    ),
                    flatPlan(
                        abi.encode(
                            LIQUID_LANE_REQUEST_TYPEHASH,
                            rwa,
                            uint256(100e18),
                            keccak256(
                                abi.encode(
                                    keccak256(abi.encode(LIQUID_LANE_OUTPUT_TYPEHASH, asset, uint256(95e18), account))
                                )
                            ),
                            block.timestamp + 1 hours,
                            uint256(7),
                            address(0xBEEF)
                        )
                    )
                )
            )
        );
        return digest;
    }
}
