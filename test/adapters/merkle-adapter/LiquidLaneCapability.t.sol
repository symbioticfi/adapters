// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {LiquidLaneCapability} from "../../../src/contracts/merkle_adapter/LiquidLaneCapability.sol";
import {OracleRegistry} from "../../../src/contracts/merkle_adapter/OracleRegistry.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {ILiquidLaneCapability} from "../../../src/interfaces/merkle_adapter/ILiquidLaneCapability.sol";
import {IOracleRegistry} from "../../../src/interfaces/merkle_adapter/IOracleRegistry.sol";
import {IOracle} from "../../../src/interfaces/ll-adapter/IOracle.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract OracleRegistryTest is Test {
    OracleRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal asset = makeAddr("asset");
    address internal tokenToRedeem = makeAddr("tokenToRedeem");
    address internal oracleFactory = makeAddr("oracleFactory");

    function setUp() public {
        registry = new OracleRegistry(owner);
    }

    function test_SetOracleFactoryStoresPairAndEmits() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOracleRegistry.SetOracleFactory(asset, tokenToRedeem, oracleFactory);

        vm.prank(owner);
        registry.setOracleFactory(asset, tokenToRedeem, oracleFactory);

        assertEq(registry.oracleFactories(asset, tokenToRedeem), oracleFactory);
    }

    function test_SetOracleFactoryRejectsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setOracleFactory(asset, tokenToRedeem, oracleFactory);
    }

    function test_SetOracleFactoryRejectsReplacement() public {
        vm.startPrank(owner);
        registry.setOracleFactory(asset, tokenToRedeem, oracleFactory);
        vm.expectRevert(IOracleRegistry.OracleFactoryAlreadySet.selector);
        registry.setOracleFactory(asset, tokenToRedeem, makeAddr("otherOracleFactory"));
        vm.stopPrank();
    }
}

contract LiquidLaneCapabilityTest is Test {
    CapabilityTokenMock internal asset;
    CapabilityTokenMock internal vaultAsset;
    CapabilityTokenMock internal tokenToRedeem;
    CapabilityVaultMock internal vault;
    CapabilityAdapterMock internal adapter;
    OracleRegistry internal registry;
    MigratablesFactory internal capabilityFactory;
    MigratablesFactory internal oracleFactory;
    CapabilityOracleMock internal latestOracleImplementation;
    LiquidLaneCapability internal capability;

    address internal adapterOwner = makeAddr("adapterOwner");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        asset = new CapabilityTokenMock("USD Coin", "USDC", 6);
        vaultAsset = new CapabilityTokenMock("Wrapped Ether", "WETH", 18);
        tokenToRedeem = new CapabilityTokenMock("RWA", "RWA", 18);
        vault = new CapabilityVaultMock(address(vaultAsset));
        adapter = new CapabilityAdapterMock(address(vault), adapterOwner);
        registry = new OracleRegistry(address(this));
        capabilityFactory = new MigratablesFactory(address(this));
        oracleFactory = new MigratablesFactory(address(this));

        oracleFactory.whitelist(address(new CapabilityOracleMock(address(oracleFactory), 1e18)));
        latestOracleImplementation = new CapabilityOracleMock(address(oracleFactory), 2e18);
        oracleFactory.whitelist(address(latestOracleImplementation));
        registry.setOracleFactory(address(asset), address(tokenToRedeem), address(oracleFactory));

        capabilityFactory.whitelist(address(new LiquidLaneCapability(address(capabilityFactory), address(registry))));
        capability = _createCapability(address(adapter), address(asset), _outputs(address(tokenToRedeem)));
    }

    function test_FactoryCreationInitializesAdapterOwnerFactoryAndVersion() public view {
        assertEq(capability.adapter(), address(adapter));
        assertEq(capability.inputAsset(), address(asset));
        assertEq(capability.ORACLE_REGISTRY(), address(registry));
        assertEq(capability.FACTORY(), address(capabilityFactory));
        assertEq(capability.version(), capabilityFactory.lastVersion());
        assertEq(capability.owner(), adapterOwner);

        CapabilityOracleMock oracle = CapabilityOracleMock(capability.oracles(address(tokenToRedeem)));
        assertEq(capability.getTokensToRedeemLength(), 1);
        assertEq(capability.tokensToRedeem(0), address(tokenToRedeem));
        assertEq(oracleFactory.lastVersion(), 2);
        assertEq(oracle.version(), oracleFactory.lastVersion());
        assertEq(oracle.owner(), capability.owner());
        assertEq(oracle.inputAsset(), address(asset));
        assertEq(oracle.capability(), address(capability));
        assertEq(oracle.price(), latestOracleImplementation.price());
    }

    function test_InitializationCreatesAllOutputsInOrder() public {
        CapabilityTokenMock secondOutput = new CapabilityTokenMock("Second RWA", "RWA2", 8);
        registry.setOracleFactory(address(asset), address(secondOutput), address(oracleFactory));
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenToRedeem);
        outputs[1] = address(secondOutput);

        LiquidLaneCapability secondCapability = _createCapability(address(adapter), address(asset), outputs);

        assertEq(secondCapability.getTokensToRedeemLength(), 2);
        assertEq(secondCapability.tokensToRedeem(0), address(tokenToRedeem));
        assertEq(secondCapability.tokensToRedeem(1), address(secondOutput));
        assertNotEq(secondCapability.oracles(address(tokenToRedeem)), address(0));
        assertNotEq(secondCapability.oracles(address(secondOutput)), address(0));
    }

    function test_InitializationRejectsZeroAdapterAtomically() public {
        _expectCreateRevert(
            ILiquidLaneCapability.InvalidAdapter.selector, address(0), address(asset), _outputs(address(tokenToRedeem))
        );
    }

    function test_InitializationRejectsZeroInputAssetAtomically() public {
        _expectCreateRevert(
            ILiquidLaneCapability.InvalidInputAsset.selector,
            address(adapter),
            address(0),
            _outputs(address(tokenToRedeem))
        );
    }

    function test_InitializationRejectsEmptyOutputsAtomically() public {
        _expectCreateRevert(
            ILiquidLaneCapability.EmptyTokensToRedeem.selector, address(adapter), address(asset), new address[](0)
        );
    }

    function test_InitializationRejectsZeroOutputAtomically() public {
        _expectCreateRevert(
            ILiquidLaneCapability.InvalidTokenToRedeem.selector, address(adapter), address(asset), _outputs(address(0))
        );
    }

    function test_InitializationRejectsInputAsOutputAtomically() public {
        _expectCreateRevert(
            ILiquidLaneCapability.InvalidTokenToRedeem.selector,
            address(adapter),
            address(asset),
            _outputs(address(asset))
        );
    }

    function test_InitializationRejectsDuplicateOutputAtomically() public {
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenToRedeem);
        outputs[1] = address(tokenToRedeem);

        _expectCreateRevert(
            ILiquidLaneCapability.InvalidTokenToRedeem.selector, address(adapter), address(asset), outputs
        );
    }

    function test_InitializationRejectsMissingOracleFactoryAtomically() public {
        CapabilityTokenMock unknownToken = new CapabilityTokenMock("Unknown", "UNKNOWN", 18);
        _expectCreateRevert(
            ILiquidLaneCapability.InvalidOracleFactory.selector,
            address(adapter),
            address(asset),
            _outputs(address(unknownToken))
        );
    }

    function test_InitializationAllowsMoreThanFiftyOutputs() public {
        address[] memory outputs = new address[](51);
        for (uint256 i; i < outputs.length; ++i) {
            outputs[i] = address(uint160(1000 + i));
            registry.setOracleFactory(address(asset), outputs[i], address(oracleFactory));
        }

        LiquidLaneCapability largeCapability = _createCapability(address(adapter), address(asset), outputs);

        assertEq(largeCapability.getTokensToRedeemLength(), outputs.length);
        assertEq(largeCapability.tokensToRedeem(outputs.length - 1), outputs[outputs.length - 1]);
    }

    function test_MigratePreservesConfiguration() public {
        address oracle = capability.oracles(address(tokenToRedeem));
        capabilityFactory.whitelist(address(new LiquidLaneCapability(address(capabilityFactory), address(registry))));
        uint64 newVersion = capabilityFactory.lastVersion();

        vm.prank(adapterOwner);
        capabilityFactory.migrate(address(capability), newVersion, bytes(""));

        assertEq(capability.version(), newVersion);
        assertEq(capability.owner(), adapterOwner);
        assertEq(capability.adapter(), address(adapter));
        assertEq(capability.inputAsset(), address(asset));
        assertEq(capability.getTokensToRedeemLength(), 1);
        assertEq(capability.tokensToRedeem(0), address(tokenToRedeem));
        assertEq(capability.oracles(address(tokenToRedeem)), oracle);
    }

    function test_MigrateLegacyCapabilityBackfillsInputAssetAndPreservesConfiguration() public {
        MigratablesFactory legacyFactory = new MigratablesFactory(address(this));
        legacyFactory.whitelist(address(new LegacyLiquidLaneCapability(address(legacyFactory), address(registry))));
        LegacyLiquidLaneCapability legacyCapability = LegacyLiquidLaneCapability(
            legacyFactory.create(legacyFactory.lastVersion(), adapterOwner, abi.encode(address(adapter)))
        );
        registry.setOracleFactory(address(vaultAsset), address(tokenToRedeem), address(oracleFactory));
        adapter.execute(
            address(legacyCapability),
            abi.encodeCall(LegacyLiquidLaneCapability.addTokenToRedeem, (address(tokenToRedeem)))
        );
        address oracle = legacyCapability.oracles(address(tokenToRedeem));
        legacyFactory.whitelist(address(new LiquidLaneCapability(address(legacyFactory), address(registry))));
        uint64 newVersion = legacyFactory.lastVersion();

        vm.prank(adapterOwner);
        legacyFactory.migrate(address(legacyCapability), newVersion, bytes(""));

        LiquidLaneCapability migrated = LiquidLaneCapability(address(legacyCapability));
        assertEq(migrated.inputAsset(), address(vaultAsset));
        assertEq(migrated.adapter(), address(adapter));
        assertEq(migrated.getTokensToRedeemLength(), 1);
        assertEq(migrated.tokensToRedeem(0), address(tokenToRedeem));
        assertEq(migrated.oracles(address(tokenToRedeem)), oracle);
        assertEq(migrated.getAmountOut(address(tokenToRedeem), 100e18), 200e18);

        tokenToRedeem.mint(address(migrated), 100e18);
        vaultAsset.mint(address(adapter), 200e18);
        adapter.approve(address(vaultAsset), address(migrated), type(uint256).max);
        adapter.execute(address(migrated), abi.encodeCall(ILiquidLaneCapability.swap, (_swap(100e18, 190e18))));

        assertEq(vaultAsset.balanceOf(recipient), 190e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 100e18);
    }

    function test_MigrateRejectsNonEmptyDataAndKeepsVersion() public {
        capabilityFactory.whitelist(address(new LiquidLaneCapability(address(capabilityFactory), address(registry))));
        uint64 newVersion = capabilityFactory.lastVersion();

        vm.prank(adapterOwner);
        vm.expectRevert(ILiquidLaneCapability.InvalidMigrationData.selector);
        capabilityFactory.migrate(address(capability), newVersion, hex"01");

        assertEq(capability.version(), 1);
    }

    function test_AddTokenToRedeemSelectorIsUnavailable() public {
        vm.expectRevert();
        adapter.execute(
            address(capability), abi.encodeWithSelector(bytes4(keccak256("addTokenToRedeem(address)")), address(asset))
        );
    }

    function test_GetAmountOutUsesExplicitInputAssetAndTokenDecimals() public view {
        assertEq(capability.getAmountOut(address(tokenToRedeem), 100e18), 200e6);
    }

    function test_SwapPullsInputAssetToRecipientAndTransfersRwaToAdapter() public {
        tokenToRedeem.mint(address(capability), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(capability), type(uint256).max);
        ILiquidLaneCapability.Swap memory swap_ = _swap(100e18, 190e6);

        vm.expectEmit(false, false, false, true, address(capability));
        emit ILiquidLaneCapability.DoSwap(swap_);
        adapter.execute(address(capability), abi.encodeCall(ILiquidLaneCapability.swap, (swap_)));

        assertEq(asset.balanceOf(recipient), 190e6);
        assertEq(asset.balanceOf(address(adapter)), 10e6);
        assertEq(asset.balanceOf(address(capability)), 0);
        assertEq(tokenToRedeem.balanceOf(address(capability)), 0);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 100e18);
    }

    function test_SwapTransfersOnlyAmountInRwaToAdapter() public {
        tokenToRedeem.mint(address(capability), 120e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(capability), type(uint256).max);
        ILiquidLaneCapability.Swap memory swap_ = _swap(100e18, 190e6);

        adapter.execute(address(capability), abi.encodeCall(ILiquidLaneCapability.swap, (swap_)));

        assertEq(tokenToRedeem.balanceOf(address(capability)), 20e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 100e18);
    }

    function test_SwapPropagatesOutputAssetTransferFailure() public {
        tokenToRedeem.mint(address(capability), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(capability), type(uint256).max);
        tokenToRedeem.setRevertTransfers(true);

        vm.expectRevert(CapabilityTokenMock.ForcedTransferRevert.selector);
        adapter.execute(address(capability), abi.encodeCall(ILiquidLaneCapability.swap, (_swap(100e18, 190e6))));

        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 200e6);
        assertEq(tokenToRedeem.balanceOf(address(capability)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 0);
    }

    function test_SwapRejectsNonAdapter() public {
        vm.expectRevert(ILiquidLaneCapability.InvalidCaller.selector);
        capability.swap(_swap(100e18, 190e6));
    }

    function test_SwapRejectsUnknownToken() public {
        CapabilityTokenMock unknownToken = new CapabilityTokenMock("Unknown", "UNKNOWN", 18);
        vm.expectRevert(ILiquidLaneCapability.InvalidTokenToRedeem.selector);
        adapter.execute(
            address(capability),
            abi.encodeCall(ILiquidLaneCapability.swap, (_swap(address(unknownToken), 100e18, 190e6)))
        );
    }

    function test_SwapRejectsAmountInAboveRwaBalance() public {
        tokenToRedeem.mint(address(capability), 99e18);

        vm.expectRevert(ILiquidLaneCapability.InsufficientRwaBalance.selector);
        adapter.execute(address(capability), abi.encodeCall(ILiquidLaneCapability.swap, (_swap(100e18, 190e6))));
    }

    function test_SwapRejectsAmountOutAboveOracleQuote() public {
        tokenToRedeem.mint(address(capability), 100e18);

        vm.expectRevert(ILiquidLaneCapability.InvalidSwapRate.selector);
        adapter.execute(address(capability), abi.encodeCall(ILiquidLaneCapability.swap, (_swap(100e18, 201e6))));
    }

    function test_SwapPropagatesInputAssetAllowanceFailure() public {
        tokenToRedeem.mint(address(capability), 100e18);
        asset.mint(address(adapter), 200e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(capability), uint256(0), uint256(190e6)
            )
        );
        adapter.execute(address(capability), abi.encodeCall(ILiquidLaneCapability.swap, (_swap(100e18, 190e6))));

        assertEq(tokenToRedeem.balanceOf(address(capability)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 200e6);
    }

    function test_SwapPropagatesInputAssetBalanceFailure() public {
        tokenToRedeem.mint(address(capability), 100e18);
        adapter.approve(address(asset), address(capability), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), uint256(0), uint256(190e6)
            )
        );
        adapter.execute(address(capability), abi.encodeCall(ILiquidLaneCapability.swap, (_swap(100e18, 190e6))));

        assertEq(tokenToRedeem.balanceOf(address(capability)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
    }

    function test_SwapPropagatesOracleFailure() public {
        tokenToRedeem.mint(address(capability), 100e18);
        CapabilityOracleMock(capability.oracles(address(tokenToRedeem))).setRevertGetPrice(true);

        vm.expectRevert(bytes("oracle failure"));
        adapter.execute(address(capability), abi.encodeCall(ILiquidLaneCapability.swap, (_swap(100e18, 190e6))));
    }

    function _swap(uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (ILiquidLaneCapability.Swap memory swap_)
    {
        swap_ = _swap(address(tokenToRedeem), amountIn, amountOut);
    }

    function _swap(address output, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (ILiquidLaneCapability.Swap memory swap_)
    {
        swap_ = ILiquidLaneCapability.Swap({
            recipient: recipient, tokenIn: output, amountIn: amountIn, amountOut: amountOut
        });
    }

    function _createCapability(address adapter_, address inputAsset_, address[] memory outputs)
        internal
        returns (LiquidLaneCapability created)
    {
        created = LiquidLaneCapability(
            capabilityFactory.create(
                capabilityFactory.lastVersion(), adapterOwner, abi.encode(adapter_, inputAsset_, outputs)
            )
        );
    }

    function _expectCreateRevert(bytes4 selector, address adapter_, address inputAsset_, address[] memory outputs)
        internal
    {
        uint256 capabilityEntities = capabilityFactory.totalEntities();
        uint256 oracleEntities = oracleFactory.totalEntities();
        uint64 version = capabilityFactory.lastVersion();
        vm.expectRevert(selector);
        capabilityFactory.create(version, adapterOwner, abi.encode(adapter_, inputAsset_, outputs));
        assertEq(capabilityFactory.totalEntities(), capabilityEntities);
        assertEq(oracleFactory.totalEntities(), oracleEntities);
    }

    function _outputs(address output) internal pure returns (address[] memory outputs) {
        outputs = new address[](1);
        outputs[0] = output;
    }
}

contract LegacyLiquidLaneCapability is MigratableEntity {
    address public adapter;
    address public immutable ORACLE_REGISTRY;
    address[] public tokensToRedeem;
    mapping(address tokenToRedeem => address oracle) public oracles;
    mapping(address tokenToRedeem => bool exists) internal _isTokenToRedeem;

    constructor(address factory, address oracleRegistry) MigratableEntity(factory) {
        ORACLE_REGISTRY = oracleRegistry;
    }

    function addTokenToRedeem(address tokenToRedeem) external {
        require(msg.sender == adapter);
        address vault_ = CapabilityAdapterMock(adapter).vault();
        address asset_ = CapabilityVaultMock(vault_).asset();
        address oracleFactory_ = IOracleRegistry(ORACLE_REGISTRY).oracleFactories(asset_, tokenToRedeem);
        address oracle = MigratablesFactory(oracleFactory_)
            .create(MigratablesFactory(oracleFactory_).lastVersion(), owner(), abi.encode(vault_, address(this)));
        oracles[tokenToRedeem] = oracle;
        _isTokenToRedeem[tokenToRedeem] = true;
        tokensToRedeem.push(tokenToRedeem);
    }

    function _initialize(uint64, address, bytes memory data) internal override {
        adapter = abi.decode(data, (address));
    }
}

contract CapabilityAdapterMock {
    using Address for address;

    address public immutable vault;
    address public immutable owner;

    constructor(address vault_, address owner_) {
        vault = vault_;
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        result = target.functionCall(data);
    }

    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }
}

contract CapabilityVaultMock {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

contract CapabilityTokenMock is ERC20 {
    error ForcedTransferRevert();

    uint8 internal immutable _tokenDecimals;
    bool internal _revertTransfers;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setRevertTransfers(bool status) external {
        _revertTransfers = status;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (_revertTransfers && from != address(0)) {
            revert ForcedTransferRevert();
        }
        super._update(from, to, amount);
    }
}

contract CapabilityOracleMock is MigratableEntity, IOracle {
    uint256 public immutable price;
    address public inputAsset;
    address public capability;
    bool public revertGetPrice;

    constructor(address factory, uint256 price_) MigratableEntity(factory) {
        price = price_;
    }

    function getPrice() external view returns (uint256) {
        if (revertGetPrice) {
            revert("oracle failure");
        }
        return price;
    }

    function setRevertGetPrice(bool status) external {
        revertGetPrice = status;
    }

    function _initialize(uint64, address, bytes memory data) internal override {
        (inputAsset, capability) = abi.decode(data, (address, address));
    }
}
