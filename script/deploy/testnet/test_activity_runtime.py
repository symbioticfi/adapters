"""Activity harness host tool and timeout guards."""
import tempfile
import json
import unittest
from pathlib import Path
from unittest.mock import patch
import activity_runtime as RUNTIME

class RuntimeToolsTest(unittest.TestCase):
    def test_slow_rpc_reads_have_time_to_finish_and_keep_explicit_environment(self):
        supplied = {'ETH_RPC_TIMEOUT': '240', 'KEEP': 'configured'}

        def execute(argv, **kwargs):
            self.assertGreaterEqual(int(kwargs['env']['ETH_RPC_TIMEOUT']), 46)
            self.assertIn(kwargs['env']['KEEP'], ('inherited', 'configured'))
            return RUNTIME.subprocess.CompletedProcess(argv, 0)

        with patch.dict(RUNTIME.os.environ, {'KEEP': 'inherited'}, clear=True), \
                patch.object(RUNTIME.subprocess, 'run', side_effect=execute):
            RUNTIME.run(['cast', 'code'])
            RUNTIME.run(['cast', 'code'], env=supplied)
        self.assertEqual(supplied, {'ETH_RPC_TIMEOUT': '240', 'KEEP': 'configured'})

    def test_rejects_mixed_foundry_tool_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            installed = home / '.foundry/versions/foundry-rs/foundry/v1.8.5'
            installed.mkdir(parents=True)
            for tool, version in (('forge', '1.8.5'), ('cast', '1.8.1')):
                executable = installed / tool
                executable.write_text(f'#!/bin/sh\nprintf "%s\\n" "{tool} Version: {version}"\n')
                executable.chmod(0o700)
            with patch.object(RUNTIME.Path, 'home', return_value=home):
                with self.assertRaisesRegex(SystemExit, 'foundryup -i v1.8.5'):
                    RUNTIME.tools()

    def test_sepolia_rejects_old_fallback_toolchain_before_running_scripts(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            forge = home / 'forge'
            forge.write_text('#!/bin/sh\nprintf "%s\\n" "forge Version: 1.8.1"\n')
            forge.chmod(0o700)
            with patch.object(RUNTIME.Path, 'home', return_value=home), \
                    patch.object(RUNTIME.shutil, 'which', return_value=str(forge)):
                with self.assertRaisesRegex(SystemExit, 'foundryup -i v1.8.5'):
                    RUNTIME.tools()


class ManifestTest(unittest.TestCase):
    def test_requires_official_sepolia_forwarder_and_per_stand_replica(self):
        owner = '0x' + '1' * 40
        manifest = dict(RUNTIME.SEPOLIA, chainId=RUNTIME.SEPOLIA_CHAIN_ID,
                        owner=owner, schemaVersion=1, seedAssets=2000,
                        upstreamPins=RUNTIME.upstream_pins(), infrastructure='sepolia',
                        chainlinkRegistry='0x' + '2' * 40,
                        markets=[{'asset': RUNTIME.SEPOLIA['usdc']}] * 7)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'manifest.json'
            path.write_text(json.dumps(manifest))
            self.assertEqual(RUNTIME.load_manifest(path, owner, RUNTIME.SEPOLIA_CHAIN_ID), manifest)
            for key, value in [('forwarder', owner), ('chainlinkRegistry', '0x' + '0' * 40)]:
                with self.subTest(key=key):
                    changed = dict(manifest, **{key: value})
                    path.write_text(json.dumps(changed))
                    with self.assertRaisesRegex(SystemExit, key if key == 'forwarder' else 'oracle infrastructure'):
                        RUNTIME.load_manifest(path, owner, RUNTIME.SEPOLIA_CHAIN_ID)
