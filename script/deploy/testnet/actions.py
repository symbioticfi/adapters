#!/usr/bin/env python3
"""Execute a finite batch of reproducible protocol actions against a deployed testnet."""
import argparse
import hashlib
import json
import os
import random
import subprocess
from pathlib import Path

import bootstrap

ROOT = bootstrap.ROOT
PREFIX = bootstrap.PREFIX
ZERO = '0x' + '0' * 40


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def task_seed(seed, round_index, task):
    return int.from_bytes(hashlib.sha256(f'{seed}:{round_index}:{task}'.encode()).digest(), 'big')


def tasks(data, seed, round_index):
    result = []
    for index, market in enumerate(data['markets']):
        result.append((f'market-{index}', 'MarketActivity', index, None))
        result.append((f'threef-{index}', 'ThreeFActivity', index, None))
        result.append((f'merkle-threef-{index}', 'MerkleThreeFActivity', index, None))
        for profile in market['rwaProfiles']:
            result.append((f'rwa-{profile}', 'RWAActivity', index, profile))
    random.Random(task_seed(seed, round_index, 'order')).shuffle(result)
    return result


def save(path, data):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.replace(path)


def artifact_name(signature=None):
    return (signature.split('(', 1)[0] if signature else 'run') + '-latest.json'


def load_result(path):
    """Normalize Foundry uint values, which serialize as strings above JSON's safe integer range."""
    result = json.loads(path.read_text())
    for key in ('chainId', 'seed', 'settled', 'nextCursor', 'amount', 'yieldAssets', 'withdrawn', 'bought', 'cashSpent', 'sold', 'cashReceived'):
        if key in result:
            result[key] = number(result[key])
    for key in ('cursors', 'settlements', 'families'):
        if key in result:
            result[key] = [number(value) for value in result[key]]
    return result


def source_identity(root=ROOT):
    """Pin protocol dependencies, catalog and compilation settings without reading secret environment files."""
    sources = set()
    for directory in ('src', 'script', 'lib'):
        sources.update((root / directory).rglob('*.sol'))
    sources.update((root / PREFIX).rglob('*.py'))
    sources.add(root / PREFIX / 'catalog/integrations.json')
    for name in ('foundry.toml', 'foundry.lock', 'remappings.txt', '.gitmodules'):
        sources.add(root / name)
    digest = hashlib.sha256()
    for source in sorted(sources):
        if source.is_file():
            digest.update(str(source.relative_to(root)).encode())
            digest.update(source.read_bytes())
    return digest.hexdigest()


def request_environment(state):
    return {f'TESTNET_MERKLE_THREEF_REQUESTS_{market}': ','.join(requests)
            for market, requests in state.get('merkleRequests', {}).items()}


def verify_receipts(artifact, start_nonce, end_nonce, owner, get_receipt):
    """Require every nonce broadcast by this phase to have its own successful RPC receipt."""
    selected = {}
    for item in artifact.get('transactions', []):
        transaction = item.get('transaction', {})
        nonce = number(transaction.get('nonce', -1))
        if (bootstrap.same_address(transaction.get('from'), owner)
                and start_nonce <= nonce < end_nonce):
            if nonce in selected:
                raise ValueError('Duplicate broadcast nonce in artifact.')
            selected[nonce] = item['hash']
    if set(selected) != set(range(start_nonce, end_nonce)):
        raise ValueError('Broadcast artifact does not account for every mined owner nonce.')
    receipts = []
    for nonce in sorted(selected):
        receipt = get_receipt(selected[nonce])
        if (number(receipt['status']) != 1
                or receipt['transactionHash'].lower() != selected[nonce].lower()
                or not bootstrap.same_address(receipt['from'], owner)):
            raise ValueError('A broadcast transaction has no matching successful receipt.')
        receipts.append({'hash': selected[nonce], 'block': number(receipt['blockNumber']),
                         'gasUsed': number(receipt['gasUsed']), 'logs': len(receipt['logs'])})
    return receipts


def record_receipts(entry, artifact, owner, get_receipt):
    """Keep a phase's nonce-bounded journal independent of task-level receipt aggregation."""
    entry['receipts'] = verify_receipts(artifact, entry['startNonce'], entry['endNonce'], owner, get_receipt)
    return list(entry['receipts'])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc-url', required=True)
    parser.add_argument('--manifest', required=True, type=Path)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument('--account')
    signing.add_argument('--keystore', type=Path)
    parser.add_argument('--password-file', required=True, type=Path)
    parser.add_argument('--seed', type=int, default=20261008)
    parser.add_argument('--batches', type=int, default=1, help='Positive number of finite batches, then exit.')
    parser.add_argument('--advance-local-time', type=int, default=0,
                        help='Anvil-only seconds to advance before each batch; zero uses real time.')
    parser.add_argument('--state', type=Path, help='Receipt journal and restart cursor (default beside manifest).')
    args = parser.parse_args(argv)
    if args.batches < 1 or args.advance_local_time < 0:
        parser.error('Batches must be positive and local time advance must be nonnegative.')
    manifest = (ROOT / args.manifest).resolve()
    state_path = (ROOT / (args.state or manifest.with_name(manifest.stem + '-actions.json'))).resolve()
    if not manifest.is_relative_to(ROOT) or not state_path.is_relative_to(ROOT):
        parser.error('Manifest and state must be inside the repository for Foundry file permissions.')
    forge, cast = bootstrap.tools()
    wallet = ['--account', args.account] if args.account else ['--keystore', str(args.keystore.resolve())]
    wallet += ['--password-file', str(args.password_file.resolve())]
    owner = bootstrap.run([cast, 'wallet', 'address', *wallet], capture=True)
    chain_id = int(bootstrap.run([cast, 'chain-id', '--rpc-url', args.rpc_url], capture=True))
    if chain_id not in (bootstrap.LOCAL_CHAIN_ID, bootstrap.SEPOLIA_CHAIN_ID):
        parser.error('Only local Anvil 31337 and official Sepolia are supported.')
    forge, cast, runtime = bootstrap.script_runtime(chain_id)
    if args.advance_local_time and chain_id != bootstrap.LOCAL_CHAIN_ID:
        parser.error('Public-chain timestamps cannot be advanced by action scripts.')
    data = bootstrap.load_manifest(manifest, owner, chain_id)
    try:
        supported = bootstrap.run([cast, 'call', data['cowSettlement'], 'supportsContractSignatures()(bool)',
                                   '--rpc-url', args.rpc_url], capture=True)
        if supported != 'true':
            raise ValueError('Missing contract signature support.')
    except (subprocess.CalledProcessError, ValueError) as error:
        raise SystemExit('CoW fixture predates account signature support; deploy a fresh current environment.') from error
    catalog = json.loads((ROOT / PREFIX / 'catalog/integrations.json').read_text())['profiles']
    profiles = [profile for market in data['markets'] for profile in market['rwaProfiles']]
    if sorted(profiles) != list(range(len(catalog))):
        parser.error('Activity requires every catalog profile exactly once in the manifest.')
    for index, market in enumerate(data['markets']):
        if any(catalog[profile]['market'] != index for profile in market['rwaProfiles']):
            parser.error('A catalog profile is attached to the wrong native asset market.')
    for market in data['markets']:
        if any(key not in market for key in ('merkleActions', 'recipeSteps', 'morphoBlueParams',
                                             'morphoMidnightParams', 'restakingDelegator')):
            parser.error('Manifest predates activity support; export the existing deployment with the current script.')
        if any(len(market[key]) != len(market['rwaProfiles']) for key in ('rwaTokens', 'rwaOracles', 'priceFeeds', 'redemptionEndpoints')):
            parser.error('Manifest RWA metadata arrays do not match its catalog profiles.')
        for profile, endpoint in zip(market['rwaProfiles'], market['redemptionEndpoints']):
            native = catalog[profile]
            if native['kind'] < 3 or (native['kind'] == 4 and native['variant'] in (0, 3, 4, 6, 7, 8)):
                try:
                    bootstrap.run([cast, 'call', endpoint, 'activeRequestCount()(uint256)',
                                   '--rpc-url', args.rpc_url], capture=True)
                except subprocess.CalledProcessError as error:
                    raise SystemExit('Issuer fixtures predate activity queue counters; deploy a fresh current environment.') from error
    manifest_hash = hashlib.sha256(manifest.read_bytes()).hexdigest()
    identity = {'manifestHash': manifest_hash, 'sourceHash': source_identity(),
                'chainId': chain_id, 'owner': owner.lower(), 'seed': args.seed}
    if state_path.exists():
        state = json.loads(state_path.read_text())
        if any(state.get(key) != value for key, value in identity.items()):
            parser.error('Existing action journal has different sources, manifest, chain, owner or seed.')
        if state.get('activeTask') or any(entry['status'] not in ('mined', 'reconciled')
                                        or (entry['status'] == 'reconciled' and not entry.get('reconciliation'))
                                        for entry in state['transactions']):
            parser.error('Journal contains interrupted or failed broadcasts; reconcile their receipts before restarting.')
    else:
        state = {**identity, 'nextRound': 0, 'nextTask': 0, 'cursors': {}, 'midnight': {},
                 'coverage': {}, 'transactions': [], 'merkleRequests': {}, 'activeTask': None, 'maintenanceComplete': False}
    state_path.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.pop('TESTNET_SNAPSHOT_BLOCK', None)
    env.update(TESTNET_MANIFEST=str(manifest), TESTNET_RPC_URL=args.rpc_url, TESTNET_OWNER=owner)

    def rpc(method, *params):
        return json.loads(bootstrap.run([cast, 'rpc', method, *(json.dumps(value) if isinstance(value, bool) else str(value) for value in params),
                                        '--rpc-url', args.rpc_url], capture=True))

    def nonce():
        return int(bootstrap.run([cast, 'nonce', owner, '--rpc-url', args.rpc_url], capture=True))

    anchor = rpc('eth_getBlockByNumber', hex(data['startBlock']), False)
    if not anchor or state.get('anchorHash', anchor['hash']) != anchor['hash']:
        parser.error('Deployment block changed; activity journal cannot be reused after a chain reset.')
    state['anchorHash'] = anchor['hash']
    for previous in state['transactions']:
        for receipt in previous.get('receipts', []):
            live = rpc('eth_getTransactionReceipt', receipt['hash'])
            if not live or number(live['status']) != 1:
                parser.error('A journal receipt is no longer canonical; reconcile before continuing.')
        for receipt in previous.get('failedReceipts', []):
            live = rpc('eth_getTransactionReceipt', receipt['hash'])
            if not live or number(live['status']) != 0:
                parser.error('A reconciled failed receipt changed; inspect the journal before continuing.')

    def phase(name, label, task_env, signature=None):
        entry = {'task': label, 'round': state['nextRound'], 'status': 'started', 'startNonce': nonce()}
        state['transactions'].append(entry)
        save(state_path, state)
        log = state_path.with_name(f'{state_path.stem}-{len(state["transactions"])}.log')
        command = [forge, 'script', PREFIX + name + '.s.sol:' + name.split('/')[-1] + 'Script',
                   '--rpc-url', args.rpc_url, '--no-isolate', '--non-interactive',
                   '--disable-external-identification', '--gas-estimate-multiplier', '200',
                   *runtime, '--broadcast', '--slow', *wallet]
        if signature:
            command += ['--sig', signature]
        try:
            with log.open('w') as output:
                subprocess.run(command, cwd=ROOT, env={**env, **task_env}, check=True,
                               stdout=output, stderr=subprocess.STDOUT, text=True)
            entry['endNonce'] = nonce()
            artifact_path = ROOT / 'broadcast' / (name.split('/')[-1] + '.s.sol') / str(chain_id) / artifact_name(signature)
            artifact = json.loads(artifact_path.read_text()) if entry['endNonce'] > entry['startNonce'] else {}
            receipts = record_receipts(entry, artifact, owner,
                                       lambda tx: rpc('eth_getTransactionReceipt', tx))
            entry['status'] = 'mined'
            entry['log'] = str(log.relative_to(ROOT))
            save(state_path, state)
            return receipts
        except (subprocess.CalledProcessError, OSError, ValueError, KeyError) as error:
            entry['status'] = 'needs-reconciliation'
            entry['log'] = str(log.relative_to(ROOT))
            save(state_path, state)
            raise SystemExit(f'{label} stopped; inspect {log} and reconcile the journal before retrying: {error}') from error

    completed = 0
    refresh_on_start = True
    while completed < args.batches:
        round_index = state['nextRound']
        if refresh_on_start or not state.get('maintenanceComplete'):
            if args.advance_local_time and state['nextTask'] == 0 and not state.get('maintenanceComplete'):
                rpc('evm_increaseTime', args.advance_local_time)
                rpc('evm_mine')
            maintenance_path = state_path.with_name(state_path.stem + '-result.json')
            state['activeTask'] = 'maintenance'
            save(state_path, state)
            receipts = phase('activity/MaintenanceActivity', 'maintenance', {
                'TESTNET_ACTIVITY_MARKET': '0',
                'TESTNET_ACTIVITY_SEED': str(task_seed(args.seed, round_index, 'maintenance')),
                'TESTNET_ACTIVITY_CURSORS': ','.join(str(state['cursors'].get(f'rwa-{profile}', 0))
                                                    for profile in range(len(catalog))),
                'TESTNET_ACTIVITY_RESULT': str(maintenance_path)})
            result = load_result(maintenance_path)
            state['cursors'].update({f'rwa-{profile}': cursor for profile, cursor in enumerate(result['cursors'])})
            state['coverage']['maintenance'] = {'round': round_index, **result, 'minedTransactions': len(receipts)}
            state.update(maintenanceComplete=True, activeTask=None)
            save(state_path, state)
            refresh_on_start = False
            phase('SyncMerkleTestnet',
                  'report-before', request_environment(state))
        print(f'Batch {round_index}: 53 profiles, seven Merkle markets, adapter and account 3F lifecycles.', flush=True)
        ordered = tasks(data, args.seed, round_index)
        for task_index in range(state['nextTask'], len(ordered)):
            label, script, market_index, profile = ordered[task_index]
            state['activeTask'] = label
            save(state_path, state)
            result_path = state_path.with_name(state_path.stem + '-result.json')
            result_path.unlink(missing_ok=True)
            task_env = {'TESTNET_ACTIVITY_MARKET': str(market_index),
                        'TESTNET_ACTIVITY_SEED': str(task_seed(args.seed, round_index, label)),
                        'TESTNET_ACTIVITY_CURSOR': str(state['cursors'].get(label, 0)),
                        'TESTNET_ACTIVITY_RESULT': str(result_path),
                        'TESTNET_ACTIVITY_MIDNIGHT': state['midnight'].get(str(market_index), ''),
                        'TESTNET_MERKLE_THREEF_REQUESTS': ','.join(state.get('merkleRequests', {}).get(str(market_index), []))}
            if profile is not None:
                task_env['TESTNET_ACTIVITY_PROFILE'] = str(profile)
            receipts = phase('activity/' + script, label, task_env)
            result = load_result(result_path)
            if script == 'ThreeFActivity' and result.get('request', ZERO).lower() != ZERO:
                finalized = result['settled']
                prepared_cursor = result['nextCursor']
                request = result['request']
                maker = data['markets'][market_index]['threeFAdapter']
                amount = result['amount']
                expiration = bootstrap.run([cast, 'call', request, 'maturity()(uint48)', '--rpc-url', args.rpc_url], capture=True).split()[0]
                offer = f'({maker},{amount},{amount//100},0,{expiration},true)'
                digest = bootstrap.run([cast, 'call', request,
                                        'offerDigest((address,uint256,uint256,uint256,uint256,bool))(bytes32)',
                                        offer, '--rpc-url', args.rpc_url], capture=True)
                signed = bootstrap.run([cast, 'wallet', 'sign', '--no-hash', *wallet, digest], capture=True)
                task_env.update(TESTNET_ACTIVITY_REQUEST=request, TESTNET_ACTIVITY_AMOUNT=str(amount),
                                TESTNET_ACTIVITY_SIGNATURE=signed)
                receipts += phase('activity/' + script, label + '-consume', task_env, 'runConsume()')
                result = load_result(result_path)
                result['settled'] += finalized
                result['nextCursor'] = prepared_cursor
            if result.get('executed') and not receipts:
                raise SystemExit(f'{label} reported execution without mined transactions.')
            if result.get('midnightParams'):
                state['midnight'][str(market_index)] = result['midnightParams']
            if script == 'MerkleThreeFActivity' and result.get('request', ZERO).lower() != ZERO:
                requests = state.setdefault('merkleRequests', {}).setdefault(str(market_index), [])
                if not any(bootstrap.same_address(request, result['request']) for request in requests):
                    requests.append(result['request'])
            state['cursors'][label] = result['nextCursor']
            state['coverage'][label] = {'round': round_index, **result, 'minedTransactions': len(receipts)}
            state['nextTask'] = task_index + 1
            state['activeTask'] = None
            save(state_path, state)
            print(f'{label}: {len(receipts)} mined, {result["settled"]} settled'
                  + (f'; waiting: {result["waiting"]}' if result['waiting'] else ''), flush=True)
        phase('SyncMerkleTestnet',
              'report-after', request_environment(state))
        state.update(nextRound=round_index + 1, nextTask=0, maintenanceComplete=False)
        save(state_path, state)
        completed += 1
        print(f'Batch {round_index} complete; receipt journal: {state_path}', flush=True)


if __name__ == '__main__':
    main()
