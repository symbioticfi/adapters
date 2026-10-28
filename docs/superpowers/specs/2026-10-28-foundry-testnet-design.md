# Foundry-native testnet deployment

The user selected replacing Python deployment orchestration with Foundry while preserving fast deployment. Keep the existing Solidity phase scripts and expose them through a thin shell entry point. Foundry owns simulation, batched broadcasting, signed transaction artifacts and `--resume`; do not use `--slow` for normal deployment or maintain a second transaction planner.

Move local/self-hosted ownership proof signing into the activation script using the supplied Foundry wallet. Official CRE activation still requires externally supplied organization artifacts. Preserve manifest identity, pin checks, overwrite protection, backing checks and all on-chain preflights. Never rerun deployment to resume an interrupted broadcast.

Keep Python for pinned heterogeneous upstream builds/artifact loading, public config export and the independent randomized activity test harness. Remove the Python bootstrap and custom fast broadcaster rather than retain compatibility aliases. Keep ordinary NAV publishing external and leave the separate 3F discovery-policy question unchanged.

Alternatives considered: keep the Python bootstrap and delete only its fast planner (smaller deletion but leaves duplicated phase/signing logic); replace it with a large Solidity mega-script (unnecessary coupling across oracle report waits). Use the existing independent Foundry phases instead.

Validate an actual full deployment under normal contract-size/gas limits, native batching and interrupted resume, activation with an encrypted wallet, seeding/sync/validation with the ordinary daemon, and the full repository suites. Measure wall time and receipt counts. No public-chain broadcasts.
