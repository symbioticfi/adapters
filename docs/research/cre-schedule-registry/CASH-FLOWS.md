> Historical research: the current contracts use signed capital-flow checkpoints,
> snapshot-covered liquidity release and snapshot-based cadence. The cutoff/buffer prototypes and
> old report ABI below are superseded; they are not current integration instructions.
> See [the current oracle design](../../MERKLE-ORACLE.md).

# NAV with snapshot cash-flow counters

This is a design alternative, not the current report ABI or adapter accounting.

Reporting only inflows and outflows cannot value yield, losses or liabilities.
Reporting NAV together with cumulative vault/adapter flows can remove the cutoff's
valuation purpose: reconcile the old snapshot with flows that occurred afterward.

Let `G_s` be net portfolio value at snapshot `s`, including idle cash and withdrawal
reserves and subtracting external liabilities. Let `I` and `O` be cumulative actual
inflows from and outflows to the vault:

```text
estimated value now = G_s + (I_now - I_s) - (O_now - O_s)
strategy NAV now = estimated value now - reserves_now
adapter total assets = estimated value now
```

This still uses snapshot prices. Gains or losses after that snapshot arrive in a
later valuation. A report for 1,000 followed by a deposit of 300 and an actual
withdrawal of 150 gives 1,150. If remaining reserves are 50, strategy NAV is 1,100.
Maturing another 100 into reserves changes strategy NAV to 1,000 but leaves total
value at 1,150. Maturation is not a cash outflow.

The adapter records actual net custody changes onchain. For the existing
delegator, inflow is `allocate()`'s returned allocation, not the amount initially
transferred: the unmatched remainder is pulled back. Outflow is `deallocate()`'s
returned amount. Do not count account `push`/`pull`, trades, withdrawal requests,
reserve maturation or vault operations that do not cross the adapter boundary.
The oracle reports the counters read at the same finalized block as NAV.

Movement limits must also compare values at the same snapshot. Against the last
accepted report `p`:

```text
baseline_s = G_p + (I_s - I_p) - (O_s - O_p)
profit or loss = G_s - baseline_s
```

Apply the configured growth/loss limits and tolerance to that comparison. Counter
bounds and monotonicity reject impossible values, but do not prove which values
existed at the reported historical block. Without onchain flow checkpoints, that
history is another DON-attested report field. If the movement guard must remain
independent of reported cash-flow history, store/check an authenticated onchain
flow checkpoint or commitment. That has storage and gas costs.

This can avoid moving a cutoff when a delayed report is reviewed. It does not
settle the withdrawal design. The adapter still needs requests, protected idle
cash, partial funding/deferral and reserve-backing checks. Decide whether deposits
remain reserved until acknowledged and which requests each report may mature
before removing the two batches. Negative reconciled value or unbacked reserves
must not be hidden by saturating arithmetic. Net flow deltas before applying them
to avoid unnecessary intermediate overflow.

An alternative is to report only a signed gain/loss adjustment. It must reference
the last accepted report and be applied once; referencing the previous cron run
would mishandle skipped or rejected reports. Absolute NAV plus snapshot counters
is easier to inspect and reconcile. Neither is a small isolated oracle change.
