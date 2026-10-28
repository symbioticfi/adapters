import copy
import unittest

from export_config import export_market


def address(number):
    return '0x' + format(number, '040x')


class ExportConfigTest(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            'chainId': 31337, 'startBlock': 10, 'collateral': address(2), 'collateralFeed': address(11),
            'threeFRequestsFactory': address(3), 'threeFFirstRequest': 3758, 'recipeCapability': address(4), 'recipeExecutorFactory': address(12),
            'aaveHealthFactorReader': address(5), 'eulerHealthFactorReader': address(6),
            'morphoBlueHealthFactorReader': address(7), 'aaveV3LiquidityReader': address(8),
            'aaveV4LiquidityReader': address(9), 'morphoLiquidityReader': address(10),
        }
        self.market = {key: address(i + 20) for i, key in enumerate([
            'asset', 'vault', 'merkleAdapter', 'merkleAdapterFactory', 'morphoBlue', 'morphoVault',
            'aavePool', 'aaveDataProvider', 'aaveV4', 'eulerEVC', 'eulerFactory', 'eulerVault',
            'eulerCollateralVault', 'assetFeed', 'morphoFactory', 'reactor', 'threeFPolicy', 'policyFactory', 'connectorFactory',
        ])}
        self.market['morphoBlueMarketId'] = '0x' + 'ab' * 32
        self.market['decimals'] = 6

    def test_exports_actual_pool_data_provider_factories_and_prices(self):
        profile, inventory = export_market(self.manifest, self.market, 'a' * 40)
        portfolio = profile['portfolio']
        self.assertEqual(portfolio['aaveV3'][0]['provider'], self.market['aaveDataProvider'])
        self.assertEqual(portfolio['aaveV3'][0]['pool'], self.market['aavePool'])
        self.assertEqual(portfolio['euler']['factory'], self.market['eulerFactory'])
        self.assertEqual(portfolio['prices']['feeds'][self.market['asset']]['feeds'][0]['proxy'], self.market['assetFeed'])
        self.assertEqual(inventory['commit'], 'a' * 40)
        self.assertEqual(inventory['adapter'], self.market['merkleAdapter'])
        scopes = inventory['chains'][0]['protocols']
        euler = next(p for p in scopes if p['protocol'] == 'euler')
        self.assertEqual(euler['ids'], [self.market['eulerVault'], self.market['eulerCollateralVault']])
        self.assertEqual(euler['subaccounts'], [0])
        self.assertEqual(portfolio['threeF']['firstRequest'], 3758)
        self.assertEqual(portfolio['threeF']['startBlock'], 10)
        self.assertNotIn('rpcURL', str(profile))

    def test_shared_lending_reserves_include_every_explicit_price_route(self):
        other = copy.deepcopy(self.market)
        other.update(asset=address(100), assetFeed=address(101))
        self.manifest['markets'] = [self.market, other]
        profile, _ = export_market(self.manifest, self.market, 'a' * 40)
        self.assertEqual(profile['portfolio']['prices']['feeds'][other['asset']]['feeds'][0]['proxy'], other['assetFeed'])

    def test_refuses_missing_or_zero_required_facts(self):
        for key in ['aaveDataProvider', 'eulerFactory', 'morphoBlue']:
            with self.subTest(key=key):
                broken = copy.deepcopy(self.market)
                broken[key] = address(0)
                with self.assertRaisesRegex(ValueError, key):
                    export_market(self.manifest, broken, 'a' * 40)

    def test_refuses_unpinned_metadata(self):
        with self.assertRaisesRegex(ValueError, '40-hex metadata commit'):
            export_market(self.manifest, self.market, 'latest')


if __name__ == '__main__':
    unittest.main()
