# Capability governance

```mermaid
flowchart LR
  S[Registry owner] -->|Whitelist adapter, capability, selectors| R[CapabilitiesRegistry]
  C[Adapter owner] -->|Add or remove capability| A[MerkleAdapter]
  A -->|Read approved selectors on installation| R
  A -->|Store installed selector list| A
  X[Protocol caller] -->|Callback| A
  A -->|Delegatecall through OpenZeppelin Proxy| I[Capability code]
```

## Authority and lifecycle

1. The registry owner calls `whitelistCapability(adapter, capability, signatures)`.
   Every call replaces the complete selector list for that exact pair. A nonempty
   list requires deployed capability code; an empty list revokes installation approval.
2. The adapter owner calls `addCapability(capability)`. The adapter reads the
   current list, copies it locally, and installs each route. Empty lists, duplicate
   selectors, and collisions with other capabilities revert the whole addition.
3. Registry changes leave installed routes unchanged. The adapter owner calls
   `removeCapability(capability)` to clear the installed selectors without reading
   the registry. A missing registry cannot prevent removal.
4. Removal followed by reinstallation adopts the current whitelist. An atomic
   adapter `multicall` can replace an implementation or its installed selector list.
   Native adapter and factory-proxy functions retain precedence over capability routes.

Both contracts expose selector arrays through public indexed `capabilitySelectors`
getters and `capabilitySelectorsLength`. Registry reads take `(adapter, capability)`;
adapter reads take only `(capability)`. Indexed getters append the selector index.

## Boundaries

- `BorrowCapability`, `ThreeFCapability`, `CoWSwapCapability`, and
  `LiquidLaneRedeemCapability` execute in namespaced adapter storage. Their managed
  operations require `onlyMyself`, a Merkle proof, and the caller's leaf role.
  Borrow minimum changes use this same path. Reads and ERC-1271 callbacks remain public.
- Whitelisting controls installation, not individual lending pools. A single
  BorrowCapability supports multiple pools through separately approved Merkle leaves.
- The Merkle implementation fixes its capabilities registry at deployment.
  Registry ownership and adapter ownership remain distinct authorities.
- Only reviewed direct implementations fit this model. Delegatecall gives code the
  adapter's full storage and execution context; selectors are entrypoints, not a
  storage sandbox. Capability code must authenticate callbacks and preserve protocol
  accounting. The dispatcher does not run `manage`'s final reserve check.
- Installation and removal run no capability hooks. They do not clear capability
  storage, cancel orders, revoke token allowances, or settle obligations. Such work
  remains explicit in each integration. LiquidLaneConnector has separate inventory
  and its own factory proxy.

## Verification

Tests cover per-adapter approval, selector replacement, empty-list revocation,
registry and adapter owner permissions, collision rollback, native function
precedence, return/revert forwarding, STATICCALL callbacks, and removal after
registry deletion or failure. Registry replacement cannot clear another capability's
routes because removal uses only the adapter's installed list.
