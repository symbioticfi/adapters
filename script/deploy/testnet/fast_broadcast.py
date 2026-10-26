"""Prepare gas on an isolated fork, then resume Foundry's durable batched broadcast."""
import contextlib
import copy
import fcntl
import hashlib
import json
import os
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import bootstrap


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(value, stream)
        stream.write('\n')
    temporary.replace(path)


@contextlib.contextmanager
def writer_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError('A deployment writer is still running. Stop it with Ctrl-C before resuming.') from error
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


class Rpc:
    def __init__(self, url):
        self.url = url

    def request(self, payload):
        request = urllib.request.Request(self.url, data=json.dumps(payload).encode(),
                                         headers={'Content-Type': 'application/json'})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=45) as response:
                    return json.load(response)
            except (urllib.error.URLError, TimeoutError) as error:
                if attempt == 3:
                    raise ValueError('RPC request failed; endpoint details are omitted.') from error
                time.sleep(2**attempt)

    def call(self, method, params):
        for attempt in range(4):
            response = self.request({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
            if 'error' not in response:
                return response['result']
            message = response['error'].get('message', 'unknown error')
            if attempt == 3 or not any(word in message.lower() for word in ('rate limit', 'too many requests', 'temporarily unavailable')):
                raise ValueError(f'RPC {method} failed: {message}')
            print(f'Provider throttled {method}; retrying the same request.', flush=True)
            time.sleep(2**attempt)

    def batch(self, calls):
        results = []
        last_update = time.monotonic()
        for offset in range(0, len(calls), 32):
            chunk = calls[offset:offset + 32]
            response = self.request([{'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params}
                                     for i, (method, params) in enumerate(chunk)])
            if not isinstance(response, list):
                # Some providers disable JSON-RPC batching.
                results.extend(self.call(method, params) for method, params in chunk)
                continue
            indexed = {item['id']: item for item in response}
            for i, (method, params) in enumerate(chunk):
                item = indexed.get(i, {})
                if 'result' not in item:
                    if 'error' not in item:
                        raise ValueError(f'RPC batch {method} omitted a response.')
                    results.append(self.call(method, params))
                else:
                    results.append(item['result'])
            if time.monotonic() - last_update >= 10:
                print(f'RPC reads completed: {len(results)}/{len(calls)}.', flush=True)
                last_update = time.monotonic()
        return results


def load_sequence(public, sensitive):
    recovery = sensitive.with_name(sensitive.name + '.recovery.json')
    pending = recovery.with_suffix('.pending')
    if pending.exists() or recovery.exists():
        snapshot = json.loads((pending if pending.exists() else recovery).read_text())
        if (snapshot['version'] != 1 or snapshot['multi'] or snapshot['batch']
                or snapshot['data']['kind'] != 'single' or len(snapshot['deployments']) != 1):
            raise ValueError('Unsupported Foundry recovery snapshot; expected one ordinary deployment.')
        sequence = snapshot['data']['sequence']
        if sequence['recovery_generation'] != snapshot['generation']:
            raise ValueError('Recovery snapshot has mismatched generations.')
        return sequence, snapshot['deployments'][0].get('attempts', [])
    sequence = json.loads(public.read_text())
    cache = json.loads(sensitive.read_text())
    if (sequence.get('recovery_generation') != cache.get('recovery_generation')
            or len(sequence['transactions']) != len(cache['transactions'])):
        raise ValueError('Broadcast and sensitive cache do not match.')
    return sequence, []


def validate_sequence(sequence, owner, chain_id):
    if sequence['chain'] != chain_id or not sequence['transactions']:
        raise ValueError('Saved deployment has the wrong chain or no transactions.')
    first = number(sequence['transactions'][0]['transaction']['nonce'])
    for index, item in enumerate(sequence['transactions']):
        tx = item['transaction']
        if (not bootstrap.same_address(tx.get('from'), owner)
                or number(tx['nonce']) != first + index
                or number(tx.get('chainId', chain_id)) != chain_id
                or tx.get('authorizationList')):
            raise ValueError('Fast deployment requires one owner, contiguous nonces and the configured chain.')


def stage_sequence(sequence, rpc_url, public, sensitive):
    sequence = copy.deepcopy(sequence)
    sequence['recovery_generation'] = None
    for item in sequence['transactions']:
        item.pop('rpc', None)
    write_json(public, sequence)
    write_json(sensitive, {'transactions': [{'rpc': rpc_url} for _ in sequence['transactions']],
                           'recovery_generation': None})


def bind_manifest(sequence, path):
    manifest = json.loads(path.read_text())
    planned = {item['contractAddress'].lower() for item in sequence['transactions']
               if item.get('transactionType') in ('CREATE', 'CREATE2') and item.get('contractAddress')}
    for item in sequence['transactions']:
        planned.update(contract['address'].lower() for contract in item.get('additionalContracts', []))
    if manifest['vaultFactory'].lower() not in planned:
        raise ValueError('The manifest does not belong to this saved deployment plan.')
    destinations = {(item['transaction'].get('to') or '').lower() for item in sequence['transactions']}
    calldata = [item['transaction'].get('input', '0x').lower() for item in sequence['transactions']]
    for market in manifest['markets']:
        for key in ('vault', 'account', 'merkleAdapter'):
            address = market[key].lower()
            # --skip-simulation omits internal CREATE metadata; factory outputs still appear
            # as subsequent call targets or ABI address words in configuration calls.
            if (address not in planned and address not in destinations
                    and not any('0' * 24 + address[2:] in data for data in calldata)):
                raise ValueError('The manifest does not belong to this saved deployment plan.')


def manifest_contracts(path):
    data = json.loads(path.read_text())
    owner = data['owner'].lower()
    addresses = set()
    for values in [data, *data['markets']]:
        for key, value in values.items():
            if key == 'reportPublisher':
                continue
            for item in value if isinstance(value, list) else [value]:
                if bootstrap.address(item) and item.lower() != owner:
                    addresses.add(item.lower())
    return addresses


def check_transaction(actual, planned):
    if actual is None or not bootstrap.same_address(actual.get('from'), planned['from']):
        raise ValueError('Canonical transaction does not match the deployment sender.')
    for key in ('nonce', 'value', 'chainId'):
        if number(actual.get(key, 0)) != number(planned.get(key, 0)):
            raise ValueError(f'Canonical transaction differs in {key}.')
    if ((actual.get('to') or '').lower() != (planned.get('to') or '').lower()
            or actual.get('input', '0x').lower() != planned.get('input', '0x').lower()):
        raise ValueError('Canonical transaction calldata or destination differs from the saved plan.')


def reconcile(sequence, attempts, rpc, cast):
    result = copy.deepcopy(sequence)
    transactions = result['transactions']
    payloads = {}
    for attempt in attempts:
        members = attempt['members']
        kind = attempt['kind']
        if len(members) != 1 or members[0]['sequence'] != 0 or kind['kind'] not in ('signed', 'legacy'):
            raise ValueError('Unsupported recovery attempt; expected one signed owner transaction.')
        index = members[0]['index']
        if not 0 <= index < len(transactions):
            raise ValueError('Recovery attempt is outside the transaction plan.')
        tx_hash = kind['payload']['hash'] if kind['kind'] == 'signed' else kind['hash']
        existing = transactions[index].get('hash')
        if existing and existing.lower() != tx_hash.lower():
            raise ValueError('Saved transaction and signed recovery attempt have different hashes.')
        transactions[index]['hash'] = tx_hash
        if kind['kind'] == 'signed':
            payloads[tx_hash] = kind['payload']['payload']
    indices = [i for i, tx in enumerate(transactions) if tx.get('hash')]
    known = {transactions[i]['hash'].lower() for i in indices}
    if any(tx_hash.lower() not in known for tx_hash in result.get('pending', [])):
        raise ValueError('Saved pending hash is not bound to a deployment operation.')
    receipts = rpc.batch([('eth_getTransactionReceipt', [transactions[i]['hash']]) for i in indices])
    canonical = rpc.batch([('eth_getTransactionByHash', [transactions[i]['hash']]) for i in indices])
    submissions = []
    expected_hashes = []
    for position, index in enumerate(indices):
        item = transactions[index]
        tx_hash = item['hash']
        if receipts[position] is None:
            if canonical[position] is None:
                raw = payloads.get(tx_hash)
                if raw is None:
                    raise ValueError(f'Transaction {index} has an unknown outcome and no durable signed payload.')
                decoded = subprocess.run([cast, 'decode-transaction', '--json'], input=raw, text=True,
                                         capture_output=True, check=True)
                decoded = json.loads(decoded.stdout)
                decoded = decoded.get('data', decoded)
                decoded['from'] = decoded['signer']
                check_transaction(decoded, item['transaction'])
                if decoded['hash'].lower() != tx_hash.lower():
                    raise ValueError('Durable signed payload does not match its saved hash.')
                # Replay exactly the already signed payload; never replace an uncertain submission.
                submissions.append(('eth_sendRawTransaction', [raw]))
                expected_hashes.append(tx_hash.lower())
            else:
                check_transaction(canonical[position], item['transaction'])
    if submissions:
        print(f'Resubmitting {len(submissions)} existing signed payloads without replacing them.', flush=True)
        submitted = rpc.batch(submissions)
        if [tx_hash.lower() for tx_hash in submitted] != expected_hashes:
            raise ValueError('RPC returned a different hash for an existing signed transaction.')
    waiting = [i for i, receipt in enumerate(receipts) if receipt is None]
    refresh = waiting.copy()
    deadline = time.monotonic() + 180
    last_update = 0
    while waiting and time.monotonic() < deadline:
        if time.monotonic() - last_update >= 10:
            print(f'Waiting for {len(waiting)} existing transactions before fork preparation.', flush=True)
            last_update = time.monotonic()
        time.sleep(2)
        updated = rpc.batch([('eth_getTransactionReceipt', [transactions[indices[i]]['hash']]) for i in waiting])
        for position, receipt in zip(waiting, updated):
            receipts[position] = receipt
        waiting = [i for i in waiting if receipts[i] is None]
    if waiting:
        raise ValueError('Existing signed transactions are still pending. Retry the same fast resume command later.')
    refreshed = rpc.batch([('eth_getTransactionByHash', [transactions[indices[i]]['hash']]) for i in refresh])
    for position, actual in zip(refresh, refreshed):
        canonical[position] = actual
    for position, index in enumerate(indices):
        item = transactions[index]
        tx_hash = item['hash']
        check_transaction(canonical[position], item['transaction'])
        receipt = receipts[position]
        if (number(receipt['status']) != 1 or receipt['transactionHash'].lower() != tx_hash.lower()
                or not bootstrap.same_address(receipt.get('from'), item['transaction']['from'])):
            raise ValueError(f'Deployment transaction {index} has no matching successful canonical receipt.')
        if item.get('transactionType') == 'CREATE' and not bootstrap.same_address(
                receipt.get('contractAddress'), item.get('contractAddress')):
            raise ValueError(f'Canonical creation address differs at transaction {index}.')
    if indices != list(range(len(indices))):
        raise ValueError('Confirmed deployment operations are not a contiguous nonce prefix.')
    owner = transactions[0]['transaction']['from']
    block = rpc.call('eth_getBlockByNumber', ['latest', False])
    expected = number(transactions[0]['transaction']['nonce']) + len(indices)
    latest = number(rpc.call('eth_getTransactionCount', [owner, block['number']]))
    pending = number(rpc.call('eth_getTransactionCount', [owner, 'pending']))
    if latest != expected or pending != expected:
        raise ValueError('Owner has an unaccounted mined or pending nonce. Stop other owner transactions before resuming.')
    if any(number(receipt['blockNumber']) > number(block['number']) for receipt in receipts):
        raise ValueError('RPC returned receipts beyond the fork block; retry with a consistent endpoint.')
    result.update(receipts=receipts, pending=[])
    print(f'Canonical deployment progress: {len(indices)}/{len(transactions)} successful transactions.', flush=True)
    return result, block, len(indices)


class LocalFork:
    def __init__(self, url, block, chain_id, owner, cups=2500):
        self.url, self.block, self.chain_id, self.owner = url, block, chain_id, owner
        if cups <= 0:
            raise ValueError('TESTNET_FORK_CUPS must be positive.')
        self.cups = cups
        self.process = None

    def __enter__(self):
        anvil = Path(bootstrap.tools()[0]).with_name('anvil')
        if not anvil.is_file():
            raise ValueError('Foundry 1.8.5 Anvil is required for fork gas preparation.')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        self.rpc = Rpc(f'http://127.0.0.1:{port}')
        self.process = subprocess.Popen([str(anvil), '--host', '127.0.0.1', '--port', str(port),
                                         '--fork-url', self.url, '--fork-block-number', str(self.block),
                                         '--chain-id', str(self.chain_id), '--compute-units-per-second', str(self.cups),
                                         '--no-fork-node-info', '--silent'],
                                        cwd=bootstrap.ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 45
        try:
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise ValueError('Local Anvil fork failed to start.')
                try:
                    request = urllib.request.Request(self.rpc.url, data=json.dumps(
                        {'jsonrpc': '2.0', 'id': 1, 'method': 'eth_chainId', 'params': []}).encode(),
                        headers={'Content-Type': 'application/json'})
                    with urllib.request.urlopen(request, timeout=1) as response:
                        if number(json.load(response)['result']) != self.chain_id:
                            raise ValueError('Local fork has the wrong chain ID.')
                    self.rpc.call('anvil_impersonateAccount', [self.owner])
                    # Local gas-price defaults can exhaust an owner funded for much cheaper Sepolia fees.
                    # Only the fork uses zero fees; the public broadcast estimates its own EIP-1559 fees.
                    self.rpc.call('anvil_setNextBlockBaseFeePerGas', ['0x0'])
                    self.rpc.call('evm_mine', [])
                    return self.rpc
                except (urllib.error.URLError, TimeoutError):
                    time.sleep(0.1)
            raise ValueError('Local fork did not start within 45 seconds.')
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *_):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


def replay_gas(sequence, local, start, gas_multiplier=130):
    result = copy.deepcopy(sequence)
    owner = result['transactions'][0]['transaction']['from']
    expected = number(result['transactions'][0]['transaction']['nonce']) + start
    if number(local.call('eth_getTransactionCount', [owner, 'latest'])) != expected:
        raise ValueError('Fork owner nonce does not match the remaining saved deployment.')
    beginning = time.monotonic()
    last_update = beginning
    for index in range(start, len(result['transactions'])):
        item = result['transactions'][index]
        tx = copy.deepcopy(item['transaction'])
        for key in ('gasPrice', 'maxFeePerGas', 'maxPriorityFeePerGas', 'type'):
            tx.pop(key, None)
        tx['gasPrice'] = '0x0'
        if not item.get('isFixedGasLimit'):
            tx.pop('gas', None)
        estimated = number(local.call('eth_estimateGas', [tx]))
        if not item.get('isFixedGasLimit'):
            tx['gas'] = hex((estimated * gas_multiplier + 99) // 100)
            item['transaction']['gas'] = tx['gas']
        elif not tx.get('gas'):
            raise ValueError('An explicit gas budget is missing from the saved transaction.')
        tx_hash = local.call('eth_sendTransaction', [tx])
        deadline = time.monotonic() + 30
        receipt = local.call('eth_getTransactionReceipt', [tx_hash])
        while receipt is None and time.monotonic() < deadline:
            time.sleep(0.05)
            receipt = local.call('eth_getTransactionReceipt', [tx_hash])
        if receipt is None or number(receipt['status']) != 1:
            raise ValueError(f'Fork replay transaction {index} failed; no public broadcast has started.')
        if item.get('transactionType') == 'CREATE' and not bootstrap.same_address(
                receipt.get('contractAddress'), item.get('contractAddress')):
            raise ValueError(f'Fork creation address differs at transaction {index}.')
        if item.get('transactionType') in ('CREATE', 'CREATE2'):
            if local.call('eth_getCode', [item['contractAddress'], 'latest']) == '0x':
                raise ValueError(f'Fork deployment has no code at transaction {index}.')
        if time.monotonic() - last_update >= 10:
            print(f'Gas prepared: {index - start + 1}/{len(result["transactions"]) - start} '
                  f'({time.monotonic() - beginning:.0f}s)', flush=True)
            last_update = time.monotonic()
    print(f'Fork gas preparation completed in {time.monotonic() - beginning:.1f}s.', flush=True)
    return result


def warm_accounts(sequence, local, start, *, remote, block, extra_addresses=()):
    addresses = set(extra_addresses)
    for item in sequence['transactions'][start:]:
        for address in (item['transaction'].get('to'), item.get('contractAddress')):
            if bootstrap.address(address):
                addresses.add(address.lower())
        addresses.update(contract['address'].lower() for contract in item.get('additionalContracts', []))
    print(f'Preparing the fork account cache for {len(addresses)} addresses.', flush=True)
    addresses = sorted(addresses)
    balances = remote.batch([('eth_getBalance', [address, block]) for address in addresses])
    # Identity writes retain nonce, bytecode and lazy fork storage, while caching account info
    # in Anvil's working database instead of repeatedly fetching it during cloned gas estimates.
    local.batch([('anvil_setBalance', [address, balance]) for address, balance in zip(addresses, balances)])


def broadcast(command, wallet, env, manifest, *, resume=False):
    forge, cast = bootstrap.tools()
    rpc_url, owner = env['TESTNET_RPC_URL'], env['TESTNET_OWNER']
    rpc = Rpc(rpc_url)
    chain_id = number(rpc.call('eth_chainId', []))
    if chain_id not in (bootstrap.LOCAL_CHAIN_ID, bootstrap.SEPOLIA_CHAIN_ID):
        raise ValueError('Fast broadcasting supports only local Anvil and Sepolia.')
    config = json.loads(bootstrap.run([forge, 'config', '--json'], env=env, capture=True))
    broadcast_root = (bootstrap.ROOT / config['broadcast']).resolve()
    cache_root = (bootstrap.ROOT / config['cache_path']).resolve()
    if not broadcast_root.is_relative_to(bootstrap.ROOT) or not cache_root.is_relative_to(bootstrap.ROOT):
        raise ValueError('Fast broadcast and cache directories must be inside the repository.')
    filename = Path(command[2].split(':')[0]).name
    common = Path(filename) / str(chain_id) / 'run-latest.json'
    scope = hashlib.sha256(str(manifest).encode()).hexdigest()[:16]
    pointer = cache_root / 'testnet-fast' / scope / filename / 'latest.json'
    with writer_lock(cache_root / 'testnet-fast' / f'{chain_id}-{owner.lower()}.lock'):
        generation = uuid.uuid4().hex
        target_broadcast = broadcast_root / 'testnet-fast' / scope / generation
        target_cache = cache_root / 'testnet-fast' / scope / generation
        target_cache.mkdir(parents=True, mode=0o700)
        # Reuse compiler metadata and the unchanged output directory; do not rebuild the entire IR project.
        compiler_cache = cache_root / 'solidity-files-cache.json'
        if compiler_cache.exists():
            shutil.copy2(compiler_cache, target_cache / compiler_cache.name)
        target_env = env.copy()
        target_env.update(FOUNDRY_BROADCAST=str(target_broadcast), FOUNDRY_CACHE_PATH=str(target_cache))
        if resume:
            if pointer.exists():
                saved = json.loads(pointer.read_text())
                if (saved['chainId'] != chain_id or not bootstrap.same_address(saved['owner'], owner)
                        or saved['manifest'] != str(manifest)):
                    raise ValueError('Fast recovery pointer does not match the deployment manifest.')
                source_public = Path(saved.get('sourcePublic', str(Path(saved['broadcastRoot']) / common)))
                source_sensitive = Path(saved.get('sourceSensitive', str(Path(saved['cacheRoot']) / common)))
                if not source_public.is_relative_to(broadcast_root) or not source_sensitive.is_relative_to(cache_root):
                    raise ValueError('Fast recovery pointer is outside the configured artifact directories.')
            else:
                source_public, source_sensitive = broadcast_root / common, cache_root / common
        else:
            print('Generating the transaction plan without public broadcasting.', flush=True)
            bootstrap.run([*command, '--skip-simulation', '--sender', owner], env=target_env)
            dry_common = Path(filename) / str(chain_id) / 'dry-run' / 'run-latest.json'
            source_public, source_sensitive = target_broadcast / dry_common, target_cache / dry_common
        recovery = source_sensitive.with_name(source_sensitive.name + '.recovery.json')
        with writer_lock(source_public.with_suffix('.recovery.lock')), writer_lock(recovery.with_suffix('.lock')):
            sequence, attempts = load_sequence(source_public, source_sensitive)
            validate_sequence(sequence, owner, chain_id)
            if filename == 'DeployRealisticTestnet.s.sol':
                bind_manifest(sequence, manifest)
            backup = target_cache / 'source-backup'
            backup.mkdir(mode=0o700)
            for label, path in (('broadcast.json', source_public), ('sensitive.json', source_sensitive),
                                ('recovery.json', recovery), ('recovery.pending', recovery.with_suffix('.pending'))):
                if path.exists():
                    shutil.copy2(path, backup / label)
                    (backup / label).chmod(0o600)
            write_json(pointer, {'chainId': chain_id, 'owner': owner, 'manifest': str(manifest),
                                 'broadcastRoot': str(target_broadcast), 'cacheRoot': str(target_cache),
                                 'sourcePublic': str(source_public), 'sourceSensitive': str(source_sensitive),
                                 'status': 'planning'})
            sequence, block, start = reconcile(sequence, attempts, rpc, cast)
            if start == len(sequence['transactions']):
                print('Deployment is already complete; every saved transaction has a successful receipt.', flush=True)
                return
            beginning = time.monotonic()
            required_contracts = manifest_contracts(manifest) if filename == 'DeployRealisticTestnet.s.sol' else set()
            fork_block, replay_start = block, start
            if filename == 'DeployRealisticTestnet.s.sol' and env.get('TESTNET_FAST_FORK_LATEST') != '1':
                original_block = number(json.loads(manifest.read_text())['startBlock'])
                fork_block = rpc.call('eth_getBlockByNumber', [hex(original_block), False])
                if fork_block is None or original_block > number(block['number']):
                    raise ValueError('Original deployment block is unavailable; use TESTNET_FAST_FORK_LATEST=1 for latest-state planning.')
                replay_start = 0
                print(f'Replaying the complete plan from original block {original_block}; '
                      'confirmed transactions will only execute on the local fork.', flush=True)
            with LocalFork(rpc_url, number(fork_block['number']), chain_id, owner,
                           cups=number(env.get('TESTNET_FORK_CUPS', 2500))) as local:
                warm_accounts(sequence, local, replay_start, remote=rpc,
                              block=fork_block['number'], extra_addresses=required_contracts)
                prepared = replay_gas(sequence, local, replay_start)
                if replay_start < start:
                    prepared['transactions'][:start] = copy.deepcopy(sequence['transactions'][:start])
                if required_contracts:
                    codes = local.batch([('eth_getCode', [address, 'latest']) for address in sorted(required_contracts)])
                    if any(code in (None, '0x', '0x00') for code in codes):
                        raise ValueError('A manifest contract has no code after fork replay; public broadcasting has not started.')
            # Reject concurrent owner activity or a reorg before signing the new suffix.
            canonical_block = rpc.call('eth_getBlockByNumber', [fork_block['number'], False])
            if canonical_block is None or canonical_block['hash'] != fork_block['hash']:
                raise ValueError('Fork block was reorganized. Retry the same fast resume command.')
            reconcile(prepared, [], rpc, cast)
            fee = number(rpc.call('eth_gasPrice', []))
            remaining = prepared['transactions'][start:]
            budget = sum(number(item['transaction']['gas']) * fee
                         + number(item['transaction'].get('value', 0)) for item in remaining)
            if number(rpc.call('eth_getBalance', [owner, 'latest'])) < budget:
                raise ValueError(f'Owner needs at least {budget} wei at the current gas price for the remaining plan.')
            public, sensitive = target_broadcast / common, target_cache / common
            stage_sequence(prepared, rpc_url, public, sensitive)
            saved = {'chainId': chain_id, 'owner': owner, 'manifest': str(manifest),
                     'broadcastRoot': str(target_broadcast), 'cacheRoot': str(target_cache),
                     'sourcePublic': str(public), 'sourceSensitive': str(sensitive),
                     'forkBlock': number(fork_block['number']), 'forkBlockHash': fork_block['hash'],
                     'preparedTransactions': len(prepared['transactions']) - start,
                     'replayedTransactions': len(prepared['transactions']) - replay_start,
                     'gasPreparationSeconds': round(time.monotonic() - beginning, 2), 'status': 'prepared'}
            write_json(pointer, saved)
            print(f'Broadcasting {saved["preparedTransactions"]} remaining transactions in Foundry batches of 100.', flush=True)
            try:
                bootstrap.run([*command, '--resume', '--broadcast', *wallet], env=target_env)
            except subprocess.CalledProcessError:
                raise ValueError('Fast broadcast was interrupted or failed. Preserve the artifacts and retry with --fast --resume.') from None
            final, final_attempts = load_sequence(public, sensitive)
            final, confirmed_block, completed = reconcile(final, final_attempts, rpc, cast)
            if completed != len(final['transactions']):
                raise ValueError('Fast broadcast did not confirm every planned transaction.')
            contracts = {item['contractAddress'] for item in final['transactions']
                         if item.get('transactionType') in ('CREATE', 'CREATE2')}
            contracts.update(required_contracts)
            for item in final['transactions']:
                contracts.update(contract['address'] for contract in item.get('additionalContracts', []))
            codes = rpc.batch([('eth_getCode', [contract, confirmed_block['number']]) for contract in contracts])
            if any(code in (None, '0x', '0x00') for code in codes):
                raise ValueError('A confirmed deployment address has no runtime code.')
            saved['status'] = 'complete'
            write_json(pointer, saved)
            print(f'Fast broadcast verified: {completed} successful receipts and {len(contracts)} deployed contracts.', flush=True)
