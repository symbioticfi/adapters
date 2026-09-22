# Chainlink CRE test references

Sources: [chainlink-evm at b6427ea1f4847d640abdf24dbd6c6f01d7799d59](https://github.com/smartcontractkit/chainlink-evm/tree/b6427ea1f4847d640abdf24dbd6c6f01d7799d59/contracts).

These MIT-licensed sources exercise the real report-signature verification and
forwarder-to-receiver path in CREOracle tests. Imports point to the copied support
contracts and this repository's OpenZeppelin ERC165Checker; formatting follows
Foundry. The forwarder's verification and routing logic is unchanged.

`WorkflowRegistry.sol`, `access/Ownable2Step.sol` and
`access/Ownable2StepMsgSender.sol` come from
[chainlink-evm at 2a2b38e8b74479054db92ab911521d60278c3d78](https://github.com/smartcontractkit/chainlink-evm/tree/2a2b38e8b74479054db92ab911521d60278c3d78/contracts).
The registry retains its upstream BUSL 1.1 license and logic. Its exact Solidity
0.8.26 pragma is widened to `^0.8.26`, imports point to local support contracts and
this repository's OpenZeppelin, and formatting follows Foundry. Only this fixture
is compiled via IR, as required by its upstream implementation. Tests deploy the
artifact with `deployCode`; protocol contracts retain `via_ir=false`.
`interfaces/IWorkflowRegistry.sol` exposes the test read/admin ABI without making
the test suites import a source requiring the different compiler pipeline.
