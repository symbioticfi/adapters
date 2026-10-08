#!/usr/bin/env python3
"""Check complete wrapper coverage and unchanged source-pinned protocol engines."""
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
for dependency, name, version in [('morpho-blue', 'Morpho', '0.8.19'), ('morpho-midnight', 'Midnight', '0.8.34')]:
    source = (ROOT / f'lib/{dependency}/src/{name}.sol').read_text()
    local = (ROOT / f'script/deploy/testnet/protocols/upstream/Testnet{name}.sol').read_text()
    source = source.replace(f'pragma solidity {version};', f'pragma solidity ^{version};')
    source = source.replace('"./', f'"{dependency}/src/').replace(f'contract {name} is ', f'contract Testnet{name} is ')
    # Formatting/comments can differ; executable tokens must remain identical.
    def tokens(value):
        value = re.sub(r'/\*.*?\*/|//[^\n]*', '', value, flags=re.S)
        tokenize = lambda text: re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z0-9_]+|[^\s]', text)
        imports = sorted(tokenize(text) for text in re.findall(r'import\b[^;]*;', value, flags=re.S))
        value = re.sub(r'import\b[^;]*;', '', value, flags=re.S)
        return tokenize(value) + [token for statement in imports for token in statement]
    assert tokens(source) == tokens(local), f'{name}: upstream logic changed'
print(f'Covered all {len(wrappers)} wrappers and {len(profiles)-len(wrappers)} generic families; native engines unchanged.')
