# Review method and boundaries

The requested scope contains 15 production Solidity files, recorded in `scope.tsv` and identified by SHA-256 hashes in `source-manifest.json`. Liquidity and health-factor automation implementations are excluded. Interfaces, inherited contracts, tests and documentation are supporting context only.

Three passes were requested. Each pass schedules twelve specialty reviews in batches of at most three concurrent subagents. The final run files record actual completion; this document is not completion evidence.

This is a defensive static source review. No new exploit code, exploit execution, live chain interactions or deployment validation is part of the review. Existing tests are read as context, not presented as fresh test results. Findings require source evidence and realistic reachability; repeated agent agreement alone does not validate a defect.

The source bundle was frozen once. The initial discovery commit was `973468244254dac8f836353ae125502cb58c6f80`; the snapshot manifest records `ddbe92faf528cffa2fd1a9e4ad45e13e41b9f5b0`, a documentation-only successor with identical scoped Solidity sources. Other work is changing documentation and tests in the shared checkout. Conclusions refer to the frozen source bundle and source hashes, not stale test assertions.

The skill's assertion that explicit narrowing casts revert is incorrect for Solidity. They truncate; this review checks actual bounds and realistic reachability independently. Operational policy documented in interfaces is distinguished from missing authorization or accounting defects.

Live collateral, role assignments, deployed implementations, CRE/DON configuration, off-chain NAV production, external integrations and permission-leaf construction remain outside the verified boundary.

During pass 2, concurrent work changed one scoped source: `CREOracle._onReport` now uses `SafeCast.toUint256()` for its historical baseline. The unchanged source bundle remains the target of all three passes. `source.md` preserves that exact bundle; `source-drift.json` records the observed source hashes and `concurrent-oracle-change.diff` preserves the diff.

The concurrent edit is reviewed separately at source level. Vendored `SafeCast.toUint256(int256)` reverts when the input is negative, so the new conversion removes the unchecked sign conversion identified in the frozen snapshot. The call occurs before movement-limit handling and therefore applies to normal and reviewed reports. No build, regression run or production-path verification is claimed for this edit. It is not represented as having received all three passes.
