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
        'oracleMode': 'official-cre',
        'reportPublisher': OWNER,
        'infrastructure': 'official-sepolia' if chain_id == BOOTSTRAP.SEPOLIA_CHAIN_ID else 'local-fixtures',
        'chainId': chain_id,
        'owner': OWNER,
        'seedAssets': 100_000,
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


class RuntimeToolsTest(unittest.TestCase):
    def test_rejects_mixed_foundry_tool_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            installed = home / '.foundry/versions/foundry-rs/foundry/v1.8.5'
            installed.mkdir(parents=True)
            for tool, version in (('forge', '1.8.5'), ('cast', '1.8.1')):
                executable = installed / tool
                executable.write_text(f'#!/bin/sh\nprintf "%s\\n" "{tool} Version: {version}"\n')
                executable.chmod(0o700)
            with patch.object(BOOTSTRAP.Path, 'home', return_value=home):
                with self.assertRaisesRegex(SystemExit, 'foundryup -i v1.8.5'):
                    BOOTSTRAP.tools()

    def test_helpers_use_foundry_185_and_sepolia_uses_rpc_gas_estimates(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            for version in ('1.8.1', '1.8.5'):
                installed = home / f'.foundry/versions/foundry-rs/foundry/v{version}'
                installed.mkdir(parents=True)
                for tool in ('forge', 'cast'):
                    executable = installed / tool
                    executable.write_text(f'#!/bin/sh\nprintf "%s\\n" "{tool} Version: {version}"\n')
                    executable.chmod(0o700)
            with patch.object(BOOTSTRAP.Path, 'home', return_value=home):
                forge, cast, options = BOOTSTRAP.script_runtime(11_155_111)
                self.assertEqual(Path(forge).parent.name, 'v1.8.5')
                self.assertEqual(Path(cast).parent.name, 'v1.8.5')
                self.assertEqual(options, ['--skip-simulation'])
                forge, cast, options = BOOTSTRAP.script_runtime(31_337)
                self.assertEqual(Path(forge).parent.name, 'v1.8.5')
                self.assertEqual(Path(cast).parent.name, 'v1.8.5')
                self.assertEqual(options, [])

    def test_sepolia_rejects_old_fallback_toolchain_before_running_scripts(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            forge = home / 'forge'
            forge.write_text('#!/bin/sh\nprintf "%s\\n" "forge Version: 1.8.1"\n')
            forge.chmod(0o700)
            with patch.object(BOOTSTRAP.Path, 'home', return_value=home), \
                    patch.object(BOOTSTRAP.shutil, 'which', return_value=str(forge)):
                with self.assertRaisesRegex(SystemExit, 'foundryup -i v1.8.5'):
                    BOOTSTRAP.script_runtime(11_155_111)


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
            if argv[3] == 'owner()(address)':
                return OWNER
            if argv[3] == 'isForwarder(address)(bool)':
                return 'true'
            if argv[3] == 'typeAndVersion()(string)':
                return self.forwarder_version if argv[2] in (BOOTSTRAP.SEPOLIA['forwarder'], self.data['forwarder']) else self.version
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

    def self_hosted(self):
        self.data['oracleMode'] = 'self-hosted'
        self.data['forwarder'] = numbered_address(900)
        self.data['reportPublisher'] = numbered_address(901)

    def test_self_hosted_bootstrap_deploys_and_activates_then_waits_for_daemon(self):
        self.self_hosted()
        BOOTSTRAP.main(self.base + ['--manifest', str(self.path), '--oracle-mode', 'self-hosted',
                                   '--report-publisher', self.data['reportPublisher']])
        self.assertEqual(self.phases(), ['DeployRealisticTestnet', 'ActivateMerkleTestnet'])
        self.assertEqual(len(self.signing_calls()), 7)
        self.assertFalse(any('--no-hash' in call for call in self.signing_calls()))
        encodings = [argv for argv, _ in self.calls if argv[:2] == ['cast', 'abi-encode'] and 'uint8' in argv[2]]
        self.assertTrue(all(argv[5] == str(BOOTSTRAP.SEPOLIA_CHAIN_ID) for argv in encodings))
        phase_envs = [env for argv, env in self.calls if argv[:2] == ['forge', 'script']]
        self.assertTrue(all(env['TESTNET_ORACLE_MODE'] == 'self-hosted' for env in phase_envs))
        self.assertTrue(all(env['TESTNET_REPORT_PUBLISHER'] == self.data['reportPublisher'] for env in phase_envs))
        first_codes = [argv[2].lower() for argv, _ in self.calls if argv[:2] == ['cast', 'code']]
        self.assertNotIn(BOOTSTRAP.SEPOLIA['forwarder'].lower(), first_codes)
        self.assertTrue(all(value.lower() in first_codes for key, value in BOOTSTRAP.SEPOLIA.items() if key != 'forwarder'))

    def test_self_hosted_resume_preserves_wiring_and_uses_external_report(self):
        self.self_hosted()
        self.resume('seed')
        self.assertEqual(self.phases(), ['SyncMerkleTestnet', 'SeedRealisticTestnet'])
        self.assertEqual(self.signing_calls(), [])
        env = [env for argv, env in self.calls if argv[:2] == ['forge', 'script']][0]
        self.assertEqual(env['TESTNET_ORACLE_MODE'], 'self-hosted')
        self.assertEqual(env['TESTNET_CHAINLINK_REGISTRY'], REGISTRY)
        self.assertEqual(env['TESTNET_REPORT_PUBLISHER'], self.data['reportPublisher'])

    def test_local_self_hosted_bootstrap_and_seed_leave_reporting_to_daemon(self):
        self.chain_id = BOOTSTRAP.LOCAL_CHAIN_ID
        self.data = manifest(self.chain_id)
        self.data['oracleMode'] = 'self-hosted'
        BOOTSTRAP.main(self.base + ['--manifest', str(self.path), '--oracle-mode', 'self-hosted'])
        self.assertEqual(self.phases(), ['DeployRealisticTestnet', 'ActivateMerkleTestnet'])
        self.assertEqual(len(self.signing_calls()), 7)
        self.calls.clear()
        self.resume('seed')
        self.assertEqual(self.phases(), ['SyncMerkleTestnet', 'SeedRealisticTestnet'])
        self.assertEqual(self.signing_calls(), [])

    def test_shared_report_phase_selects_local_fixture_or_external_publisher(self):
        for chain_id, mode, expected in ((BOOTSTRAP.LOCAL_CHAIN_ID, 'official-cre', 'ReportMerkleTestnet'),
                                         (BOOTSTRAP.LOCAL_CHAIN_ID, 'self-hosted', 'SyncMerkleTestnet'),
                                         (BOOTSTRAP.SEPOLIA_CHAIN_ID, 'official-cre', 'SyncMerkleTestnet'),
                                         (BOOTSTRAP.SEPOLIA_CHAIN_ID, 'self-hosted', 'SyncMerkleTestnet')):
            with self.subTest(chain=chain_id, mode=mode):
                self.assertEqual(BOOTSTRAP.report_phase({'chainId': chain_id, 'oracleMode': mode}), expected)

    def test_self_hosted_rejects_mode_registry_publisher_and_official_activation_overrides(self):
        self.self_hosted()
        for extra, message in ((['--oracle-mode', 'official-cre'], 'mode does not match'),
                               (['--chainlink-registry', OWNER], 'registry does not match'),
                               (['--report-publisher', OWNER], 'publisher does not match'),
                               (['--cre-activation', str(self.activation_path)], 'self-hosted')):
            with self.subTest(extra=extra):
                with self.assertRaisesRegex(SystemExit, message):
                    self.resume('activate', *extra)
                self.assertEqual(self.phases(), [])

    def test_self_hosted_fresh_rejects_registry_override_and_official_activation(self):
        for extra in (['--chainlink-registry', REGISTRY], ['--cre-activation', str(self.activation_path)]):
            with self.subTest(extra=extra):
                with self.assertRaisesRegex(SystemExit, 'self-hosted'):
                    BOOTSTRAP.main(self.base + ['--manifest', str(self.path), '--oracle-mode', 'self-hosted', *extra])
                self.assertEqual(self.phases(), [])

    def test_saved_manifest_requires_explicit_mode_and_publisher(self):
        for field in ('oracleMode', 'reportPublisher'):
            with self.subTest(field=field):
                self.data = manifest(self.chain_id)
                del self.data[field]
                with self.assertRaisesRegex(SystemExit, 'regenerate'):
                    self.resume('sync')
                self.assertEqual(self.phases(), [])

    def test_fresh_rejects_empty_publisher_and_invalid_environment_mode(self):
        with self.assertRaisesRegex(SystemExit, 'nonzero address'):
            BOOTSTRAP.main(self.base + ['--manifest', str(self.path), '--report-publisher', ''])
        BOOTSTRAP.os.environ['TESTNET_ORACLE_MODE'] = 'unknown'
        with self.assertRaisesRegex(SystemExit, 'oracle mode'):
            BOOTSTRAP.main(self.base + ['--manifest', str(self.path)])
        self.assertEqual(self.phases(), [])

    def test_official_mode_rejects_dedicated_publisher(self):
        with self.assertRaisesRegex(SystemExit, 'self-hosted'):
            BOOTSTRAP.main(self.base + ['--manifest', str(self.path), '--report-publisher', REGISTRY])
        self.assertEqual(self.phases(), [])

    def test_self_hosted_resume_checks_infrastructure_ownership_and_publisher_authority(self):
        self.self_hosted()
        original = self.fake_run
        for getter, wrong, message in (('owner()(address)', REGISTRY, 'owned by'),
                                       ('isForwarder(address)(bool)', 'false', 'not authorized')):
            def invalid(argv, **kwargs):
                return wrong if argv[:2] == ['cast', 'call'] and argv[3] == getter else original(argv, **kwargs)
            with self.subTest(getter=getter), patch.object(BOOTSTRAP, 'run', side_effect=invalid):
                with self.assertRaisesRegex(SystemExit, message):
                    self.resume('sync')
                self.assertEqual(self.phases(), [])

    def test_self_hosted_fast_resume_resumes_deployment_then_generates_new_activation_plan(self):
        self.self_hosted()
        self.path.write_text(json.dumps(self.data))
        deployed = False
        infrastructure = {self.data['chainlinkRegistry'], self.data['forwarder']}

        def read(argv, **kwargs):
            if argv[:2] == ['cast', 'code'] and argv[2] in infrastructure and not deployed:
                return '0x'
            return self.fake_run(argv, **kwargs)

        def broadcast(command, *args, **kwargs):
            nonlocal deployed
            if 'DeployRealisticTestnet.s.sol:' in command[2]:
                deployed = True

        with patch.object(BOOTSTRAP, 'run', side_effect=read), \
                patch('fast_broadcast.broadcast', side_effect=broadcast, create=True) as fast:
            BOOTSTRAP.main(self.base + ['--fast', '--resume', '--existing-manifest', str(self.path)])
        self.assertEqual([call.kwargs['resume'] for call in fast.call_args_list], [True, False])

    def test_self_hosted_fast_resume_validates_infrastructure_after_deployment(self):
        self.self_hosted()
        self.path.write_text(json.dumps(self.data))
        for getter, wrong, message in (('code', '0x', 'no deployed code'),
                                       ('owner()(address)', REGISTRY, 'owned by'),
                                       ('isForwarder(address)(bool)', 'false', 'not authorized')):
            def invalid(argv, **kwargs):
                if (getter == 'code' and argv[:3] == ['cast', 'code', self.data['chainlinkRegistry']]
                        or argv[:2] == ['cast', 'call'] and argv[3] == getter):
                    return wrong
                return self.fake_run(argv, **kwargs)

            with self.subTest(getter=getter), patch.object(BOOTSTRAP, 'run', side_effect=invalid), \
                    patch('fast_broadcast.broadcast', create=True) as fast:
                with self.assertRaisesRegex(SystemExit, message):
                    BOOTSTRAP.main(self.base + ['--fast', '--resume', '--phase', 'deploy',
                                               '--existing-manifest', str(self.path)])
                self.assertEqual(fast.call_count, 1)
                self.assertTrue(fast.call_args.kwargs['resume'])

    def test_self_hosted_cannot_use_official_forwarder_or_synthetic_threef(self):
        self.self_hosted()
        self.data['forwarder'] = BOOTSTRAP.SEPOLIA['forwarder']
        with self.assertRaisesRegex(SystemExit, 'own forwarder'):
            self.resume('sync')
        with self.assertRaisesRegex(SystemExit, 'only for local fixtures'):
            BOOTSTRAP.local_threef('cast', 'https://rpc.invalid', [], self.data, {})

    def test_sepolia_deployment_uses_rpc_gas_prices_without_runtime_or_compiler_override(self):
        self.fresh()
        command = [argv for argv, _ in self.calls if argv[:2] == ['forge', 'script']][0]
        self.assertIn('--skip-simulation', command)
        self.assertNotIn('--hardfork', command)
        self.assertNotIn('--evm-version', command)

    def test_fast_deployment_generates_and_broadcasts_through_fork_planner(self):
        def broadcast(command, wallet, env, manifest, *, resume=False):
            Path(manifest).write_text(json.dumps(self.data))
            self.assertNotIn('--slow', command)
            self.assertNotIn('--skip-simulation', command)
            self.assertNotIn('--hardfork', command)
            self.assertFalse(resume)

        with patch('fast_broadcast.broadcast', side_effect=broadcast, create=True) as fast:
            try:
                self.fresh('--fast')
            except SystemExit as error:
                self.fail(f'Fast deployment flag is unavailable: {error}')
            self.assertEqual(fast.call_count, 1)
            self.assertEqual(self.phases(), [])

    def test_fast_resume_uses_saved_manifest_without_regenerating_addresses(self):
        self.path.write_text(json.dumps(self.data))
        before = self.path.read_bytes()
        with patch('fast_broadcast.broadcast', create=True) as fast:
            try:
                BOOTSTRAP.main(self.base + ['--fast', '--resume', '--existing-manifest', str(self.path)])
            except SystemExit as error:
                self.fail(f'Fast deployment resume is unavailable: {error}')
            self.assertEqual(fast.call_count, 1)
            self.assertTrue(fast.call_args.kwargs['resume'])
            self.assertEqual(self.phases(), [])
            self.assertEqual(self.path.read_bytes(), before)

    def test_sepolia_seed_uses_rpc_gas_prices_for_both_sync_and_funding(self):
        self.resume('seed')
        commands = [argv for argv, _ in self.calls if argv[:2] == ['forge', 'script']]
        self.assertEqual(len(commands), 2)
        for command in commands:
            self.assertIn('--skip-simulation', command)
            self.assertNotIn('--hardfork', command)

    def test_fast_sync_uses_public_estimates_and_funding_keeps_fork_planning(self):
        self.self_hosted()
        for phase, planned in (('sync', []), ('seed', ['SeedRealisticTestnet'])):
            with self.subTest(phase=phase), patch('fast_broadcast.broadcast', create=True) as fast:
                self.calls.clear()
                self.resume(phase, '--fast')
                self.assertEqual(self.phases(), ['SyncMerkleTestnet'])
                command = [argv for argv, _ in self.calls if argv[:2] == ['forge', 'script']][0]
                for flag in ('--skip-simulation', '--broadcast', '--slow'):
                    self.assertIn(flag, command)
                self.assertEqual([call.args[0][2].split(':')[1].removesuffix('Script')
                                  for call in fast.call_args_list], planned)

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

    def test_official_activation_accepts_paused_registration_status(self):
        document = activation(self.data)
        document['entries'][0]['status'] = 1
        self.activation_path.write_text(json.dumps(document))
        self.resume('activate', '--cre-activation', str(self.activation_path))
        self.assertEqual(self.phases(), ['ActivateMerkleTestnet'])

    def test_activation_identity_order_and_unique_values_checked_before_broadcast(self):
        for mutation in ('owner', 'wrapper', 'duplicate-proof', 'missing-workflow', 'empty-tag', 'invalid-tag', 'invalid-status', 'negative-status', 'string-status', 'bool-status'):
            with self.subTest(mutation=mutation):
                document = activation(self.data)
                if mutation == 'owner':
                    document['owner'] = REGISTRY
                elif mutation == 'wrapper':
                    document['entries'][0]['wrapper'] = document['entries'][1]['wrapper']
                elif mutation == 'duplicate-proof':
                    document['entries'][1]['proof'] = document['entries'][0]['proof']
                elif mutation == 'missing-workflow':
                    del document['entries'][0]['workflowId']
                elif mutation == 'empty-tag':
                    document['entries'][0]['tag'] = ''
                elif mutation == 'invalid-tag':
                    document['entries'][0]['tag'] = 1
                elif mutation == 'invalid-status':
                    document['entries'][0]['status'] = 2
                elif mutation == 'negative-status':
                    document['entries'][0]['status'] = -1
                elif mutation == 'string-status':
                    document['entries'][0]['status'] = 'PAUSED'
                else:
                    document['entries'][0]['status'] = True
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
        self.assertTrue(all('--hardfork' not in argv for argv, _ in self.calls if argv[:2] == ['forge', 'script']))
        self.assertTrue(all('--skip-simulation' not in argv for argv, _ in self.calls if argv[:2] == ['forge', 'script']))

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
