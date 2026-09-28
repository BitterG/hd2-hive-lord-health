"""Offline simulation + mutation tests for hivelord_memscan.lua.

The scanner runs against the live process with a byte-signature search, so the
failure modes worth catching offline are:

  * it reads its candidate addresses through a non-pointer (real FFI aborts on
    that, so the stub does too);
  * it accepts a coincidental 150000 that is not a HealthComponent;
  * it misses a structure that straddles a chunk boundary;
  * it cannot see a live health value change;
  * a crash loses the scan position.

Run:  python HiveLord-HP/tests/test_memscan.py
"""
import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
ENTRY = ROOT / 'Source/mods/hivelord/hivelord_memscan.lua'
FIXTURE = Path(__file__).resolve().parent / 'fixture_mem.lua'


class Run:
    def __init__(self, src, tmp, pre=None):
        os.environ['HIVELORD_TEST_APPDATA'] = str(tmp)
        self.tmp = tmp
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(FIXTURE.read_text(encoding='utf-8'))
        if pre:
            self.lua.execute(pre)
        self.result = self.lua.execute(src)
        self.g = self.lua.globals()

    def ticks(self, n):
        for _ in range(n):
            self.g.update(0.016)

    def read(self, name):
        for d in (Path(self.tmp) / 'Arrowhead/Helldivers2', Path(self.tmp)):
            p = d / name
            if p.exists():
                return p.read_text(encoding='utf-8', errors='replace')
        return ''

    def count(self, pattern):
        return len([p for p in self.read('hivelord_mem.log').splitlines()
                    if pattern in p])


def new_tmp(pristine=True):
    d = Path(tempfile.mkdtemp(prefix='hlmem_'))
    if pristine:
        cfg_dir = d / 'Arrowhead/Helldivers2'
        cfg_dir.mkdir(parents=True, exist_ok=True)
        # A tiny per-frame budget forces every region to span several frames, which
        # is what makes the resume-inside-a-region logic observable.  chunk=65536
        # puts a real seam at 262144 for the straddling-signature fixture.
        (cfg_dir / 'hivelord_mem.cfg').write_text(
            'debug=true\nchunk=65536\nbudget_ms=0.001\nstart_delay=5\n'
            'watch_seconds=0.5\nrescan_seconds=2\n', encoding='ascii')
    return d


def run_suite(src):
    checks = {}
    detail = {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp)
        r.ticks(2500)          # start_delay is 600 frames; budget 6 ms/frame
        log = r.read('hivelord_mem.log')
        status = r.read('hivelord_mem_STATUS.txt')

        checks['the region inventory was built'] = 'REGIONS count=' in log
        checks['no read was attempted outside a mapped region'] = \
            int(r.g.__read_errors()) == 0
        checks['all four fixture regions were scanned'] = 'SCAN_DONE' in log

        r1 = r.count('MATCH addr=0x10000100')
        r2 = r.count('MATCH addr=0x2007FFF')  # seam region, address logged after scan
        checks['the genuine HealthComponent region 1 is found'] = r1 == 1
        checks['the coincidental 150000 decoy is rejected'] = \
            'why=decoy' not in log and r.count('MATCH addr=0x10000800') == 0
        checks['the live damaged copy is found'] = r.count('MATCH addr=0x40000000') == 1

        # The seam case: the 8-byte fixed signature spans a 65536-byte chunk seam.
        seam_lines = [l for l in log.splitlines()
                      if l.startswith('MATCH ') and '0x200' in l]
        detail['seam_hits'] = len(seam_lines)
        checks['a structure straddling a chunk seam is still found'] = len(seam_lines) == 1
        # ...and it must be found by a *signature* match.  If only the zone-array walk
        # reached it, the chunk overlap is not actually working.
        checks['the seam hit came from the signature, not the zone fallback'] = \
            len(seam_lines) == 1 and 'why=invariant' in seam_lines[0]

        # The shape the old scanner could never see: damaged health AND no zone table.
        # The 150000 value pattern cannot match a damaged health by construction, and the
        # zone fallback needs an intact 15000/35000 plate pair, so a block like this was
        # invisible to both paths.  Only the damage-independent archetype signature
        # (Size==3 | Mass==30000.0 | KillScore==2000) can reach it.
        slim_lines = [l for l in log.splitlines()
                      if l.startswith('MATCH ') and '0x50000000' in l]
        detail['slim_hits'] = len(slim_lines)
        checks['a damaged live copy with no zone table is found'] = len(slim_lines) == 1
        checks['it was found by the damage-independent signature'] = \
            len(slim_lines) == 1 and 'why=invariant' in slim_lines[0]
        checks['its damaged health is reported, not 150000'] = \
            len(slim_lines) == 1 and 'health=4711' in slim_lines[0]
        # The full component readout must reproduce the offline-verified constellation
        # exactly -- main 150000, zone health sum 1640000, zone constitution sum 455000,
        # TOTAL 1790000, 13 zones carrying 35000 constitution.  Anything else means the
        # zone offsets are wrong and a displayed HP would be wrong with them.
        checks['the readout reproduces the offline zone constellation'] = \
            ('zone_health_sum=1640000' in log and 'TOTAL=1790000' in log
             and 'zone_constitution_sum=455000' in log and 'const35000=13/13' in log)
        checks['a copy without a zone table falls back to the main health'] = \
            'TOTAL=4711' in log

        big = int(r.g.__big_reads())
        passes = max(1, sum(1 for l in log.splitlines() if l.startswith('SCAN_DONE')))
        detail['big_reads'] = big
        detail['scan_passes'] = passes
        # Bound it per pass: with re-scanning the total grows with the pass count,
        # and a restart-each-frame bug would dwarf even that.
        checks['large regions are scanned in a bounded number of chunks'] = \
            3 * passes <= big <= 40 * passes

        checks['the zone array was recognised'] = 'zones_plausible=38' in log
        checks['the zone constellation matches the Hive Lord'] = 'zones_magic=38' in log
        checks['the status file reports the match count'] = 'complete:' in status
        checks['hex context was captured for offline analysis'] = 'MATCH_HEX' in log
        # A pure data-table hit must be labelled as such, so a live copy is
        # distinguishable rather than silently identical.
        checks['matches are classified as blueprint or other'] = 'MATCH_KIND' in log
        checks['the pass count and rescan interval are reported'] = \
            'SCAN_DONE pass=1' in log and 'next_rescan_in=' in log
        # "The signature never matched" and "it matched but every candidate was rejected"
        # need opposite fixes, so the pass summary has to separate them.
        checks['the scan reports how often each pattern matched'] = \
            'pattern_hits(invariant=' in log and 'fixed=' in log and 'zone=' in log
        checks['the invariant pattern matched at least once'] = \
            'pattern_hits(invariant=0 ' not in log
        checks['the log reports its own health'] = \
            any(l.startswith('LOG_OPEN path=') and '%s' not in l and 'hivelord_mem.log' in l
                for l in log.splitlines())
        checks['the log actually received lines'] = len(log.splitlines()) > 5
        # A completed pass must leave the cursor at the start.  Leaving it at the end
        # made the next session resume there and scan nothing at all.
        checks['a completed pass resets the cursor to the start'] = \
            'region_cursor=1' in r.read('hivelord_mem_state.txt')
        # A single pass is not enough: the target usually spawns after the scan
        # starts, so the scanner must go round again.
        checks['a second scan pass happens'] = \
            'RESCAN start' in log and 'SCAN_DONE pass=2' in log

        # ---- the watch loop must see a live health change ---------------------
        before = r.count('WATCH_CHANGE')
        ok = r.g.__set_live_health(12345)
        r.ticks(400)
        after = r.count('WATCH_CHANGE')
        checks['a live health change is observed'] = bool(ok) and after > before
        checks['the change is reported with the new value'] = '-> 12345' in r.read('hivelord_mem.log')
        detail['watch_changes'] = after

        # ---- ...but a nonsense value must NOT be reported as a health change ---
        # A live session logged "health 185 -> 815043536" because a freed block had
        # been reused; the watcher must reject that instead of reporting it.
        bad_before = r.count('WATCH_CHANGE')
        r.g.__set_live_health(815043536)
        r.ticks(300)
        checks['an implausible value is rejected, not reported'] = \
            'WATCH_REJECT' in r.read('hivelord_mem.log') and \
            r.count('WATCH_CHANGE') == bad_before

        # ---- and a block whose fingerprint stops holding is dropped ------------
        r.g.__set_live_health(12345)
        r.ticks(60)
        broke = r.g.__break_fixed(0x40000000)
        r.ticks(300)
        checks['a block that stops matching is dropped, not read'] = \
            bool(broke) and 'MATCH_STALE' in r.read('hivelord_mem.log')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # ---- resume after a crash ----------------------------------------------
    tmp = new_tmp()
    try:
        r = Run(src, tmp)
        r.ticks(640)
        state = r.read('hivelord_mem_state.txt')
        checks['a scan cursor is written while scanning'] = 'region_cursor=' in state
        cursor = 0
        for line in state.splitlines():
            if line.startswith('region_cursor='):
                cursor = int(line.split('=')[1])
        detail['cursor_at_640_ticks'] = cursor
        r2 = Run(src, tmp)
        r2.ticks(700)
        checks['a relaunch resumes from the saved region'] = \
            'SCAN_RESUME region_index=' in r2.read('hivelord_mem.log')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return checks, detail


MUTATIONS = {
    # Scanner drops the fixed-field scoring and takes any 150000.
    'accept-any-150000': (
        "    if score < need then return end",
        "    if score < 0 then return end",
    ),
    # Scanner forgets to overlap chunks, so a seam signature is lost.
    'no-chunk-overlap': (
        "        off = off + want - 4096      -- overlap so a signature on a seam is not missed",
        "        off = off + want",
    ),
    # Scanner restarts each region every frame instead of resuming inside it.
    'restart-region-each-frame': (
        "    local off = M.region_off or 0",
        "    local off = 0",
    ),
    # Watch loop never compares against the previous value.
    'watch-never-detects-change': (
        "            if h ~= m.health then",
        "            if false then",
    ),
    # A raw number is passed where a pointer is required (the FFI type bug).
    'raw-number-to-pointer': (
        "        local blob = read(r.base + off, want)",
        "        local blob = read(tostring(r.base + off), want)",
    ),
    # The hit is not classified, so the memory-mapped data table cannot be told
    # apart from a live per-entity copy -- which is the whole question.
    'no-match-kind': (
        "    wf('MATCH_KIND addr=0x%x kind=%s implied_mapping_base=0x%x', addr, kind, delta)",
        "    -- classification removed",
    ),
    # Only one pass ever runs, so a target that spawns later is never seen.
    'no-rescan': (
        "    elseif M.clock >= (M.next_rescan or 0) and C.rescan_seconds > 0 then",
        "    elseif false then",
    ),
    # The cursor is left at the end of the list, so the next session resumes there
    # and scans nothing -- exactly what the live log showed (bytes=0 MiB).
    'no-cursor-reset': (
        "                save_cursor(1)",
        "                -- cursor left where the pass ended",
    ),
    # The log-open line is printed with its format specifier unexpanded, so the log
    # never records where it is.
    'logopen-unformatted': (
        "wf('LOG_OPEN path=%s', tostring(log_path))",
        "w('LOG_OPEN path=%s', tostring(log_path))",
    ),
    # A pinned address is believed forever, so a freed block that has been reused
    # gets read as if it were the component (live log: "health 185 -> 815043536").
    'no-revalidate': (
        "        if vscore < vneed then",
        "        if not blob then",
    ),
    # The primary pattern is replaced by the OLD value-based one (150000).  This is
    # precisely the bug that cost several live sessions: a signature made of a health
    # value cannot see a Hive Lord that has already been damaged, so the damaged copy
    # with no zone table disappears from the results.
    'invariant-signature-is-value-based': (
        "local HIVE_LORD_INV_SIG = le_bytes_from_hex('03000000' .. '0060ea46' .. 'd0070000')",
        "local HIVE_LORD_INV_SIG = le_bytes_from_hex('f0490200' .. '00000000')",
    ),
    # Zone Health read from the wrong offset, so every zone number -- and therefore the
    # whole HP readout -- is silently wrong while still looking plausible.
    'zone-health-offset-wrong': (
        "local ZONE_HEALTH_OFF, ZONE_CONST_OFF = 0xE8, 0xEC",
        "local ZONE_HEALTH_OFF, ZONE_CONST_OFF = 0xD8, 0xEC",
    ),
    # The full component readout never runs, so a match is found but no HP is produced.
    'no-live-readout': (
        "                if m.invariants then\n                    local full = read(m.addr, COMP_SIZE)",
        "                if false then\n                    local full = read(m.addr, COMP_SIZE)",
    ),
    # The pattern-hit counter is not maintained, so the log can no longer distinguish
    # "the signature never matched" from "it matched and everything was rejected".
    'pattern-hits-not-counted': (
        "                M.inv_hits = M.inv_hits + 1",
        "                M.inv_hits = M.inv_hits",
    ),
    # No plausibility gate, so a reused allocation is reported as a health change.
    'no-plausibility-gate': (
        "            if h and h >= 0 and h <= C.max_plausible_health then",
        "            if h then",
    ),
}


def run_env_suite(src):
    """A fallback scanner that cannot work must say so, not fail silently."""
    checks = {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre=(
            "ffi = nil\n"
            "require = function(n) if n == 'ffi' then return nil end\n"
            "  error('module not found: ' .. tostring(n)) end\n"))
        status = r.read('hivelord_mem_STATUS.txt')
        log = r.read('hivelord_mem.log')
        checks['a missing ffi is reported in STATUS and the log'] = \
            'ffi builtin is unavailable' in status and 'ffi builtin is unavailable' in log
        installed = None
        if r.result is not None:
            try:
                installed = r.result['installed']
            except Exception:
                installed = None
        checks['a missing ffi reports that it did not install'] = installed is False
        checks['the scanner does not start without ffi'] = \
            'START memscan' not in log
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mutate')
    ap.add_argument('--list', action='store_true')
    args = ap.parse_args()
    if args.list:
        for k in MUTATIONS:
            print(k)
        return 0

    src = ENTRY.read_text(encoding='utf-8')
    if args.mutate:
        if args.mutate not in MUTATIONS:
            print('unknown mutation', args.mutate)
            return 2
        old, new = MUTATIONS[args.mutate]
        # CRLF: a multi-line anchor written with \n would never match and the mutation
        # would silently SKIP, which a sweep that demands a verdict now reports.
        flat = src.replace('\r\n', '\n')
        if old not in flat:
            print(f'SKIP {args.mutate}: anchor not found')
            return 2
        mutated = flat.replace(old, new, 1)
        checks, _ = run_suite(mutated)
        checks.update(run_env_suite(mutated))
        failed = sorted(k for k, v in checks.items() if not v)
        print(f'--- mutation {args.mutate} ---')
        for k in failed:
            print('  caught by:', k)
        if failed:
            print('MUTATION CAUGHT')
            return 0
        print('MUTATION NOT CAUGHT -- the suite has a hole')
        return 1

    checks, detail = run_suite(src)
    checks.update(run_env_suite(src))
    for k, v in checks.items():
        print(f'{"PASS" if v else "FAIL"}  {k}')
    print()
    for k, v in detail.items():
        print(f'  {k} = {v}')
    failed = [k for k, v in checks.items() if not v]
    print()
    if failed:
        print(f'{len(failed)} check(s) failed')
        return 1
    print(f'all {len(checks)} checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
