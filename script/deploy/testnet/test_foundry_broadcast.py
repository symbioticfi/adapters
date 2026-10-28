"""Opt-in characterization of native Foundry batching and interrupted resume."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.request import Request, urlopen

SOURCE = 'pragma solidity ^0.8.18;\ninterface Vm {\n    function startBroadcast(address owner) external;\n    function stopBroadcast() external;\n    function envAddress(string calldata name) external returns (address);\n}\ncontract Counter {\n    uint256 public value;\n    function increment(uint256 expected) public { require(value == expected); value++; }\n}\ncontract Batch {\n    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));\n    function run() public returns (address counter) {\n        vm.startBroadcast(vm.envAddress("TESTNET_OWNER"));\n        counter = address(new Counter());\n        for (uint256 i; i < 110; i++) Counter(counter).increment(i);\n        vm.stopBroadcast();\n    }\n}\n'


class FoundryLauncherTest(unittest.TestCase):
    def test_failed_resume_preflight_prevents_broadcast(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            pinned = home / '.foundry/versions/foundry-rs/foundry/v1.8.5'
            pinned.mkdir(parents=True)
            forge = pinned / 'forge'
            forge.write_text('#!/bin/sh\nif [ "$1" = --version ]; then\n'
                             '  printf "%s\\n" "forge Version: 1.8.5"\nelse\n'
                             '  case "$*" in *checkManifest*) exit 17;; esac\n'
                             '  touch "$TESTNET_CAPTURE"\nfi\n')
            forge.chmod(0o700)
            capture = home / 'broadcast'
            env = dict(os.environ, HOME=str(home), TESTNET_CAPTURE=str(capture),
                       TESTNET_RPC_URL='http://127.0.0.1:8545',
                       TESTNET_OWNER='0x' + '11' * 20, TESTNET_MANIFEST=str(home / 'manifest.json'))
            result = subprocess.run(['bash', str(Path(__file__).with_name('run.sh')), 'deploy', '--resume'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 17, result.stderr)
            self.assertFalse(capture.exists())

    def test_validate_runs_read_only_with_system_bash(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            pinned = home / '.foundry/versions/foundry-rs/foundry/v1.8.5'
            pinned.mkdir(parents=True)
            forge = pinned / 'forge'
            forge.write_text('#!/bin/sh\nif [ "$1" = --version ]; then\n'
                             '  printf "%s\\n" "forge Version: 1.8.5"\nelse\n'
                             '  printf "%s\\n" "$@" > "$TESTNET_CAPTURE"\nfi\n')
            forge.chmod(0o700)
            capture = home / 'arguments'
            env = dict(os.environ, HOME=str(home), TESTNET_CAPTURE=str(capture),
                       TESTNET_RPC_URL='http://127.0.0.1:8545',
                       TESTNET_OWNER='0x' + '11' * 20, TESTNET_MANIFEST=str(home / 'manifest.json'))
            result = subprocess.run(['bash', str(Path(__file__).with_name('run.sh')), 'validate'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('--broadcast', capture.read_text().splitlines())


@unittest.skipUnless(os.environ.get('TESTNET_FOUNDRY_INTEGRATION') == '1',
                     'Set TESTNET_FOUNDRY_INTEGRATION=1 for disposable native Foundry broadcasts.')
class FoundryBroadcastTest(unittest.TestCase):
    def test_native_batching_and_resume_preserve_create_addresses_and_receipts(self):
        installed = Path.home() / '.foundry/versions/foundry-rs/foundry/v1.8.5'
        forge, cast, anvil = [str(installed / name) for name in ('forge', 'cast', 'anvil')]
        with tempfile.TemporaryDirectory(prefix='native-foundry-') as directory:
            root = Path(directory)
            (root / 'script').mkdir()
            (root / 'script/Batch.s.sol').write_text(SOURCE)
            (root / 'foundry.toml').write_text('[profile.default]\nsolc="0.8.37"\nevm_version="osaka"\noptimizer=true\n')
            password = root / 'password'
            password.write_text('ephemeral-local-only')
            password.chmod(0o600)
            keys = root / 'keys'
            keys.mkdir()
            env = {**os.environ, 'CAST_PASSWORD': 'ephemeral-local-only'}
            subprocess.run([cast, 'wallet', 'new', str(keys), 'test'], env=env, check=True, capture_output=True)
            wallet = ['--keystore', str(keys / 'test'), '--password-file', str(password)]
            owner = subprocess.check_output([cast, 'wallet', 'address', *wallet], text=True).strip()
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            url = f'http://127.0.0.1:{port}'
            def rpc(method, *params):
                payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
                with urlopen(Request(url, payload, {'Content-Type': 'application/json'}), timeout=10) as response:
                    result = json.load(response)
                if 'error' in result:
                    raise ValueError(result['error'])
                return result['result']
            node = subprocess.Popen([anvil, '--host', '127.0.0.1', '--port', str(port), '--chain-id', '31337',
                                     '--hardfork', 'osaka', '--enable-tx-gas-limit', '--block-time', '1', '--silent'],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for attempt in range(100):
                    try:
                        rpc('web3_clientVersion')
                        break
                    except OSError:
                        time.sleep(0.05)
                rpc('anvil_setBalance', owner, hex(100 * 10**18))
                env['TESTNET_OWNER'] = owner
                command = [forge, 'script', 'script/Batch.s.sol:Batch', '--rpc-url', url,
                           '--sender', owner, '--broadcast', '--non-interactive', *wallet]
                artifact = root / 'broadcast/Batch.s.sol/31337/run-latest.json'
                with (root / 'commands.log').open('w') as output:
                    started = time.monotonic()
                    subprocess.run(command, cwd=root, env=env, check=True, stdout=output, stderr=output, timeout=90)
                    elapsed = time.monotonic() - started
                    initial = json.loads(artifact.read_text())
                    self.assertEqual(len(initial['receipts']), 111)
                    self.assertTrue(all(int(row['status'], 16) == 1 for row in initial['receipts']))
                    self.assertLess(len({row['blockNumber'] for row in initial['receipts']}), 20)
                    self.assertLess(elapsed, 60, '111 transactions must not wait for 111 one-second blocks')
                    interrupted = subprocess.Popen([*command, '--slow'], cwd=root, env=env, stdout=output, stderr=output)
                    try:
                        deadline = time.monotonic() + 45
                        while int(rpc('eth_getTransactionCount', owner, 'latest'), 16) < 116:
                            if interrupted.poll() is not None or time.monotonic() > deadline:
                                self.fail('Native partial broadcast made no progress')
                            time.sleep(0.1)
                    finally:
                        interrupted.terminate()
                        interrupted.wait(timeout=10)
                    before = json.loads(artifact.read_text())
                    address = before['transactions'][0]['contractAddress']
                    submitted = {r['transactionHash'] for r in before['receipts']}
                    subprocess.run([*command, '--resume'], cwd=root, env=env, check=True,
                                   stdout=output, stderr=output, timeout=90)
                    final = json.loads(artifact.read_text())
                    self.assertEqual(final['transactions'][0]['contractAddress'], address)
                    self.assertEqual(len(final['receipts']), 111)
                    self.assertTrue(submitted <= {r['transactionHash'] for r in final['receipts']})
                    self.assertEqual(int(rpc('eth_getTransactionCount', owner, 'latest'), 16), 222)
                    self.assertEqual(int(rpc('eth_call', {'to': address, 'data': '0x3fa4f245'}, 'latest'), 16), 110)
                    print(f'Native Foundry: 111 transactions in {elapsed:.2f}s; interrupted resume verified.')
            finally:
                node.terminate()
                node.wait(timeout=10)


if __name__ == '__main__':
    unittest.main()
