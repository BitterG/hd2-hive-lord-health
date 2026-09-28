"""Build the Hive Lord addons as installable Bingus Shared Loader packages.

Also runs the static checks that only the real, one-shot game environment can
punish you for -- most importantly "this file may not reference any engine member
outside the allow-list", because an earlier probe in this workspace walked the
Network table and crashed the game twice.

Usage:  python HiveLord-HP/scripts/build_addons.py [--target probe|memscan]
"""
import argparse
import json
import re
import struct
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT.parent
sys.path.insert(0, str(REPO / 'BingusSharedLoader/scripts'))
sys.path.insert(0, str(ROOT / 'tests'))

from archive import ARCHIVE, TYPE, make_archive, resource_hash  # noqa: E402
import loader_accept  # noqa: E402

FORBIDDEN_PATTERNS = [
    (r'WriteProcessMemory', 'process memory write'),
    (r'VirtualProtect', 'page protection change'),
    (r'set_game_object_field', 'engine field write'),
    (r'CreateFileW', 'raw Win32 file API'),
    (r'0x1[0-9a-fA-F]{8,}', 'hardcoded absolute address'),
]

# ---------------------------------------------------------------- target: probe
PROBE = {
    'entry': ROOT / 'Source/mods/hivelord/hivelord_probe.lua',
    'resource': 'mods/hivelord/hivelord_probe',
    'display': 'Hive Lord HP Probe 1.1.0',
    'zip': 'HiveLord-HP-Probe-1.1.0.zip',
    'guid': 'b1f0c6a4-5d2e-4f77-9a3c-7e1d2b8c4f10',
    'blurb': ('Read-only Hive Lord health reconnaissance. Requires Bingus Shared '
              'Loader v15 or newer (API 1); the loader is the only other thing you '
              'need to install. Findings go to %APPDATA%\\Arrowhead\\Helldivers2\\ '
              '(hivelord_STATUS.txt first).'),
    'required': [
        ('-- HD2-Addon: mods/hivelord/hivelord_probe', 'addon declaration'),
        ('game_object_field_batched', 'the field read this probe exists to prove'),
        ('MIN_150K', 'the Hive Lord 150000 gate'),
        ('save_cursor', 'crash-resumable cursor'),
        ('STAGE_D probe_begin', 'write-ahead logging'),
        ('WEAK', 'the weak fallback branch'),
    ],
    'allow_members': {
        'GameSession': {'game_object_exists', 'game_object_field_batched',
                        'in_session', 'objects_owned_by'},
        'Network': {'game_session', 'peer_id', 'object_info'},
        'Application': {'worlds', 'main_world'},
        'World': set(),
        'Gui': set(),
    },
    'allow_sr': {'Application', 'Network', 'GameSession', 'World', 'Gui'},
    'allow_ffi': False,
    'extra': [('hivelord.cfg', 'hivelord.cfg')],
    'readme': 'README.txt',
}

# -------------------------------------------------------------- target: health
# Exact Hive Lord health, by the method of the Enemy HP mod, pinned to one game build and
# gated on the PE headers of game.dll and helldivers2.exe.  Read-only.
HEALTH = {
    'entry': ROOT / 'Source/mods/hivelord/hivelord_health.lua',
    'resource': 'mods/hivelord/hivelord_health',
    'display': 'Hive Lord Health 1.10.0',
    'zip': 'HiveLord-HP-Health-1.10.0.zip',
    'guid': '3e9c7a41-5b28-4d0e-9f13-8a2c6b7d4e91',
    'blurb': ('Read-only: the Hive Lord\'s exact current and maximum health, read from the '
              'game\'s health manager on game build 25480438. Verified for that build from '
              'the PE headers of game.dll and helldivers2.exe; refuses on any other build. '
              'Requires Bingus Shared Loader v15 or newer (API 1). Findings go to '
              '%APPDATA%\\Arrowhead\\Helldivers2\\ (hivelord_health_STATUS.txt first).'),
    'required': [
        ('-- HD2-Addon: mods/hivelord/hivelord_health', 'addon declaration'),
        ('ReadProcessMemory', 'the only way to reach the manager'),
        ('supported_build', 'fail-closed build identification from the module headers'),
        ('TimeDateStamp', 'the header fields the build identity is made of'),
        ('max_for_type', 'the health-table lookup that gives the maximum'),
    ],
    'allow_members': {
        'GameSession': set(),
        'Network': set(),
        'Application': {'worlds', 'main_world'},
        'World': {'create_screen_gui', 'destroy_gui'},
        'Gui': {'text', 'update_text', 'destroy_text', 'resolution', 'material'},
    },
    'allow_sr': {'Application', 'World', 'Gui', 'Vector2', 'Vector3', 'Color',
                 'IdString64', 'Material'},
    'allow_ffi': True,
    'extra': [],
    'readme': 'README_HEALTH.txt',
}

# -------------------------------------------------------------- target: roster
# Read-only faction-roster reader.  No engine Lua API is used at all and no memory is
# written; the only imports are GetModuleHandleA, GetCurrentProcess and
# ReadProcessMemory, all on the current process.
ROSTER = {
    'entry': ROOT / 'Source/mods/hivelord/hivelord_roster.lua',
    'resource': 'mods/hivelord/hivelord_roster',
    'display': 'Hive Lord Roster + HP Probe 1.1.0',
    'zip': 'HiveLord-HP-Roster-1.1.0.zip',
    'guid': '7b41e2c8-3d95-4a76-8f02-6c1d9e4a7b30',
    'blurb': ('Read-only: answers whether the Hive Lord is in this mission by walking the '
              'director faction roster, independently of the networked field array. '
              'Requires Bingus Shared Loader v15 or newer (API 1). Findings go to '
              '%APPDATA%\\Arrowhead\\Helldivers2\\ (hivelord_roster_STATUS.txt first).'),
    'required': [
        ('-- HD2-Addon: mods/hivelord/hivelord_roster', 'addon declaration'),
        ('ReadProcessMemory', 'the only way to reach the roster'),
        ('build_gate', 'fail-closed check that the build matches the verified offsets'),
        ('reference_overlap', 'the self-check that separates reading the roster from '
                              'reading something plausible'),
        ('entities_in', 'the pure row walk'),
    ],
    'allow_members': {k: set() for k in ('GameSession', 'Network', 'Application',
                                         'World', 'Gui')},
    'allow_sr': set(),
    'allow_ffi': True,
    'extra': [],
    'readme': 'README_ROSTER.txt',
}

# -------------------------------------------------------------- target: memscan
MEMSCAN = {
    'entry': ROOT / 'Source/mods/hivelord/hivelord_memscan.lua',
    'resource': 'mods/hivelord/hivelord_memscan',
    'display': 'Hive Lord HP MemScan 1.1.0',
    'zip': 'HiveLord-HP-MemScan-1.1.0.zip',
    'guid': 'c72d5f18-9a44-4b03-8e6f-1a4d7c2b9e55',
    'blurb': ('Read-only fallback: locates Hive Lord health structures in process '
              'memory by signature and watches them. Requires Bingus Shared Loader '
              'v15 or newer (API 1). Findings go to '
              '%APPDATA%\\Arrowhead\\Helldivers2\\ (hivelord_mem_STATUS.txt first).'),
    'required': [
        ('-- HD2-Addon: mods/hivelord/hivelord_memscan', 'addon declaration'),
        ('ReadProcessMemory', 'the only way to reach a live health value'),
        ('HIVE_LORD_SIG', 'the secondary (value-based) signature'),
        ('HIVE_LORD_INV_SIG', 'the primary damage-independent signature'),
        ('report_live', 'the full main+38-zone readout that the network fields cannot give'),
        ('save_cursor', 'crash-resumable cursor'),
    ],
    'allow_members': {k: set() for k in ('GameSession', 'Network', 'Application',
                                         'World', 'Gui')},
    'allow_sr': set(),
    'allow_ffi': True,
    'extra': [],
    'readme': 'README_MEMSCAN.txt',
}

# ------------------------------------------------------------------- target: hp
HP = {
    'entry': ROOT / 'Source/mods/hivelord/hivelord_hp.lua',
    'resource': 'mods/hivelord/hivelord_hp',
    'display': 'Hive Lord HP Reader 1.2.0',
    'zip': 'HiveLord-HP-Reader-1.2.0.zip',
    'guid': '0a7c4e21-6b58-4d9f-9c31-2f8e5a6d0b74',
    'blurb': ('Read-only Hive Lord live health reader with runtime self-calibration '
              'and an optional text HUD. Requires Bingus Shared Loader v15 or newer '
              '(API 1). Findings go to %APPDATA%\\Arrowhead\\Helldivers2\\ '
              '(hivelord_hp_STATUS.txt first).'),
    'required': [
        ('-- HD2-Addon: mods/hivelord/hivelord_hp', 'addon declaration'),
        ('game_object_field_batched', 'the field read this mod exists to prove'),
        ('calibrate', 'runtime field self-calibration'),
        ('MIN_150K', 'the Hive Lord 150000 gate'),
        ('save_state', 'crash-resumable cursor and pinned goid'),
        ('create_screen_gui', 'the optional HUD surface'),
    ],
    'allow_members': {
        'GameSession': {'game_object_exists', 'game_object_field_batched',
                        'in_session', 'objects_owned_by'},
        'Network': {'game_session', 'peer_id', 'object_info'},
        'Application': {'worlds', 'main_world'},
        'World': {'create_screen_gui', 'destroy_gui'},
        'Gui': {'text', 'destroy_text', 'destroy_triangle', 'resolution'},
    },
    'allow_sr': {'Application', 'Network', 'GameSession', 'World', 'Gui',
                 'Vector2', 'Vector3', 'Color'},
    'allow_ffi': False,
    'extra': [('hivelord_hp.cfg', 'hivelord_hp.cfg')],
    'readme': 'README_HP.txt',
}

TARGETS = {'probe': PROBE, 'memscan': MEMSCAN, 'hp': HP, 'roster': ROSTER,
           'health': HEALTH}
ALIAS = {'GS': 'GameSession', 'Net': 'Network', 'App': 'Application',
         'World': 'World', 'Gui': 'Gui'}


def strip_lua_comments(src):
    """Remove Lua comments so the member check sees code, not prose.

    Without this, merely *mentioning* an engine member in a comment trips the
    allow-list check -- which is a false positive, and a false positive here
    teaches the wrong lesson about which text is dangerous.
    """
    src = re.sub(r'--\[\[.*?\]\]', ' ', src, flags=re.S)
    src = re.sub(r'--[^\n]*', ' ', src)
    return src


def checks(t, src_override=None):
    src = src_override if src_override is not None else t['entry'].read_text(encoding='utf-8')
    code = strip_lua_comments(src)
    raw = src.encode('utf-8')
    out = []

    def check(label, ok):
        out.append((label, bool(ok)))

    check('entry is plain ASCII without a BOM or NUL',
          raw[:3] != b'\xef\xbb\xbf' and b'\0' not in raw and raw.isascii())
    check('entry declares the resource name on line 1',
          src.splitlines()[0] == '-- HD2-Addon: ' + t['resource'])
    for pat, why in FORBIDDEN_PATTERNS:
        if why == 'process memory write' and t['allow_ffi']:
            continue
        check(f'no {why}', not re.search(pat, code))
    if t['allow_ffi']:
        check('FFI is used for reading only (no write primitive)',
              'ffi.' in code and not re.search(r'VirtualProtectEx|WriteProcessMemory', code))
    else:
        check('no FFI use (this addon must stay pure Lua)', 'ffi.' not in code)
    for needle, why in t['required']:
        check(f'contains {why}', needle in src)

    bad = []
    for ns in ('GS', 'Net', 'App', 'World', 'Gui'):
        for m in re.finditer(rf'\b{ns}\.([A-Za-z_][A-Za-z0-9_]*)', code):
            if m.group(1) not in t['allow_members'][ALIAS[ns]]:
                bad.append(f'{ns}.{m.group(1)}')
    check('no engine member outside the allow-list is referenced'
          + ('' if not bad else ' -- offenders: ' + ', '.join(sorted(set(bad)))),
          not bad)

    bad_sr = [m.group(0) for m in re.finditer(r'\bsr\.[A-Za-z_][A-Za-z0-9_]*', code)
              if m.group(0)[3:] not in t['allow_sr']]
    check('no stingray sub-namespace outside the allow-list is referenced'
          + ('' if not bad_sr else ' -- offenders: ' + ', '.join(sorted(set(bad_sr)))),
          not bad_sr)

    check('the API surface stage only reads the table (no dynamic invocation)',
          'call(t[' not in code and 'call(Net[fn]' not in code and 'call(GS[fn]' not in code)

    name = t['display']
    check('manifest Name is pure ASCII with no Windows-illegal characters',
          name.isascii() and not re.search(r'[\\/:*?"<>|]', name))
    return out


def build(t):
    src = t['entry'].read_bytes()
    marker = ('-- HD2-Addon: ' + t['resource'] + '\n').encode()
    if src.startswith(b'-- HD2-Addon:'):
        line, _, rest = src.partition(b'\n')
        assert line.rstrip(b'\r') == marker[:-1], 'declaration does not match resource name'
        body = marker + rest
    else:
        body = marker + src
    entry = struct.pack('<II', len(body), 2) + body
    archive = make_archive({resource_hash(t['resource']): entry})

    description = t['blurb']
    manifest = {
        'Version': 1,
        'Guid': t['guid'],
        'Name': t['display'],
        'Description': description,
        'Options': [{'Name': 'Core', 'Description': description, 'Include': ['Addon']}],
    }
    files = {
        'manifest.json': (json.dumps(manifest, indent=2) + '\n').encode(),
        'Addon/' + ARCHIVE: archive,
        'Addon/' + ARCHIVE + '.stream': b'',
        'Addon/' + ARCHIVE + '.gpu_resources': b'',
        'README.txt': (ROOT / t['readme']).read_bytes(),
    }
    for src_name, zip_name in t['extra']:
        files[zip_name] = (ROOT / src_name).read_bytes()

    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    out = dist / t['zip']
    with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for path, content in sorted(files.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, content)
    return out, archive, body


def verify_archive(archive, body, resource):
    magic, version, count, _pad, size, _u, _p = struct.unpack_from('<III20sQQ24s', archive, 0)
    assert magic == 0xF0000011, hex(magic)
    assert version == 1 and count == 1, (version, count)
    assert size == len(archive), (size, len(archive))
    row = 72 + 32 * version
    name_hash, etype, offset = struct.unpack_from('<QQQ', archive, row)
    length = struct.unpack_from('<Q', archive, row + 56)[0]
    assert etype == TYPE, hex(etype)
    assert name_hash == resource_hash(resource), 'resource hash mismatch'
    blob = archive[offset:offset + length]
    blen, bver = struct.unpack_from('<II', blob, 0)
    assert bver == 2, bver
    assert blob[8:8 + blen] == body, 'round-trip body mismatch'
    return True


def self_test():
    """Prove the allow-list check can actually fail, and is not fooled by prose."""
    t = TARGETS['hp']
    src = t['entry'].read_text(encoding='utf-8')
    label = 'no engine member outside the allow-list is referenced'
    failures = 0

    def result(mutated, what, want_fail):
        nonlocal failures
        got = dict(checks(t, mutated))
        key = [k for k in got if k.startswith(label)][0]
        failed = not got[key]
        ok = (failed == want_fail)
        print(f'{"PASS" if ok else "FAIL"}  {what} -> check {"fails" if failed else "passes"}')
        if not ok:
            failures += 1

    result(src, 'the real source passes', False)
    result(src + '\nlocal _ = Gui.rect(1, 2)\n', 'a real out-of-list call is caught', True)
    result(src + '\n-- a comment mentioning Gui.rect must not trip it\n',
           'merely mentioning a member in a comment is not a call', False)
    result(src + '\nlocal _ = World.create_particle_effect()\n',
           'a real out-of-list World call is caught', True)
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--target', choices=sorted(TARGETS), default='probe')
    ap.add_argument('--self-test', action='store_true',
                    help='verify the static checks themselves can fail')
    args = ap.parse_args()

    if args.self_test:
        n = self_test()
        print(f'\n{"self-test failed" if n else "static checks are falsifiable"}')
        return 1 if n else 0

    t = TARGETS[args.target]

    results = checks(t)
    failed = 0
    for label, ok in results:
        print(f'{"PASS" if ok else "FAIL"}  {label}')
        if not ok:
            failed += 1
    if failed:
        print(f'\n{failed} static check(s) failed; not building')
        return 1

    out, archive, body = build(t)
    verify_archive(archive, body, t['resource'])
    # Final gate: the loader's own discovery rules, reimplemented in
    # tests/loader_accept.py.  A package the loader would not find is a mod that
    # silently never starts, which is the single most expensive failure mode here.
    names, rejected = loader_accept.scan_file(archive)
    if names != [t['resource']]:
        print(f'\nFAIL  the loader would not discover this package'
              f' (found {names}, rejected {rejected})')
        return 1
    print(f'loader-acceptance verified: discovered {names[0]}')
    print(f'\nround-trip verified: {len(archive)} byte archive, '
          f'{len(body)} byte Lua body')
    print(f'built {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
