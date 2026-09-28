"""Offline simulation + mutation tests for hivelord_probe.lua.

The probe runs once per game launch in a process that dies hard on a bad native
call, so the failures worth catching are not "Lua raised" but:

  * it called an engine member it was never allowed to call  (this actually
    crashed the game twice for an earlier probe in this workspace);
  * it ran the field sweep outside a mission;
  * it mis-identified something as a Hive Lord;
  * a crash lost its progress instead of resuming past the object that died.

Every one of those gets a fixture and a mutation test here, because a check that
cannot fail is not a check.  Run:  python HiveLord-HP/tests/run_tests.py
"""
import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / 'Source/mods/hivelord/hivelord_probe.lua'
FIXTURE = Path(__file__).resolve().parent / 'fixture.lua'

# Engine members the probe is allowed to touch.  Anything else in __CALLS is a
# speculative call.
ALLOWED = {
    'GS.game_object_exists',
    'GS.game_object_field_batched',
    'GS.in_session',
    'GS.objects_owned_by',
    'Net.game_session',
    'Net.peer_id',
    'Net.object_info',
    'App.worlds',
    'App.main_world',
}

TICKS = 1500
# Must exceed probe_delay (900 frames) so the "no sweep outside a mission" check
# is actually able to fail: at a lower value the probe has not reached Stage D at
# all during the ship phase and the check passes vacuously.
SHIP_TICKS = 1200


class Run:
    """One simulated game launch."""

    def __init__(self, probe_src, tmpdir, tick_offset=0):
        self.tmp = tmpdir
        os.environ['HIVELORD_TEST_APPDATA'] = str(tmpdir)
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        g.__HIVELORD_TEST = True
        self.lua.execute(FIXTURE.read_text(encoding='utf-8'))
        self.lua.execute(probe_src)
        self.g = self.lua.globals()
        self.tick = tick_offset

    def ticks(self, n, until=None):
        for _ in range(n):
            if until is not None and until():
                return True
            self.g.update(0.016)
            self.tick += 1
        return until is not None and until()

    def distinct_calls(self):
        return set(x for x in self.lua.eval('__distinct_calls()').split(',') if x)

    def probed(self):
        txt = self.lua.eval('__probed_text()')
        return [int(x) for x in txt.split(',') if x] if txt else []

    def speculative(self):
        return self.lua.eval('__SPECULATIVE_CALLED')

    def object_info_bad(self):
        return self.lua.eval('__OBJECT_INFO_BAD')

    def read(self, name):
        for d in (Path(self.tmp) / 'Arrowhead/Helldivers2', Path(self.tmp)):
            p = d / name
            if p.exists():
                return p.read_text(encoding='utf-8', errors='replace')
        return ''

    def find(self, pattern):
        out = []
        for d in (Path(self.tmp) / 'Arrowhead/Helldivers2', Path(self.tmp)):
            if d.exists():
                out += [p.name for p in d.glob(pattern)]
        return sorted(out)


def new_tmp(pristine=True):
    # ASCII-only path: Lua's fopen cannot open a path containing non-ASCII.
    d = Path(tempfile.mkdtemp(prefix='hlprobe_'))
    if pristine:
        # Model the real machine, where the game has already created this folder.
        (d / 'Arrowhead/Helldivers2').mkdir(parents=True, exist_ok=True)
    return d


def run_suite(probe_src):
    """Returns {check_name: bool} plus a few artefacts for the report."""
    checks = {}
    detail = {}
    tmp = new_tmp()
    try:
        r = Run(probe_src, tmp)
        # ---- Phase 1: on the ship. -------------------------------------------
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        ship_fields = [c for c in r.distinct_calls() if 'field_batched' in c]

        # ---- Phase 2: in a mission. -----------------------------------------
        r.ticks(TICKS, until=lambda: bool(r.find('hivelord_cand*')))
        # Keep going so the decoys at ids 40-42 are actually probed.  Stopping the
        # moment the real Hive Lord is found would make every decoy assertion pass
        # vacuously -- the decoys would never have been looked at.
        r.ticks(300)

        calls = r.distinct_calls()
        probed = r.probed()
        cand_files = r.find('hivelord_hit*')
        watch_files = r.find('hivelord_watch*')

        checks['no engine member outside the allow-list is called'] = not (
            calls - ALLOWED)
        checks['no speculative call flag was raised'] = r.speculative() is None
        checks['Net.object_info is never called without a valid type'] = \
            r.object_info_bad() is None
        checks['the field sweep does not run outside a mission'] = not ship_fields

        checks['the census runs and finds the fixture objects'] = \
            'census: ' in r.read('hivelord_STATUS.txt') or 'STAGE_C census_done' in r.read('hivelord.log')
        checks['the field probe actually ran'] = len(probed) > 20
        checks['the decoys were actually reached by the sweep'] = \
            all(x in probed for x in (40, 41, 42))
        checks['the Hive Lord object is identified'] = bool(cand_files) and \
            all('goid31' in f for f in cand_files)
        checks['exactly one candidate is reported'] = len(cand_files) == 1
        # If the networked array does not mirror the entity definition, the weak
        # branch is the safety net -- prove the fixture actually exercises it.
        checks['the weak fallback branch captured objects too'] = len(watch_files) > 0
        checks['the strong hit is not confused with a weak capture'] = \
            not any('goid31' in f for f in watch_files)
        checks['the single-150000 decoy is rejected'] = not any('goid40' in f for f in cand_files)
        checks['the two-150000 decoy is rejected'] = not any('goid41' in f for f in cand_files)
        checks['the no-150000 decoy is rejected'] = not any('goid42' in f for f in cand_files)
        checks['the candidate report carries the zone constellation'] = \
            '150000x10' in r.read(cand_files[0]) if cand_files else False
        checks['the api listing was written'] = 'FUNCTIONS:' in r.read('hivelord_api.txt')
        checks['the status file starts with a conclusion'] = \
            r.read('hivelord_STATUS.txt').startswith('hivelord-probe-v2')
        detail['candidate_files'] = cand_files
        detail['probed_count'] = len(probed)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # ---- Phase 3: crash mid-probe, then resume. -----------------------------
    tmp = new_tmp()
    try:
        r = Run(probe_src, tmp)
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.g.__CRASH_ON_PROBE = 31
        r.ticks(TICKS, until=lambda: bool(r.g.__DIED))
        died = bool(r.g.__DIED)
        logtext = r.read('hivelord.log')
        state = r.read('hivelord_state.txt')
        cursor = None
        for line in state.splitlines():
            m = line.strip().startswith('probe_cursor=')
            if m:
                cursor = int(line.strip().split('=')[1])
        checks['a crash during the sweep still lands the log'] = died and 'STAGE_C' in logtext
        checks['the last log line names the object that killed the process'] = \
            'STAGE_D probe_begin goid=31' in logtext
        # The fixture cannot abort in the middle of an update tick the way a native
        # fault does, so the cursor may have advanced one id past the killer.  The
        # invariant that matters is that the killer is never *behind* the cursor.
        checks['the cursor was written ahead of the risky call'] = \
            cursor is not None and 31 <= cursor <= 33

        r2 = Run(probe_src, tmp)
        r2.g.__set_ship_ticks(SHIP_TICKS)
        for _ in range(1500):
            r2.g.update(0.016)
            if len(r2.probed()) > 20:
                break
        second = r2.probed()
        checks['a relaunch resumes past the object that crashed it'] = \
            bool(second) and min(second) > 31
        detail['resume_first_probed'] = min(second) if second else None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return checks, detail


MUTATIONS = {
    # name -> (exact text in the probe, replacement)
    'speculative-engine-call': (
        "    wf('STAGE_A listed=%d lines (no engine call made)', #lines)",
        "    call(Net.all_objects)\n"
        "    wf('STAGE_A listed=%d lines (no engine call made)', #lines)",
    ),
    'loose-fingerprint-threshold': (
        "                if distinct >= MIN_DISTINCT and (found[150000] or 0) >= MIN_150K then",
        "                if distinct >= 1 then",
    ),
    'sweep-outside-mission': (
        "    if C.in_mission_only and owned_n == 0 then return end",
        "    if false then return end",
    ),
    'no-write-ahead-cursor': (
        "        save_cursor(id)                       -- write-ahead: a crash points here",
        "        -- cursor write removed",
    ),
    'allow-hit-on-decoy-by-dropping-150k-gate': (
        "                if distinct >= MIN_DISTINCT and (found[150000] or 0) >= MIN_150K then",
        "                if distinct >= 5 then",
    ),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mutate', help='apply one mutation and require a failure')
    ap.add_argument('--list', action='store_true')
    args = ap.parse_args()

    if args.list:
        for k in MUTATIONS:
            print(k)
        return 0

    src = PROBE.read_text(encoding='utf-8')

    if args.mutate:
        if args.mutate not in MUTATIONS:
            print('unknown mutation', args.mutate)
            return 2
        old, new = MUTATIONS[args.mutate]
        # CRLF: a multi-line anchor written with \n would never match and the mutation
        # would silently SKIP, which a sweep that demands a verdict now reports.
        flat = src.replace('\r\n', '\n')
        if old not in flat:
            print(f'SKIP {args.mutate}: anchor text not found (probe changed?)')
            return 2
        checks, _ = run_suite(flat.replace(old, new, 1))
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
