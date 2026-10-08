"""Test bootstrap phase selection and preflight guards without RPC or Forge."""
import copy
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('testnet_bootstrap', Path(__file__).with_name('bootstrap.py'))
BOOTSTRAP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOOTSTRAP)
OWNER = '0x' + '11' * 20
REGISTRY = '0x' + '22' * 20


def numbered_address(value):
    return '0x' + f'{value:040x}'


def manifest(chain_id):
    markets = [{
        'asset': BOOTSTRAP.SEPOLIA['usdc'] if chain_id == BOOTSTRAP.SEPOLIA_CHAIN_ID and index == 0 else numbered_address(100 + index),
        'decimals': (6, 18, 18, 8, 8, 18, 6)[index],
        'creOracle': numbered_address(200 + index),
        'workflowRegistry': numbered_address(300 + index),
        'threeFAdapter': numbered_address(400 + index),
        'threeFRequest': numbered_address(500 + index),
    } for index in range(7)]
    return {
        'schemaVersion': 2,
        'infrastructure': 'official-sepolia' if chain_id == BOOTSTRAP.SEPOLIA_CHAIN_ID else 'local-fixtures',
        'chainId': chain_id,
        'owner': OWNER,
        'seedAssets': 100_000,
        'maxReportAge': 86_400,
        'chainlinkRegistry': REGISTRY,
        **{key: value for key, value in BOOTSTRAP.SEPOLIA.items() if key != 'usdc'},
        'workflowRegistries': [market['workflowRegistry'] for market in markets],
        'markets': markets,
    }


def activation(data):
    return {
        'chainId': BOOTSTRAP.SEPOLIA_CHAIN_ID,
        'owner': OWNER,
        'chainlinkRegistry': REGISTRY,
        'entries': [{
            'oracle': market['creOracle'],
            'wrapper': market['workflowRegistry'],
            'expiry': 2_000_000_000,
            'proof': '0x' + f'{index + 1:064x}',
            'signature': '0x1234',
            'workflowId': '0x' + f'{index + 100:064x}',
            'donFamily': 'organization-don',
            'binaryUrl': 'https://example.org/workflow.wasm.br',
            'configUrl': 'https://example.org/workflow.json',
            'attributes': '0x',
        } for index, market in enumerate(data['markets'])],
    }


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.password = self.root / 'password'
        self.password.write_text('encrypted-wallet-password\n')
        self.path = self.root / 'deployment.json'
        self.activation_path = self.root / 'activation.json'
        self.chain_id = BOOTSTRAP.SEPOLIA_CHAIN_ID
        self.data = manifest(self.chain_id)
        self.calls = []
        self.code = '0x6001'
        self.version = '"WorkflowRegistry 2.0.0"'
        self.forwarder_version = '"KeystoneForwarder 1.0.0"'
        self.decimals = '6'
        self.balance = 1000 * 10**18
        self.base = ['--rpc-url', 'https://rpc.invalid', '--account', 'encrypted', '--password-file', str(self.password)]
        self.patches = [patch.object(BOOTSTRAP, 'ROOT', self.root),
                        patch.object(BOOTSTRAP, 'tools', return_value=('forge', 'cast')),
                        patch.object(BOOTSTRAP, 'run', side_effect=self.fake_run),
                        patch.dict(BOOTSTRAP.os.environ, {}, clear=True),
                        patch('sys.stdout', new=io.StringIO()),
                        patch('sys.stderr', new=io.StringIO())]
        for mock in self.patches:
            mock.start()

    def tearDown(self):
        for mock in reversed(self.patches):
            mock.stop()
        self.temporary.cleanup()

    def fake_run(self, argv, *, env=None, capture=False):
        self.calls.append((argv, copy.deepcopy(env)))
        if argv[:3] == ['cast', 'wallet', 'address']:
            return OWNER
        if argv[:2] == ['cast', 'chain-id']:
            return str(self.chain_id)
        if argv[:2] == ['cast', 'code']:
            return self.code
        if argv[:2] == ['cast', 'balance']:
            return str(self.balance)
        if argv[:2] == ['cast', 'call']:
            if argv[3] == 'typeAndVersion()(string)':
                return self.forwarder_version if argv[2] == BOOTSTRAP.SEPOLIA['forwarder'] else self.version
            if argv[3] == 'decimals()(uint8)':
                return self.decimals
            if argv[3] == 'nonce(address)(uint256)':
                return '0'
            if argv[3] == 'maturity()(uint48)':
                return '2000000000'
            return '0x' + 'ab' * 32
        if argv[:2] == ['cast', 'block']:
            return json.dumps({'data': {'timestamp': '0x1234'}})
        if argv[:2] in (['cast', 'abi-encode'], ['cast', 'keccak']):
            return '0x' + 'ab' * 32
        if argv[:3] == ['cast', 'wallet', 'sign']:
            return '0x' + 'cd' * 65
        if argv[:2] == ['forge', 'script'] and 'DeployRealisticTestnet.s.sol:' in argv[2]:
            Path(env['TESTNET_MANIFEST']).write_text(json.dumps(self.data))
        return None

    def phases(self):
        return [argv[2].split(':')[1].removesuffix('Script') for argv, _ in self.calls if argv[:2] == ['forge', 'script']]

    def signing_calls(self):
        return [argv for argv, _ in self.calls if argv[:3] == ['cast', 'wallet', 'sign']]

    def fresh(self, *extra):
        BOOTSTRAP.main(self.base + ['--manifest', str(self.path), '--chainlink-registry', REGISTRY, *extra])

    def resume(self, phase, *extra):
        self.path.write_text(json.dumps(self.data))
        BOOTSTRAP.main(self.base + ['--phase', phase, '--existing-manifest', str(self.path), *extra])

    def test_official_bootstrap_only_deploys_and_never_signs(self):
        self.fresh()
        self.assertEqual(self.phases(), ['DeployRealisticTestnet'])
        self.assertEqual(self.signing_calls(), [])
        code_addresses = [argv[2].lower() for argv, _ in self.calls if argv[:2] == ['cast', 'code']]
        self.assertEqual(set(code_addresses), {REGISTRY.lower(), *(value.lower() for value in BOOTSTRAP.SEPOLIA.values())})

    def test_unsupported_chain_rejected_before_any_forge_call(self):
        self.chain_id = 1
        with self.assertRaisesRegex(SystemExit, 'Unsupported chain'):
            self.fresh()
        self.assertEqual(self.phases(), [])

    def test_official_staging_registry_is_default_for_new_deployment(self):
        self.data['chainlinkRegistry'] = BOOTSTRAP.SEPOLIA_STAGING_WORKFLOW_REGISTRY
        BOOTSTRAP.main(self.base + ['--manifest', str(self.path)])
        self.assertEqual(self.phases(), ['DeployRealisticTestnet'])
        phase_env = [env for argv, env in self.calls if argv[:2] == ['forge', 'script']][0]
        self.assertEqual(phase_env['TESTNET_CHAINLINK_REGISTRY'], BOOTSTRAP.SEPOLIA_STAGING_WORKFLOW_REGISTRY)
        self.assertTrue(any(argv[:3] == ['cast', 'code', BOOTSTRAP.SEPOLIA_STAGING_WORKFLOW_REGISTRY]
                            for argv, _ in self.calls))
        self.assertEqual(self.signing_calls(), [])

    def test_environment_registry_overrides_new_deployment_default(self):
        BOOTSTRAP.os.environ['TESTNET_CHAINLINK_REGISTRY'] = REGISTRY
        BOOTSTRAP.main(self.base + ['--manifest', str(self.path)])
        phase_env = [env for argv, env in self.calls if argv[:2] == ['forge', 'script']][0]
        self.assertEqual(phase_env['TESTNET_CHAINLINK_REGISTRY'], REGISTRY)

    def test_empty_or_bad_explicit_registry_override_rejected(self):
        for registry in ('', 'invalid-address', '0x' + '00' * 20):
            with self.subTest(registry=registry):
                with self.assertRaisesRegex(SystemExit, 'nonzero address'):
                    BOOTSTRAP.main(self.base + ['--manifest', str(self.path), '--chainlink-registry', registry])
                self.assertEqual(self.phases(), [])

    def test_empty_environment_registry_does_not_use_default(self):
        BOOTSTRAP.os.environ['TESTNET_CHAINLINK_REGISTRY'] = ''
        with self.assertRaisesRegex(SystemExit, 'empty overrides'):
            BOOTSTRAP.main(self.base + ['--manifest', str(self.path)])
        self.assertEqual(self.phases(), [])

    def test_existing_organization_registry_is_preserved_without_explicit_override(self):
        self.resume('sync')
        phase_env = [env for argv, env in self.calls if argv[:2] == ['forge', 'script']][0]
        self.assertEqual(phase_env['TESTNET_CHAINLINK_REGISTRY'], REGISTRY)
        self.assertFalse(any(argv[:3] == ['cast', 'code', BOOTSTRAP.SEPOLIA_STAGING_WORKFLOW_REGISTRY]
                             for argv, _ in self.calls))

    def test_empty_explicit_registry_override_cannot_bypass_resume_identity_check(self):
        with self.assertRaisesRegex(SystemExit, 'registry does not match'):
            self.resume('sync', '--chainlink-registry', '')
        self.assertEqual(self.phases(), [])

    def test_registry_code_version_and_usdc_decimals_fail_before_deploy(self):
        cases = [('code', '0x', 'no deployed code'), ('code', '0x00', 'no deployed code'),
                 ('version', '"WorkflowRegistry 1.0.0"', 'WorkflowRegistry 2.0.0'), ('decimals', '18', 'six decimals')]
        for field, value, message in cases:
            with self.subTest(field=field, value=value):
                setattr(self, field, value)
                with self.assertRaisesRegex(SystemExit, message):
                    self.fresh()
                self.assertEqual(self.phases(), [])
                setattr(self, field, {'code': '0x6001', 'version': '"WorkflowRegistry 2.0.0"', 'decimals': '6'}[field])

    def test_wrong_forwarder_version_fails_before_deploy(self):
        self.forwarder_version = '"KeystoneForwarder 2.0.0"'
        with self.assertRaisesRegex(SystemExit, 'KeystoneForwarder 1.0.0'):
            self.fresh()
        self.assertEqual(self.phases(), [])

    def test_signing_helpers_reject_official_manifests(self):
        for helper in (BOOTSTRAP.local_activation, BOOTSTRAP.local_threef):
            with self.assertRaises(SystemExit):
                helper('cast', 'https://rpc.invalid', [], self.data, {})
        self.assertEqual(self.calls, [])

    def test_backing_shortfall_fails_before_deploy(self):
        self.balance = 1
        with self.assertRaisesRegex(SystemExit, 'backing'):
            self.fresh()
        self.assertEqual(self.phases(), [])

    def test_official_activation_requires_artifacts(self):
        with self.assertRaisesRegex(SystemExit, 'activation requires'):
            self.resume('activate')
        self.assertEqual(self.phases(), [])
        self.assertEqual(self.signing_calls(), [])

    def test_official_activation_uses_supplied_artifacts_without_local_signing(self):
        self.activation_path.write_text(json.dumps(activation(self.data)))
        self.resume('activate', '--cre-activation', str(self.activation_path))
        self.assertEqual(self.phases(), ['ActivateMerkleTestnet'])
        self.assertEqual(self.signing_calls(), [])
        phase_env = [env for argv, env in self.calls if argv[:2] == ['forge', 'script']][0]
        self.assertEqual(phase_env['TESTNET_CRE_ACTIVATION'], str(self.activation_path))

    def test_activation_identity_order_and_unique_values_checked_before_broadcast(self):
        for mutation in ('owner', 'wrapper', 'duplicate-proof', 'missing-workflow'):
            with self.subTest(mutation=mutation):
                document = activation(self.data)
                if mutation == 'owner':
                    document['owner'] = REGISTRY
                elif mutation == 'wrapper':
                    document['entries'][0]['wrapper'] = document['entries'][1]['wrapper']
                elif mutation == 'duplicate-proof':
                    document['entries'][1]['proof'] = document['entries'][0]['proof']
                else:
                    del document['entries'][0]['workflowId']
                self.activation_path.write_text(json.dumps(document))
                with self.assertRaisesRegex(SystemExit, 'Invalid CRE activation file'):
                    self.resume('activate', '--cre-activation', str(self.activation_path))
                self.assertEqual(self.phases(), [])

    def test_official_seed_requires_sync_and_skips_synthetic_threef_and_report(self):
        self.resume('seed')
        self.assertEqual(self.phases(), ['SyncMerkleTestnet', 'SeedRealisticTestnet'])
        self.assertEqual(self.signing_calls(), [])
        self.assertFalse(any(argv[:2] == ['cast', 'call'] and argv[3] == 'balanceOf(address)(uint256)' for argv, _ in self.calls))

    def test_failed_sync_prevents_official_seed(self):
        original = self.fake_run

        def reject_sync(argv, **kwargs):
            if argv[:2] == ['forge', 'script'] and 'SyncMerkleTestnet.s.sol:' in argv[2]:
                self.calls.append((argv, None))
                raise BOOTSTRAP.subprocess.CalledProcessError(1, argv)
            return original(argv, **kwargs)

        with patch.object(BOOTSTRAP, 'run', side_effect=reject_sync):
            with self.assertRaises(BOOTSTRAP.subprocess.CalledProcessError):
                self.resume('seed')
        self.assertEqual(self.phases(), ['SyncMerkleTestnet'])

    def test_official_sync_does_not_require_funding_balance(self):
        self.balance = 0
        self.resume('sync')
        self.assertEqual(self.phases(), ['SyncMerkleTestnet'])
        self.assertFalse(any(argv[:2] == ['cast', 'balance'] for argv, _ in self.calls))

    def test_validate_is_read_only(self):
        self.balance = 0
        self.resume('validate')
        self.assertEqual(self.phases(), ['ValidateRealisticTestnet'])
        command = [argv for argv, _ in self.calls if argv[:2] == ['forge', 'script']][0]
        self.assertNotIn('--broadcast', command)
        self.assertNotIn('--password-file', command)

    def test_manifest_chain_owner_binding_and_budget_mismatches_fail_before_phase(self):
        for key, value in [('chainId', 1), ('owner', REGISTRY), ('forwarder', REGISTRY), ('infrastructure', 'local-fixtures')]:
            with self.subTest(key=key):
                self.data = manifest(self.chain_id)
                self.data[key] = value
                with self.assertRaisesRegex(SystemExit, 'Invalid manifest'):
                    self.resume('seed')
                self.assertEqual(self.phases(), [])
        self.data = manifest(self.chain_id)
        with self.assertRaisesRegex(SystemExit, 'recorded in the manifest'):
            self.resume('seed', '--seed-assets', '200000')
        self.assertEqual(self.phases(), [])

    def test_resume_rejects_registry_override_and_clears_fixture_signatures(self):
        with self.assertRaisesRegex(SystemExit, 'registry does not match'):
            self.resume('sync', '--chainlink-registry', OWNER)
        BOOTSTRAP.os.environ.update(TESTNET_LINK_SIGNATURES='untrusted', TESTNET_THREE_F_SIGNATURES='untrusted')
        self.resume('sync')
        phase_env = [env for argv, env in self.calls if argv[:2] == ['forge', 'script']][0]
        self.assertNotIn('TESTNET_LINK_SIGNATURES', phase_env)
        self.assertNotIn('TESTNET_THREE_F_SIGNATURES', phase_env)

    def test_local_bootstrap_preserves_all_automatic_phases_and_signatures(self):
        self.chain_id = BOOTSTRAP.LOCAL_CHAIN_ID
        self.data = manifest(self.chain_id)
        self.fresh()
        self.assertEqual(self.phases(), ['DeployRealisticTestnet', 'ActivateMerkleTestnet', 'ReportMerkleTestnet',
                                        'SeedRealisticTestnet', 'SeedThreeFTestnet', 'ReportMerkleTestnet',
                                        'ValidateRealisticTestnet'])
        self.assertEqual(len(self.signing_calls()), 14)
        self.assertEqual(sum('--no-hash' in argv for argv in self.signing_calls()), 7)
        self.assertFalse(any(argv[:2] == ['cast', 'code'] for argv, _ in self.calls))

    def test_local_deploy_and_phase_resume(self):
        self.chain_id = BOOTSTRAP.LOCAL_CHAIN_ID
        self.data = manifest(self.chain_id)
        self.fresh('--phase', 'deploy')
        self.assertEqual(self.phases(), ['DeployRealisticTestnet'])
        self.calls.clear()
        self.resume('activate')
        self.assertEqual(self.phases(), ['ActivateMerkleTestnet'])
        self.assertEqual(len(self.signing_calls()), 7)

    def test_existing_manifest_cannot_be_overwritten_by_bootstrap(self):
        self.path.write_text(json.dumps(self.data))
        with self.assertRaises(SystemExit):
            self.fresh()
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
