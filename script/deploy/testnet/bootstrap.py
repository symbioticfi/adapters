#!/usr/bin/env python3
"""Bootstrap local fixtures or resume the official Sepolia deployment phases."""
import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PREFIX = 'script/deploy/testnet/'
LOCAL_CHAIN_ID = 31337
SEPOLIA_CHAIN_ID = 11155111
SEPOLIA_STAGING_WORKFLOW_REGISTRY = '0xaE55eB3EDAc48a1163EE2cbb1205bE1e90Ea1135'
SEPOLIA = {
    'forwarder': '0xF8344CFd5c43616a4366C34E3EEE75af79a74482',
    'threeFRequestsFactory': '0x56834F241E4A4D6e5C4207B03bB16b2B3FfCc5fb',
    'threeFFacility': '0x68129DbAEefA7eB88fc0276b9C27A5169c43d675',
    'threeFWhitelist': '0xA80b976A357aC24f3c38F7E5ED3Dd5b813bb09E1',
    'usdc': '0x809e6c18bC13Cc7C9F7b8000d74243BAaccE84d7',
}


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


def address(value):
    return isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]{40}', value) is not None and int(value, 16) > 0


def same_address(left, right):
    return address(left) and address(right) and left.lower() == right.lower()


def load_manifest(path, owner, chain_id):
    try:
        data = json.loads(path.read_text())
        if data['chainId'] != chain_id or not same_address(data['owner'], owner):
            raise ValueError('Manifest owner or chain does not match the configured deployment.')
        if data['schemaVersion'] != 2 or not isinstance(data['markets'], list) or len(data['markets']) != 7:
            raise ValueError('Expected a schema 2 manifest with seven markets.')
        if any(type(data[key]) is not int or data[key] <= 0 for key in ('seedAssets', 'maxReportAge')):
            raise ValueError('Manifest seed budget and report age must be positive integers.')
        if chain_id == SEPOLIA_CHAIN_ID:
            if data['infrastructure'] != 'official-sepolia':
                raise ValueError('Sepolia requires an official-sepolia manifest.')
            for key, expected in SEPOLIA.items():
                actual = data['markets'][0]['asset'] if key == 'usdc' else data[key]
                if not same_address(actual, expected):
                    raise ValueError(f'Manifest {key} does not match the official Sepolia binding.')
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f'Invalid manifest: {error}') from error
    return data


def preflight_sepolia(cast, rpc_url, registry):
    if not address(registry):
        raise SystemExit('Configured Sepolia WorkflowRegistry must be a nonzero address; empty overrides are invalid.')
    for name, contract in {'chainlinkRegistry': registry, **SEPOLIA}.items():
        code = run([cast, 'code', contract, '--rpc-url', rpc_url], capture=True)
        if not re.fullmatch(r'0x[0-9a-fA-F]+', code) or len(code) <= 2 or set(code[2:]) <= {'0'}:
            raise SystemExit(f'Sepolia {name} has no deployed code at {contract}.')
    for contract, expected in ((registry, 'WorkflowRegistry 2.0.0'), (SEPOLIA['forwarder'], 'KeystoneForwarder 1.0.0')):
        version = run([cast, 'call', contract, 'typeAndVersion()(string)', '--rpc-url', rpc_url], capture=True)
        if version.strip('"') != expected:
            raise SystemExit(f'Sepolia contract {contract} must report {expected}.')
    decimals = run([cast, 'call', SEPOLIA['usdc'], 'decimals()(uint8)', '--rpc-url', rpc_url], capture=True)
    if int(decimals.split()[0], 0) != 6:
        raise SystemExit('Official Sepolia USDC must have six decimals.')


def preflight_backing(cast, rpc_url, owner, seed_assets):
    weth_budget = seed_assets * 10**18 // 3000
    required_eth = weth_budget * 4 + weth_budget * 2 // 100
    balance = int(run([cast, 'balance', owner, '--rpc-url', rpc_url], capture=True))
    if balance <= required_eth:
        raise SystemExit(f'Owner needs more than {required_eth} wei for WETH and ETH staking backing, plus gas.')


def check_activation(path, data):
    try:
        activation = json.loads(path.read_text())
        if (activation['chainId'] != SEPOLIA_CHAIN_ID
                or not same_address(activation['owner'], data['owner'])
                or not same_address(activation['chainlinkRegistry'], data['chainlinkRegistry'])):
            raise ValueError('Activation owner, chain or registry does not match the manifest.')
        entries = activation['entries']
        if not isinstance(entries, list) or len(entries) != len(data['markets']):
            raise ValueError('Activation needs one entry per manifest market, in market order.')
        seen = {key: set() for key in ('oracle', 'wrapper', 'proof', 'workflowId')}
        for entry, market in zip(entries, data['markets']):
            if (not same_address(entry['oracle'], market['creOracle'])
                    or not same_address(entry['wrapper'], market['workflowRegistry'])):
                raise ValueError('Activation oracle or wrapper does not match its manifest market.')
            expiry = entry['expiry']
            if type(expiry) is not int or not 0 < expiry < 2**48:
                raise ValueError('Activation expiry must be a positive uint48 timestamp.')
            for key in ('proof', 'workflowId'):
                if not re.fullmatch(r'0x[0-9a-fA-F]{64}', entry[key]) or int(entry[key], 16) == 0:
                    raise ValueError(f'Activation {key} must be a nonzero bytes32 value.')
            if not re.fullmatch(r'0x(?:[0-9a-fA-F]{2})+', entry['signature']):
                raise ValueError('Activation signature must contain Chainlink-issued signature bytes.')
            if not re.fullmatch(r'0x(?:[0-9a-fA-F]{2})*', entry['attributes']):
                raise ValueError('Activation attributes must be hex-encoded bytes.')
            for key in ('donFamily', 'binaryUrl', 'configUrl'):
                if not isinstance(entry[key], str) or not entry[key]:
                    raise ValueError(f'Activation {key} must be supplied by the CRE organization.')
            for key, values in seen.items():
                value = entry[key].lower()
                if value in values:
                    raise ValueError(f'Activation {key} values must be unique.')
                values.add(value)
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f'Invalid CRE activation file: {error}') from error


def local_activation(cast, rpc_url, wallet, data, env):
    if data['chainId'] != LOCAL_CHAIN_ID:
        raise SystemExit('Ownership self-signing is available only for locally owned fixtures.')
    block = json.loads(run([cast, 'block', 'latest', '--json', '--rpc-url', rpc_url], capture=True))
    block = block.get('data', block)
    timestamp = int(block['timestamp'], 0) if isinstance(block['timestamp'], str) else block['timestamp']
    expiry = timestamp + 86_400
    proof = '0x' + secrets.token_hex(32)
    signatures = []
    for registry in data['workflowRegistries']:
        encoded_proof = run([cast, 'abi-encode', 'f(bytes32,address)', proof, registry], capture=True)
        derived = run([cast, 'keccak', encoded_proof], capture=True)
        encoded = run([cast, 'abi-encode', 'f(uint8,address,uint256,address,string,uint256,bytes32)',
                       '0', registry, str(LOCAL_CHAIN_ID), data['chainlinkRegistry'],
                       'WorkflowRegistry 2.0.0', str(expiry), derived], capture=True)
        digest = run([cast, 'keccak', encoded], capture=True)
        # The locally owned registry verifies the EIP-191 prefixed hash.
        signatures.append(run([cast, 'wallet', 'sign', *wallet, digest], capture=True))
    env.update(TESTNET_LINK_EXPIRY=str(expiry), TESTNET_LINK_PROOF=proof,
               TESTNET_LINK_SIGNATURES=','.join(signatures))


def local_threef(cast, rpc_url, wallet, data, env):
    if data['chainId'] != LOCAL_CHAIN_ID:
        raise SystemExit('Synthetic 3F funding is available only for local fixtures.')
    signatures = []
    for index, market in enumerate(data['markets']):
        price = 3000 if index == 5 else 60_000 if 2 <= index <= 4 else 1
        amount = data['seedAssets'] * 10**market['decimals'] // price
        request = market['threeFRequest']
        maker = market['threeFAdapter']
        nonce = run([cast, 'call', request, 'nonce(address)(uint256)', maker,
                     '--rpc-url', rpc_url], capture=True).split()[0]
        maturity = run([cast, 'call', request, 'maturity()(uint48)',
                        '--rpc-url', rpc_url], capture=True).split()[0]
        offer = f'({maker},{amount//50},{amount//500},{nonce},{maturity},true)'
        digest = run([cast, 'call', request,
                      'offerDigest((address,uint256,uint256,uint256,uint256,bool))(bytes32)',
                      offer, '--rpc-url', rpc_url], capture=True)
        signatures.append(run([cast, 'wallet', 'sign', '--no-hash', *wallet, digest], capture=True))
    env['TESTNET_THREE_F_SIGNATURES'] = ','.join(signatures)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc-url', required=True)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument('--account', help='Encrypted Foundry keystore name')
    signing.add_argument('--keystore', type=Path, help='Path to encrypted keystore JSON')
    parser.add_argument('--password-file', required=True, type=Path)
    parser.add_argument('--phase', choices=('bootstrap', 'deploy', 'activate', 'seed', 'sync', 'validate'), default='bootstrap')
    manifests = parser.add_mutually_exclusive_group()
    manifests.add_argument('--manifest', type=Path, help='New manifest path for bootstrap/deploy')
    manifests.add_argument('--existing-manifest', type=Path, help='Saved deployment for activate/seed/sync/validate')
    parser.add_argument('--seed-assets', type=int, help='USD budget per market (default: 100000 for a new deployment)')
    parser.add_argument('--max-report-age', type=int, help='Oracle report age in seconds (default: 86400 for a new deployment)')
    parser.add_argument('--chainlink-registry', default=os.environ.get('TESTNET_CHAINLINK_REGISTRY'),
                        help=f'Sepolia WorkflowRegistry override (new deployment default: {SEPOLIA_STAGING_WORKFLOW_REGISTRY})')
    parser.add_argument('--cre-activation', type=Path, default=os.environ.get('TESTNET_CRE_ACTIVATION'),
                        help='Official CRE activation JSON for Sepolia activate')
    args = parser.parse_args(argv)
    fresh = args.phase in ('bootstrap', 'deploy')
    if (fresh and args.existing_manifest) or (not fresh and not args.existing_manifest):
        parser.error('bootstrap/deploy require a new --manifest; later phases require --existing-manifest.')
    manifest = (ROOT / (args.existing_manifest or args.manifest or Path(PREFIX + 'manifests/realistic.json'))).resolve()
    if not manifest.is_relative_to(ROOT):
        parser.error('Manifest must be inside the repository for Foundry file permissions.')
    if fresh and manifest.exists():
        parser.error('Choose a new manifest path; an existing deployment must not be overwritten.')
    if not fresh and not manifest.is_file():
        parser.error('Existing manifest does not exist.')
    for value in (args.seed_assets, args.max_report_age):
        if value is not None and value <= 0:
            parser.error('Seed budget and report age must be positive.')
    password = args.password_file.resolve()
    if not password.is_file():
        parser.error('Password file does not exist.')
    forge, cast = tools()
    wallet = (['--account', args.account] if args.account else ['--keystore', str(args.keystore.resolve())])
    wallet += ['--password-file', str(password)]
    owner = run([cast, 'wallet', 'address', *wallet], capture=True)
    chain_id = int(run([cast, 'chain-id', '--rpc-url', args.rpc_url], capture=True))
    if chain_id not in (LOCAL_CHAIN_ID, SEPOLIA_CHAIN_ID):
        raise SystemExit(f'Unsupported chain {chain_id}; use local Anvil 31337 or official Sepolia 11155111.')
    data = None if fresh else load_manifest(manifest, owner, chain_id)
    seed_assets = args.seed_assets if args.seed_assets is not None else (100_000 if fresh else data['seedAssets'])
    max_report_age = args.max_report_age if args.max_report_age is not None else (86_400 if fresh else data['maxReportAge'])
    if data and (seed_assets != data['seedAssets'] or max_report_age != data['maxReportAge']):
        raise SystemExit('Resume must use the seed budget and report age recorded in the manifest.')
    env = os.environ.copy()
    env.pop('TESTNET_SNAPSHOT_BLOCK', None)
    env.update(TESTNET_OWNER=owner, TESTNET_RPC_URL=args.rpc_url,
               TESTNET_MANIFEST=str(manifest), TESTNET_SEED_ASSETS=str(seed_assets),
               TESTNET_MAX_REPORT_AGE=str(max_report_age))
    if chain_id == SEPOLIA_CHAIN_ID:
        for key in ('TESTNET_LINK_EXPIRY', 'TESTNET_LINK_PROOF', 'TESTNET_LINK_SIGNATURES', 'TESTNET_THREE_F_SIGNATURES'):
            env.pop(key, None)
        # An implicit new-deployment default must never replace a saved organization registry.
        registry = (args.chainlink_registry if args.chainlink_registry is not None
                    else SEPOLIA_STAGING_WORKFLOW_REGISTRY) if fresh else data['chainlinkRegistry']
        if data and args.chainlink_registry is not None and not same_address(args.chainlink_registry, registry):
            raise SystemExit('Configured registry does not match the saved deployment.')
        preflight_sepolia(cast, args.rpc_url, registry)
        env['TESTNET_CHAINLINK_REGISTRY'] = registry
        if args.phase == 'activate':
            if not args.cre_activation:
                raise SystemExit('Sepolia activation requires --cre-activation or TESTNET_CRE_ACTIVATION from the CRE organization.')
            activation = (ROOT / args.cre_activation).resolve()
            if not activation.is_relative_to(ROOT):
                parser.error('CRE activation file must be inside the repository for Foundry file permissions.')
            check_activation(activation, data)
            env['TESTNET_CRE_ACTIVATION'] = str(activation)
    if fresh or args.phase == 'seed':
        preflight_backing(cast, args.rpc_url, owner, seed_assets)
    run(['python3', PREFIX + 'check_catalog.py'])

    def phase(name, *, broadcast=True):
        print(f'Running {name} on chain {chain_id}', flush=True)
        command = [forge, 'script', PREFIX + name + '.s.sol:' + name + 'Script',
                   '--rpc-url', args.rpc_url, '--no-isolate', '--non-interactive',
                   '--disable-external-identification']
        if broadcast:
            command += ['--broadcast', '--slow', *wallet]
        run(command, env=env)

    if fresh:
        phase('DeployRealisticTestnet')
        data = load_manifest(manifest, owner, chain_id)
        if chain_id == SEPOLIA_CHAIN_ID or args.phase == 'deploy':
            print(f'Deployment manifest: {manifest}', flush=True)
            if chain_id == SEPOLIA_CHAIN_ID:
                print('Handoff ready; CRE activation and the initial official forwarder report are pending. '
                      'Resume with --phase activate --existing-manifest and --cre-activation.', flush=True)
            else:
                print('Resume with --phase activate --existing-manifest, then seed.', flush=True)
            return
    if args.phase in ('bootstrap', 'activate'):
        if chain_id == LOCAL_CHAIN_ID:
            local_activation(cast, args.rpc_url, wallet, data, env)
        phase('ActivateMerkleTestnet')
        if args.phase == 'activate':
            print('Activation submitted. Wait for the initial official CRE report before seed.'
                  if chain_id == SEPOLIA_CHAIN_ID else 'Activation submitted. Resume with --phase seed.', flush=True)
            return
    if args.phase in ('bootstrap', 'seed'):
        phase('SyncMerkleTestnet' if chain_id == SEPOLIA_CHAIN_ID else 'ReportMerkleTestnet')
        phase('SeedRealisticTestnet')
        if chain_id == SEPOLIA_CHAIN_ID:
            print('Funding submitted. Wait for a new completed-block CRE report, then run --phase sync and --phase validate.', flush=True)
            return
        local_threef(cast, args.rpc_url, wallet, data, env)
        phase('SeedThreeFTestnet')
        phase('ReportMerkleTestnet')
        phase('ValidateRealisticTestnet', broadcast=False)
        print(f'Complete local testnet manifest: {manifest}', flush=True)
        return
    if args.phase == 'sync':
        phase('SyncMerkleTestnet' if chain_id == SEPOLIA_CHAIN_ID else 'ReportMerkleTestnet')
        print(f'Report synchronized for {manifest}', flush=True)
    elif args.phase == 'validate':
        phase('ValidateRealisticTestnet', broadcast=False)
        print(f'Deployment validated: {manifest}', flush=True)


if __name__ == '__main__':
    main()
