"""Offline verification of the MemScan signatures against the game's own data table.

This test exists because the scanner's PRIMARY pattern is not a health value: it is the
archetype invariant block

    component + 0x28   Size      int32   == 3          (UnitSize_Massive)
    component + 0x2C   Mass      float32 == 30000.0
    component + 0x30   KillScore uint32  == 2000

The whole reason that pattern exists is that a *value* signature (150000) cannot match a
Hive Lord that has already been damaged -- a mistake that cost several live sessions.  So
the properties that make the replacement legitimate have to be checked against bytes, not
asserted in a comment:

  1. the exact pattern hard-coded in the Lua source occurs in
     filediver/datalibrary/generated_entities.dl_bin (45,630,790 bytes) EXACTLY ONCE;
  2. that one occurrence is the Hive Lord's record[27], at file offset
     HIVELORD_FILE_OFF + 0x28 -- so the scanner's INV_SIG_OFF arithmetic is right;
  3. each constant is doing real work: Size==3 alone is shared by many records, Mass and
     KillScore are each unique;
  4. the record the scanner would accept really is the Hive Lord: main Health 150000 and
     the 38-zone constellation that sums to the numbers the live readout checks against.

If the game's data ever drifts, or if someone "tidies" the constant, this test fails
instead of the mod silently reading the wrong number in a mission.

Run:  python HiveLord-HP/tests/test_signature.py
      python HiveLord-HP/tests/test_signature.py --self-test   (prove the checks can fail)
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT.parent
ENTRY = ROOT / 'Source/mods/hivelord/hivelord_memscan.lua'
DATA = REPO / 'filediver/datalibrary/generated_entities.dl_bin'

# Byte-exact layout facts from work/hivelord/HIVE_LORD_HEALTH.md (parsed out of the
# game's own typelib + this same data file).
BLOCK_MAGIC = 0x0075F1EE
REC_BASE = 0x00762F86
REC_STRIDE = 22096
N_REC = 493
HIVELORD_RECORD = 27
HIVELORD_FILE_OFF = 0x7F49F6

ZONE_BASE, ZONE_STRIDE, ZONE_COUNT = 0x208, 552, 38
ZONE_HEALTH_OFF, ZONE_CONST_OFF = 0xE8, 0xEC

EXPECT_ZONE_SUM = 1640000          # 9*150000 + 12*15000 + 20000 + 2*10000 + 14*5000
EXPECT_CONST_SUM = 455000          # 13 * 35000
EXPECT_TOTAL = 150000 + EXPECT_ZONE_SUM


def lua_pattern_bytes(source):
    """The bytes the Lua source actually ships, read out of the source itself."""
    m = re.search(r'HIVE_LORD_INV_SIG\s*=\s*le_bytes_from_hex\((.*?)\)', source)
    if not m:
        raise AssertionError('HIVE_LORD_INV_SIG is not defined the way this test expects')
    hexstr = ''.join(re.findall(r"'([0-9a-fA-F]+)'", m.group(1)))
    return bytes.fromhex(hexstr)


def i32(b, o): return struct.unpack_from('<i', b, o)[0]
def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def f32(b, o): return struct.unpack_from('<f', b, o)[0]


def evaluate(source, data):
    """All checks, as a pure function of (Lua source, data-table bytes)."""
    checks, detail = {}, {}
    detail['data_bytes'] = len(data)

    pat = lua_pattern_bytes(source)
    detail['pattern'] = pat.hex()
    checks['the shipped pattern is the 12-byte archetype block'] = (
        len(pat) == 12
        and pat[0:4] == struct.pack('<i', 3)
        and pat[4:8] == struct.pack('<f', 30000.0)
        and pat[8:12] == struct.pack('<I', 2000))

    # (1) exactly one occurrence in the whole file
    offs, start = [], 0
    while True:
        k = data.find(pat, start)
        if k < 0:
            break
        offs.append(k)
        start = k + 1
    detail['occurrences'] = len(offs)
    detail['occurrence_offsets'] = [hex(o) for o in offs]
    checks['the signature occurs exactly once in the 45 MB data table'] = len(offs) == 1

    # (2) and that occurrence is the Hive Lord record, at file_off + 0x28
    checks['it is the Hive Lord record head + 0x28'] = (
        len(offs) == 1 and offs[0] == HIVELORD_FILE_OFF + 0x28)

    # the scanner's arithmetic: component base = pattern - INV_SIG_OFF
    m = re.search(r'INV_SIG_OFF\s*=\s*(0x[0-9a-fA-F]+|\d+)', source)
    inv_off = int(m.group(1), 16) if m and m.group(1).lower().startswith('0x') else (
        int(m.group(1)) if m else -1)
    detail['inv_sig_off'] = hex(inv_off) if inv_off >= 0 else 'MISSING'
    checks['the source offset puts the base on the record head'] = any(
        o - inv_off == HIVELORD_FILE_OFF for o in offs)

    # sanity: the record really is at that offset in the record array
    checks['the offset really is record 27 of the array'] = (
        (HIVELORD_FILE_OFF - REC_BASE) % REC_STRIDE == 0
        and (HIVELORD_FILE_OFF - REC_BASE) // REC_STRIDE == HIVELORD_RECORD)
    checks['the block magic is where the layout says'] = \
        data[BLOCK_MAGIC:BLOCK_MAGIC + 4] == b'LDLD'

    # (3) each constant earns its place
    size3 = [r for r in range(N_REC) if i32(data, REC_BASE + r * REC_STRIDE + 0x28) == 3]
    mass = [r for r in range(N_REC) if f32(data, REC_BASE + r * REC_STRIDE + 0x2C) == 30000.0]
    kill = [r for r in range(N_REC) if u32(data, REC_BASE + r * REC_STRIDE + 0x30) == 2000]
    detail['records_size3'] = len(size3)
    detail['records_mass30000'] = mass
    detail['records_kill2000'] = kill
    checks['Size==3 alone is not unique, so the extra constants are load-bearing'] = len(size3) > 1
    checks['Mass==30000.0 is unique to the Hive Lord'] = mass == [HIVELORD_RECORD]
    checks['KillScore==2000 is unique to the Hive Lord'] = kill == [HIVELORD_RECORD]

    # (4) the accepted record is the Hive Lord, and its 38 zones sum to what the live
    #     readout asserts at runtime
    checks['the record main health is 150000'] = i32(data, HIVELORD_FILE_OFF) == 150000
    zone_sum, const_sum, const35k, healths = 0, 0, 0, {}
    for k in range(ZONE_COUNT):
        z = HIVELORD_FILE_OFF + ZONE_BASE + k * ZONE_STRIDE
        h = i32(data, z + ZONE_HEALTH_OFF)
        c = i32(data, z + ZONE_CONST_OFF)
        zone_sum += h
        const_sum += c
        if c == 35000:
            const35k += 1
        healths[h] = healths.get(h, 0) + 1
    detail['zone_sum'] = zone_sum
    detail['const_sum'] = const_sum
    detail['const35000_zones'] = const35k
    detail['zone_health_multiset'] = {str(k): v for k, v in sorted(healths.items())}
    checks['the zone health sum is the number the live readout checks'] = zone_sum == EXPECT_ZONE_SUM
    checks['the zone constitution sum is the number the live readout checks'] = const_sum == EXPECT_CONST_SUM
    checks['13 zones carry a 35000 constitution'] = const35k == 13
    detail['expected_total'] = EXPECT_TOTAL

    # and the same numbers the Lua constant carries
    bp = re.search(r'BP_EXPECT\s*=\s*\{\s*main\s*=\s*(\d+),\s*zone_sum\s*=\s*(\d+),'
                   r'\s*total\s*=\s*(\d+),\s*const35k\s*=\s*(\d+)\s*\}', source)
    checks['BP_EXPECT in the source matches the bytes'] = bool(bp) and (
        int(bp.group(1)), int(bp.group(2)), int(bp.group(3)), int(bp.group(4))) == \
        (150000, EXPECT_ZONE_SUM, EXPECT_TOTAL, 13)

    return checks, detail


MUTATIONS = {
    # The bug this whole signature replaced: a pattern made of the health value.
    'pattern-is-value-based': (
        "le_bytes_from_hex('03000000' .. '0060ea46' .. 'd0070000')",
        "le_bytes_from_hex('f0490200' .. '00000000')",
    ),
    # The scanner's base arithmetic drifts by one field.
    'inv-off-drifted': ('INV_SIG_OFF = 0x28', 'INV_SIG_OFF = 0x2C'),
    # The runtime layout assertion drifts away from the bytes.
    'bpexpect-drifted': ('zone_sum = 1640000', 'zone_sum = 1620000'),
    # The uniqueness property is asserted but not actually required any more.
    'pattern-only-size3': (
        "le_bytes_from_hex('03000000' .. '0060ea46' .. 'd0070000')",
        "le_bytes_from_hex('03000000' .. '00000000' .. '00000000')",
    ),
}


def report(checks, detail, quiet=False):
    if not quiet:
        for k, v in checks.items():
            print(f'{"PASS" if v else "FAIL"}  {k}')
        print()
        for k, v in detail.items():
            print(f'  {k} = {v}')
        print()
    failed = [k for k, v in checks.items() if not v]
    if failed:
        if not quiet:
            print(f'{len(failed)} check(s) failed')
        return 1, failed
    if not quiet:
        print(f'all {len(checks)} checks passed')
    return 0, []


def self_test(source, data):
    """Every mutation must be caught, or the checks above are decoration."""
    bad = 0
    for name, (old, new) in MUTATIONS.items():
        if old not in source:
            print(f'SKIP  {name}: anchor not found -- the self-test itself is stale')
            bad += 1
            continue
        checks, _ = evaluate(source.replace(old, new, 1), data)
        rc, failed = report(checks, {}, quiet=True)
        if rc == 0:
            print(f'NOT CAUGHT  {name} -- these checks cannot fail')
            bad += 1
        else:
            print(f'caught  {name}  by: {failed[0]}' + (
                f' (+{len(failed)-1} more)' if len(failed) > 1 else ''))
    print()
    if bad:
        print(f'{bad} mutation(s) escaped')
        return 1
    print(f'all {len(MUTATIONS)} mutations caught')
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--self-test', action='store_true',
                    help='mutate the source constants and require every check to fail')
    args = ap.parse_args()

    missing = [str(p) for p in (ENTRY, DATA) if not p.exists()]
    if missing:
        print('SKIP: missing input(s): ' + ', '.join(missing))
        return 0

    source = ENTRY.read_text(encoding='utf-8')
    data = DATA.read_bytes()
    if args.self_test:
        return self_test(source, data)
    checks, detail = evaluate(source, data)
    return report(checks, detail)[0]


if __name__ == '__main__':
    sys.exit(main())
