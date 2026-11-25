#!/usr/bin/env python3
"""Check complete wrapper coverage against the current account interfaces."""
import json
import re
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
catalog = json.loads((ROOT / 'script/deploy/testnet/catalog/integrations.json').read_text())
profiles = catalog['profiles']
wrappers = sorted((ROOT / 'src/contracts/ll-adapter/tokens-to-redeem').glob('*.sol'))
expected = {p.stem.removesuffix('_Account'): p for p in wrappers}
actual = {p['symbol']: p for p in profiles if '/tokens-to-redeem/' in p['source']}
assert actual.keys() == expected.keys(), f'Catalog coverage drift: {actual.keys() ^ expected.keys()}'
assert len({p['symbol'] for p in profiles}) == len(profiles), 'Duplicate profile'
fixtures = [p for p in profiles if p.get('fixtureOnly')]
for profile in profiles:
    assert (ROOT / profile['source']).is_file(), f"Missing source for {profile['symbol']}"
assert all(p['symbol'] not in actual for p in fixtures), 'Wrapper marked fixture-only'
for symbol, source in expected.items():
    data = actual[symbol]
    assert data['source'] == str(source.relative_to(ROOT))
    family = re.search(r'is (\w+)', source.read_text()).group(1)
    assert data['family'] == family, f'{symbol}: account family changed'
    interface = ROOT / f'src/interfaces/ll-adapter/tokens-to-redeem/I{source.stem}.sol'
    constants = dict(re.findall(r'uint\d+ internal constant (\w+)\s*=\s*([^;]+)', interface.read_text()))
    assert data['constants'] == constants, f'{symbol}: source constants changed'
    assert data['cooldownSolidity'] == constants.get('TOKEN_COOLDOWN', '0')
    bounds = re.search(r'new \w+Oracle\(\s*([\d_.e]+)\s*,\s*([\d_.e]+)', source.read_text())
    if bounds:
        assert [data['minPrice'], data['maxPrice']] == [int(Decimal(v.replace('_', ''))) for v in bounds.groups()]
        assert data['minPrice'] <= data['fixturePrice'] <= data['maxPrice']
generic = len(profiles) - len(wrappers) - len(fixtures)
print(f'Covered all {len(wrappers)} wrappers, {generic} generic families and {len(fixtures)} fixture-only profiles.')
