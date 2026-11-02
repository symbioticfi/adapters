### src/contracts/MerkleAdapter.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Adapter} from "./Adapter.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {IMerkleAdapterOracle} from "../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../interfaces/IMerkleAdapter.sol";

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";

/// @title MerkleAdapter
/// @notice Contract for bridging vault capital and a strategy account with flow-adjusted oracle accounting.
contract MerkleAdapter is Adapter, IMerkleAdapter {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using Checkpoints for Checkpoints.Trace208;

    /* IMMUTABLES */

    /// @inheritdoc IMerkleAdapter
    address public immutable override ORACLE_FACTORY;

    /// @inheritdoc IMerkleAdapter
    address public immutable override ACCOUNT_FACTORY;

    /* STATE VARIABLES */

    /// @inheritdoc IMerkleAdapter
    address public override oracle;

    /// @inheritdoc IMerkleAdapter
    uint256 public pendingDeallocation;

    /// @inheritdoc IMerkleAdapter
    uint256 public releasedLiquidity;

    /// @inheritdoc IMerkleAdapter
    uint256 public stagedLiquidity;

    /// @inheritdoc IMerkleAdapter
    address public account;

    /// @inheritdoc IMerkleAdapter
    uint48 public stagedBlock;

    /// @inheritdoc IMerkleAdapter
    uint48 public syncedSnapshotBlock;

    // Values preserve the two's-complement bits of int208; each block/value checkpoint occupies one slot.
    Checkpoints.Trace208 private _netFlow;

    /* CONSTRUCTOR */

    /// @dev Initializes the immutable factory dependencies for the implementation.
    constructor(address newVaultFactory, address newAdapterFactory, address newOracleFactory, address newAccountFactory)
        Adapter(newVaultFactory, newAdapterFactory)
    {
        ORACLE_FACTORY = newOracleFactory;
        ACCOUNT_FACTORY = newAccountFactory;
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc IMerkleAdapter
    function netFlow() public view returns (int256) {
        return int208(_netFlow.latest());
    }

    /// @inheritdoc IMerkleAdapter
    function netFlowAt(uint48 snapshotBlock) public view returns (int256) {
        return int208(_netFlow.upperLookupRecent(snapshotBlock));
    }

    /// @inheritdoc IAdapter
    function totalAssets() public view override(Adapter, IAdapter) returns (uint256) {
        (uint48 snapshotBlock, uint256 snapshotTotalAssets) = IMerkleAdapterOracle(oracle).latestSnapshot();
        return uint256(int256(snapshotTotalAssets) - netFlowAt(snapshotBlock) + netFlow());
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleAdapter
    function push(uint256 amount) public {
        if (account != msg.sender) revert InvalidCaller();
        if (amount > freeAssets().saturatingSub(Math.max(pendingDeallocation, releasedLiquidity + stagedLiquidity))) {
            revert InsufficientIdleAssets();
        }

        IERC20(IERC4626(vault).asset()).safeTransfer(account, amount);
        emit Push(amount);
    }

    /// @inheritdoc IMerkleAdapter
    function pull(uint256 amount) public {
        if (account != msg.sender) revert InvalidCaller();

        IERC20(IERC4626(vault).asset()).safeTransferFrom(account, address(this), amount);
        stageLiquidity();
        emit Pull(amount);
    }

    /// @inheritdoc IAdapter
    function deallocate(uint256 amount) public override(Adapter, IAdapter) onlyDelegator returns (uint256 deallocated) {
        syncReport();
        uint256 released = releasedLiquidity;
        // The delegator validates NAV through totalAssets() even when nothing is released.
        if (released == 0) return 0;
        deallocated = Math.min(amount, Math.min(released, totalAssets()));
        if (deallocated == 0) return 0;
        releasedLiquidity = released - deallocated;
        pendingDeallocation = pendingDeallocation.saturatingSub(deallocated);
        _netFlow.push(uint48(block.number), uint208(int208(netFlow() - int256(deallocated))));
        // The vault takes the tokens after this call: staging here would count outgoing cash again.
    }

    /// @inheritdoc IMerkleAdapter
    function syncReport() public {
        uint48 snapshotBlock = IMerkleAdapterOracle(oracle).snapshotBlock();
        if (snapshotBlock > syncedSnapshotBlock) {
            uint256 curTotalAssets = totalAssets();
            syncedSnapshotBlock = snapshotBlock;
            if (stagedBlock > 0 && stagedBlock <= snapshotBlock) {
                releasedLiquidity += stagedLiquidity;
                delete stagedLiquidity;
                delete stagedBlock;
            }
            if (releasedLiquidity > curTotalAssets) {
                releasedLiquidity = curTotalAssets;
            }
            if (pendingDeallocation > curTotalAssets) {
                pendingDeallocation = curTotalAssets;
            }
            emit SyncReport(snapshotBlock, releasedLiquidity);
        }
        stageLiquidity();
    }

    /// @inheritdoc IMerkleAdapter
    function stageLiquidity() public {
        if (stagedBlock > 0 || pendingDeallocation <= releasedLiquidity) return;

        uint256 amount = Math.min(freeAssets(), pendingDeallocation).saturatingSub(releasedLiquidity);
        if (amount == 0) return;

        stagedLiquidity = amount;
        stagedBlock = uint48(block.number);
        emit StageLiquidity(amount, stagedBlock);
    }

    /* INTERNAL FUNCTIONS */

    function _allocate(uint256 amount) internal override returns (uint256) {
        syncReport();
        _netFlow.push(uint48(block.number), uint208(int208(netFlow() + int256(amount))));
        return amount;
    }

    /// @dev The delegator supplies cumulative outstanding demand after draining immediately available liquidity.
    function _requestDeallocate(uint256 amount) internal override {
        pendingDeallocation = amount;
        stageLiquidity();
    }

    /* INITIALIZATION */

    /// @dev Creates the latest strategy account and accounting oracle owned by the adapter owner.
    function __initialize(address, bytes memory data) internal override {
        InitParams memory params = abi.decode(data, (InitParams));
        account = IMigratablesFactory(ACCOUNT_FACTORY)
            .create(
                IMigratablesFactory(ACCOUNT_FACTORY).lastVersion(),
                owner(),
                abi.encode(address(this), params.merkleAccountData)
            );
        emit SetAccount(account);
        oracle = IMigratablesFactory(ORACLE_FACTORY)
            .create(
                IMigratablesFactory(ORACLE_FACTORY).lastVersion(), owner(), abi.encode(address(this), params.oracleData)
            );
        emit SetOracle(oracle);
    }
}
```

### src/contracts/common/ImmutableFactory.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IImmutableFactory} from "../../interfaces/common/IImmutableFactory.sol";

import {Registry} from "@symbioticfi/core/src/contracts/common/Registry.sol";

import {SSTORE2} from "solady/utils/SSTORE2.sol";

/// @title ImmutableFactory
/// @notice Factory contract for deploying and registering instances of fixed creation bytecode.
/// @dev Creation bytecode uses an SSTORE2 contract created during construction. Predict instance addresses
/// using the factory's current nonce rather than assuming its first CREATE uses nonce one.
contract ImmutableFactory is Registry, IImmutableFactory {
    /* IMMUTABLES */

    /// @inheritdoc IImmutableFactory
    address public immutable implementationPointer;

    /* CONSTRUCTOR */

    constructor(bytes memory newImplementation) {
        implementationPointer = SSTORE2.write(newImplementation);
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IImmutableFactory
    function create(bytes calldata data) public returns (address entityAddress) {
        bytes memory bytecode = bytes.concat(SSTORE2.read(implementationPointer), data);
        assembly ("memory-safe") {
            entityAddress := create(0, add(bytecode, 32), mload(bytecode))
        }
        if (entityAddress.code.length == 0) revert DeploymentFailed();

        _addEntity(entityAddress);
    }
}
```

### src/contracts/merkle-adapter/connectors/OracleRegistry.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IOracleRegistry} from "../../../interfaces/merkle-adapter/connectors/IOracleRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title OracleRegistry
/// @notice Owned registry contract for RWA price oracles approved for individual Liquid Lane connectors.
contract OracleRegistry is Ownable, IOracleRegistry {
    /* STATE VARIABLES */

    /// @inheritdoc IOracleRegistry
    mapping(address connector => mapping(address tokenToRedeem => address oracle)) public oracles;

    /* CONSTRUCTOR */

    /// @dev Sets the initial registry owner.
    constructor(address newOwner) Ownable(newOwner) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IOracleRegistry
    function setOracle(address connector, address tokenToRedeem, address newOracle) public onlyOwner {
        oracles[connector][tokenToRedeem] = newOracle;

        emit SetOracle(connector, tokenToRedeem, newOracle);
    }
}
```

### src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "../libraries/AssetRateLimits.sol";

import {
    DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneConnector
} from "../../../interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
import {IOracleRegistry} from "../../../interfaces/merkle-adapter/connectors/IOracleRegistry.sol";
import {IOracle} from "../../../interfaces/ll-adapter/IOracle.sol";

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title LiquidLaneConnector
/// @notice Contract for account-bound RWA inventory swaps with saved oracles and asset budgets.
contract LiquidLaneConnector is MigratableEntity, EIP712, ILiquidLaneConnector {
    using AssetRateLimits for AssetRateLimits.AssetLimit;
    using Math for uint256;
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneConnector
    address public immutable MERKLE_ACCOUNT_FACTORY;

    /// @inheritdoc ILiquidLaneConnector
    address public immutable ORACLE_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc ILiquidLaneConnector
    address public account;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => address oracle) public oracles;

    /// @inheritdoc ILiquidLaneConnector
    address public outputAsset;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => AssetRateLimits.AssetLimit) public assetLimits;

    /// @inheritdoc ILiquidLaneConnector
    address public signer;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => uint256 discount) public minDiscount;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => mapping(uint256 nonce => bool invalidated)) public isUsedNonce;

    /* MODIFIERS */

    /// @dev Restricts a function to the bound account.
    modifier onlyAccount() {
        if (account != msg.sender) revert InvalidCaller();

        _;
    }

    /* CONSTRUCTOR */

    /// @dev Initializes the connector factory, Merkle account factory and oracle registry dependencies.
    constructor(address newFactory, address newMerkleAccountFactory, address newOracleRegistry)
        MigratableEntity(newFactory)
        EIP712("LiquidLaneConnector", "1")
    {
        MERKLE_ACCOUNT_FACTORY = newMerkleAccountFactory;
        ORACLE_REGISTRY = newOracleRegistry;
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc ILiquidLaneConnector
    function remainingAssets(address tokenToRedeem) public view returns (uint256) {
        return assetLimits[tokenToRedeem].remaining();
    }

    /// @inheritdoc ILiquidLaneConnector
    function getAmountOut(address tokenToRedeem, uint256 amountIn) public view returns (uint256) {
        address oracle = oracles[tokenToRedeem];
        if (oracle == address(0)) revert InvalidTokenToRedeem();

        return amountIn.mulDiv(
            IOracle(oracle).getPrice() * 10 ** IERC20Metadata(outputAsset).decimals(),
            1e18 * 10 ** IERC20Metadata(tokenToRedeem).decimals()
        );
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILiquidLaneConnector
    function setSigner(address newSigner) public onlyOwner {
        signer = newSigner;
        emit SetSigner(newSigner);
    }

    /// @inheritdoc ILiquidLaneConnector
    function setMinDiscount(address tokenToRedeem, uint256 newMinDiscount) public onlyOwner {
        if (newMinDiscount > DISCOUNT_PRECISION) revert InvalidDiscount();

        minDiscount[tokenToRedeem] = newMinDiscount;
        emit SetMinDiscount(tokenToRedeem, newMinDiscount);
    }

    /// @inheritdoc ILiquidLaneConnector
    function invalidateNonce(address tokenToRedeem, uint256 nonce) public {
        if (owner() != msg.sender && signer != msg.sender) revert InvalidCaller();

        isUsedNonce[tokenToRedeem][nonce] = true;
        emit InvalidateNonce(tokenToRedeem, nonce);
    }

    /// @inheritdoc ILiquidLaneConnector
    function addTokenToRedeem(address tokenToRedeem) public onlyAccount {
        if (tokenToRedeem == address(0) || tokenToRedeem == outputAsset || oracles[tokenToRedeem] != address(0)) {
            revert InvalidTokenToRedeem();
        }

        address oracle = IOracleRegistry(ORACLE_REGISTRY).oracles(address(this), tokenToRedeem);
        if (oracle == address(0)) revert InvalidOracle();

        oracles[tokenToRedeem] = oracle;
        emit AddTokenToRedeem(tokenToRedeem, oracle);
    }

    /// @inheritdoc ILiquidLaneConnector
    function removeTokenToRedeem(address tokenToRedeem) public onlyAccount {
        if (oracles[tokenToRedeem] == address(0)) revert InvalidTokenToRedeem();

        delete oracles[tokenToRedeem];
        emit RemoveTokenToRedeem(tokenToRedeem);
    }

    /// @inheritdoc ILiquidLaneConnector
    function setMaxAssetsPerDuration(address tokenToRedeem, uint256 newMaxAssets, uint48 newDuration)
        public
        onlyAccount
    {
        assetLimits[tokenToRedeem].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(tokenToRedeem, newMaxAssets, newDuration);
    }

    /// @inheritdoc ILiquidLaneConnector
    function swap(Swap calldata newSwap) public onlyAccount {
        if (newSwap.amountOut > getAmountOut(newSwap.tokenIn, newSwap.amountIn)) revert InvalidSwapRate();

        _swap(newSwap);
    }

    /// @inheritdoc ILiquidLaneConnector
    function swap(
        DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn
    ) public onlyAccount returns (uint256 amountOut) {
        Discount calldata discount = discountSwap.discount;
        if (discount.signer != owner() && discount.signer != signer) revert InvalidSigner();
        if (discount.deadline < block.timestamp || discountSwap.protocolDeadline < block.timestamp) {
            revert ExpiredSwap();
        }
        if (isUsedNonce[discount.tokenToRedeem][discount.nonce]) revert AlreadyUsedNonce();
        if (discount.discount < minDiscount[discount.tokenToRedeem]) revert InvalidDiscount();

        bytes32 discountHash = keccak256(abi.encode(DISCOUNT_TYPEHASH, discount));
        if (!SignatureChecker.isValidSignatureNowCalldata(
                discount.signer, _hashTypedDataV4(discountHash), discountSwap.signerSignature
            )) revert InvalidSignature();
        if (!SignatureChecker.isValidSignatureNowCalldata(
                discount.protocol,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(
                            DISCOUNT_SWAP_TYPEHASH,
                            discountHash,
                            keccak256(discountSwap.signerSignature),
                            discountSwap.protocolDeadline
                        )
                    )
                ),
                protocolSignature
            )) revert InvalidSignature();

        amountOut = getAmountOut(discount.tokenToRedeem, amountIn) * (DISCOUNT_PRECISION - discount.discount)
            / DISCOUNT_PRECISION;
        _swap(Swap({recipient: recipient, tokenIn: discount.tokenToRedeem, amountIn: amountIn, amountOut: amountOut}));
    }

    /* INTERNAL FUNCTIONS */

    function _swap(Swap memory newSwap) internal {
        assetLimits[newSwap.tokenIn].consume(newSwap.amountOut);
        IERC20(newSwap.tokenIn).safeTransfer(msg.sender, newSwap.amountIn);
        IERC20(outputAsset).safeTransferFrom(msg.sender, newSwap.recipient, newSwap.amountOut);

        emit DoSwap(newSwap);
    }

    /* INITIALIZATION */

    /// @dev Binds the connector proxy to a registered Merkle account and funding asset.
    function _initialize(uint64, address, bytes memory data) internal override {
        (account, outputAsset) = abi.decode(data, (address, address));
        if (!IRegistry(MERKLE_ACCOUNT_FACTORY).isEntity(account)) revert InvalidAccount();
    }

    /* MIGRATION */

    /// @dev Migration is intentionally unsupported for this implementation.
    function _migrate(uint64, uint64, bytes calldata) internal pure override {
        revert();
    }
}
```

### src/contracts/merkle-adapter/CapabilitiesRegistry.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ICapabilitiesRegistry} from "../../interfaces/merkle-adapter/ICapabilitiesRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CapabilitiesRegistry
/// @notice Contract for whitelisting capability selectors for individual accounts.
contract CapabilitiesRegistry is Ownable, ICapabilitiesRegistry {
    /* STATE VARIABLES */

    mapping(address account => mapping(address capability => bytes4[] selectors)) internal _selectors;

    /* CONSTRUCTOR */

    constructor(address newOwner) Ownable(newOwner) {}

    /* VIEW FUNCTIONS */

    /// @inheritdoc ICapabilitiesRegistry
    function selectors(address account, address capability) public view returns (bytes4[] memory) {
        return _selectors[account][capability];
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICapabilitiesRegistry
    function whitelistCapability(address account, address capability, bytes4[] calldata newSignatures)
        public
        onlyOwner
    {
        _selectors[account][capability] = newSignatures;
        emit WhitelistCapability(account, capability, newSignatures);
    }
}
```

### src/contracts/merkle-adapter/capabilities/RecipeCapability.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Recipes} from "../Recipes.sol";

import {IRecipeCapability} from "../../../interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";

/// @title RecipeCapability
/// @notice Contract for stateless Merkle-committed recipes executed in the account's context.
contract RecipeCapability is Recipes, IRecipeCapability {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IRecipeCapability
    function execute(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs)
        public
        returns (uint256[] memory)
    {
        if (address(this) != msg.sender) revert InvalidCaller();
        uint256 stepsLength = steps.length;
        State memory state = State({values: new uint256[](stepsLength), index: 0});
        for (; state.index < stepsLength; ++state.index) {
            state.values[state.index] = _run(queries, steps, inputs, state);
        }
        return state.values;
    }
}
```

### src/contracts/merkle-adapter/oracle/CREOracle.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    ICREOracle,
    ORACLE_GUARD_ROLE,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "../../../interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "../../../interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IMerkleAdapterOracle} from "../../../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../../../interfaces/IMerkleAdapter.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title CREOracle
/// @notice Contract for storing MerkleAdapter NAV delivered by an approved CRE forwarder and workflow.
contract CREOracle is Multicallable, MigratableEntity, AccessControlEnumerableUpgradeable, ICREOracle {
    using SafeCast for int256;
    using SafeCast for uint256;

    /* IMMUTABLES */

    /// @inheritdoc ICREOracle
    address public immutable WORKFLOW_REGISTRY;

    /// @inheritdoc IMerkleAdapterOracle
    uint48 public immutable MAX_REPORT_AGE;

    /* STATE VARIABLES */

    /// @inheritdoc ICREOracle
    uint32 public maxOracleGrowth;

    /// @inheritdoc ICREOracle
    uint32 public maxOracleLoss;

    /// @inheritdoc ICREOracle
    uint128 public oracleTolerance;

    /// @inheritdoc ICREOracle
    address public forwarder;

    /// @inheritdoc ICREOracle
    address public adapter;

    /// @inheritdoc IMerkleAdapterOracle
    uint256 public totalAssets;

    /// @inheritdoc IMerkleAdapterOracle
    uint48 public snapshotBlock;

    /// @inheritdoc IMerkleAdapterOracle
    uint48 public snapshotTimestamp;

    /// @inheritdoc ICREOracle
    bytes32 public rejectedReportHash;

    /* CONSTRUCTOR */

    /// @dev Pins report freshness; the registry stores each proxy's workflow.
    constructor(address newFactory, address newWorkflowRegistry, uint48 newMaxReportAge) MigratableEntity(newFactory) {
        WORKFLOW_REGISTRY = newWorkflowRegistry;
        MAX_REPORT_AGE = newMaxReportAge;
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc IMerkleAdapterOracle
    function latestSnapshot() public view returns (uint48 reportBlock, uint256 assets) {
        if (snapshotTimestamp == 0 || block.timestamp - snapshotTimestamp > MAX_REPORT_AGE) revert OracleStale();
        return (snapshotBlock, totalAssets);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlEnumerableUpgradeable, IERC165)
        returns (bool)
    {
        // Chainlink IReceiver adds only onReport to IERC165.
        return interfaceId == ICREOracle.onReport.selector || super.supportsInterface(interfaceId);
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICREOracle
    function setOracleLimits(uint32 newGrowth, uint32 newLoss, uint128 newTolerance)
        public
        onlyRole(ORACLE_LIMITS_ROLE)
    {
        _setOracleLimits(newGrowth, newLoss, newTolerance);
    }

    /// @inheritdoc ICREOracle
    function acceptReport(bytes calldata data) public onlyRole(ORACLE_GUARD_ROLE) {
        if (keccak256(data) != rejectedReportHash) revert InvalidReport();
        _onReport(data, true);
        delete rejectedReportHash;
        emit AcceptReport(data);
    }

    /// @inheritdoc ICREOracle
    function onReport(bytes calldata metadata, bytes calldata data) public {
        if (forwarder != msg.sender) revert InvalidSender();

        // KeystoneForwarder includes a trailing bytes2 report ID.
        if (
            metadata.length != 64 || address(bytes20(metadata[42:62])) != WORKFLOW_REGISTRY
                || bytes32(metadata[:32]) == bytes32(0)
                || bytes32(metadata[:32]) != ICREWorkflowRegistry(WORKFLOW_REGISTRY).workflowId(address(this))
        ) revert InvalidWorkflow();
        if (data.length != 160) revert InvalidReport();
        _onReport(data, false);
    }

    /* INTERNAL FUNCTIONS */

    function _setOracleLimits(uint32 newGrowth, uint32 newLoss, uint128 newTolerance) internal {
        if (newGrowth > ORACLE_LIMIT_PRECISION || newLoss > ORACLE_LIMIT_PRECISION) revert InvalidOracleLimit();

        maxOracleGrowth = newGrowth;
        maxOracleLoss = newLoss;
        oracleTolerance = newTolerance;
        emit SetOracleLimits(newGrowth, newLoss, newTolerance);
    }

    /// @dev A reviewed report bypasses movement limits only.
    function _onReport(bytes calldata data, bool reviewed) internal {
        Report memory report = abi.decode(data, (Report));
        if (report.chainId != block.chainid || report.adapter != adapter) revert InvalidReport();

        if (
            report.snapshotBlock <= snapshotBlock || report.snapshotBlock >= block.number
                || report.snapshotTimestamp <= snapshotTimestamp || report.snapshotTimestamp > block.timestamp
                || block.timestamp - report.snapshotTimestamp > MAX_REPORT_AGE
        ) revert StaleReport();

        int256 newFlow = IMerkleAdapter(adapter).netFlowAt(report.snapshotBlock);
        if (report.totalAssets.toInt256() - newFlow + IMerkleAdapter(adapter).netFlow() < 0) revert InvalidAssets();
        uint256 baseline = uint256(int256(totalAssets) - IMerkleAdapter(adapter).netFlowAt(snapshotBlock) + newFlow);
        if (!reviewed) {
            bool grows = report.totalAssets >= baseline;
            uint256 delta = grows ? report.totalAssets - baseline : baseline - report.totalAssets;
            if (
                delta > oracleTolerance
                    && delta > baseline * (grows ? maxOracleGrowth : maxOracleLoss) / ORACLE_LIMIT_PRECISION
            ) {
                rejectedReportHash = keccak256(data);
                emit OnReport(report, true);
                return;
            }
        }
        totalAssets = report.totalAssets;
        snapshotBlock = report.snapshotBlock;
        snapshotTimestamp = report.snapshotTimestamp;
        emit OnReport(report, false);
    }

    /* INITIALIZATION */

    /// @dev Binds the adapter and forwarder and applies the oracle's initial role grants and movement limits.
    function _initialize(uint64, address, bytes memory data) internal override {
        (adapter, data) = abi.decode(data, (address, bytes));
        InitParams memory params = abi.decode(data, (InitParams));

        forwarder = params.forwarder;
        _setOracleLimits(params.maxOracleGrowth, params.maxOracleLoss, params.oracleTolerance);

        if (params.defaultAdminRoleHolder != address(0)) _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        if (params.oracleLimitsRoleHolder != address(0)) _grantRole(ORACLE_LIMITS_ROLE, params.oracleLimitsRoleHolder);
        if (params.oracleGuardRoleHolder != address(0)) _grantRole(ORACLE_GUARD_ROLE, params.oracleGuardRoleHolder);
    }
}
```

### src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ICREWorkflowRegistry} from "../../../interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IChainlinkWorkflowRegistry} from "../../../interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title CREWorkflowRegistry
/// @notice Contract for CRE registration requiring Symbiotic's proposal and the curator's acceptance.
contract CREWorkflowRegistry is Ownable, ICREWorkflowRegistry {
    using Bytes for bytes;

    /* IMMUTABLES */

    /// @inheritdoc ICREWorkflowRegistry
    address public immutable CHAINLINK_WORKFLOW_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc ICREWorkflowRegistry
    mapping(address oracle => bytes32 workflowId) public workflowId;

    /// @inheritdoc ICREWorkflowRegistry
    mapping(address oracle => bytes32 workflowId) public proposedWorkflowId;

    /// @inheritdoc ICREWorkflowRegistry
    mapping(address oracle => WorkflowParams params) public proposedWorkflowParams;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newChainlinkWorkflowRegistry) Ownable(newOwner) {
        CHAINLINK_WORKFLOW_REGISTRY = newChainlinkWorkflowRegistry;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICREWorkflowRegistry
    function proposeWorkflow(address oracle, bytes32 newWorkflowId, WorkflowParams calldata newParams)
        public
        onlyOwner
    {
        proposedWorkflowId[oracle] = newWorkflowId;
        if (newWorkflowId == bytes32(0)) delete proposedWorkflowParams[oracle];
        else proposedWorkflowParams[oracle] = newParams;

        emit ProposeWorkflow(oracle, newWorkflowId, newParams);
    }

    /// @inheritdoc ICREWorkflowRegistry
    function acceptWorkflow(address oracle, bytes32 newWorkflowId, WorkflowParams calldata newParams) public {
        if (Ownable(oracle).owner() != msg.sender) revert InvalidCaller();
        if (
            newWorkflowId == bytes32(0) || proposedWorkflowId[oracle] != newWorkflowId
                || !abi.encode(proposedWorkflowParams[oracle]).equal(abi.encode(newParams))
        ) revert InvalidWorkflow();

        delete proposedWorkflowId[oracle];
        delete proposedWorkflowParams[oracle];
        IChainlinkWorkflowRegistry(CHAINLINK_WORKFLOW_REGISTRY)
            .upsertWorkflow(
                Strings.toHexString(oracle),
                "default",
                newWorkflowId,
                IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
                newParams.donFamily,
                newParams.binaryUrl,
                newParams.configUrl,
                newParams.attributes,
                false
            );
        workflowId[oracle] = newWorkflowId;
        emit AcceptWorkflow(oracle, newWorkflowId);
    }

    /// @inheritdoc ICREWorkflowRegistry
    function linkOwner(uint48 validityTimestamp, bytes32 proof, bytes calldata signature) public onlyOwner {
        IChainlinkWorkflowRegistry(CHAINLINK_WORKFLOW_REGISTRY).linkOwner(validityTimestamp, proof, signature);
    }
}
```

### src/contracts/merkle-adapter/Recipes.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IRecipes,
    OP_ADD,
    OP_CALL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_SATURATING_SUB,
    OP_SUB,
    SRC_INPUT,
    SRC_LITERAL,
    SRC_RESULT
} from "../../interfaces/merkle-adapter/IRecipes.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LibBytes} from "solady/utils/LibBytes.sol";

/// @title Recipes
/// @notice Base contract for the stateless interpreter shared by executor and account capability recipes.
/// @dev Authorization and account management belong to the concrete execution wrapper.
abstract contract Recipes is IRecipes {
    using Address for address;
    using LibBytes for bytes;
    using Math for uint256;

    /* INTERNAL FUNCTIONS */

    function _run(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs, State memory state)
        internal
        returns (uint256)
    {
        (uint8 operation, bytes calldata operationData) = _step(steps[state.index]);
        if (operation == OP_READ) {
            (address target, bytes memory data, uint256[] memory bindings, uint256 offset) =
                abi.decode(queries[abi.decode(operationData, (uint256))], (address, bytes, uint256[], uint256));
            _bind(data, bindings, steps, inputs, state);
            bytes memory result = target.functionStaticCall(data);
            if (offset + 32 > result.length) revert InvalidQuery();
            return uint256(result.load(offset));
        } else if (operation == OP_CALL) {
            (address target, bytes memory data, uint256[] memory bindings) =
                abi.decode(operationData, (address, bytes, uint256[]));
            _bind(data, bindings, steps, inputs, state);
            target.functionCall(data);
        } else if (operation <= OP_LESS_OR_EQUAL) {
            (uint256 a, uint256 b) = abi.decode(operationData, (uint256, uint256));
            a = _value(a, steps, inputs, state);
            b = _value(b, steps, inputs, state);
            if (operation == OP_ADD) return a + b;
            if (operation == OP_SUB) return a - b;
            if (operation == OP_SATURATING_SUB) return a.saturatingSub(b);
            if (operation == OP_MIN) return Math.min(a, b);
            if (operation == OP_MAX) return Math.max(a, b);
            if (operation == OP_MUL_DIV) {
                // The first two packed operands occupy 64 bytes.
                return a * b / _value(abi.decode(operationData[64:], (uint256)), steps, inputs, state);
            }
            if (operation == OP_EQUAL ? a != b : a > b) revert CheckFailed();
        } else {
            revert InvalidOperation();
        }
        return 0;
    }

    function _step(bytes calldata operationAndData) internal pure returns (uint8 operation, bytes calldata data) {
        return (uint8(operationAndData[0]), operationAndData[1:]);
    }

    function _value(uint256 srcAndValue, bytes[] calldata steps, uint256[] calldata inputs, State memory state)
        internal
        pure
        returns (uint256)
    {
        uint8 src = uint8(srcAndValue >> 216);
        uint256 value = uint216(srcAndValue);
        if (src == SRC_LITERAL) return value;
        if (src == SRC_INPUT) return inputs[value];
        if (src != SRC_RESULT) revert InvalidReference();
        if (value >= state.index || uint8(steps[value][0]) > OP_MUL_DIV) revert InvalidReference();
        return state.values[value];
    }

    function _bind(
        bytes memory data,
        uint256[] memory bindings,
        bytes[] calldata steps,
        uint256[] calldata inputs,
        State memory state
    ) internal pure {
        uint256 end = 4;
        uint256 bindingsLength = bindings.length;
        uint256 dataLength = data.length;
        for (uint256 i; i < bindingsLength; ++i) {
            uint256 offset = bindings[i] >> 224;
            if (offset < end) revert InvalidCall();
            end = offset + 32;
            if (end > dataLength) revert InvalidCall();
            uint256 value = _value(bindings[i], steps, inputs, state);
            assembly ("memory-safe") {
                mstore(add(add(data, 32), offset), value)
            }
        }
    }
}
```

### src/contracts/merkle-adapter/libraries/AssetRateLimits.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.4;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title AssetRateLimits
 * @notice Library for fixed-period asset budgets shared by adapter actions.
 */
library AssetRateLimits {
    using Math for uint256;

    /* ERRORS */

    /**
     * @notice Raised when an operation exceeds the remaining asset budget.
     */
    error AssetLimitExceeded();

    /**
     * @notice Raised when a configured period has zero duration.
     */
    error InvalidDuration();

    /**
     * @notice Raised when an asset has no enabled funding budget.
     */
    error UnconfiguredAsset();

    /* STRUCTS */

    /**
     * @notice Funding budget and cumulative usage for one asset's fixed period.
     * @param maxAssets Maximum funding-token base units per period; zero disables spending.
     * @param duration Period length in seconds; nonzero after configuration.
     * @param periodStart Start of the last recorded period.
     * @param spent Funding-token base units spent in that period.
     */
    struct AssetLimit {
        uint256 maxAssets;
        uint48 duration;
        uint48 periodStart;
        uint256 spent;
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @dev Updates configuration without granting a fresh budget during an active period.
     */
    function configure(AssetLimit storage limit, uint256 newMaxAssets, uint48 newDuration) internal {
        if (newDuration == 0) revert InvalidDuration();

        if (limit.duration > 0) _rollPeriod(limit);
        if (newDuration != limit.duration) limit.periodStart = uint48(block.timestamp);
        limit.maxAssets = newMaxAssets;
        limit.duration = newDuration;
    }

    /**
     * @dev Charges funding before external transfers; an outer revert restores all usage.
     */
    function consume(AssetLimit storage limit, uint256 assets) internal {
        if (limit.maxAssets == 0) revert UnconfiguredAsset();

        _rollPeriod(limit);

        limit.spent += assets;
        if (limit.spent > limit.maxAssets) revert AssetLimitExceeded();
    }

    /**
     * @dev Computes the current capacity without mutating an expired period.
     */
    function remaining(AssetLimit storage limit) internal view returns (uint256) {
        if (limit.maxAssets == 0) return 0;
        return block.timestamp - limit.periodStart < limit.duration
            ? limit.maxAssets.saturatingSub(limit.spent)
            : limit.maxAssets;
    }

    /* PRIVATE FUNCTIONS */

    /**
     * @dev Advances whole periods without accruing unused capacity or drifting the period boundaries.
     */
    function _rollPeriod(AssetLimit storage limit) private {
        uint256 periods = (block.timestamp - limit.periodStart) / limit.duration;
        if (periods == 0) return;
        limit.periodStart = uint48(limit.periodStart + periods * limit.duration);
        limit.spent = 0;
    }
}
```

### src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMerkleAccount} from "../../../interfaces/merkle-adapter/IMerkleAccount.sol";

/**
 * @title MerkleAdapterVerifier
 * @notice Library for hashing masked Merkle actions into canonical leaves.
 */
library MerkleAdapterVerifier {
    /* INTERNAL FUNCTIONS */

    /**
     * @dev Constructs the canonical double-hashed leaf, committing the mask alongside the masked calldata.
     * Both are caller-supplied, so committing only the masked result would authorize every `data` that
     * is a bitwise superset of it: a caller can pass `dataMask = ~maskedData`, which leaves the leaf's
     * zero bits unconstrained. A mask must pin a bit to zero as firmly as it pins one to one.
     */
    function leaf(address target, uint96 value, bytes memory data, bytes memory dataMask)
        internal
        pure
        returns (bytes32)
    {
        uint256 length = data.length;
        if (length != dataMask.length) revert IMerkleAccount.InvalidDataMaskLength();

        bytes memory maskedData = new bytes(length);
        // Bytes allocations are padded to whole words; hashing below excludes the trailing padding.
        assembly ("memory-safe") {
            let end := add(length, 32)
            for { let i := 32 } lt(i, end) { i := add(i, 32) } {
                mstore(add(maskedData, i), and(mload(add(data, i)), not(mload(add(dataMask, i)))))
            }
        }
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        target, value == 0 ? bytes1(0) : bytes1(0xff), keccak256(dataMask), keccak256(maskedData)
                    )
                )
            )
        );
    }
}
```

### src/contracts/merkle-adapter/RootRegistry.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IRootRegistry} from "../../interfaces/merkle-adapter/IRootRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RootRegistry
/// @notice Protocol-owned registry contract for proposed account Merkle roots.
contract RootRegistry is Ownable, IRootRegistry {
    /* STATE VARIABLES */

    /// @inheritdoc IRootRegistry
    mapping(address account => bytes32 root) public roots;

    /* CONSTRUCTOR */

    /// @dev Sets the protocol owner that may publish roots.
    constructor(address newOwner) Ownable(newOwner) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IRootRegistry
    function setRoot(address account, bytes32 newRoot) public onlyOwner {
        roots[account] = newRoot;

        emit SetRoot(account, newRoot);
    }
}
```

### src/contracts/merkle-adapter/MerkleAccount.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MerkleAdapterVerifier} from "./libraries/MerkleAdapterVerifier.sol";

import {ICapabilitiesRegistry} from "../../interfaces/merkle-adapter/ICapabilitiesRegistry.sol";
import {IMerkleAccount} from "../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {IRootRegistry} from "../../interfaces/merkle-adapter/IRootRegistry.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title MerkleAccount
/// @notice Migratable contract for strategy custody, Merkle permissions and capability execution.
contract MerkleAccount is
    MigratableEntity,
    AccessControlEnumerableUpgradeable,
    Multicallable,
    Proxy,
    ERC721Holder,
    IMerkleAccount
{
    using Address for address;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /* IMMUTABLES */

    /// @inheritdoc IMerkleAccount
    address public immutable MERKLE_ADAPTER_FACTORY;

    /// @inheritdoc IMerkleAccount
    address public immutable ROOT_REGISTRY;

    /// @inheritdoc IMerkleAccount
    address public immutable CAPABILITIES_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc IMerkleAccount
    address public adapter;

    /// @inheritdoc IMerkleAccount
    bytes32 public root;

    /// @inheritdoc IMerkleAccount
    mapping(bytes4 selector => address capability) public capabilityBySelector;

    EnumerableSet.AddressSet private _capabilities;

    /// @inheritdoc IMerkleAccount
    mapping(address capability => bytes4[] selectors) public capabilitySelectors;

    /// @inheritdoc IMerkleAccount
    mapping(bytes32 digest => bool approved) public signatures;

    /* CONSTRUCTOR */

    constructor(
        address newFactory,
        address newMerkleAdapterFactory,
        address newRootRegistry,
        address newCapabilitiesRegistry
    ) MigratableEntity(newFactory) {
        MERKLE_ADAPTER_FACTORY = newMerkleAdapterFactory;
        ROOT_REGISTRY = newRootRegistry;
        CAPABILITIES_REGISTRY = newCapabilitiesRegistry;
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc IMerkleAccount
    function getCapabilities() public view override returns (address[] memory) {
        return _capabilities.values();
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 digest, bytes calldata) public view returns (bytes4) {
        return signatures[digest] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleAccount
    function addCapability(address capability) public override onlyOwner {
        bytes4[] memory selectors = ICapabilitiesRegistry(CAPABILITIES_REGISTRY).selectors(address(this), capability);
        if (selectors.length == 0) revert CapabilityNotWhitelisted();

        if (!_capabilities.add(capability)) revert CapabilityAlreadyAdded();

        capabilitySelectors[capability] = selectors;
        for (uint256 i; i < selectors.length; ++i) {
            if (capabilityBySelector[selectors[i]] != address(0)) revert SelectorAlreadyUsed();

            capabilityBySelector[selectors[i]] = capability;
        }
        emit AddCapability(capability);
    }

    /// @inheritdoc IMerkleAccount
    function removeCapability(address capability) public override onlyOwner {
        if (!_capabilities.remove(capability)) revert CapabilityNotAdded();

        bytes4[] storage selectors = capabilitySelectors[capability];
        for (uint256 i; i < selectors.length; ++i) {
            delete capabilityBySelector[selectors[i]];
        }
        delete capabilitySelectors[capability];
        emit RemoveCapability(capability);
    }

    /// @inheritdoc IMerkleAccount
    function acceptRoot(bytes32 newRoot) public override onlyOwner {
        if (IRootRegistry(ROOT_REGISTRY).roots(address(this)) != newRoot) revert InvalidRoot();

        root = newRoot;
        emit AcceptRoot(newRoot);
    }

    /// @inheritdoc IMerkleAccount
    function revokeSignature(bytes32 digest) public onlyOwner {
        delete signatures[digest];
        emit RevokeSignature(digest);
    }

    /// @inheritdoc IMerkleAccount
    function manage(Action[] calldata actions) public override nonReentrant returns (bytes[] memory results) {
        bytes32 curRoot = root;
        uint256 length = actions.length;
        for (uint256 i; i < length; ++i) {
            Action calldata action = actions[i];
            bytes32 leaf = MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
            if (!MerkleProof.verifyCalldata(action.proof, curRoot, leaf)) revert InvalidMerkleProof();

            _checkRole(leaf);
        }

        results = new bytes[](length);
        for (uint256 i; i < length; ++i) {
            Action calldata action = actions[i];
            results[i] = action.target.functionCallWithValue(action.data, action.value);
        }
        emit Manage(actions);
    }

    /// @inheritdoc IMerkleAccount
    function sign(bytes32 domainSeparator, bytes calldata buffer, Hash[] calldata plan) public {
        if (address(this) != msg.sender) revert InvalidCaller();

        uint256 size = buffer.length;
        uint256 planLength = plan.length;
        if (size < 32 || planLength == 0) revert InvalidHashPlan();

        // The plan collapses a copy, so the event can carry the buffer it was given.
        bytes memory collapsed = buffer;
        bytes32 structHash;
        for (uint256 i; i < planLength; ++i) {
            uint256 offset = plan[i].offset;
            uint256 length = plan[i].length;
            uint256 destination = plan[i].destination;

            if (offset > size || length > size - offset || destination > size - 32) revert InvalidHashPlan();

            assembly ("memory-safe") {
                let base := add(collapsed, 0x20)
                structHash := keccak256(add(base, offset), length)
                mstore(add(base, destination), structHash)
            }
        }

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        signatures[digest] = true;
        emit Sign(digest, domainSeparator, buffer, plan);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Unrecognized selectors delegate into installed capabilities in this account's storage.
    function _implementation() internal view override returns (address capability) {
        capability = capabilityBySelector[msg.sig];
        if (msg.data.length < 4 || capability == address(0)) revert UnknownSelector();
    }

    /* INITIALIZATION */

    function _initialize(uint64, address, bytes memory data) internal override {
        (adapter, data) = abi.decode(data, (address, bytes));
        if (!IRegistry(MERKLE_ADAPTER_FACTORY).isEntity(adapter)) revert InvalidAdapter();

        InitParams memory params = abi.decode(data, (InitParams));
        if (params.defaultAdminRoleHolder != address(0)) _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);

        IERC20(IERC4626(IMerkleAdapter(adapter).vault()).asset()).forceApprove(adapter, type(uint256).max);
    }

    /* RECEIVE FUNCTION */

    receive() external payable {}
}
```

### src/contracts/merkle-adapter/automations/RecipeExecutor.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Recipes} from "../Recipes.sol";

import {MerkleAdapterVerifier} from "../libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "../../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "../../../interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {OP_APPROVE, OP_MANAGE} from "../../../interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title RecipeExecutor
/// @notice Contract for curator-committed approved actions with dependent amounts and conditions.
contract RecipeExecutor is Recipes, Multicallable, Ownable, ReentrancyGuardTransient, IRecipeExecutor {
    /* IMMUTABLES */

    /// @inheritdoc IRecipeExecutor
    address public immutable account;

    /* STATE VARIABLES */

    /// @inheritdoc IRecipeExecutor
    address public caller;

    /// @inheritdoc IRecipeExecutor
    uint48 public recipeBlock;

    /// @inheritdoc IRecipeExecutor
    bytes32 public recipeHash;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newAccount) Ownable(newOwner) {
        account = newAccount;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IRecipeExecutor
    function setCaller(address newCaller) public nonReentrant onlyOwner {
        caller = newCaller;
        emit SetCaller(newCaller);
    }

    /// @inheritdoc IRecipeExecutor
    function setRecipe(bytes[] calldata newQueries, bytes[] calldata newSteps) public nonReentrant onlyOwner {
        recipeHash = keccak256(abi.encode(newQueries, newSteps));
        recipeBlock = uint48(block.number);
        emit SetRecipe(recipeHash, newQueries, newSteps);
    }

    /// @inheritdoc IRecipeExecutor
    function execute(
        bytes[] calldata queries,
        bytes[] calldata steps,
        uint256[] calldata inputs,
        bytes[] calldata runtime
    ) public nonReentrant returns (uint256[] memory) {
        if (caller != msg.sender) revert InvalidCaller();
        if (recipeHash != keccak256(abi.encode(queries, steps))) revert InvalidRecipe();

        uint256 runtimeIndex;
        uint256 stepsLength = steps.length;
        State memory state = State({values: new uint256[](stepsLength), index: 0});
        for (; state.index < stepsLength; ++state.index) {
            (uint8 operation, bytes calldata operationData) = _step(steps[state.index]);
            if (operation == OP_MANAGE) {
                bytes calldata payload = runtime[runtimeIndex++];
                (uint256 gate, bytes32[] memory leaves, uint256[][] memory bindings) =
                    abi.decode(operationData, (uint256, bytes32[], uint256[][]));
                if (_value(gate, steps, inputs, state) == 0) continue;
                IMerkleAccount.Action[] memory actions = abi.decode(payload, (IMerkleAccount.Action[]));
                uint256 actionsLength = actions.length;
                if (actionsLength != leaves.length || actionsLength != bindings.length) revert InvalidRuntime();
                for (uint256 i; i < actionsLength; ++i) {
                    _bind(actions[i].data, bindings[i], steps, inputs, state);
                    _checkAction(actions[i], leaves[i]);
                }
                IMerkleAccount(account).manage(actions);
            } else if (operation == OP_APPROVE) {
                (uint256 amount, address token, address spender, bytes32 leaf) =
                    abi.decode(operationData, (uint256, address, address, bytes32));
                amount = _value(amount, steps, inputs, state);
                (bytes memory mask, bytes32[] memory proof) = abi.decode(runtime[runtimeIndex++], (bytes, bytes32[]));
                uint256 length = amount == 0 || IERC20(token).allowance(account, spender) == 0 ? 1 : 2;
                IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](length);
                for (uint256 i; i < length; ++i) {
                    IMerkleAccount.Action memory action = actions[i];
                    action.target = token;
                    action.data = abi.encodeCall(IERC20.approve, (spender, length == 1 || i > 0 ? amount : 0));
                    action.dataMask = mask;
                    action.proof = proof;
                    _checkAction(action, leaf);
                }
                bytes[] memory responses = IMerkleAccount(account).manage(actions);
                uint256 responsesLength = responses.length;
                for (uint256 i; i < responsesLength; ++i) {
                    if (responses[i].length > 0 && !abi.decode(responses[i], (bool))) revert ApprovalFailed();
                }
            } else {
                state.values[state.index] = _run(queries, steps, inputs, state);
            }
        }
        if (runtimeIndex != runtime.length) revert InvalidRuntime();
        return state.values;
    }

    /* INTERNAL FUNCTIONS */

    function _checkAction(IMerkleAccount.Action memory action, bytes32 leaf) internal pure {
        if (
            action.value > 0
                || MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask) != leaf
        ) revert InvalidAction();
    }
}
```

### src/contracts/merkle-adapter/automations/policies/ThreeFPolicy.sol

```solidity
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "../../libraries/AssetRateLimits.sol";

import {
    IThreeFPolicy,
    YIELD_PRECISION
} from "../../../../interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title ThreeFPolicy
/// @notice Migratable contract storing one curator-controlled request funding policy for its consumer.
contract ThreeFPolicy is MigratableEntity, Multicallable, IThreeFPolicy {
    using AssetRateLimits for AssetRateLimits.AssetLimit;

    /* STATE VARIABLES */

    /// @inheritdoc IThreeFPolicy
    address public consumer;

    /// @inheritdoc IThreeFPolicy
    mapping(address asset => uint256) public minYieldPerRequest;

    /// @inheritdoc IThreeFPolicy
    mapping(address asset => AssetRateLimits.AssetLimit) public assetLimits;

    /* CONSTRUCTOR */

    constructor(address newFactory) MigratableEntity(newFactory) {}

    /* VIEW FUNCTIONS */

    /// @inheritdoc IThreeFPolicy
    function remainingAssets(address asset) public view returns (uint256) {
        return assetLimits[asset].remaining();
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFPolicy
    function setConsumer(address newConsumer) public onlyOwner {
        _setConsumer(newConsumer);
    }

    /// @inheritdoc IThreeFPolicy
    function setMaxAssetsPerDuration(address asset, uint256 newMaxAssets, uint48 newDuration) public onlyOwner {
        assetLimits[asset].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(asset, newMaxAssets, newDuration);
    }

    /// @inheritdoc IThreeFPolicy
    function setMinYieldPerRequest(address asset, uint256 newMinimum) public onlyOwner {
        minYieldPerRequest[asset] = newMinimum;
        emit SetMinYieldPerRequest(asset, newMinimum);
    }

    /// @inheritdoc IThreeFPolicy
    function consume(address asset, uint256 assets, uint256 yieldAssets) public {
        if (consumer != msg.sender) revert InvalidCaller();
        if (assets == 0) revert InvalidAssets();
        if (yieldAssets * YIELD_PRECISION / assets < minYieldPerRequest[asset]) revert TooLowYield();
        assetLimits[asset].consume(assets);
        emit Consume(asset, assets);
    }

    /* INTERNAL FUNCTIONS */

    function _setConsumer(address newConsumer) internal {
        consumer = newConsumer;
        emit SetConsumer(newConsumer);
    }

    /* INITIALIZATION */

    function _initialize(uint64, address, bytes memory data) internal override {
        _setConsumer(abi.decode(data, (address)));
    }
}
```
