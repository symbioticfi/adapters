"""Scheduler and mined-receipt accounting regressions; no wallet or RPC required."""
import contextlib
import io
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import actions as activity

OWNER = '0x' + '1' * 40
OTHER = '0x' + '2' * 40


class ActivityCommandsTest(unittest.TestCase):
    def test_identity_includes_protocol_dependencies_catalog_and_compiler_settings(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            dependency = root / 'lib/dependency/Protocol.sol'
            dependency.parent.mkdir(parents=True)
            dependency.write_text('pragma solidity ^0.8.0;')
            initial = activity.source_identity(root)
            dependency.write_text('pragma solidity ^0.8.4;')
            changed = activity.source_identity(root)
            self.assertNotEqual(initial, changed)
            (root / 'foundry.toml').write_text('solc="0.8.37"')
            configured = activity.source_identity(root)
            self.assertNotEqual(changed, configured)
            catalog = root / activity.PREFIX / 'catalog/integrations.json'
            catalog.parent.mkdir(parents=True)
            catalog.write_text('{"profiles":[]}')
            self.assertNotEqual(configured, activity.source_identity(root))

    def test_zero_batches_cannot_start_a_continuous_process(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            activity.main(['--rpc-url', 'unused', '--manifest', 'unused', '--account', 'unused',
                           '--password-file', 'unused', '--batches', '0'])
        self.assertEqual(error.exception.code, 2)

    def test_large_foundry_uints_keep_exact_integer_precision(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'result.json'
            path.write_text('{"amount":"68000000000000000000","seed":"111740672179550993908803040417935088694581348640773243496867842352916845954315","settled":1,"nextCursor":"2","cursors":[0,"3"],"families":["1",0],"request":"0x0123","executed":false}')
            result = activity.load_result(path)
        self.assertEqual(result['amount'] // 100, 680000000000000000)
        self.assertEqual(result['seed'], 111740672179550993908803040417935088694581348640773243496867842352916845954315)
        self.assertEqual(result['cursors'], [0, 3])
        self.assertEqual(result['families'], [1, 0])
        self.assertEqual(result['request'], '0x0123')
        self.assertFalse(result['executed'])

    def test_explicit_entrypoint_uses_its_own_broadcast_artifact(self):
        self.assertEqual(activity.artifact_name(), 'run-latest.json')
        self.assertEqual(activity.artifact_name('runConsume()'), 'runConsume-latest.json')

    def test_seeded_schedule_covers_every_profile_once_and_every_market(self):
        data = {'markets': [{'rwaProfiles': list(range(i, 52, 7))} for i in range(7)]}
        scheduled = activity.tasks(data, 42, 0)
        self.assertEqual(len(scheduled), 73)
        self.assertEqual(sorted(task[3] for task in scheduled if task[3] is not None), list(range(52)))
        self.assertEqual(scheduled, activity.tasks(data, 42, 0))
        self.assertNotEqual(scheduled, activity.tasks(data, 42, 1))
        self.assertNotEqual(scheduled, activity.tasks(data, 43, 0))

    def receipt(self, tx, status='0x1'):
        return {'transactionHash': tx, 'status': status, 'from': OWNER,
                'blockNumber': '0x10', 'gasUsed': '0x5208', 'logs': [{}]}

    def artifact(self, nonce=3, sender=OWNER):
        return {'transactions': [{'hash': '0xabc', 'transaction': {'nonce': hex(nonce), 'from': sender}}]}

    def test_success_requires_matching_live_receipt(self):
        receipts = activity.verify_receipts(self.artifact(), 3, 4, OWNER, self.receipt)
        self.assertEqual(receipts, [{'hash': '0xabc', 'block': 16, 'gasUsed': 21000, 'logs': 1}])

    def test_combining_native_prepare_and_consume_keeps_each_phase_nonce_bounded(self):
        prepared = {'startNonce': 3, 'endNonce': 4}
        consumed = {'startNonce': 4, 'endNonce': 5}
        consume_artifact = self.artifact(4)
        consume_artifact['transactions'][0]['hash'] = '0xdef'
        task_receipts = activity.record_receipts(prepared, self.artifact(), OWNER, self.receipt)
        task_receipts += activity.record_receipts(consumed, consume_artifact, OWNER, self.receipt)
        self.assertEqual([r['hash'] for r in task_receipts], ['0xabc', '0xdef'])
        self.assertEqual([r['hash'] for r in prepared['receipts']], ['0xabc'])
        self.assertEqual([r['hash'] for r in consumed['receipts']], ['0xdef'])

    def test_stale_artifact_or_unaccounted_nonce_is_rejected(self):
        for artifact in (self.artifact(2), self.artifact(sender=OTHER), {'transactions': []}):
            with self.assertRaises(ValueError):
                activity.verify_receipts(artifact, 3, 4, OWNER, self.receipt)
        with self.assertRaises(ValueError):
            activity.verify_receipts(self.artifact(), 3, 5, OWNER, self.receipt)

    def test_failed_transaction_or_wrong_hash_cannot_count_as_activity(self):
        with self.assertRaises(ValueError):
            activity.verify_receipts(self.artifact(), 3, 4, OWNER, lambda tx: self.receipt(tx, '0x0'))
        with self.assertRaises(ValueError):
            activity.verify_receipts(self.artifact(), 3, 4, OWNER, lambda tx: self.receipt('0xwrong'))

    def test_duplicate_nonce_is_rejected(self):
        artifact = self.artifact()
        artifact['transactions'] *= 2
        with self.assertRaises(ValueError):
            activity.verify_receipts(artifact, 3, 4, OWNER, self.receipt)

    def test_empty_broadcast_has_no_activity_evidence(self):
        self.assertEqual(activity.verify_receipts({}, 3, 3, OWNER, self.receipt), [])


if __name__ == '__main__':
    unittest.main()
