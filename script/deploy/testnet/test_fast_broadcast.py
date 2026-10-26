"""Recovery and gas-planning checks without a wallet or public-chain writes."""
import copy
import importlib.util
import json
import io
import inspect
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

PATH = Path(__file__).with_name('fast_broadcast.py')
FAST = None
if PATH.exists():
    SPEC = importlib.util.spec_from_file_location('fast_broadcast', PATH)
    FAST = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(FAST)
OWNER = '0x' + '11' * 20
TARGET = '0x' + '22' * 20
BLOCK_HASH = '0x' + 'bb' * 32


def plan(count=3):
    return {'chain': 11155111, 'transactions': [{
        'hash': None, 'transactionType': 'CALL', 'contractAddress': TARGET,
        'transaction': {'from': OWNER, 'to': TARGET, 'nonce': hex(i),
                        'chainId': hex(11155111), 'input': '0x1234', 'value': '0x0'},
        'isFixedGasLimit': False,
    } for i in range(count)], 'receipts': [], 'pending': [], 'recovery_generation': None}


class LocalRpc:
    def __init__(self, nonce=0, status=1):
        self.nonce = nonce
        self.status = status
        self.sent = []

    def call(self, method, params):
        if method == 'eth_getTransactionCount':
            return hex(self.nonce)
        if method == 'eth_estimateGas':
            if int(params[0]['nonce'], 0) != self.nonce:
                raise ValueError('Out-of-order gas estimation.')
            return hex(8_000_000)
        if method == 'eth_sendTransaction':
            self.sent.append(copy.deepcopy(params[0]))
            self.nonce += 1
            return '0x' + f'{self.nonce:064x}'
        if method == 'eth_getTransactionReceipt':
            return {'status': hex(self.status), 'gasUsed': hex(7_000_000), 'contractAddress': None}
        if method == 'eth_getCode':
            return '0x6000'
        raise AssertionError(method)


class PublicRpc:
    def __init__(self, sequence, count=1):
        self.sequence = sequence
        self.count = count
        self.status = 1
        self.foreign_pending = False
        self.wrong_input = False

    def batch(self, calls):
        return [self.call(method, params) for method, params in calls]

    def call(self, method, params):
        if method == 'eth_getBlockByNumber':
            return {'number': '0x10', 'hash': BLOCK_HASH, 'gasLimit': hex(200_000_000)}
        if method == 'eth_getTransactionCount':
            return hex(self.count + (1 if self.foreign_pending and params[1] == 'pending' else 0))
        if method in ('eth_getTransactionByHash', 'eth_getTransactionReceipt'):
            tx = copy.deepcopy(self.sequence['transactions'][0]['transaction'])
            if method == 'eth_getTransactionByHash':
                tx.update(hash=params[0], input='0xabcd' if self.wrong_input else tx['input'])
                return tx
            return {'transactionHash': params[0], 'from': OWNER, 'to': TARGET,
                    'status': hex(self.status), 'blockNumber': '0xf', 'blockHash': BLOCK_HASH}
        raise AssertionError(method)


class FastBroadcastTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(FAST, 'Fast deployment and recovery helper has not been implemented.')
        if 'reconcile' in self._testMethodName:
            self.assertTrue(callable(getattr(FAST, 'reconcile', None)), 'Canonical recovery is not implemented.')

    def test_gas_replay_preserves_calldata_addresses_and_nonce_order(self):
        source = plan()
        source['transactions'][0]['hash'] = '0x' + 'aa' * 32
        rpc = LocalRpc(nonce=1)
        result = FAST.replay_gas(source, rpc, 1)
        self.assertEqual(len(rpc.sent), 2)
        self.assertEqual(source['transactions'][1]['transaction'].get('gas'), None)
        self.assertEqual(result['transactions'][0], source['transactions'][0])
        for index, sent in enumerate(rpc.sent, 1):
            self.assertEqual(int(sent['gas'], 0), 10_400_000)
            self.assertEqual(sent.get('gasPrice'), '0x0', 'Fork planning must not spend the real owner gas budget.')
            for key in ('from', 'to', 'nonce', 'input', 'value'):
                self.assertEqual(sent[key], source['transactions'][index]['transaction'][key])
            self.assertEqual(result['transactions'][index]['transaction']['gas'], sent['gas'])

    def test_gas_replay_stops_at_first_failed_receipt(self):
        rpc = LocalRpc(status=0)
        with self.assertRaisesRegex(ValueError, 'replay.*failed'):
            FAST.replay_gas(plan(), rpc, 0)
        self.assertEqual(len(rpc.sent), 1)

    def test_fixed_gas_budget_is_preserved(self):
        source = plan(1)
        source['transactions'][0].update(isFixedGasLimit=True)
        source['transactions'][0]['transaction']['gas'] = hex(9_000_000)
        rpc = LocalRpc()
        result = FAST.replay_gas(source, rpc, 0)
        self.assertEqual(result['transactions'][0]['transaction']['gas'], hex(9_000_000))

    def test_rejects_nonce_gaps_wrong_owner_and_chain(self):
        for change in ('nonce', 'owner', 'chain'):
            source = plan()
            if change == 'nonce':
                source['transactions'][1]['transaction']['nonce'] = '0x4'
            elif change == 'owner':
                source['transactions'][1]['transaction']['from'] = TARGET
            else:
                source['chain'] = 1
            with self.subTest(change=change), self.assertRaises(ValueError):
                FAST.validate_sequence(source, OWNER, 11155111)

    def test_authoritative_recovery_snapshot_overrides_stale_mirrors(self):
        with tempfile.TemporaryDirectory() as directory:
            public = Path(directory) / 'broadcast/run-latest.json'
            sensitive = Path(directory) / 'cache/run-latest.json'
            public.parent.mkdir(); sensitive.parent.mkdir()
            public.write_text(json.dumps(plan(1)))
            sensitive.write_text('{}')
            source = plan(3)
            source['recovery_generation'] = 'new'
            snapshot = {'version': 1, 'generation': 'new', 'batch': False, 'multi': False,
                        'data': {'kind': 'single', 'sequence': source},
                        'deployments': [{'attempts': []}]}
            sensitive.with_name(sensitive.name + '.recovery.json').write_text(json.dumps(snapshot))
            loaded, attempts = FAST.load_sequence(public, sensitive)
            self.assertEqual(loaded, source)
            self.assertEqual(attempts, [])

    def test_staging_keeps_receipts_and_rpc_out_of_public_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            public = Path(directory) / 'public.json'
            sensitive = Path(directory) / 'sensitive.json'
            source = plan()
            source['receipts'] = [{'transactionHash': 'existing'}]
            source['recovery_generation'] = 'old'
            FAST.stage_sequence(source, 'https://rpc.invalid/credential', public, sensitive)
            saved = json.loads(public.read_text())
            self.assertEqual(saved['receipts'], source['receipts'])
            self.assertIsNone(saved['recovery_generation'])
            self.assertNotIn('credential', public.read_text())
            self.assertEqual(len(json.loads(sensitive.read_text())['transactions']), 3)
            self.assertEqual(sensitive.stat().st_mode & 0o777, 0o600)

    def test_recovery_lock_refuses_an_active_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'writer.lock'
            with FAST.writer_lock(path):
                with self.assertRaisesRegex(ValueError, 'running|writer'):
                    with FAST.writer_lock(path):
                        self.fail('Acquired an active deployment lock.')

    def test_reconcile_retains_canonical_prefix_before_gas_replay(self):
        source = plan()
        source['transactions'][0]['hash'] = '0x' + 'aa' * 32
        result, block, start = FAST.reconcile(source, [], PublicRpc(source), 'unused')
        self.assertEqual(start, 1)
        self.assertEqual(block['hash'], BLOCK_HASH)
        self.assertEqual(len(result['receipts']), 1)
        self.assertEqual(result['pending'], [])
        self.assertEqual(result['transactions'][1:], source['transactions'][1:])

    def test_reconcile_finds_signed_attempt_missing_from_public_mirror(self):
        source = plan()
        tx_hash = '0x' + 'aa' * 32
        attempts = [{'members': [{'sequence': 0, 'index': 0}],
                     'kind': {'kind': 'signed', 'payload': {'hash': tx_hash, 'payload': 'unused'}}}]
        result, _, start = FAST.reconcile(source, attempts, PublicRpc(source), 'unused')
        self.assertEqual(start, 1)
        self.assertEqual(result['transactions'][0]['hash'], tx_hash)

    def test_reconcile_rejects_failed_changed_and_foreign_transactions(self):
        for change in ('status', 'input', 'pending', 'consumed-nonce'):
            source = plan()
            source['transactions'][0]['hash'] = '0x' + 'aa' * 32
            rpc = PublicRpc(source)
            if change == 'status':
                rpc.status = 0
            elif change == 'input':
                rpc.wrong_input = True
            elif change == 'pending':
                rpc.foreign_pending = True
            else:
                rpc.count = 2
            with self.subTest(change=change), self.assertRaises(ValueError):
                FAST.reconcile(source, [], rpc, 'unused')

    def test_reconcile_replays_all_existing_signed_payloads_before_waiting(self):
        source = plan(2)
        hashes = ['0x' + f'{i + 1:064x}' for i in range(2)]
        attempts = [{'members': [{'sequence': 0, 'index': i}],
                     'kind': {'kind': 'signed', 'payload': {'hash': hashes[i], 'payload': str(i)}}}
                    for i in range(2)]
        sent = []

        class RecoveryRpc(PublicRpc):
            def call(self, method, params):
                if method == 'eth_sendRawTransaction':
                    sent.append(params[0])
                    return hashes[int(params[0])]
                if method in ('eth_getTransactionByHash', 'eth_getTransactionReceipt'):
                    if not sent:
                        return None
                    if len(sent) < 2:
                        raise AssertionError('Waited for a receipt before submitting the whole signed batch.')
                    i = hashes.index(params[0])
                    if method == 'eth_getTransactionByHash':
                        return {**source['transactions'][i]['transaction'], 'hash': hashes[i]}
                    return {'transactionHash': hashes[i], 'from': OWNER, 'to': TARGET,
                            'status': '0x1', 'blockNumber': '0xf', 'blockHash': BLOCK_HASH}
                return super().call(method, params)

        def decode(_, *, input, **kwargs):
            i = int(input)
            return SimpleNamespace(stdout=json.dumps({'data': {
                **source['transactions'][i]['transaction'], 'signer': OWNER, 'hash': hashes[i]}}))

        with patch.object(FAST.subprocess, 'run', side_effect=decode), patch.object(FAST.time, 'sleep'):
            result, _, completed = FAST.reconcile(source, attempts, RecoveryRpc(source, count=2), 'cast')
        self.assertEqual(sent, ['0', '1'])
        self.assertEqual(completed, 2)
        self.assertEqual(len(result['receipts']), 2)

    def test_resume_manifest_must_belong_to_the_saved_plan(self):
        source = plan()
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / 'manifest.json'
            manifest.write_text(json.dumps({'vaultFactory': OWNER, 'markets': []}))
            self.assertTrue(callable(getattr(FAST, 'bind_manifest', None)), 'Manifest binding is not implemented.')
            with self.assertRaisesRegex(ValueError, 'manifest'):
                FAST.bind_manifest(source, manifest)

    def test_manifest_binding_accepts_factory_creations_referenced_in_calldata(self):
        source = plan(2)
        source['transactions'][0].update(transactionType='CREATE', contractAddress=OWNER)
        adapter = '0x' + '33' * 20
        source['transactions'][1]['transaction']['input'] = '0x12345678' + '00' * 12 + adapter[2:]
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / 'manifest.json'
            manifest.write_text(json.dumps({'vaultFactory': OWNER, 'markets': [
                {'vault': TARGET, 'account': TARGET, 'merkleAdapter': adapter}]}))
            FAST.bind_manifest(source, manifest)

    def test_planning_fork_does_not_use_anvils_slow_default_rpc_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            anvil = Path(directory) / 'anvil'
            anvil.touch()
            response = io.BytesIO(json.dumps({'result': hex(11155111)}).encode())
            process = SimpleNamespace(poll=lambda: None, terminate=lambda: None, wait=lambda **_: None)
            with patch.object(FAST.bootstrap, 'tools', return_value=(str(anvil.with_name('forge')), 'cast')), \
                    patch.object(FAST.subprocess, 'Popen', return_value=process) as spawn, \
                    patch.object(FAST.urllib.request, 'urlopen', return_value=response), \
                    patch.object(FAST.Rpc, 'call', return_value=None):
                with FAST.LocalFork('https://rpc.invalid', 123, 11155111, OWNER):
                    pass
            command = spawn.call_args.args[0]
            self.assertIn('--compute-units-per-second', command)
            self.assertEqual(command[command.index('--compute-units-per-second') + 1], '2500')
            self.assertNotIn('--hardfork', command)

    def test_resume_can_recover_a_fresh_plan_after_fork_preparation_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = root / 'manifest.json'
            env = {'TESTNET_OWNER': OWNER, 'TESTNET_RPC_URL': 'https://rpc.invalid'}
            command = ['forge', 'script', 'script/Batch.s.sol:Batch']

            def run(argv, *, env, capture=False):
                if argv[1] == 'config':
                    return json.dumps({'broadcast': 'broadcast', 'cache_path': 'cache'})
                common = Path('Batch.s.sol/11155111/dry-run/run-latest.json')
                FAST.stage_sequence(plan(), env['TESTNET_RPC_URL'],
                                    Path(env['FOUNDRY_BROADCAST']) / common,
                                    Path(env['FOUNDRY_CACHE_PATH']) / common)
                manifest.write_text('{}')

            class Rpc(PublicRpc):
                def call(self, method, params):
                    return hex(11155111) if method == 'eth_chainId' else super().call(method, params)

            with patch.object(FAST.bootstrap, 'ROOT', root), \
                    patch.object(FAST.bootstrap, 'tools', return_value=('forge', 'cast')), \
                    patch.object(FAST.bootstrap, 'run', side_effect=run), \
                    patch.object(FAST, 'Rpc', return_value=Rpc(plan(), count=0)), \
                    patch.object(FAST, 'LocalFork') as fork:
                fork.return_value.__enter__.side_effect = ValueError('fork planning stopped')
                with self.assertRaisesRegex(ValueError, 'fork planning stopped'):
                    FAST.broadcast(command, [], env, manifest)
                pointers = list((root / 'cache/testnet-fast').rglob('latest.json'))
                self.assertEqual(len(pointers), 1, 'Fresh plans must be resumable before fork preparation completes.')
                self.assertEqual(json.loads(pointers[0].read_text())['status'], 'planning')
                with self.assertRaisesRegex(ValueError, 'fork planning stopped'):
                    FAST.broadcast(command, [], env, manifest, resume=True)

    def test_warm_accounts_populates_fork_without_changing_canonical_balances(self):
        self.assertIn('remote', inspect.signature(FAST.warm_accounts).parameters,
                      'Fork account preparation must use the canonical pinned state.')
        calls = []

        class Remote:
            def batch(self, requests):
                self_requests = list(requests)
                self.assertions = self_requests
                return ['0x123' for _ in self_requests]

        class Local:
            def batch(self, requests):
                calls.extend(requests)
                return [True for _ in requests]

        remote = Remote()
        FAST.warm_accounts(plan(), Local(), 0, remote=remote, block='0x10')
        self.assertEqual(remote.assertions, [('eth_getBalance', [TARGET, '0x10'])])
        self.assertEqual(calls, [('anvil_setBalance', [TARGET, '0x123'])])

    def test_manifest_contracts_include_factory_outputs_and_skip_wallets_and_zero(self):
        self.assertTrue(callable(getattr(FAST, 'manifest_contracts', None)), 'Factory outputs are not verified.')
        adapter = '0x' + '33' * 20
        rwa = '0x' + '44' * 20
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'manifest.json'
            path.write_text(json.dumps({'owner': OWNER, 'reportPublisher': '0x' + '99' * 20,
                                        'vaultFactory': TARGET, 'accounts': [adapter],
                                        'markets': [{'asset': rwa, 'account': adapter,
                                                     'rwaTokens': [rwa], 'threeFRequest': '0x' + '00' * 20}]}))
            self.assertEqual(FAST.manifest_contracts(path), {TARGET, adapter, rwa})

    def test_deployment_planning_uses_original_fork_to_keep_created_storage_local(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = root / 'manifest.json'
            env = {'TESTNET_OWNER': OWNER, 'TESTNET_RPC_URL': 'https://rpc.invalid'}
            command = ['forge', 'script', 'script/DeployRealisticTestnet.s.sol:DeployRealisticTestnetScript']

            def run(argv, *, env, capture=False):
                if argv[1] == 'config':
                    return json.dumps({'broadcast': 'broadcast', 'cache_path': 'cache'})
                source = plan(1)
                source['transactions'][0]['transactionType'] = 'CREATE'
                common = Path('DeployRealisticTestnet.s.sol/11155111/dry-run/run-latest.json')
                FAST.stage_sequence(source, env['TESTNET_RPC_URL'], Path(env['FOUNDRY_BROADCAST']) / common,
                                    Path(env['FOUNDRY_CACHE_PATH']) / common)
                manifest.write_text(json.dumps({'owner': OWNER, 'vaultFactory': TARGET, 'markets': [], 'startBlock': 10}))

            class Rpc(PublicRpc):
                def call(self, method, params):
                    if method == 'eth_chainId':
                        return hex(11155111)
                    if method == 'eth_getBlockByNumber' and params[0] == '0xa':
                        return {'number': '0xa', 'hash': BLOCK_HASH}
                    return super().call(method, params)

            with patch.object(FAST.bootstrap, 'ROOT', root), \
                    patch.object(FAST.bootstrap, 'tools', return_value=('forge', 'cast')), \
                    patch.object(FAST.bootstrap, 'run', side_effect=run), \
                    patch.object(FAST, 'Rpc', return_value=Rpc(plan(), count=0)), \
                    patch.object(FAST, 'LocalFork') as fork:
                fork.return_value.__enter__.side_effect = ValueError('probe stopped')
                with self.assertRaisesRegex(ValueError, 'probe stopped'):
                    FAST.broadcast(command, [], env, manifest)
                self.assertEqual(fork.call_args.args[1], 10, 'Latest-state forks make every new storage slot an RPC read.')

    def test_rpc_batch_retries_only_failed_reads_after_a_provider_rate_limit(self):
        rpc = FAST.Rpc('https://rpc.invalid')
        responses = [[{'id': 0, 'result': 'first'},
                      {'id': 1, 'error': {'code': -32005, 'message': 'too many requests'}}],
                     {'error': {'code': -32005, 'message': 'too many requests'}},
                     {'result': 'second'}]
        with patch.object(rpc, 'request', side_effect=responses) as request, patch.object(FAST.time, 'sleep'):
            try:
                result = rpc.batch([('eth_getBalance', [OWNER, '0x10']), ('eth_getBalance', [TARGET, '0x10'])])
            except ValueError as error:
                self.fail(f'Transient provider throttling aborted preparation: {error}')
        self.assertEqual(result, ['first', 'second'])
        self.assertEqual(request.call_args_list[1].args[0]['params'], [TARGET, '0x10'])
        self.assertEqual(request.call_args_list[2].args[0]['params'], [TARGET, '0x10'])


if __name__ == '__main__':
    unittest.main()
