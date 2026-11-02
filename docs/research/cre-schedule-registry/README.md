> Historical research: the current contracts use signed capital-flow checkpoints,
> snapshot-covered liquidity release and snapshot-based cadence. The cutoff/buffer prototypes and
> old report ABI below are superseded; they are not current integration instructions.
> See [the current oracle design](../../MERKLE-ORACLE.md).

# CRE cutoff and registry research — 25 September 2026

Historical research against the pre-simplification `codex/merkle-adapter` working tree, the pinned
Chainlink WorkflowRegistry 2.0.0 source, CRE CLI v1.32.0, and the local
`chainlink-nav` producer. The cutoff patch below is a tested proposal, not an
applied runtime change.

The registry was subsequently simplified to direct upsert. Workflow removal and
the local workflow-ID mapping were later removed. The comparison tests below preserve the historical
baseline and are not current regression tests. See [current registry operations](../../MERKLE-ORACLE.md)
and `test/adapters/merkle-adapter/oracle/CREWorkflowRegistry.t.sol` for the implemented behavior.

## Cutoff: the full grid jump is optional

Freezing, rejecting another report while frozen, and empty unfreeze do not move
cutoff, nonce or the CRE cron schedule. Accepting a reviewed payload does settle
and rotate batches, so it is a new accounting epoch.

The current formula chooses the first strictly future grid cutoff. With interval
100 and buffer 10, review at 291 moves cutoff to 390. A report whose snapshot is
299 then fails, even though its cron trigger at 300 has not changed. Reviewing a
fresher payload at the same transaction time produces the same cutoff; freshness
alone does not fix this skipped run.

A full grid jump is not required for snapshot safety. A smaller, review-only
change is:

```text
nextCron = now + interval - now % interval
reviewedCutoff = max(now + 1, nextCron - buffer)
```

At 291 this yields 292. Transactions after review in the same block can still
modify the promoted current batch. At 292 and later they enter the next batch.
A valid snapshot at or after 292 therefore observes the closed current batch and
the new nonce. No additional storage field is needed. Normal, unreviewed report
acceptance retains the existing grid formula.

This preserves the explicit post-acceptance snapshot boundary. Simply retaining
an old, past cutoff would remove that explicit boundary and rely on the producer
reading the new nonce at a pinned post-acceptance block, or require a separate
onchain check of the last acceptance block. The review-only clamp is a smaller
change than adding that state.

There are two real limits to the proposal:

- It shortens the recovery epoch's buffer. The next cron can settle only if its
  **finalized** snapshot is at or after the adjusted cutoff. It cannot promise
  that an imminent cron run will have such a snapshot.
- The adjustment is confined to explicit guard review. Applying it to every
  acceptance would also permit repeated ordinary acceptance within a buffer
  window, changing the grid's cadence and the meaning of per-report limits.

Recommendation: use the review-only clamp if preserving an eligible upcoming cron
report is the desired recovery policy. Retain the current formula if every newly
promoted batch must receive the full buffer before the following cron. The buffer
is a schedule/settlement policy, not an onchain proof of finality.

The [prototype patch](cutoff-prototype.patch) was applied temporarily in the audit
worktree and restored. The [research harness](MerkleScheduleRegistryResearch.t.sol)
checks same-block allocation/cancellation, protected reserves, post-cutoff
allocation, NAV conservation, pre-review snapshot rejection and the next cron.
Both proposed-cutoff tests fail against the unchanged formula and pass with the
prototype, including 100 fuzz runs. This is focused validation, not a complete
regression pass or an audit of the proposed policy.

## Registry: ordinary upsert works, recovery needs more

The [pinned upstream implementation](https://github.com/smartcontractkit/chainlink-evm/blob/2a2b38e8b74479054db92ab911521d60278c3d78/contracts/cre/src/v2/WorkflowRegistry.sol#L861)
keys records by owner, name and tag. A fresh ID can update an existing ACTIVE
record on the same DON without deletion. The update preserves its creation time
and active-workflow count. It cannot change status or DON, and supplying an
already registered ID reverts, including that record's own ID.

The current wrapper uses delete-and-register uniformly. That supports paused
workflow recovery, DON changes and reusing an ID with the same two-party approval.
All local tracking, upstream deletion, registration and receiver changes remain
atomic.

There is a meaningful trade-off: creation rechecks quotas; an ordinary in-place
update does not. A local upstream-source test reduced the owner's DON allowance
to zero. Wrapper replacement reverted and preserved the original workflow,
whereas in-place rotation succeeded. No claim is made that the intended production
owner currently has a reduced quota.

Recommendation: the existing uniform path is simple and supports recovery. If
rotation must remain available after quota reductions, add an in-place path for
a fresh ID on an ACTIVE, same-DON record, with a narrowly selected replacement
path for status/DON changes or same-ID reactivation. Replacing the whole function
with unconditional upsert loses those recovery cases. Blanket exception swallowing
would also conceal genuine upstream failures.

## Operations with the current wrapper

| Intent                                  | Authorized operation                                                                           | Result                                                                                                                                                     |
| --------------------------------------- | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Link to CRE                             | Wrapper owner calls `linkOwner` with a Chainlink proof for the wrapper                         | Links the contract that will own registrations; can relink after unlink with a fresh proof                                                                 |
| Register or rotate                      | Wrapper owner proposes ID and complete params; current oracle owner accepts the exact proposal | Wrapper registers ACTIVE, with oracle-address name and `default` tag, then changes the receiver ID                                                         |
| Freeze NAV acceptance                   | Oracle guard calls `freezeOracle`                                                              | Does not pause/delete the CRE registration; later authenticated reports can replace the rejected payload                                                   |
| Resume                                  | Guard reviews the cached payload, or calls empty unfreeze                                      | Review settles; empty unfreeze only clears the latch and cached report                                                                                     |
| Retire workflow                         | Not exposed by the wrapper                                                                     | Freeze the Oracle to stop NAV-dependent operations; the upstream registration remains active                                                               |
| Recover upstream unlink                 | Owner relinks; provider and curator register again                                             | Unlink deletes all registrations owned by the wrapper without clearing Oracle state or pending proposals                                                   |
| Pause/resume execution without deletion | Not exposed by the wrapper                                                                     | Chainlink has pause/activate calls, but a provider EOA cannot call them on behalf of the wrapper; add dedicated methods only if this operation is required |

The wrapper owner and oracle owner are distinct authorities even when held by the
same wallet. A generic external-call function would bypass the proposal/acceptance
model and is not needed for these operations.

## CRE CLI compatibility

Configure onchain registry mode, `workflow-owner-address` as the **wrapper**, and
`workflow-name` as the Oracle's lowercase, 0x-prefixed address. Prepare artifacts using the
[documented unsigned flow](https://docs.chain.link/cre/guides/operations/using-multisig-wallets).
Decode the returned upstream transaction into the wrapper's proposal fields;
execute proposal/acceptance through the wrapper, not the raw upstream calldata
from the provider EOA. Ownership-link calldata likewise needs to be translated
into the wrapper's owner-only `linkOwner` call.

Two CLI details matter for recovery:

- [Deployment parameter preparation](https://github.com/smartcontractkit/cre-cli/blob/v1.32.0/cmd/workflow/deploy/register.go#L30)
  preserves an existing PAUSED status in its raw upsert. The current wrapper
  always upserts ACTIVE and cannot reactivate an existing paused record.
- The CLI skips redeployment when the computed ID is unchanged. The current
  wrapper also cannot reuse an ID that remains registered upstream.

The [artifact upload code](https://github.com/smartcontractkit/cre-cli/blob/v1.32.0/cmd/workflow/deploy/artifacts.go)
uses the [organization-authenticated GraphQL client](https://github.com/smartcontractkit/cre-cli/blob/v1.32.0/internal/client/graphqlclient/graphqlclient.go).
It does not require a wrapper `allowlistRequest` method. The CLI's separate
owner-key secrets path uses that method; the current NAV workflow consumes no CRE
secrets. `--unsigned` avoids broadcasting the registration transaction but can
still upload artifacts. No CLI deployment, upload or ownership linking was run
for this research.

## Producer integration still matters

The current sibling repository remains a mock submission implementation:

- `chainlink-nav/internal/workflow/workflow.go:64` records through `NewMock`.
- `internal/usecase/valuation/epoch.go:67-74` still requires idle backing for the
  entire surviving withdrawal. It can withhold exactly the illiquid reports the
  adapter now accepts by deferring the unfunded remainder.
- Its fixed 10% producer deviation policy can withhold outliers before the oracle
  caches a rejected payload; it does not read the configured onchain dust policy.
- It reads cutoff and nonce at a finalized block and has no freeze-specific gate.
  This supports continued valuation attempts, not a claim of live report delivery.

Those producer paths must be aligned before claiming end-to-end recovery or
illiquidity handling. They were inspected but not edited during this research.

## Verification and reproduction

Six focused research tests passed with the temporary cutoff prototype: two cutoff
tests (one with 100 fuzz runs), four registry behavior tests. Baseline results:
four registry tests pass and the two proposed-cutoff assertions fail as expected.
To reproduce in an isolated copy, put the harness under
`test/adapters/merkle-adapter/oracle/`, apply the adjacent patch, and run:

```sh
forge test --match-contract MerkleScheduleRegistryResearchTest -vv
```

Three existing registry integration tests also passed against the deployed
registry at Ethereum block **26,055,335** using publicnode, by changing only the
fork block in a temporary test copy. They cover replacement and report acceptance,
rollback on failed registration, and removal/re-registration. The fixture locally
impersonates upstream governance to authorize its test proof signer and DON;
this is not proof of production organization onboarding, real quotas or live CRE
execution. A separate read at that block confirmed `WorkflowRegistry 2.0.0` at
`0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`. No transaction was broadcast.

Both runtime contract trees were restored byte-for-byte after the prototype.
This research adds documentation and reproducible experiment artifacts only.
