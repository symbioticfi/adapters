"""Export public consumer configuration from one freshly deployed manifest."""

import argparse
import json
from pathlib import Path
import re

ZERO = '0x' + '0' * 40
REPOSITORY = 'https://github.com/symbioticfi/metadata-sepolia'


def required(source, key):
    value = source.get(key, '')
    if not re.fullmatch(r'0x[0-9a-fA-F]{40}', value) or value.lower() == ZERO:
        raise ValueError(f'{key} requires a nonzero address')
    return value.lower()


def export_market(manifest, market, commit):
    if not re.fullmatch(r'[0-9a-fA-F]{40}', commit):
        raise ValueError('an exact 40-hex metadata commit is required')
    chain = manifest['chainId']
    if not isinstance(chain, int) or chain <= 0:
        raise ValueError('positive chainId is required')
    asset = required(market, 'asset')
    collateral = required(manifest, 'collateral')
    feeds = {}
    for token, feed in ([(required(row, 'asset'), required(row, 'assetFeed')) for row in manifest.get('markets', [market])]
                        + [(collateral, required(manifest, 'collateralFeed'))]):
        feeds[token] = {'feeds': [{'proxy': feed, 'heartbeat': 86400}]}
    three_f = manifest.get('threeFRequestsFactory', ZERO).lower()
    if three_f == ZERO and market.get('threeFRequest', ZERO).lower() != ZERO:
        raise ValueError('synthetic 3F requests cannot enter a production consumer profile')
    first_request = manifest.get('threeFFirstRequest')
    if three_f != ZERO and (type(first_request) is not int or first_request < 0):
        raise ValueError('threeFFirstRequest requires the captured factory baseline')
    portfolio = {
        'chainId': chain, 'metadataRepo': 'metadata-sepolia',
        'aaveV3': {'core': {'pool': required(market, 'aavePool'), 'provider': required(market, 'aaveDataProvider')}},
        'aaveV4': [required(market, 'aaveV4')],
        'euler': {'evc': required(market, 'eulerEVC')},
        'morphoBlue': required(market, 'morphoBlue'),
        'threeF': {'factory': three_f, 'firstRequest': first_request} if three_f != ZERO else None,
        'merkl': None,
        'prices': {'feeds': feeds},
        'rwa': {'products': {}, 'midasStartIDs': {}, 'paretoStartEpochs': {}, 'pareto': {}},
        'ember': [],
    }
    protocols = [
        {'protocol': 'tokens', 'ids': list(feeds)},
        {'protocol': 'aave_v3', 'ids': ['core']},
        {'protocol': 'aave_v4', 'ids': [required(market, 'aaveV4')]},
        {'protocol': 'euler', 'ids': [required(market, 'eulerVault'), required(market, 'eulerCollateralVault')], 'subaccounts': [0]},
        {'protocol': 'morpho_blue', 'ids': [market['morphoBlueMarketId']]},
        {'protocol': 'morpho_vaultv2', 'ids': [required(market, 'morphoVault')]},
    ]
    if portfolio['threeF']:
        protocols.append({'protocol': 'three_f', 'ids': []})
    profile = {
        'fromBlock': str(manifest['startBlock']),
        'merkleAdapterFactory': required(market, 'merkleAdapterFactory'),
        'recipeCapability': required(manifest, 'recipeCapability'),
        'recipeExecutorFactory': required(manifest, 'recipeExecutorFactory'),
        'eulerEvc': required(market, 'eulerEVC'),
        'vaultFactories': {'euler': required(market, 'eulerFactory'), 'morphoVaultV2': required(market, 'morphoFactory')},
        'morphoBlue': portfolio['morphoBlue'],
        'threeF': {'policyFactory': required(market, 'policyFactory'), 'requestsFactory': three_f},
        'liquidLane': {'connectorFactory': required(market, 'connectorFactory'), 'reactor': required(market, 'reactor'), 'protocol': None},
        'healthFactors': {'aave': required(manifest, 'aaveHealthFactorReader'), 'euler': required(manifest, 'eulerHealthFactorReader'), 'morphoBlue': required(manifest, 'morphoBlueHealthFactorReader')},
        'liquidity': {'aaveV3': required(manifest, 'aaveV3LiquidityReader'), 'aaveV4': required(manifest, 'aaveV4LiquidityReader'), 'morpho': required(manifest, 'morphoLiquidityReader')},
        'suggestions': {'aavePools': [{'address': required(market, 'aavePool'), 'label': 'Aave'}], 'tokens': [{'address': asset, 'label': market.get('symbol', 'Asset')}]},
        'portfolio': portfolio,
    }
    inventory = {'repository': REPOSITORY, 'commit': commit.lower(), 'adapter': required(market, 'merkleAdapter'),
                 'chainId': chain, 'chains': [{'chainId': chain, 'protocols': protocols}]}
    return profile, inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--metadata-commit', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    exported = [export_market(manifest, market, args.metadata_commit) for market in manifest['markets']]
    args.out.mkdir(parents=True, exist_ok=True)
    for market, (profile, inventory) in zip(manifest['markets'], exported):
        folder = args.out / required(market, 'merkleAdapter')
        folder.mkdir(exist_ok=True)
        (folder / 'deployment.json').write_text(json.dumps(profile, indent=2) + '\n')
        (folder / 'metadata.json').write_text(json.dumps(inventory, indent=2) + '\n')
        (folder / 'portfolio.json').write_text(json.dumps(profile['portfolio'], indent=2) + '\n')
    print(f'Exported {len(exported)} public deployment profiles to {args.out}')


if __name__ == '__main__':
    main()
