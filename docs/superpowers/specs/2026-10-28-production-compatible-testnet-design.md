# Production-compatible Merkle testnet deployment

## Intent and selected approach

Testnet must exercise the production contracts and production client paths. The user selected deploying upstream implementations wherever possible over extending custom interface-compatible models. A matching selector is insufficient when debt, collateral, caps or authorization behave differently.

Use pinned upstream Aave V3/V4, Euler EVC/EVK, Morpho Blue/Vault V2 and Midnight implementations for the integrations admitted by the full deployment. Retain official Sepolia 3F contracts. Controlled test tokens, liquidity providers and price feeds remain test infrastructure with production interfaces and explicit synthetic values.

## Alternatives

- Extend the funded models: smaller deployment but preserves different financial behavior; rejected by the user.
- Deploy pinned upstream implementations: selected. More upstream dependencies, shared production semantics and fewer application exceptions.
- Reuse public venues exclusively: useful when their asset and configuration match, but cannot provide the repeatable funded markets required by this full deployment.

## Deployment and configuration

Build upstream code with its supported compiler and pinned dependency versions. Reuse upstream deployment helpers or compiled artifacts; do not rewrite financial logic or relax chain contract-size/gas limits. Keep a single repeatable deploy/seed/validate flow with canonical receipt reconciliation. Deploy and initialize real protocol factories, pools/vaults, controllers, collateral settings, interest-rate models and bounded allocation caps. Test owners configure and fund venues through their real interfaces.

Use one multi-reserve Aave market so collateral and borrowed assets can differ. Euler uses EVC-linked collateral and debt vaults, including owned XOR subaccounts. Morpho Vault V2 supplies through real allocation adapters and caps; borrowing occurs in Blue, never directly from Vault V2. Rewrite seeding and activity callers accordingly, removing model-only debt and collateral APIs. Replace the edited Blue/Midnight source copies with the pinned upstream build mechanism. Select versions matching the production readers, not an unreviewed upstream HEAD.

The manifest is the source for public addresses, protocol identities, inventory declarations, enumeration starts and price-feed routes. Export the deployment configuration consumed by the frontend and NAV process from it. Do not retain a second set of handwritten Sepolia addresses. Missing integrations are not silently represented by a different contract family.

All issuer routes admitted into the Merkle portfolio must satisfy the normal issuer bindings and queue/read contracts. A synthetic issuer fixture is not proof of compatibility: validate it through the production collector before advertising it. Preserve official 3F enrollment, factory checks, policy accounting and three-leaf permissions.

## Consumer simplification

Use the ordinary protocol readers and execution builders with chain configuration. Remove test-only naming overrides, reader substitutes and portfolio valuation branches once their production replacements pass parity checks. Keep only the separate self-hosted report publishing transport; it shares portfolio accounting and acceptance/recovery semantics with the existing service. Preserve pinned blocks, asset/debt rounding, metadata-selected inventory, fail-closed coverage and exact accepted-report witnesses.

The NAV profile must configure chain ID, metadata admission, lending catalogues, factory/request baselines and pricing admission, not merely collector addresses. The configured report chain ID must reach Service.Run. Inventory metadata remains independently selected, adapter-bound and exact-commit-pinned. Record the admitted integration matrix before changes; do not quietly reduce it. Collectors with embedded issuer addresses require an explicit compatible deployment/binding change and parity tests before the route is advertised.

Existing on-chain deployments are immutable evidence. Updated scripts target fresh deployments; no Sepolia broadcast or replacement root is part of this source-change request. Do not edit authenticated old metadata to make incompatible contracts appear compatible.

## Validation and completion

1. Deploy the complete environment on a disposable local chain under normal code-size and transaction limits.
2. Verify canonical factories, implementations and configuration, then supply, collateralize, borrow, accrue, repay and withdraw using the normal account/recipe path. Include six-decimal assets and Euler subaccounts.
3. Execute the generated full deploy, seed and activity sequence, then read the resulting positions through the production NAV collectors and frontend reader at the same pinned block; compare exact amounts, debt, cash, caps and ownership. Exercise partial liquidity, health-factor rejection and withdrawal coverage. Upstream unit tests alone are insufficient.
4. Verify 3F mint/claim/enrollment construction against the factory-scoped production contracts, including invalid requests. Official API settlement remains an independent live test.
5. Run repository gates, regenerate artifacts only from source, push scoped PRs and report any remaining incompatible venue explicitly. No model-backed route may be reported as production-compatible.

Preserve unrelated local work in deployment broadcasting helpers and the automation gallery.
