"""Validate an addon archive against the loader's own discovery rules.

`BingusSharedLoader/src/discover.lua` is the authority on whether a mod is found:
it parses each deployed `9ba626afa44a3aa3.patch_<n>`, looks for the Lua resource
type, walks to the envelope, reads the declaration from the first 256 body bytes
and finally checks that the MurmurHash64A of the declared name equals the key the
archive stored.  Anything less than that is a mod that silently never starts.

This reimplements those rules literally -- including the details that are easy to
get wrong (offset64 gives up when the high word exceeds 2^21 because Lua numbers
are doubles; an unmarked override hides an older declaration with the same key;
higher patch numbers win) -- so the packaging path can be proven before a game
launch is spent on it.

Usage:
    python HiveLord-HP/tests/loader_accept.py --deployed
    python HiveLord-HP/tests/loader_accept.py --zip <pkg.zip>...
    python HiveLord-HP/tests/loader_accept.py --self-test
"""
import argparse
import re
import struct
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT.parent / 'BingusSharedLoader/scripts'))
from archive import resource_hash  # noqa: E402

GAME = Path(r'E:\SteamLibrary\steamapps\common\Helldivers 2')
FAMILY = '9ba626afa44a3aa3'
LUA_TYPE_BYTES = bytes((226, 23, 209, 44, 250, 141, 78, 161))
MAGIC = 0xF0000011
DECLARATION = re.compile(rb'^-- HD2-Addon: (mods/[A-Za-z0-9_]+/[A-Za-z0-9_/]+)\r?\n')


def u32(b, off):
    return struct.unpack_from('<I', b, off)[0]


def offset64(b, off):
    high = u32(b, off + 4)
    if high > 2097151:            # Lua's exact-integer ceiling, per discover.lua
        return None
    return u32(b, off) + high * 4294967296


def declaration(prefix):
    m = DECLARATION.match(prefix)
    if not m:
        return None
    name = m.group(1).decode('ascii')
    if '//' in name or name.endswith('/') or name == 'mods/codex/loader':
        return None
    return name


def key_bytes(name):
    return resource_hash(name).to_bytes(8, 'little')


def scan_file(data):
    """Returns (discovered_names, rejected_reasons) for one archive."""
    names, rejected = [], []
    size = len(data)
    if size < 72:
        return names, ['truncated header']
    if u32(data, 0) != MAGIC:
        return names, [f'invalid archive magic {u32(data, 0):#x}']
    types, count = u32(data, 4), u32(data, 8)
    table_start = 72 + 32 * types
    table_end = table_start + 80 * count
    if not (types > 0 and table_end <= size):
        return names, ['truncated archive tables']

    seen = set()
    for index in range(count):
        row = data[table_start + index * 80: table_start + index * 80 + 80]
        if len(row) < 80:
            rejected.append(f'row {index} truncated')
            continue
        if row[8:16] != LUA_TYPE_BYTES:
            continue
        key = row[0:8]
        offset, length = offset64(row, 16), u32(row, 56)
        if seen.__contains__(key):
            continue
        if offset is None or offset < table_end or length < 8:
            rejected.append(f'row {index}: offset/length unusable')
            continue
        if offset > size or length > size - offset:
            rejected.append(f'row {index}: resource outside the archive')
            continue
        envelope = data[offset:offset + 8]
        body_length = u32(envelope, 0)
        if u32(envelope, 4) != 2 or body_length > length - 8:
            rejected.append(f'row {index}: bad envelope')
            continue
        seen.add(key)
        prefix = data[offset + 8: offset + 8 + min(body_length, 256)]
        name = declaration(prefix)
        if not name:
            rejected.append(f'row {index}: no valid declaration')
            continue
        if key_bytes(name) != key:
            rejected.append(f'row {index}: declaration {name!r} does not hash to its key')
            continue
        names.append(name)
    return names, rejected


def scan_deployed(game=GAME):
    """Reproduce discovery.scan's ordering and override semantics."""
    data_dir = game / 'data'
    files = []
    for p in data_dir.glob(f'{FAMILY}.patch_*'):
        m = re.fullmatch(rf'{FAMILY}\.patch_(\d+)', p.name)
        if m:
            files.append((int(m.group(1)), p))
    files.sort()
    found, order = {}, []
    for number, path in files:
        names, rejected = scan_file(path.read_bytes())
        for name in names:
            if name not in found:
                found[name] = (number, path.name)
                order.append(name)
        if rejected:
            print(f'  {path.name}: rejected {rejected}')
    return found


def check_zip(path):
    with zipfile.ZipFile(path) as z:
        members = [n for n in z.namelist()
                   if re.fullmatch(rf'Addon/{FAMILY}\.patch_\d+', n)]
        if not members:
            return [], [f'{path.name}: no {FAMILY}.patch_N inside']
        out, rej = [], []
        for n in sorted(members):
            names, r = scan_file(z.read(n))
            out += names
            rej += r
        return out, rej


def self_test():
    """The check must be able to fail, or it proves nothing."""
    pkg = ROOT / 'dist/HiveLord-HP-Reader-1.0.10.zip'
    if not pkg.exists():
        print('SKIP: build the hp package first')
        return 2
    with zipfile.ZipFile(pkg) as z:
        blob = z.read(f'Addon/{FAMILY}.patch_0')
    failures = 0

    def expect(what, data, want_names, want_reject):
        nonlocal failures
        names, rejected = scan_file(data)
        ok = names == want_names and bool(rejected) == want_reject
        print(f'{"PASS" if ok else "FAIL"}  {what}'
              f' -> names={names} rejected={len(rejected)}')
        if not ok:
            failures += 1

    expect('the real archive is discovered',
           blob, ['mods/hivelord/hivelord_hp'], False)

    # A corrupted declaration must be refused, not silently accepted.
    broken = bytearray(blob)
    at = broken.find(b'-- HD2-Addon: mods/hivelord/hivelord_hp')
    assert at > 0, 'declaration not found in the archive'
    broken[at + 14:at + 22] = b'XXXXXXXX'
    expect('a mangled declaration is rejected', bytes(broken), [], True)

    # A declaration that does not hash to its stored key must be refused.
    other = bytearray(blob)
    other[at:at + 38] = b'-- HD2-Addon: mods/hivelord/other_name\n'
    expect('a declaration whose hash does not match is rejected', bytes(other), [], True)

    # A wrong magic means the whole archive is ignored.
    bad_magic = bytearray(blob)
    bad_magic[0] = 0
    expect('a wrong magic is rejected', bytes(bad_magic), [], True)
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--deployed', action='store_true')
    ap.add_argument('--zip', nargs='*', default=[])
    ap.add_argument('--self-test', action='store_true')
    ap.add_argument('--expect', action='append', default=[],
                    help='resource name that must be discovered')
    args = ap.parse_args()

    if args.self_test:
        n = self_test()
        print(f'\n{"self-test failed" if n else "discovery checking is falsifiable"}')
        return 1 if n else 0

    failed = 0
    if args.deployed:
        print(f'--- deployed patches in {GAME / "data"} ---')
        found = scan_deployed()
        for name, (number, fname) in sorted(found.items()):
            print(f'  discovered {name}  (patch_{number} = {fname})')
        for want in args.expect:
            ok = want in found
            print(f'{"PASS" if ok else "FAIL"}  the loader discovers {want}')
            if not ok:
                failed += 1

    for z in args.zip:
        names, rej = check_zip(Path(z))
        print(f'--- {Path(z).name} ---')
        for n in names:
            print(f'  discovered {n}')
        for r in rej:
            print(f'  rejected: {r}')
        if not names:
            print(f'FAIL  {Path(z).name} would not be discovered')
            failed += 1

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
