# Run 1 — solidity-auditor

<!--RUN pass=1 of=3 stamp=20260928-051347 sha=ddbe92f agents=12/12-->

Pass 1 of 3 · 2026-09-28 · `ddbe92f` · 12/12 specialty agents returned in batches of at most three. Static source review; no tests executed.

## Findings

## Leads

<!--F key=creoracle|-onreport|unchecked-negative-baseline kind=LEAD agents=1-->

- **Oracle does not check the historical baseline sign** — `CREOracle._onReport` — Code smells: unchecked signed-to-unsigned conversion at [frozen CREOracle.sol:151](/Users/andreikorokhov/symbiotic/adapters/.solidity-auditor/runs/20260928-051347/source.md:733) — The oracle converts a negative historical baseline to uint256; normal-operation reachability and material impact remain unverified.

<!--/F-->
