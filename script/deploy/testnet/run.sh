#!/usr/bin/env bash
# Foundry owns the transaction plan, signing, broadcasting and recovery.
set -euo pipefail
cd "$(dirname "$0")/../../.."
phase="${1:?Usage: run.sh deploy|activate|sync|seed|validate [forge arguments]}"
shift
: "${TESTNET_RPC_URL:?Set TESTNET_RPC_URL}"
: "${TESTNET_OWNER:?Set TESTNET_OWNER to the supplied wallet address}"
: "${TESTNET_MANIFEST:?Set a unique TESTNET_MANIFEST path}"
export TESTNET_ORACLE_MODE="${TESTNET_ORACLE_MODE:-official-cre}"
pinned="$HOME/.foundry/versions/foundry-rs/foundry/v1.8.5"
if [[ -x "$pinned/forge" ]]; then export PATH="$pinned:$PATH"; fi
if [[ "$(forge --version)" != *'Version: 1.8.5'* ]]; then
    echo 'Install Foundry 1.8.5 with foundryup -i v1.8.5.' >&2
    exit 1
fi
case "$phase" in
    deploy) script=DeployRealisticTestnet ;;
    activate) script=ActivateMerkleTestnet ;;
    sync) script=SyncMerkleTestnet ;;
    seed) script=SeedRealisticTestnet ;;
    validate) script=ValidateRealisticTestnet ;;
    *) echo "Unknown phase: $phase" >&2; exit 1 ;;
esac
resume=false
for option in "$@"; do if [[ "$option" == --resume ]]; then resume=true; fi; done
if [[ "$phase" == deploy && "$resume" == false ]]; then
    python3 script/deploy/testnet/upstream/prepare.py
fi
# Separate native recovery files per manifest, while reusing compiler metadata.
scope="$(printf '%s' "$TESTNET_MANIFEST" | shasum -a 256 | cut -c1-16)"
export FOUNDRY_BROADCAST="broadcast/testnet/$scope"
export FOUNDRY_CACHE_PATH="cache/testnet/$scope"
mkdir -p "$FOUNDRY_CACHE_PATH"
export TESTNET_MANIFEST_WITNESS="$FOUNDRY_CACHE_PATH/manifest.keccak256"
if [[ ! -e "$FOUNDRY_CACHE_PATH/solidity-files-cache.json" && -f cache/solidity-files-cache.json ]]; then
    cp cache/solidity-files-cache.json "$FOUNDRY_CACHE_PATH/solidity-files-cache.json"
fi
export ETH_RPC_TIMEOUT="${ETH_RPC_TIMEOUT:-120}"
if [[ "$resume" == true ]]; then
    FOUNDRY_BROADCAST="$FOUNDRY_BROADCAST/checks" forge script \
        script/deploy/testnet/SyncMerkleTestnet.s.sol:SyncMerkleTestnetScript \
        --sig 'checkManifest()' --rpc-url "$TESTNET_RPC_URL" --sender "$TESTNET_OWNER" \
        --non-interactive --disable-external-identification
fi
if [[ "$phase" != validate ]]; then set -- --broadcast "$@"; fi
exec forge script "script/deploy/testnet/$script.s.sol:${script}Script" \
    --rpc-url "$TESTNET_RPC_URL" --sender "$TESTNET_OWNER" --no-isolate \
    --non-interactive --disable-external-identification "$@"
