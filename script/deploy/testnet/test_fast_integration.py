"""Opt-in real Foundry batching and partial-resume tests on disposable local nodes."""
import contextlib
import io
import json
import os
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import bootstrap
import fast_broadcast as fast

SOURCE = '''pragma solidity ^0.8.18;
interface Vm {
    function startBroadcast(address owner) external;
    function stopBroadcast() external;
    function envAddress(string calldata name) external returns (address);
}
contract Counter {
    uint256 public value;
    function increment(uint256 expected) public { require(value == expected); value++; }
}
contract Batch {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    function run() public returns (address counter) {
        vm.startBroadcast(vm.envAddress("TESTNET_OWNER"));
        counter = address(new Counter());
        for (uint256 i; i < 110; i++) Counter(counter).increment(i);
        vm.stopBroadcast();
    }
}
'''


@unittest.skipUnless(os.environ.get('TESTNET_FAST_INTEGRATION') == '1',
                     'Set TESTNET_FAST_INTEGRATION=1 to exercise real Foundry on local nodes.')
class FastIntegrationTest(unittest.TestCase):
    def test_batching_and_resume_preserve_addresses_receipts_and_contract_state(self):
        forge, cast = bootstrap.tools()
        anvil = str(Path(forge).with_name('anvil'))
        with tempfile.TemporaryDirectory(prefix='adapters-fast-test-') as directory:
            root = Path(directory).resolve()
            (root / 'script').mkdir()
            (root / 'script/Batch.s.sol').write_text(SOURCE)
            (root / 'foundry.toml').write_text('[profile.default]\nsolc="0.8.37"\n'
                                             'evm_version="osaka"\nvia_ir=true\noptimizer=true\nbytecode_hash="none"\n')
            password = root / 'password'
            password.write_text('local-test-only')
            password.chmod(0o600)
            keystores = root / 'keystores'
            keystores.mkdir()
            env = os.environ.copy()
            env['CAST_PASSWORD'] = 'local-test-only'
            subprocess.run([cast, 'wallet', 'new', str(keystores), 'ephemeral'], env=env,
                           check=True, capture_output=True)
            wallet = ['--keystore', str(keystores / 'ephemeral'), '--password-file', str(password)]
            owner = subprocess.check_output([cast, 'wallet', 'address', *wallet], text=True).strip()
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            node = subprocess.Popen([anvil, '--host', '127.0.0.1', '--port', str(port), '--chain-id', '31337',
                                     '--block-time', '1', '--gas-limit', '200000000', '--silent'],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            rpc = fast.Rpc(f'http://127.0.0.1:{port}')
            try:
                time.sleep(0.5)
                rpc.call('anvil_setBalance', [owner, hex(100 * 10**18)])
                env.update(TESTNET_OWNER=owner, TESTNET_RPC_URL=rpc.url)
                command = [forge, 'script', 'script/Batch.s.sol:Batch', '--rpc-url', rpc.url,
                           '--no-isolate', '--non-interactive', '--disable-external-identification']
                with patch.object(bootstrap, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                    with (root / 'commands.log').open('w') as output:
                        original_run = bootstrap.run

                        def run(argv, *, env=None, capture=False):
                            if capture:
                                return original_run(argv, env=env, capture=True)
                            subprocess.run(argv, cwd=root, env=env, check=True, stdout=output, stderr=output)

                        with patch.object(bootstrap, 'run', side_effect=run):
                            first_manifest = root / 'first.json'
                            fast.broadcast(command, wallet, env, first_manifest)
                            scope = fast.hashlib.sha256(str(first_manifest).encode()).hexdigest()[:16]
                            pointer = root / 'cache/testnet-fast' / scope / 'Batch.s.sol/latest.json'
                            saved = json.loads(pointer.read_text())
                            result = json.loads((Path(saved['broadcastRoot']) / 'Batch.s.sol/31337/run-latest.json').read_text())
                            self.assertEqual(len(result['receipts']), 111)
                            self.assertLess(len({receipt['blockNumber'] for receipt in result['receipts']}), 10)
                            before = rpc.call('eth_getTransactionCount', [owner, 'latest'])
                            fast.broadcast(command, wallet, env, first_manifest, resume=True)
                            self.assertEqual(rpc.call('eth_getTransactionCount', [owner, 'latest']), before)
                            slow = subprocess.Popen([*command, '--skip-simulation', '--broadcast', '--slow', *wallet],
                                                    cwd=root, env=env, stdout=output, stderr=output)
                            try:
                                deadline = time.monotonic() + 30
                                while fast.number(rpc.call('eth_getTransactionCount', [owner, 'latest'])) < 116:
                                    if slow.poll() is not None or time.monotonic() > deadline:
                                        self.fail('Sequential fixture failed to make the required progress.')
                                    time.sleep(0.1)
                            finally:
                                if slow.poll() is None:
                                    slow.terminate()
                                slow.wait(timeout=10)
                            original = root / 'broadcast/Batch.s.sol/31337/run-latest.json'
                            original_bytes = original.read_bytes()
                            partial = json.loads(original_bytes)
                            partial_address = partial['transactions'][0]['contractAddress']
                            second_manifest = root / 'second.json'
                            fast.broadcast(command, wallet, env, second_manifest, resume=True)
                            scope = fast.hashlib.sha256(str(second_manifest).encode()).hexdigest()[:16]
                            saved = json.loads((root / 'cache/testnet-fast' / scope / 'Batch.s.sol/latest.json').read_text())
                            final = json.loads((Path(saved['broadcastRoot']) / 'Batch.s.sol/31337/run-latest.json').read_text())
                            self.assertEqual(len(final['receipts']), 111)
                            self.assertEqual(final['transactions'][0]['contractAddress'], partial_address)
                            self.assertEqual(original.read_bytes(), original_bytes)
                            self.assertTrue({receipt['transactionHash'] for receipt in partial['receipts']}
                                            <= {receipt['transactionHash'] for receipt in final['receipts']})
                            self.assertEqual(fast.number(rpc.call('eth_getTransactionCount', [owner, 'latest'])), 222)
                            value = rpc.call('eth_call', [{'to': partial_address, 'data': '0x3fa4f245'}, 'latest'])
                            self.assertEqual(fast.number(value), 110)
            finally:
                node.terminate()
                node.wait(timeout=10)


if __name__ == '__main__':
    unittest.main()
