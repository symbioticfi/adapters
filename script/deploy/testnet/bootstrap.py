#!/usr/bin/env python3
"""Bootstrap local fixtures or Sepolia with official CRE or a self-hosted NAV publisher."""
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
    pinned = Path.home() / '.foundry/versions/foundry-rs/foundry/v1.8.5'
    forge = str(pinned / 'forge') if (pinned / 'forge').is_file() else shutil.which('forge')
    cast = str(pinned / 'cast') if (pinned / 'cast').is_file() else shutil.which('cast')
    if (not forge or not cast or '1.8.5' not in run([forge, '--version'], capture=True)
            or '1.8.5' not in run([cast, '--version'], capture=True)):
        raise SystemExit('Install Foundry 1.8.5 with foundryup -i v1.8.5 before running this helper.')
    return forge, cast


def script_runtime(chain_id):
    # Estimate Sepolia broadcasts through the RPC under its active gas schedule.
    forge, cast = tools()
    return forge, cast, ['--skip-simulation'] if chain_id == SEPOLIA_CHAIN_ID else []


def address(value):
    return isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]{40}', value) is not None and int(value, 16) > 0


def same_address(left, right):
    return address(left) and address(right) and left.lower() == right.lower()


def report_phase(data):
    return ('ReportMerkleTestnet' if data['chainId'] == LOCAL_CHAIN_ID and data['oracleMode'] == 'official-cre'
            else 'SyncMerkleTestnet')


def load_manifest(path, owner, chain_id):
    try:
        data = json.loads(path.read_text())
        if data['chainId'] != chain_id or not same_address(data['owner'], owner):
            raise ValueError('Manifest owner or chain does not match the configured deployment.')
        if data['schemaVersion'] != 2 or not isinstance(data['markets'], list) or len(data['markets']) != 7:
            raise ValueError('Expected a schema 2 manifest with seven markets.')
        if type(data['seedAssets']) is not int or data['seedAssets'] <= 0:
            raise ValueError('Manifest seed budget must be a positive integer.')
        if 'oracleMode' not in data or 'reportPublisher' not in data:
            raise ValueError('Manifest requires explicit oracleMode and reportPublisher; regenerate the deployment manifest.')
        if data['oracleMode'] not in ('official-cre', 'self-hosted') or not address(data['reportPublisher']):
            raise ValueError('Manifest oracleMode or reportPublisher is invalid.')
        if not address(data['chainlinkRegistry']) or not address(data['forwarder']):
            raise ValueError('Manifest oracle infrastructure must contain nonzero addresses.')
        if chain_id == SEPOLIA_CHAIN_ID:
            if data['infrastructure'] != 'official-sepolia':
                raise ValueError('Sepolia requires an official-sepolia manifest.')
            for key, expected in SEPOLIA.items():
                if key == 'forwarder' and data['oracleMode'] == 'self-hosted':
                    if same_address(data[key], expected):
                        raise ValueError('Self-hosted Sepolia requires its own forwarder.')
                    continue
                actual = data['markets'][0]['asset'] if key == 'usdc' else data[key]
                if not same_address(actual, expected):
                    raise ValueError(f'Manifest {key} does not match the official Sepolia binding.')
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f'Invalid manifest: {error}') from error
    return data


def preflight_sepolia(cast, rpc_url, registry=None, forwarder=None, owner=None, publisher=None):
    if registry is not None and not address(registry):
        raise SystemExit('Configured Sepolia WorkflowRegistry must be a nonzero address; empty overrides are invalid.')
    contracts = {key: value for key, value in SEPOLIA.items() if key != 'forwarder'}
    if registry is not None:
        contracts.update(chainlinkRegistry=registry, forwarder=forwarder or SEPOLIA['forwarder'])
    for name, contract in contracts.items():
        code = run([cast, 'code', contract, '--rpc-url', rpc_url], capture=True)
        if not re.fullmatch(r'0x[0-9a-fA-F]+', code) or len(code) <= 2 or set(code[2:]) <= {'0'}:
            raise SystemExit(f'Sepolia {name} has no deployed code at {contract}.')
    for contract, expected in (() if registry is None else
                               ((registry, 'WorkflowRegistry 2.0.0'), (contracts['forwarder'], 'KeystoneForwarder 1.0.0'))):
        version = run([cast, 'call', contract, 'typeAndVersion()(string)', '--rpc-url', rpc_url], capture=True)
        if version.strip('"') != expected:
            raise SystemExit(f'Sepolia contract {contract} must report {expected}.')
        if owner is not None:
            actual = run([cast, 'call', contract, 'owner()(address)', '--rpc-url', rpc_url], capture=True)
            if not same_address(actual, owner):
                raise SystemExit('Self-hosted oracle infrastructure must be owned by the manifest owner.')
    if publisher is not None:
        authorized = run([cast, 'call', forwarder, 'isForwarder(address)(bool)', publisher,
                          '--rpc-url', rpc_url], capture=True)
        if authorized != 'true':
            raise SystemExit('Self-hosted report publisher is not authorized by the forwarder.')
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
            if not isinstance(entry.get('tag', 'default'), str) or not entry.get('tag', 'default'):
                raise ValueError('Activation tag must be a nonempty string when supplied.')
            if type(entry.get('status', 0)) is not int or entry.get('status', 0) not in (0, 1):
                raise ValueError('Activation status must be 0 (ACTIVE) or 1 (PAUSED).')
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
    if data['chainId'] != LOCAL_CHAIN_ID and not (data['chainId'] == SEPOLIA_CHAIN_ID and data['oracleMode'] == 'self-hosted'):
        raise SystemExit('Ownership self-signing requires local fixtures or explicit self-hosted Sepolia.')
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
                       '0', registry, str(data['chainId']), data['chainlinkRegistry'],
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
    parser.add_argument('--fast', action='store_true', help='Prepare gas on a local fork, then broadcast in batches of 100.')
    parser.add_argument('--resume', action='store_true', help='Resume an interrupted deployment with --fast and --existing-manifest.')
    manifests = parser.add_mutually_exclusive_group()
    manifests.add_argument('--manifest', type=Path, help='New manifest path for bootstrap/deploy')
    manifests.add_argument('--existing-manifest', type=Path, help='Saved deployment for activate/seed/sync/validate')
    parser.add_argument('--seed-assets', type=int, help='USD budget per market (default: 100000 for a new deployment)')
    parser.add_argument('--oracle-mode', choices=('official-cre', 'self-hosted'), default=os.environ.get('TESTNET_ORACLE_MODE'),
                        help='Oracle infrastructure (new deployment default: official-cre; resume uses saved mode)')
    parser.add_argument('--report-publisher', default=os.environ.get('TESTNET_REPORT_PUBLISHER'),
                        help='Authorized self-hosted report wallet (new deployment default: owner)')
    parser.add_argument('--chainlink-registry', default=os.environ.get('TESTNET_CHAINLINK_REGISTRY'),
                        help=f'Sepolia WorkflowRegistry override (new deployment default: {SEPOLIA_STAGING_WORKFLOW_REGISTRY})')
    parser.add_argument('--cre-activation', type=Path, default=os.environ.get('TESTNET_CRE_ACTIVATION'),
                        help='Official CRE activation JSON for Sepolia activate')
    args = parser.parse_args(argv)
    if args.resume and (not args.fast or args.phase not in ('bootstrap', 'deploy')):
        parser.error('--resume requires --fast and the bootstrap/deploy phase.')
    fresh = args.phase in ('bootstrap', 'deploy') and not args.resume
    if (fresh and args.existing_manifest) or (not fresh and not args.existing_manifest):
        parser.error('bootstrap/deploy require a new --manifest; later phases require --existing-manifest.')
    manifest = (ROOT / (args.existing_manifest or args.manifest or Path(PREFIX + 'manifests/realistic.json'))).resolve()
    if not manifest.is_relative_to(ROOT):
        parser.error('Manifest must be inside the repository for Foundry file permissions.')
    if fresh and manifest.exists():
        parser.error('Choose a new manifest path; an existing deployment must not be overwritten.')
    if not fresh and not manifest.is_file():
        parser.error('Existing manifest does not exist.')
    if args.seed_assets is not None and args.seed_assets <= 0:
        parser.error('Seed budget must be positive.')
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
    forge, cast, runtime = script_runtime(chain_id)
    data = None if fresh else load_manifest(manifest, owner, chain_id)
    oracle_mode = (args.oracle_mode if args.oracle_mode is not None else 'official-cre') if fresh else data['oracleMode']
    publisher = (args.report_publisher if args.report_publisher is not None else owner) if fresh else data['reportPublisher']
    if oracle_mode not in ('official-cre', 'self-hosted'):
        raise SystemExit('Configured oracle mode must be official-cre or self-hosted.')
    if data and args.oracle_mode is not None and args.oracle_mode != oracle_mode:
        raise SystemExit('Configured oracle mode does not match the saved deployment.')
    if not address(publisher):
        raise SystemExit('Report publisher must be a nonzero address.')
    if oracle_mode != 'self-hosted' and not same_address(publisher, owner):
        raise SystemExit('A dedicated report publisher requires explicit self-hosted mode.')
    if data and args.report_publisher is not None and not same_address(args.report_publisher, publisher):
        raise SystemExit('Configured report publisher does not match the saved deployment.')
    if oracle_mode == 'self-hosted' and (args.cre_activation is not None or (fresh and args.chainlink_registry is not None)):
        raise SystemExit('Explicit self-hosted mode deploys its own registry and rejects official CRE activation artifacts.')
    seed_assets = args.seed_assets if args.seed_assets is not None else (100_000 if fresh else data['seedAssets'])
    if data and seed_assets != data['seedAssets']:
        raise SystemExit('Resume must use the seed budget recorded in the manifest.')
    env = os.environ.copy()
    env.pop('TESTNET_SNAPSHOT_BLOCK', None)
    env.update(TESTNET_OWNER=owner, TESTNET_RPC_URL=args.rpc_url,
               TESTNET_MANIFEST=str(manifest), TESTNET_SEED_ASSETS=str(seed_assets),
               TESTNET_ORACLE_MODE=oracle_mode, TESTNET_REPORT_PUBLISHER=publisher)
    if chain_id == SEPOLIA_CHAIN_ID:
        for key in ('TESTNET_LINK_EXPIRY', 'TESTNET_LINK_PROOF', 'TESTNET_LINK_SIGNATURES', 'TESTNET_THREE_F_SIGNATURES'):
            env.pop(key, None)
        # An implicit new-deployment default must never replace a saved organization registry.
        registry = ((args.chainlink_registry if args.chainlink_registry is not None
                     else SEPOLIA_STAGING_WORKFLOW_REGISTRY) if oracle_mode == 'official-cre' else None) if fresh else data['chainlinkRegistry']
        if data and args.chainlink_registry is not None and not same_address(args.chainlink_registry, registry):
            raise SystemExit('Configured registry does not match the saved deployment.')
        if oracle_mode == 'self-hosted':
            env.pop('TESTNET_CRE_ACTIVATION', None)
            preflight_sepolia(cast, args.rpc_url, registry, None if fresh else data['forwarder'],
                              None if fresh else owner, None if fresh else publisher)
        else:
            preflight_sepolia(cast, args.rpc_url, registry)
        if registry is not None:
            env['TESTNET_CHAINLINK_REGISTRY'] = registry
        else:
            env.pop('TESTNET_CHAINLINK_REGISTRY', None)
        if args.phase == 'activate' and oracle_mode == 'official-cre':
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
        if args.fast and broadcast:
            import fast_broadcast
            try:
                fast_broadcast.broadcast(command, wallet, env, manifest,
                                         resume=args.resume and name == 'DeployRealisticTestnet')
            except (ValueError, OSError, KeyError) as error:
                raise SystemExit(f'Fast deployment stopped: {error}') from None
            return
        command += runtime
        if broadcast:
            command += ['--broadcast', '--slow', *wallet]
        run(command, env=env)

    if fresh or args.resume:
        phase('DeployRealisticTestnet')
        data = load_manifest(manifest, owner, chain_id)
        if data['oracleMode'] != oracle_mode or not same_address(data['reportPublisher'], publisher):
            raise SystemExit('Deployed manifest oracle mode or report publisher does not match the requested deployment.')
        if (chain_id == SEPOLIA_CHAIN_ID and oracle_mode == 'official-cre') or args.phase == 'deploy':
            print(f'Deployment manifest: {manifest}', flush=True)
            if chain_id == SEPOLIA_CHAIN_ID and oracle_mode == 'official-cre':
                print('Handoff ready; CRE activation and the initial official forwarder report are pending. '
                      'Resume with --phase activate --existing-manifest and --cre-activation.', flush=True)
            else:
                print('Resume with --phase activate --existing-manifest, then seed.', flush=True)
            return
    if args.phase in ('bootstrap', 'activate'):
        if chain_id == LOCAL_CHAIN_ID or oracle_mode == 'self-hosted':
            local_activation(cast, args.rpc_url, wallet, data, env)
        phase('ActivateMerkleTestnet')
        if oracle_mode == 'self-hosted':
            print(f'Deployment manifest: {manifest}', flush=True)
            print('Activation submitted. Start the NAV daemon and wait for its initial accepted report in a later block; '
                  'then resume with --phase seed --existing-manifest.', flush=True)
            return
        if args.phase == 'activate':
            print('Activation submitted. Wait for the initial official CRE report before seed.'
                  if chain_id == SEPOLIA_CHAIN_ID else 'Activation submitted. Resume with --phase seed.', flush=True)
            return
    if args.phase in ('bootstrap', 'seed'):
        phase(report_phase(data))
        phase('SeedRealisticTestnet')
        if report_phase(data) == 'SyncMerkleTestnet':
            print('Funding submitted. Wait for a new completed-block oracle report, then run --phase sync and --phase validate.', flush=True)
            return
        local_threef(cast, args.rpc_url, wallet, data, env)
        phase('SeedThreeFTestnet')
        phase('ReportMerkleTestnet')
        phase('ValidateRealisticTestnet', broadcast=False)
        print(f'Complete local testnet manifest: {manifest}', flush=True)
        return
    if args.phase == 'sync':
        phase(report_phase(data))
        print(f'Report synchronized for {manifest}', flush=True)
    elif args.phase == 'validate':
        phase('ValidateRealisticTestnet', broadcast=False)
        print(f'Deployment validated: {manifest}', flush=True)


if __name__ == '__main__':
    main()
