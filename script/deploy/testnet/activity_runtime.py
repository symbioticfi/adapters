#!/usr/bin/env python3
"""Host utilities for the randomized activity test harness."""
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PREFIX = 'script/deploy/testnet/'
LOCAL_CHAIN_ID = 31337
SEPOLIA_CHAIN_ID = 11155111
SEPOLIA = {
    'forwarder': '0xF8344CFd5c43616a4366C34E3EEE75af79a74482',
    'threeFRequestsFactory': '0x56834F241E4A4D6e5C4207B03bB16b2B3FfCc5fb',
    'threeFFacility': '0x68129DbAEefA7eB88fc0276b9C27A5169c43d675',
    'threeFWhitelist': '0xA80b976A357aC24f3c38F7E5ED3Dd5b813bb09E1',
    'usdc': '0x809e6c18bC13Cc7C9F7b8000d74243BAaccE84d7',
}


def run(argv, *, env=None, capture=False):
    env = dict(os.environ if env is None else env)
    env.setdefault('ETH_RPC_TIMEOUT', '120')
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


def address(value):
    return isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]{40}', value) is not None and int(value, 16) > 0


def same_address(left, right):
    return address(left) and address(right) and left.lower() == right.lower()


def upstream_pins():
    return '0x' + hashlib.sha256(Path(__file__).with_name('upstream').joinpath('pins.json').read_bytes()).hexdigest()


def load_manifest(path, owner, chain_id):
    try:
        data = json.loads(path.read_text())
        if data.get('upstreamPins') != upstream_pins():
            raise ValueError('Manifest upstream pins differ; use a fresh deployment.')
        if data['chainId'] != chain_id or not same_address(data['owner'], owner):
            raise ValueError('Manifest owner or chain does not match the configured deployment.')
        if data['schemaVersion'] != 2 or not isinstance(data['markets'], list) or len(data['markets']) != 7:
            raise ValueError('Expected a schema 2 manifest with seven markets.')
        if type(data['seedAssets']) is not int or data['seedAssets'] <= 0:
            raise ValueError('Manifest seed budget must be a positive integer.')
        if not address(data['chainlinkRegistry']) or not address(data['forwarder']):
            raise ValueError('Manifest oracle infrastructure must contain nonzero addresses.')
        if chain_id == SEPOLIA_CHAIN_ID:
            if data['infrastructure'] != 'sepolia':
                raise ValueError('Sepolia requires a sepolia manifest with a registry replica.')
            for key, expected in SEPOLIA.items():
                actual = data['markets'][0]['asset'] if key == 'usdc' else data[key]
                if not same_address(actual, expected):
                    raise ValueError(f'Manifest {key} does not match the official Sepolia binding.')
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f'Invalid manifest: {error}') from error
    return data
