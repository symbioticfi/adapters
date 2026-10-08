#!/usr/bin/env python3
"""Deploy, activate, fund and report a complete testnet using an encrypted keystore."""
import argparse
import json
import os
import secrets
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PREFIX = 'script/deploy/testnet/'


def run(argv, *, env=None, capture=False):
    result = subprocess.run(argv, cwd=ROOT, env=env, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def tools():
    pinned = Path.home() / '.foundry/versions/foundry-rs/foundry/v1.8.1'
    forge = str(pinned / 'forge') if (pinned / 'forge').is_file() else shutil.which('forge')
    cast = str(pinned / 'cast') if (pinned / 'cast').is_file() else shutil.which('cast')
    if not forge or not cast or '1.8.1' not in run([forge, '--version'], capture=True):
        raise SystemExit('Install the repository-pinned Foundry 1.8.1 before running this helper.')
    return forge, cast


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc-url', required=True)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument('--account', help='Encrypted Foundry keystore name')
    signing.add_argument('--keystore', type=Path, help='Path to encrypted keystore JSON')
    parser.add_argument('--password-file', required=True, type=Path)
    parser.add_argument('--manifest', default=PREFIX + 'manifests/realistic.json')
    parser.add_argument('--seed-assets', type=int, default=100_000, help='USD budget per market')
    parser.add_argument('--max-report-age', type=int, default=86_400)
    args = parser.parse_args()
    if args.seed_assets <= 0 or args.max_report_age <= 0:
        parser.error('Seed budget and report age must be positive.')
    manifest = (ROOT / args.manifest).resolve()
    if not manifest.is_relative_to(ROOT):
        parser.error('Manifest must be inside the repository for Foundry file permissions.')
    if manifest.exists():
        parser.error('Choose a new manifest path; an existing deployment must not be overwritten.')
    password = args.password_file.resolve()
    if not password.is_file():
        parser.error('Password file does not exist.')
    forge, cast = tools()
    wallet = (['--account', args.account] if args.account else ['--keystore', str(args.keystore.resolve())]) + ['--password-file', str(password)]
    owner = run([cast, 'wallet', 'address', *wallet], capture=True)
    chain_id = int(run([cast, 'chain-id', '--rpc-url', args.rpc_url], capture=True))
    env = os.environ.copy()
    # Each bootstrap report needs a new completed snapshot after its preceding phase.
    env.pop('TESTNET_SNAPSHOT_BLOCK', None)
    env.update(TESTNET_OWNER=owner, TESTNET_RPC_URL=args.rpc_url,
               TESTNET_MANIFEST=str(manifest), TESTNET_SEED_ASSETS=str(args.seed_assets),
               TESTNET_MAX_REPORT_AGE=str(args.max_report_age))
    run(['python3', PREFIX + 'check_catalog.py'])

    def phase(name):
        print(f'Running {name} on chain {chain_id}', flush=True)
        run([forge, 'script', PREFIX + name + '.s.sol:' + name + 'Script',
             '--rpc-url', args.rpc_url, '--broadcast', '--no-isolate', '--slow',
             '--non-interactive', *wallet], env=env)

    # Check the real native backing requirement before deploying hundreds of contracts.
    weth_budget = args.seed_assets * 10**18 // 3000
    required_eth = weth_budget * 4 + weth_budget * 2 // 100
    balance = int(run([cast, 'balance', owner, '--rpc-url', args.rpc_url], capture=True))
    if balance <= required_eth:
        raise SystemExit(f'Owner needs more than {required_eth} wei for WETH and ETH staking backing, plus gas.')
    phase('DeployRealisticTestnet')
    data = json.loads(manifest.read_text())
    if data['chainId'] != chain_id or data['owner'].lower() != owner.lower():
        raise SystemExit('Manifest owner or chain does not match the configured deployment.')
    block = json.loads(run([cast, 'block', 'latest', '--json', '--rpc-url', args.rpc_url], capture=True))
    # Foundry's JSON envelope contains the RPC block under data.
    block = block.get('data', block)
    timestamp = int(block['timestamp'], 0) if isinstance(block['timestamp'], str) else block['timestamp']
    expiry = timestamp + 86_400
    proof = '0x' + secrets.token_hex(32)
    signatures = []
    for registry in data['workflowRegistries']:
        encoded_proof = run([cast, 'abi-encode', 'f(bytes32,address)', proof, registry], capture=True)
        derived = run([cast, 'keccak', encoded_proof], capture=True)
        encoded = run([cast, 'abi-encode', 'f(uint8,address,uint256,address,string,uint256,bytes32)',
                       '0', registry, str(chain_id), data['chainlinkRegistry'],
                       'WorkflowRegistry 2.0.0', str(expiry), derived], capture=True)
        digest = run([cast, 'keccak', encoded], capture=True)
        # linkOwner verifies the EIP-191 prefixed hash, so do not use --no-hash here.
        signatures.append(run([cast, 'wallet', 'sign', *wallet, digest], capture=True))
    env.update(TESTNET_LINK_EXPIRY=str(expiry), TESTNET_LINK_PROOF=proof,
               TESTNET_LINK_SIGNATURES=','.join(signatures))
    phase('ActivateMerkleTestnet')
    phase('ReportMerkleTestnet')
    phase('SeedRealisticTestnet')
    signatures = []
    for index, market in enumerate(data['markets']):
        price = 3000 if index == 5 else 60_000 if 2 <= index <= 4 else 1
        amount = args.seed_assets * 10**market['decimals'] // price
        request = market['threeFRequest']
        maker = market['threeFAdapter']
        nonce = run([cast, 'call', request, 'nonce(address)(uint256)', maker,
                     '--rpc-url', args.rpc_url], capture=True).split()[0]
        maturity = run([cast, 'call', request, 'maturity()(uint48)',
                        '--rpc-url', args.rpc_url], capture=True).split()[0]
        offer = f'({maker},{amount//50},{amount//500},{nonce},{maturity},true)'
        digest = run([cast, 'call', request,
                      'offerDigest((address,uint256,uint256,uint256,uint256,bool))(bytes32)',
                      offer, '--rpc-url', args.rpc_url], capture=True)
        signatures.append(run([cast, 'wallet', 'sign', '--no-hash', *wallet, digest], capture=True))
    env['TESTNET_THREE_F_SIGNATURES'] = ','.join(signatures)
    phase('SeedThreeFTestnet')
    phase('ReportMerkleTestnet')
    run([forge, 'script', PREFIX + 'ValidateRealisticTestnet.s.sol:ValidateRealisticTestnetScript',
         '--rpc-url', args.rpc_url, '--no-isolate', '--non-interactive'], env=env)
    print(f'Complete testnet manifest: {manifest}', flush=True)


if __name__ == '__main__':
    main()
