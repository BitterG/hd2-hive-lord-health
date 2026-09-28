"""Offline simulation + mutation tests for hivelord_hp.lua (the reader).

This is the addon that must actually read live health, so the properties under
test are the ones that decide whether one game session is enough:

  * it finds the Hive Lord object by arithmetic alone (no type name available);
  * it identifies the *maximum* health field as the one that does not move and the
    *current* value field as the one that does -- after damage;
  * it reports the largest drop as main health, not a zone;
  * a coincidental 150000 is not mistaken for a Hive Lord;
  * the HUD is off unless asked for, and does not leak gui objects;
  * a pinned goid survives a relaunch so the sweep is not repeated;
  * no engine member outside the allow-list is ever touched.

Run:  python HiveLord-HP/tests/test_hp.py
"""
import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
ENTRY = ROOT / 'Source/mods/hivelord/hivelord_hp.lua'
FIXTURE = Path(__file__).resolve().parent / 'fixture_hp.lua'

ALLOWED = {
    'GS.game_object_exists', 'GS.game_object_field_batched', 'GS.in_session',
    'GS.objects_owned_by', 'Net.game_session', 'Net.peer_id', 'Net.object_info',
    'App.worlds', 'App.main_world', 'World.create_screen_gui', 'World.destroy_gui',
    'Gui.text', 'Gui.destroy_text', 'Gui.destroy_triangle', 'Gui.resolution',
}

TICKS = 1600
SHIP_TICKS = 1200


class Run:
    def __init__(self, src, tmp, expose_pure=False, pre=None):
        os.environ['HIVELORD_TEST_APPDATA'] = str(tmp)
        self.tmp = tmp
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(FIXTURE.read_text(encoding='utf-8'))
        if pre:
            self.lua.execute(pre)
        if expose_pure:
            self.lua.execute('__HIVELORD_EXPOSE_PURE = true')
        self.result = self.lua.execute(src)
        self.g = self.lua.globals()

    def ticks(self, n, until=None):
        for _ in range(n):
            if until is not None and until():
                return True
            self.g.update(0.016)
        return until is not None and until()

    def count(self, pattern):
        return len([p for p in Path(self.tmp).rglob(pattern)])

    def find(self, pattern):
        out = []
        for d in (Path(self.tmp) / 'Arrowhead/Helldivers2', Path(self.tmp)):
            if d.exists():
                out += [p.name for p in d.glob(pattern)]
        return sorted(out)

    def read(self, name):
        for d in (Path(self.tmp) / 'Arrowhead/Helldivers2', Path(self.tmp)):
            p = d / name
            if p.exists():
                return p.read_text(encoding='utf-8', errors='replace')
        return ''

    def calls(self):
        return set(x for x in self.lua.eval('__distinct_calls()').split(',') if x)

    def hp_lines(self):
        return [l for l in self.read('hivelord_hp.log').splitlines()
                if l.startswith('HP ')]

    def last_hp(self):
        lines = self.hp_lines()
        return lines[-1] if lines else ''

    def field(self, name):
        """Pull `name=value` out of the last HP log line."""
        line = self.last_hp()
        if not line:
            return None
        for tok in line.split():
            if tok.startswith(name + '='):
                return tok.split('=', 1)[1]
        return None


def new_tmp(with_hud):
    d = Path(tempfile.mkdtemp(prefix='hlhp_'))
    cfg = d / 'Arrowhead/Helldivers2'
    cfg.mkdir(parents=True, exist_ok=True)
    (cfg / 'hivelord_hp.cfg').write_text(
        'debug=true\nhud=%s\n' % ('true' if with_hud else 'false'), encoding='ascii')
    return d


def run_suite(src, hud=False):
    checks, detail = {}, {}
    tmp = new_tmp(hud)
    try:
        r = Run(src, tmp)
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        calls = r.calls()
        checks['no engine member outside the allow-list is called'] = not (calls - ALLOWED)
        checks['no speculative call flag was raised'] = r.g.__SPECULATIVE_CALLED is None
        # The old contract was "do nothing while objects_owned_by is empty".  That
        # contract wasted a whole live session (MISSION_ENTER three times, zero
        # owned objects, census never ran).  The census is cheap and is now the
        # thing that decides, so assert *that* instead.
        early = r.read('hivelord_hp.log')
        checks['an empty owned list does not stop the census'] = \
            'OWNED_ZERO' in early and 'SWEEP start' in early
        checks['an empty owned list is stated in STATUS'] = \
            'objects_owned_by returned nothing' in r.read('hivelord_hp_STATUS.txt')

        # ---- in a mission: find it ------------------------------------------
        r.ticks(TICKS, until=lambda: r.field('identified') is not None)
        checks['the Hive Lord object is identified'] = r.field('identified') == 'true'
        checks['the reported field count is the fixture array size'] = \
            r.field('fields') == '46'
        checks['the fingerprint counts the single 150000 maximum'] = \
            '150000x1' in r.read('hivelord_hp.log')

        pre = r.last_hp()
        checks['the maximum-health field is identified'] = 'max_idx=17' in pre
        # The current value is a six-bit synchronised fraction, and it is found by its
        # quantisation, not by an index.  256/255 and 254/255 sit in the same array and
        # are also just above/below 1, so a looser "the only value under 1" rule would
        # have been satisfied by the wrong field -- it is the k/63 test that makes this
        # identification specific rather than lucky.
        checks['the synchronised fraction is found by its quantisation'] = 'sync_idx=7' in pre
        checks['the fraction is decoded as a k/63 step'] = r.field('sync_k') == '61'
        checks['the reading is derived from the fraction, not an absolute field'] = \
            r.field('cur') == '145238'
        checks['the resolution limit is stated'] = 'step=2381' in pre
        checks['the reading is labelled client-synced'] = r.field('client_synced') == 'true'
        checks['the damage mask is found by its all-ones first value'] = \
            r.field('mask_idx') == '44'
        checks['the damage mask value is reported'] = r.field('mask') == '16383'

        # ---- damage: the fraction falls and the mask loses a bit -------------
        r.g.__damage(5000, 900)
        r.ticks(600)
        hp = r.last_hp()
        checks['the fraction is re-read after damage'] = r.field('sync_k') == '59'
        checks['the health figure follows the fraction'] = r.field('cur') == '140476'
        checks['the maximum stays the known 150000 constant'] = r.field('max') == '150000'
        checks['the damage mask falls'] = r.field('mask') == '16382'
        checks['the moved fields are listed'] = 'moved=[' in hp and '7:' in hp
        checks['the status file states the reading and its limits'] = \
            ('HP sync=140476/150000' in r.read('hivelord_hp_STATUS.txt')
             and 'client-synced value' in r.read('hivelord_hp_STATUS.txt'))
        # The diagnostics run during this scenario, and their verdict must not take the
        # conclusion away from the reading.  Asserted here rather than only in the short
        # surface suite, where the diagnostics never get a chance to run -- so a verdict
        # that overwrites the conclusion unconditionally would go unnoticed there.
        checks['the diagnostics do not take the conclusion from the reading'] = \
            'CONCLUSION: HP sync=' in r.read('hivelord_hp_STATUS.txt')
        # The loader's JIT cache state decides how this mod's own timings should be read:
        # a flush discards every compiled trace, so a hitch during one is the environment,
        # not this mod.  Asserted because the loader's `version` field is not usable as a
        # signal -- the v18 source still reports version = 17.
        checks['the status reports the loader JIT cache state'] = \
            'loader jit: managed 16384 KB / 8000 traces' in \
            r.read('hivelord_hp_STATUS.txt')

        # ---- the read loop must not stop after one pass ------------------------
        # A Hive Lord that appears and dies between two censuses was never read at all,
        # and "no candidate found" then looks identical to "no Hive Lord was present".
        # That is not a hypothetical: the ninth run probed 901 objects while a Hive Lord
        # was fought and killed in the same mission.
        log_now = r.read('hivelord_hp.log')
        checks['the probe queue is rebuilt after it drains'] = 'PROBE_REQUEUE' in log_now
        samples = r.read('hivelord_hp_samples.txt')
        listed = [l for l in samples.splitlines() if l and not l.startswith('#')]
        checks['the complete per-object shape is written to its own file'] = \
            '# id\tfields\tdistinct_magic' in samples
        checks['the shape file is complete rather than sampled'] = len(listed) >= 20
        # The hull in the fixture is 35 fields but carries a recognised 8000; goid 50 is
        # 24 fields with NO recognised value at all.  Both must be dumped: requiring a
        # recognised value is exactly how a target whose array look differs between
        # missions stays invisible.
        checks['a large object is dumped even without a known magic value'] = \
            'SHAPE_DUMP goid=50 fields=24' in log_now

        # ---- the coincidence must not be accepted ---------------------------
        log = r.read('hivelord_hp.log')
        checks['the single-150000 decoy is not identified as a Hive Lord'] = \
            'HIVE_LORD goid=40' not in log

        # ---- HUD ------------------------------------------------------------
        if hud:
            checks['the HUD text was drawn'] = '140476' in r.g.__gui_texts()
            checks['the HUD is labelled as a synchronised reading'] = \
                'HIVE LORD SYNC' in r.g.__gui_texts()
            created, destroyed = r.g.__gui_counts().split(',')
            checks['exactly one gui surface was created'] = created == '1'
            # A redraw must not create a second surface.
            r.ticks(200)
            created2, _ = r.g.__gui_counts().split(',')
            checks['redrawing does not create another surface'] = created2 == '1'

            def bar():
                # The HUD draws two lines now, so pick the one that carries the bar
                # rather than assuming it is the last.
                for txt in r.g.__gui_texts().split('|'):
                    if '[' in txt and ']' in txt:
                        return txt[txt.index('[') + 1:txt.index(']')]
                return ''

            b = bar()
            detail['bar'] = b
            # 140476/150000 of 24 cells is 22.5 -> 23 filled (round half up).
            checks['the bar is proportional'] = b == '=' * 23 + '-'
            checks['the percentage is shown'] = '93.7%' in r.g.__gui_texts()
            # The honesty line is not decoration: the display must name the wire value
            # it came from and its resolution, because the exact HP does not exist in
            # this process (FINDINGS.md §23).
            checks['the HUD names the synchronised wire value'] = 'wire 59/63' in r.g.__gui_texts()
            checks['the HUD states the resolution limit'] = '+-2381' in r.g.__gui_texts()
            checks['the HUD says it is not an exact HP'] = \
                'client-synced, not exact HP' in r.g.__gui_texts()
            checks['the HUD shows the damage mask'] = 'mask 16382/16383' in r.g.__gui_texts()

            # ---- the HUD must not stack -----------------------------------------
            # Reported from play: the lines piled up, new ones drawn while the old ones
            # stayed.  The cause was that Gui.text's return value was thrown away and 0
            # and 1 were remembered instead, so clear_hud destroyed handles that were
            # never issued.  Live handles are what says whether that is true.
            detail['live_texts'] = int(r.g.__gui_live_texts())
            checks['the HUD holds one reading, not a stack'] = \
                int(r.g.__gui_live_texts()) <= 2
            destroyed_before = r.g.__gui_destroy_ids()
            for v in (140000, 130000, 120000):
                r.g.__set_main_health(v)
                # The probe cycle is 2 s, so the reading -- and therefore the redraw --
                # only moves after ~120 frames.  Four frames proved nothing.
                r.ticks(140)
            detail['live_texts_after'] = int(r.g.__gui_live_texts())
            checks['each redraw retires the previous pair'] = \
                int(r.g.__gui_live_texts()) <= 2
            checks['redrawing destroys the handles it was given'] = \
                r.g.__gui_destroy_ids() != destroyed_before
            ids = [int(x) for x in r.g.__gui_destroy_ids().split(',') if x]
            checks['every destroyed handle was a real one'] = bool(ids) and min(ids) >= 1

            # ---- and it must not outlive the target ------------------------------
            # The other way a stale bar stays on screen: the object goes (killed or
            # despawned) while the world is unchanged.  What must not remain is the
            # identified READING.  The fixture still holds a decoy with a single 150000, so
            # the honest outcome here is the candidate line -- the mod can see a
            # 150000-holder but has no damage value for it.  Either state is acceptable;
            # a leftover "HIVE LORD SYNC" is not.
            r.g.__remove_goid(31)
            r.ticks(140)
            texts_after = r.g.__gui_live_text()
            detail['after_target_gone'] = texts_after[:80]
            checks['no identified reading survives the target'] = \
                'HIVE LORD SYNC' not in texts_after
            checks['the HUD either clears or shows a candidate, never stale data'] = \
                int(r.g.__gui_live_texts()) == 0 or 'candidate' in texts_after
            checks['a recognised candidate is named, not given a number'] = \
                'candidate' in texts_after and 'no damage value yet' in texts_after

            # ---- and it must not outlive its mission ----------------------------
            # Reported from play: the bar was still on screen after the mission ended.
            # The surface belongs to a world that a mission change replaces, so the mod
            # has to notice the owner is gone instead of only cleaning up at shutdown.
            destroyed_before_drop = len([x for x in r.g.__gui_destroy_ids().split(',') if x])
            r.g.__drop_gui_world()
            r.ticks(4)
            # The surface's own texts must have been retired by the drop; whatever is on
            # screen afterwards belongs to the new surface, not to the old one.
            checks['dropping the surface retires its texts'] = \
                len([x for x in r.g.__gui_destroy_ids().split(',') if x]) > \
                destroyed_before_drop
            checks['the HUD holds at most one reading after the drop'] = \
                int(r.g.__gui_live_texts()) <= 2
            checks['dropping the stranded HUD is logged'] = \
                'HUD_SURFACE_DROPPED' in r.read('hivelord_hp.log')
            created3, _ = r.g.__gui_counts().split(',')
            checks['a fresh surface is made for the new world'] = int(created3) >= 2

            # Over- and under-maximum readings are asserted on the renderer itself in
            # run_pure_suite: a six-bit fraction cannot express either, and writing an
            # impossible field value is how the previous fixture came to certify a
            # model the live data had already disproved.
        else:
            checks['the HUD stays off when not configured'] = r.g.__gui_texts() == ''
            created, _ = r.g.__gui_counts().split(',')
            checks['no gui surface is created when the HUD is off'] = created == '0'

        detail['hp_line'] = r.last_hp()
        detail['probed_calls'] = len(calls)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # ---- pinned goid survives a relaunch -----------------------------------
    tmp = new_tmp(hud)
    try:
        r = Run(src, tmp)
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.ticks(TICKS, until=lambda: r.field('identified') is not None)
        state = r.read('hivelord_hp_state.txt')
        checks['the found goid is persisted'] = 'goid=31' in state
        checks['the main path raised no runtime error'] = \
            'LUA_ERROR' not in r.read('hivelord_hp.log')
        # A raise inside read_once/report used to be swallowed by pcall, leaving the
        # previous calibration on screen: a stale but plausible number, which is worse
        # than no number.  That is exactly how the %d-on-a-fraction bug hid, so the
        # absence of these lines is itself a test.
        log_all = r.read('hivelord_hp.log')
        checks['no read or report error was swallowed'] = \
            'READ_ERROR' not in log_all and 'REPORT_ERROR' not in log_all

        r2 = Run(src, tmp)
        r2.g.__set_ship_ticks(SHIP_TICKS)
        r2.ticks(SHIP_TICKS + 60)
        log2 = r2.read('hivelord_hp.log')
        checks['a relaunch reuses the pinned goid'] = \
            'RESUME goid=31 from state file' in log2
        detail['resume_seen'] = 'RESUME goid=31 from state file' in log2
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return checks, detail


def run_env_suite(src):
    """A mod that loads but cannot work must still leave evidence on disk.

    Before this, every environment gate returned before the logger existed, so a
    loader that was too old (or a missing engine API) produced no output at all:
    the user sees "nothing happened" and the real cause never reaches any file.
    """
    checks, detail = {}, {}
    scenarios = [
        ('no stingray global', 'stingray = nil', 'no stingray global'),
        ('GameSession missing', 'stingray.GameSession = nil', 'GameSession is unavailable'),
        ('loader API 0', 'CowboyBingusModLoader = { api = 0, version = 14 }', 'API is 0'),
        ('no global update to chain', 'update = nil', 'no global update'),
    ]
    for label, pre, expect in scenarios:
        tmp = new_tmp(False)
        try:
            r = Run(src, tmp, pre=pre)
            status = r.read('hivelord_hp_STATUS.txt')
            log = r.read('hivelord_hp.log')
            ok = expect in status and expect in log
            checks[f'{label}: the refusal is written to STATUS and the log'] = ok
            if not ok:
                detail[f'{label}_status'] = status[:200]
            installed = None
            if r.result is not None:
                try:
                    installed = r.result['installed']
                except Exception:
                    installed = None
            checks[f'{label}: the addon reports it did not install'] = installed is False
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_session_suite(src):
    """The engine returns fresh wrappers; state must not reset because of that.

    This is the regression test for the bug that made the first live run useless:
    `session ~= M.session` was true every frame, so the reset wiped the sweep
    continuously and it never got past id 903.
    """
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.ticks(TICKS)

        def changes():
            return sum(1 for l in r.read('hivelord_hp.log').splitlines()
                       if l.startswith('SESSION_CHANGE'))

        n = changes()
        detail['session_changes_over_1600_frames'] = n
        # One transition into the session is expected; one per frame is the bug.
        checks['a stable session does not reset state every frame'] = n <= 3
        checks['the probe queue is built from the census'] = \
            'PROBE queued=' in r.read('hivelord_hp.log')
        checks['the Hive Lord is still found'] = 'HIVE_LORD goid=31' in r.read('hivelord_hp.log')

        # A real session change must still be noticed.
        r.g.__session_change()
        r.ticks(10)
        checks['a genuine session change is detected'] = changes() > n

        # Leaving and re-entering a session must clear the pinned object.
        r.g.__set_in_session(False)
        r.ticks(10)
        r.g.__set_in_session(True)
        r.ticks(10)
        checks['re-entering a session is detected as a new mission'] = \
            'MISSION_ENTER' in r.read('hivelord_hp.log')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_sparse_suite(src):
    """Ids are sparse: the target may sit at 8192, not at 31."""
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.g.__use_sparse_world()
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.ticks(TICKS)
        log = r.read('hivelord_hp.log')
        checks['a Hive Lord at id 8192 is found'] = 'HIVE_LORD goid=8192' in log
        checks['the low ids that do not exist are not probed'] = \
            'PROBE queued=' in log and 'SCAN goid=31' not in log
        detail['sparse_found'] = 'HIVE_LORD goid=8192' in log
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_minimal_suite(src):
    """An array holding only 150000s must still be captured and ranked."""
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.g.__use_minimal_world()
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.ticks(TICKS)
        log = r.read('hivelord_hp.log')
        checks['a one-kind array is still scanned'] = 'SCAN goid=6000' in log
        checks['a one-kind array is still dumped'] = \
            any('goid6000' in f for f in r.find('hivelord_hp_weak*'))
        checks['a one-kind array reaches the scoreboard'] = \
            'goid=6000' in log and 'n150k=2' in log
        detail['minimal_scanned'] = 'SCAN goid=6000' in log
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_diag_suite(src):
    """The diagnostic block must remove the ambiguity the first live run left.

    That run swept 380 real objects, found no candidates, and could not say whether
    game_object_field_batched had returned nothing or had returned arrays with no
    known health value.  Every check here exists to keep that question answerable.
    """
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.ticks(TICKS)
        log = r.read('hivelord_hp.log')

        checks['the entity API liveness check runs'] = \
            'DIAG object_info(rHVbvgIu).fields=' in log
        checks['the API reports the field count DRIVER HUD documents'] = \
            'DIAG object_info(rHVbvgIu).fields=27' in log
        checks['the owned-object list is reported'] = 'DIAG owned n=' in log
        checks['owned objects are probed first'] = 'DIAG owned_probe goid=' in log
        checks['the owned reads are summarised'] = 'DIAG owned_field_reads ok=' in log
        checks['a field-count histogram is reported'] = 'DIAG fields_hist' in log
        checks['the census reports how many objects returned fields'] = \
            'CENSUS_FIELDS objects=' in log
        # A live session produced a 0-byte log while STATUS worked, so the log is
        # asserted to actually contain lines, and STATUS must report its health.
        checks['the log actually received lines'] = len(log.splitlines()) > 5
        checks['STATUS reports the log path and line count'] = \
            'log: ' in r.read('hivelord_hp_STATUS.txt') and 'lines=' in r.read('hivelord_hp_STATUS.txt')
        checks['STATUS reports no failed log writes'] = 'failed=0' in r.read('hivelord_hp_STATUS.txt')
        # The verdict must not be computed on a tiny sample.  A live session
        # concluded "no health value anywhere" after examining about eight of 163
        # objects.  Every census the diagnostics write must therefore cover most of
        # the queue -- checking only the last one would let a premature first
        # verdict through, since later runs overwrite it.
        last = [l for l in log.splitlines() if l.startswith('CENSUS_FIELDS')]
        detail['census_fields_lines'] = last
        ok = bool(last)
        for line in last:
            parts = dict(p.split('=') for p in line.split() if '=' in p)
            objects = int(parts.get('objects', 0))
            with_fields = int(parts.get('with_fields', 0))
            if objects > 0 and with_fields < 0.8 * objects:
                ok = False
        checks['every census is written after most of the queue was walked'] = ok

        census = r.read('hivelord_hp_census.txt')
        checks['the census file carries a field-count column'] = \
            'fields' in census.splitlines()[1] if len(census.splitlines()) > 1 else False
        checks['the census records a real field count for an object'] = \
            any(len(p) >= 2 and p[0] == '1' and p[1] == '35'
                for p in (l.split('\t') for l in census.splitlines()
                          if l and not l.startswith('#')))
        detail['census_head'] = '\n'.join(census.splitlines()[:6])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_status_suite(src):
    """STATUS is a status file, not a second log, and it must be decisive.

    The second live session grew STATUS to 760 KB because every progress line was
    appended and the whole list rewritten each time.  That is O(n^2) writes and it
    buries the one line a reader actually needs.
    """
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.ticks(TICKS)
        status = r.read('hivelord_hp_STATUS.txt')
        log = r.read('hivelord_hp.log')
        lines = status.splitlines()

        detail['status_bytes'] = len(status)
        detail['status_head'] = '\n'.join(lines[:5])
        checks['STATUS stays small'] = len(status) < 8192
        checks['STATUS carries a replaceable CONCLUSION line'] = \
            any(l.startswith('CONCLUSION:') for l in lines)
        checks['STATUS puts the conclusion near the top'] = \
            any(l.startswith('CONCLUSION:') for l in lines[:6])
        checks['STATUS notes are capped'] = len(lines) < 40
        checks['a duplicate progress line is not appended twice'] = \
            len(set(lines[3:])) == len(lines[3:])

        checks['a VERDICT is logged'] = 'VERDICT ' in log
        checks['the VERDICT reaches STATUS'] = 'VERDICT:' in status
        # The verdict is ALWAYS a note; the conclusion belongs to whatever answers the
        # user's question.  With the HUD off and a reading in hand that is the reading, and
        # with the HUD on but nothing identified it is the HUD state.  The verdict used to
        # write the head unconditionally and overwrite both, which is how a live status
        # file came to talk about field reads while the screen was empty.
        checks['the verdict survives as a note'] = 'VERDICT:' in status
        checks['the conclusion is the reading, not the diagnostics'] = \
            'CONCLUSION: HP sync=' in status
        # A live log with 1141 of 1162 objects returning no fields announced "no Hive Lord
        # was present in this mission".  The read cannot support that claim, and the blind
        # fraction is what qualifies it -- in every branch, positive ones included.
        checks['the VERDICT states how much of the census was readable'] = \
            'census object(s) returned no fields' in log
        checks['the id-space bucketing is logged'] = 'CENSUS_BUCKETS id>>12' in log
        checks['objects carrying 150000 are counted separately'] = \
            'DIAG objects_with_150000=' in log
        checks['the resweep backoff is logged'] = 'RESWEEP new_ids=' in log
        # The second live session logged 22438 identical SCOREBOARD lines because
        # the "drained" condition stays true once true.  The probe now re-reads the
        # census continuously, so more than the old handful is legitimate -- but the
        # bound stays far below the tick count (~2200 in this suite), so a per-frame
        # flood still cannot pass.
        scoreboard_lines = sum(1 for l in log.splitlines() if l.startswith('SCOREBOARD'))
        detail['scoreboard_lines'] = scoreboard_lines
        checks['the log is not flooded with duplicate scoreboard lines'] = \
            scoreboard_lines <= 40
        checks['the queue drain is reported exactly once'] = \
            sum(1 for l in log.splitlines() if l.startswith('PROBE_DRAINED')) <= 1
        # A durable write leaves no staging file behind.
        checks['the durable write left no .new staging file'] = \
            not r.find('hivelord_hp_STATUS.txt.new') and \
            not r.find('hivelord_hp_census.txt.new')
        # The fixture's owned objects do read fields, so the verdict must say so
        # rather than blaming the API.
        checks['the verdict reflects that field reads work'] = \
            'field reads work' in log or 'held a known health value' in log

        # Drive the note list hard, so the cap is actually exercised.  Waiting for
        # the fixture to generate volume naturally would never reach it: with the
        # backoff in place a session only produces a handful of notes.
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    tmp = new_tmp(False)
    try:
        r = Run(src, tmp, expose_pure=True)
        pure = r.g.__HIVELORD_PURE
        for i in range(2000):
            pure.status('note %d' % i)
        status = r.read('hivelord_hp_STATUS.txt')
        detail['status_bytes_after_2000_notes'] = len(status)
        checks['two thousand notes still leave STATUS small'] = len(status) < 8192
        checks['the newest note is kept'] = 'note 1999' in status
        checks['the oldest notes are dropped'] = 'note 0\n' not in status
        pure.status_head('final conclusion')
        status = r.read('hivelord_hp_STATUS.txt')
        checks['the conclusion can be replaced'] = 'CONCLUSION: final conclusion' in status
        checks['replacing the conclusion does not grow the file'] = len(status) < 8192
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_fault_suite(src):
    """A raised error must be surfaced, not swallowed into silence.

    A raised error inside the update hook sets the global `failed` flag and the mod
    stops doing anything.  If the error is not logged, that is indistinguishable
    from "still working" -- the worst possible state for a one-shot resource.
    """
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.g.__HIVELORD_FAULT = True
        r.ticks(10)
        log = r.read('hivelord_hp.log')
        status = r.read('hivelord_hp_STATUS.txt')
        checks['an injected fault is logged as LUA_ERROR'] = 'LUA_ERROR' in log
        checks['an injected fault becomes the STATUS conclusion'] = \
            'CONCLUSION: LUA_ERROR' in status
        detail['fault_logged'] = 'LUA_ERROR' in log
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_namespace_suite(src):
    """The engine namespace listing is the one reconnaissance that is always safe.

    It is pure pairs() iteration, and it is the only way to learn from a live run
    whether an entity-enumeration API exists at all.  The names come from the
    game's own Lua (work/hivelord/gamelua_api.py).
    """
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.ticks(5)                     # the listing happens at load time
        log = r.read('hivelord_hp.log')
        checks['the engine namespace listing is written'] = 'NS stingray keys=' in log
        checks['stingray.EntityManager is listed'] = 'NS stingray.EntityManager' in log
        checks['the entity query entry point is visible'] = \
            'instances_with_tag_in_entity' in log
        checks['stingray.components is listed'] = 'NS stingray.components' in log
        checks['a component name is visible in the registry'] = 'HealthComponent' in log
        checks['a nil namespace is reported rather than skipped'] = \
            'NS stingray.UnitUtils = nil' in log
        checks['the listing reaches STATUS as a note'] = \
            'engine namespaces listed' in r.read('hivelord_hp_STATUS.txt')
        # Zero engine calls: the whole point is that this cannot fault.
        checks['the listing makes no engine call'] = \
            'GS.game_object_field_batched' not in r.calls()
        detail['ns_line'] = [l for l in log.splitlines() if l.startswith('NS stingray.EntityManager')][:1]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_weakwatch_suite(src):
    """The strong gate must not be a prerequisite for learning anything.

    The live run found goid 714 (field 17 = 150000) and dumped it, but never
    watched it -- so the one remaining question, "which field carries the current
    value", went unanswered even though the object was right there.
    """
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.g.__remove_goid(31)                  # no strong match will ever fire
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.ticks(TICKS)
        log = r.read('hivelord_hp.log')

        checks['a weak candidate becomes the watch target'] = 'WEAK_WATCH_SET goid=' in log
        checks['the weak candidate is watched'] = 'WATCH_FIELDS goid=' in log
        checks['watching happens although no strong match exists'] = \
            'HIVE_LORD goid=' not in log

        # Now damage it: the field that moves is the answer.  goid 32 is the sparse
        # fixture, whose field 6 holds 150000.
        detail['before'] = [l for l in log.splitlines() if l.startswith('WATCH_FIELDS')][-1:]
        ok = r.g.__set_field(32, 6, 145000)
        r.ticks(400)
        log2 = r.read('hivelord_hp.log')
        lines = [l for l in log2.splitlines() if l.startswith('WATCH_FIELDS')]
        detail['after'] = lines[-1:] if lines else None
        checks['the damage landed on the fixture object'] = bool(ok)
        checks['the moved field is reported'] = '6:150000->145000' in log2
        checks['the moving field becomes the STATUS conclusion'] = \
            'WEAK WATCH' in r.read('hivelord_hp_STATUS.txt') and \
            'field(s) changed' in r.read('hivelord_hp_STATUS.txt')
        checks['the weak watch raised no runtime error'] = 'LUA_ERROR' not in log2
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_hud_surface_suite(src):
    """The HUD surface must be taken down even when there is nothing to search for.

    This is the state a mission ends in: no pinned target, no weak watch.  The HUD used to
    be serviced only on frames where the search had something to do, so in exactly this
    state the surface was never touched again -- nothing redrew it and nothing cleared it,
    which is the bar that outlived the mission.  The main scenario always has a weak watch
    running, so it never reaches this branch.
    """
    checks, detail = {}, {}
    tmp = new_tmp(True)
    try:
        r = Run(src, tmp)
        # Short: the point is to be before any identification, with nothing pinned.
        r.ticks(30)
        created, _ = r.g.__gui_counts().split(',')
        detail['created_before'] = created
        checks['the HUD surface exists before anything is identified'] = created == '1'
        # A world that is still there must keep its surface.  Engine handles are fresh
        # wrappers per call, so comparing them by identity makes every frame look like a
        # mission change and rebuilds the surface forever -- which this catches.
        checks['a live world keeps its surface'] = \
            created == '1' and 'HUD_SURFACE_DROPPED' not in r.read('hivelord_hp.log')
        r.g.__drop_gui_world()
        r.ticks(5)
        log = r.read('hivelord_hp.log')
        checks['an idle frame still takes the stranded surface down'] = \
            'HUD_SURFACE_DROPPED' in log
        created2, _ = r.g.__gui_counts().split(',')
        checks['an idle frame still builds the surface for the new world'] = \
            int(created2) >= 2
        # A live session ended with an empty screen and a conclusion about field reads.
        # Nothing said the HUD was on and simply had nothing to draw, which reads exactly
        # like the mod having stopped drawing.
        status = r.read('hivelord_hp_STATUS.txt')
        head = status.splitlines()[4] if len(status.splitlines()) > 4 else ''
        detail['conclusion'] = head[:90]
        checks['the conclusion says the HUD is on and empty, and why'] = \
            'HUD is ON' in status
        # On the conclusion line itself, not buried in the notes: the diagnostic verdict
        # used to write that line unconditionally and overwrite this, so a live status file
        # could not explain its own empty screen.
        checks['the HUD state owns the conclusion while the HUD is on'] = 'HUD is ON' in head
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # ...and it must still own it after the diagnostics have run.  This is the live shape:
    # the HUD message is written once (it is deduped), and the verdict runs later and
    # repeatedly.  A verdict that takes the conclusion unconditionally therefore ends up
    # owning the file, which is exactly what the live status file showed while the screen
    # was empty.
    tmp2 = new_tmp(True)
    try:
        r2 = Run(src, tmp2)
        # No identified Hive Lord, so the HUD state message is the one that matters.
        r2.g.__remove_goid(31)
        r2.ticks(700)
        status2 = r2.read('hivelord_hp_STATUS.txt')
        head2 = status2.splitlines()[4] if len(status2.splitlines()) > 4 else ''
        detail['conclusion_after_diag'] = head2[:90]
        checks['a diagnostics run leaves a user-facing conclusion'] = \
            ('HUD is ON' in head2) or ('WEAK WATCH' in head2)
        # The crisp rule: whatever else happens, the diagnostics verdict must not own the
        # conclusion while the HUD is on.  This is what the live file violated.
        checks['the diagnostics verdict does not own the conclusion'] = \
            'VERDICT' not in head2
        checks['the verdict is still recorded as a note'] = 'VERDICT:' in status2
        # The rule is asserted on the mod's own report of it, not only on the final file:
        # later messages legitimately re-take the conclusion, so the file alone cannot show
        # whether the verdict was withheld or simply overwritten by something else.
        checks['withholding the verdict head is reported'] = \
            'VERDICT_HEAD withheld' in r2.read('hivelord_hp.log')
    finally:
        shutil.rmtree(tmp2, ignore_errors=True)
    return checks, detail


def run_candidate_track_suite(src):
    """Which field is the health?  Measure it on an unproven candidate.

    A live session held an object with the 150000 maximum and no k/63 fraction, so the
    reader refused to claim it -- correct behaviour, but it left the encoding of the health
    unknown.  The instrument for that is field-movement tracking: the player damaging the
    Hive Lord is the experiment, and the field that moves is the answer.  This suite proves
    the tracker reports movement and that it cannot flood the log, which is the failure this
    project has already paid for once (22438 identical scoreboard lines).
    """
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.ticks(600)
        # goid 40 is the decoy: { 150000, 35000, 15000, 5000, 100, 42 }.  Move field 6 (the
        # 42) and NOT field 1 -- field 1 IS the 150000, and replacing it stops the object
        # being a candidate at all, which is exactly what made the first version of this
        # test report that tracking did not work.
        idx = 6
        before = r.read('hivelord_hp.log')
        checks['no movement is reported before anything moves'] = \
            'CAND_MOVED goid=40' not in before

        seen = 0
        for _ in range(14):
            r.g.__set_field(40, idx, 100 + seen)
            seen += 1
            r.ticks(60)
        log = r.read('hivelord_hp.log')
        moved_lines = [l for l in log.splitlines() if l.startswith('CAND_MOVED goid=40')]
        detail['cand_moved_lines'] = len(moved_lines)
        checks['a moved field of an unproven candidate is reported'] = len(moved_lines) >= 1
        checks['the report names the field that moved'] = f'{idx}:' in log

        # The cap, tested directly.  End to end it cannot be reached: the resweep interval
        # backs off (2x, 4x ...) so a run long enough to produce four observations of the
        # same field is minutes of simulated time.  Calling the tracker itself makes the
        # cap deterministic -- and a cap that no test can reach is not a cap.
        rp = Run(src, tmp, expose_pure=True)
        rp.lua.execute(
            "local p = __HIVELORD_PURE\n"
            "for i = 1, 6 do p.track_candidate(777, { 150000, 35000, i }) end\n")
        plog = rp.read('hivelord_hp.log')
        plines = [l for l in plog.splitlines() if l.startswith('CAND_MOVED goid=777')]
        detail['pure_moved_lines'] = len(plines)
        detail['pure_mentions'] = sum(l.count('3:') for l in plines)
        checks['the cap test reached the tracker'] = len(plines) >= 1
        checks['a field that keeps moving is reported at most TRACK_MOVES times'] = \
            sum(l.count('3:') for l in plines) <= 3
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_pure_suite(src):
    """Exact-value tests of the pure helpers, reachable only through the test seam."""
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp, expose_pure=True)
        pure = r.g.__HIVELORD_PURE
        checks['the pure helpers are exposed to the harness'] = \
            pure is not None and pure.bar_text is not None
        if not checks['the pure helpers are exposed to the harness']:
            return checks, detail
        cases = [
            (150000, 150000, 24, '=' * 24, 'full health fills the bar'),
            (0, 150000, 24, '-' * 24, 'zero health empties the bar'),
            (75000, 150000, 24, '=' * 12 + '-' * 12, 'half health fills half the bar'),
            (145000, 150000, 24, '=' * 23 + '-', '96.7% fills twenty-three of twenty-four'),
            (300000, 150000, 24, '=' * 24, 'an over-maximum reading clamps to full'),
            (-5, 150000, 24, '-' * 24, 'a negative reading clamps to empty'),
            (100, 0, 24, '-' * 24, 'a zero maximum does not divide by zero'),
            (1, 3, 3, '=--', 'rounding is to nearest, not up'),
        ]
        bad = []
        for hp, mx, w, want, label in cases:
            got = r.lua.eval('__HIVELORD_PURE.bar_text(...)', hp, mx, w)
            if got != want:
                bad.append(f'{label}: got {got!r} want {want!r}')
        detail['bar_cases_failed'] = bad
        checks['every bar case is exact'] = not bad
        # nil inputs must not raise.
        got = r.lua.eval('__HIVELORD_PURE.bar_text(nil, 150000, 24)')
        checks['a nil reading yields an empty bar rather than an error'] = got == '-' * 24

        # ---- the six-bit classifier, exactly -------------------------------------
        # This is the check that keeps the identification specific.  256/255 and
        # 254/255 are the values the real object actually carries next to the
        # fraction; they are adjacent to but not equal to any k/63, so they must be
        # rejected, and so must an arbitrary value in [0,1].
        k_cases = [
            (61 / 63, 61, 'the observed fraction decodes to k=61'),
            (1.0, 63, 'the full value decodes to k=63'),
            (0.0, 0, 'zero decodes to k=0'),
            (2 / 63, 2, 'a low step decodes exactly'),
            (256 / 255, None, 'the real 256/255 constant is not a fraction'),
            (0.997067, None, 'the real 254/255 constant is not a fraction'),
            (0.5, None, 'an arbitrary value in [0,1] is not a fraction'),
            (150000, None, 'the maximum is not a fraction'),
            (-1, None, 'a negative value is not a fraction'),
        ]
        kbad = []
        for val, want, label in k_cases:
            got = r.lua.eval('__HIVELORD_PURE.is_k63(...)', val)
            if got != want:
                kbad.append(f'{label}: got {got!r} want {want!r}')
        detail['k63_cases_failed'] = kbad
        checks['every six-bit fraction case is exact'] = not kbad
        checks['nil is not a fraction'] = r.lua.eval('__HIVELORD_PURE.is_k63(nil)') is None

        # ---- the damage-mask finder --------------------------------------------
        # It is identified by its all-ones first observation, and it is deliberately
        # NOT claimed without history: guessing the mask index would be the same class
        # of error as guessing the fraction index.
        m_hit = r.lua.eval(
            "__HIVELORD_PURE.mask_of({0,0,0,16383}, {[4]={first=16383, value=16383}})")
        checks['the all-ones first value identifies the mask'] = m_hit == 4
        m_nohist = r.lua.eval("__HIVELORD_PURE.mask_of({0,0,0,16383}, {})")
        checks['the mask is not claimed without an observation'] = m_nohist is None
        m_17bit = r.lua.eval(
            "__HIVELORD_PURE.mask_of({0,0,65535}, {[3]={first=65535, value=65535}})")
        checks['a 16-bit value is not mistaken for the 14-bit mask'] = m_17bit is None

        # ---- the honesty line ---------------------------------------------------
        txt = r.lua.eval("__HIVELORD_PURE.hp_text({cur_health=145238, max_health=150000, "
                         "cur_step=2381, sync_k=61})")
        checks['the HUD line carries the derived figure'] = '145238' in txt and '150000' in txt
        sub = r.lua.eval("__HIVELORD_PURE.hp_detail({sync_k=61, mask_value=16383, cur_step=2381})")
        checks['the honesty line names the wire value'] = 'wire 61/63' in sub
        checks['the honesty line names the mask'] = 'mask 16383/16383' in sub
        checks['the honesty line states the resolution'] = '+-2381' in sub
        checks['the honesty line denies exactness'] = 'not exact HP' in sub
        sub2 = r.lua.eval("__HIVELORD_PURE.hp_detail({sync_k=61, cur_step=2381})")
        checks['the honesty line omits the mask when it is unknown'] = 'mask' not in sub2

        # ---- the zone-run fallback ----------------------------------------------
        # The measured Hive Lord carries no zone strand at all (its array has ONE
        # distinct magic value), so this path can never fire on the real object today.
        # It is kept as a cheap probe for a build that does expose the archetype's zone
        # array -- but a path that neither a test nor a live run can reach is a
        # liability rather than insurance, so it is asserted here directly.
        # Build the arrays inside Lua.  A Python list passed through lupa does not
        # arrive as a plain 1..n table, and a fixture built from a mis-converted table
        # would be testing the conversion rather than the function.
        zone_arr = r.lua.execute(
            "local t = {}\n"
            "for i = 1, 40 do t[i] = 0 end\n"
            "t[5] = 150000\n"
            "for i = 6, 16 do t[i] = 15000 end\n"
            "return t")
        zc = r.lua.eval('__HIVELORD_PURE.calibrate(...)', zone_arr)
        checks['a contiguous magic run is located'] = \
            zc is not None and zc['zone_a'] == 5 and zc['zone_b'] == 16
        flat = r.lua.execute(
            "local t = {}\n"
            "for i = 1, 46 do t[i] = 0 end\n"
            "t[7] = 61 / 63\n"
            "t[17] = 150000\n"
            "return t")
        flatc = r.lua.eval('__HIVELORD_PURE.calibrate(...)', flat)
        checks['a measured-shape array yields no zone run'] = \
            flatc is not None and flatc['zone_a'] is None
        checks['the measured shape is still identified without a zone run'] = \
            flatc is not None and flatc['identified'] is True
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_insurance_suite(src):
    """The session-saving path: a sparse array must not be lost."""
    checks, detail = {}, {}
    tmp = new_tmp(False)
    try:
        r = Run(src, tmp)
        r.g.__remove_goid(31)          # only the sparse Hive Lord exists now
        r.g.__set_ship_ticks(SHIP_TICKS)
        r.ticks(SHIP_TICKS + 40)
        r.ticks(TICKS)

        log = r.read('hivelord_hp.log')
        checks['a sparse Hive Lord does not pass the strong gate'] = \
            'HIVE_LORD goid=' not in log
        # Match the actual line prefix: the verdict text also contains the word
        # SCOREBOARD, so a substring test passes even with no scoreboard logged.
        checks['the sweep still logs a ranked scoreboard'] = \
            any(l.startswith('SCOREBOARD ') for l in log.splitlines())
        checks['the sparse candidate is ranked by its 150000 count'] = \
            'goid=32' in log and 'n150k=2' in log
        weak_files = r.find('hivelord_hp_weak*')
        detail['weak_files'] = weak_files
        checks['the sparse candidate array is dumped in full'] = \
            any('goid32' in f for f in weak_files)
        if any('goid32' in f for f in weak_files):
            name = [f for f in weak_files if 'goid32' in f][0]
            body = r.read(name)
            checks['the dump carries every field'] = body.count('\t') >= 40
            checks['the dump carries both 150000 fields'] = body.count('150000') >= 2
        else:
            checks['the dump carries every field'] = False
            checks['the dump carries both 150000 fields'] = False
        checks['the status file explains the miss'] = \
            'no strong Hive Lord match' in r.read('hivelord_hp_STATUS.txt')
        # With nothing identified the census must keep its full rate.  Backing off while
        # blind is the one behaviour that cannot help, and widening the search interval
        # is what lets a target appear and die between two censuses unread.
        checks['the census keeps looking while nothing has been found'] = \
            'backoff=1x' in log and 'backoff=2x' not in log
        # This is the only scenario where the probe queue drains without a match, so
        # it is the only place a "log every frame once drained" bug can show up.
        sb = sum(1 for l in log.splitlines() if l.startswith('SCOREBOARD'))
        detail['insurance_scoreboard_lines'] = sb
        checks['the draining path does not flood the log'] = sb <= 40
        # A raised error inside the update hook sets the global failed flag, so the
        # mod goes completely silent -- the one failure mode that must never be
        # possible silently.  Assert it never happens in any scenario.
        checks['the draining path raised no runtime error'] = 'LUA_ERROR' not in log
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


MUTATIONS = {
    # The zone array is never located, so the "maximum sits just before the zone
    # run" rule collapses and the reported zone span disappears.
    'no-zone-run-detection': (
        "            if len > best_len then best_a, best_b, best_len = a, i - 1, len end",
        "            if false then best_a, best_b, best_len = a, i - 1, len end",
    ),
    # The six-bit test is loosened until a merely plausible value passes.  0.5, 0.997067
    # and 256/255 are all within 0.01 of some k/63, so this must be caught.
    'k63-tolerance-loose': (
        "    if math.abs(v - k / 63) <= 1e-6 then return k end",
        "    if math.abs(v - k / 63) <= 0.01 then return k end",
    ),
    # k = 0 is allowed during the SEARCH again, so the first padding field wins and the
    # fraction is reported as 0/63 forever.
    'sync-may-be-a-zero-field': (
        "            if k and k > 0 then sync_idx, sync_k = i, k end",
        "            if k then sync_idx, sync_k = i, k end",
    ),
    # The mask is guessed from the current array instead of from its all-ones first
    # observation, so an unrelated small integer becomes the mask.
    'mask-guessed-without-history': (
        "        local h = hist and hist[i]\n"
        "        if h and h.first == 16383 and type(f[i]) == 'number' then return i end",
        "        if type(f[i]) == 'number' and f[i] >= 0 and f[i] <= 16383 then return i end",
    ),
    # A candidate is no longer promoted on identification, so the reader keeps watching
    # whichever object merely scores highest.
    'no-measured-promotion': (
        "                    local c0 = calibrate(f, M.hist)\n"
        "                    if c0.identified then",
        "                    local c0 = calibrate(f, M.hist)\n"
        "                    if false then",
    ),
    # The honesty line is dropped, so the display claims more than it can know.
    'honesty-line-dropped': (
        "    parts[#parts + 1] = 'client-synced, not exact HP'",
        "    parts[#parts + 1] = ''",
    ),
    # Field values are formatted as integers again.  The synchronised value is a
    # fraction, so this raises -- and it is exactly the class of bug that hides in a
    # live LuaJIT run, where %d on a float truncates silently.
    'moved-format-int-only': (
        "            out.moved[#out.moved + 1] = string.format('%d:%s->%s', i, num(h.first), num(h.value))",
        "            out.moved[#out.moved + 1] = string.format('%d:%d->%d', i, h.first, h.value)",
    ),
    # The read loop stops after one pass again, so a target that appears later is only
    # seen at the next census -- or never.
    'no-continuous-probe': (
        "    if (drained or stalled) and #M.probe_list > 0",
        "    if false and (drained or stalled) and #M.probe_list > 0",
    ),
    # The complete shape file is not written, leaving only the 20 sampled log lines.
    'no-shape-file': (
        "        land_samples()",
        "        -- shape file not written",
    ),
    # Only objects holding a recognised value are dumped, which is how a target that
    # looks different in another mission stays invisible.
    'dump-only-with-magic': (
        "            if cnt and cnt >= C.shape_dump_min then",
        "            if cnt and cnt >= C.shape_dump_min and distinct >= 1 then",
    ),
    # The census backs off while nothing has been identified, widening the window in
    # which the target can come and go unseen.  A weak watch must NOT count as "found".
    'backoff-while-blind': (
        "        if added <= 0 and M.goid then",
        "        if added <= 0 then",
    ),
    'backoff-on-weak-watch': (
        "        if added <= 0 and M.goid then",
        "        if added <= 0 and (M.goid or M.watch_goid) then",
    ),
    # The object sweep drops the Hive Lord gate, so the first tanky object found
    # (the fixture's Bastion hull) is pinned instead.
    'sweep-no-hivelord-gate': (
        "            if cnt and cnt > 0 and distinct >= MIN_DISTINCT\n"
        "                and (found[150000] or 0) >= MIN_150K then",
        "            if cnt and cnt > 0 then",
    ),
    # The HUD renders regardless of configuration.
    'hud-ignores-config': (
        "    if not C.hud then return end",
        "    if false then return end",
    ),
    # The pinned goid is never written, so every launch re-sweeps 32766 ids.  Targeted
    # at the shared implementation, not at one call site: there are two promotion sites
    # now, and removing one of them would leave the other to satisfy the check.
    'no-state-persist': (
        "local function save_state(tbl)",
        "local function save_state(tbl) if true then return end",
    ),
    # A wrong strong-gate guess would silently waste the whole session: the weak
    # dump is the insurance that makes the guess cost nothing.
    'no-weak-dump': (
        "                if found[150000] and not (M.weak_dumped and M.weak_dumped[id]) then",
        "                if false then",
    ),
    # And the scoreboard is what identifies the target when the gate never fires.
    'no-scoreboard': (
        "        report_scoreboard(grew and 'new_candidate'\n"
        "            or (drained and 'queue_drained' or 'progress'))",
        "        -- scoreboard suppressed",
    ),
    # The bar rounds up, so a nearly-dead entity reads as full.
    'bar-rounds-up': (
        "    local filled = math.floor(frac * width + 0.5)",
        "    local filled = math.ceil(frac * width)",
    ),
    # The bar is not clamped at either end.  Both guards have to go: they are
    # redundant on purpose, so removing only one is masked by the other and the
    # mutation would not express the bug it claims to.
    'bar-unclamped': (
        "    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end\n"
        "    local filled = math.floor(frac * width + 0.5)\n"
        "    if filled < 0 then filled = 0 elseif filled > width then filled = width end",
        "    local filled = math.floor(frac * width + 0.5)",
    ),
    # A refusal that does not reach disk is a silent failure: the mod is loaded,
    # nothing works, and the log says nothing.
    'refusal-not-recorded': (
        "    status_head('REFUSED - ' .. reason)",
        "    -- refusal not recorded",
    ),
    # Back to comparing engine handles by identity.  The engine returns a fresh
    # wrapper per call, so this resets the sweep every frame -- the exact bug that
    # made the first live run produce nothing.
    'identity-session-compare': (
        "    local key = tostring(session) .. '|' .. tostring(peer)",
        "    local key = session",
    ),
    # Back to walking the whole id space instead of the census.  Ids are sparse
    # (4096 and 8192 in the live log), so a two-per-frame walk never arrives.
    'walk-id-space': (
        "    for id in pairs(M.census) do\n        if all or not M.probed[id] then list[#list + 1] = id end\n    end",
        "    for id = 1, C.max_id do\n        if all or not M.probed[id] then list[#list + 1] = id end\n    end",
    ),
    # Back to requiring two *kinds* of known maximum, which silently drops an array
    # holding nothing but 150000s -- exactly the sparse shape being hunted.
    'two-kinds-threshold': (
        "            if cnt and cnt > 0 and distinct >= 1 then",
        "            if cnt and cnt > 0 and distinct >= 2 then",
    ),
    # The diagnostic block disappears, so the next live run is ambiguous again.
    'no-owned-probe': (
        "    for i = 1, math.min(#owned_ids, 8) do",
        "    for i = 1, 0 do",
    ),
    # The census loses the field-count column, which is the one that distinguishes
    # "the read returned nothing" from "the read worked".
    'census-without-field-counts': (
        "        if k then\n            with_fields = with_fields + 1",
        "        if false then\n            with_fields = with_fields + 1",
    ),
    # STATUS grows without limit again -- 760 KB in one live session.
    'status-unbounded': (
        "    while #STATUS_NOTES > STATUS_NOTE_CAP do table.remove(STATUS_NOTES, 1) end",
        "    -- notes not capped",
    ),
    # No verdict at all, so the next run is ambiguous again.  Both publications
    # have to go: the note is what survives a later live reading taking the head.
    'no-verdict': (
        "    status('VERDICT: ' .. verdict)\n    status_head('VERDICT: ' .. verdict)",
        "    -- verdict not published",
    ),
    # The "drained" flag stays true once true, so gating on it logs every frame.
    'log-flood': (
        "    if grew or M.clock >= (M.next_scoreboard or 0) then",
        "    if drained or grew or M.clock >= (M.next_scoreboard or 0) then",
    ),
    # The status file is written by truncating it first, so a reader can catch it
    # empty and a crash in that window loses the content entirely.
    'non-durable-write': (
        "    local tmp = path .. '.new'",
        "    local tmp = path",
    ),
    # A name that does not exist on this table raises exactly when the probe queue
    # drains -- and a raised error sets the global failed flag, so the whole mod
    # goes silent at the most interesting moment.
    'undefined-candidate-field': (
        "        wf('PROBE_DRAINED probed=%d candidates=%d', M.probes, #M.best)",
        "        wf('PROBE_DRAINED probed=%d candidates=%d', M.probes, #M.no_such_field)",
    ),
    # The verdict is computed on a tiny sample and then frozen -- the live session
    # concluded "no health value anywhere" after seeing about eight of 163 objects.
    'premature-verdict': (
        "    local target = math.max(24, math.floor(#M.probe_list * 0.8))",
        "    local target = 1",
    ),
    # The log silently receives nothing, which is what a live session produced
    # while STATUS kept working -- leaving no diagnostic trail at all.
    'log-writes-nothing': (
        "    local f = io.open(log_path, 'a')\n"
        "    if not f then log_fail = log_fail + 1; return end",
        "    local f = nil\n"
        "    if not f then log_fail = log_fail + 1; return end",
    ),
    # A candidate is found and dumped but never watched, so the one question that
    # matters -- which field carries the current value -- stays unanswered.
    'no-weak-watch': (
        "                    if score > (M.watch_score or -1) then",
        "                    if false then",
    ),
    # Field movement is never detected, so the delta watch reports nothing.
    'deltas-ignore-change': (
        "            if v ~= h.first then h.moved = true end",
        "            -- movement not detected",
    ),
    # The ownership picture becomes a hard gate again, which wasted a whole live
    # session: MISSION_ENTER three times, zero owned objects, census never ran.
    'owned-list-blocks-census': (
        "    if C.in_mission_only and owned_n == 0 then\n"
        "        if not M.owned_zero_logged then",
        "    if C.in_mission_only and owned_n == 0 then return end\n"
        "    if false then\n"
        "        if not M.owned_zero_logged then",
    ),
    # A duplicate note is appended again, pushing a distinct one out of the cap.
    'notes-dedupe-only-last': (
        "    for _, v in ipairs(STATUS_NOTES) do\n"
        "        if v == line then return end\n"
        "    end",
        "    if STATUS_NOTES[#STATUS_NOTES] == line then return end",
    ),
    # "some object had a known health value" is satisfied by an arbitrary 800, so
    # without a separate 150000 count the verdict cannot tell "no Hive Lord present"
    # from "Hive Lord whose health is not in the field array" -- opposite next steps.
    'no-150k-count': (
        "    wf('DIAG objects_with_150000=%d', n150k)",
        "    -- count not reported",
    ),
    # No error is ever surfaced, so a crash inside the update hook looks identical
    # to "still working".
    'errors-not-surfaced': (
        "            wf('LUA_ERROR %s', tostring(err))",
        "            -- error swallowed",
    ),
    # The one always-safe reconnaissance disappears, so a live run cannot say
    # whether an entity-enumeration API exists.
    'no-namespace-dump': (
        "end\n\ndump_namespaces()\n",
        "end\n\n-- namespace dump removed\n",
    ),
    # The loader's JIT state is not read, so a cache flush during play cannot be told
    # apart from this mod being slow.
    'no-jit-state': (
        "    local j = type(loader) == 'table' and loader.jit or nil",
        "    local j = nil",
    ),
    # The version number is used as the v18 signal, which is wrong: the v18 source still
    # reports version = 17.
    'jit-keyed-on-version': (
        "    if type(j) ~= 'table' then return 'not exposed (loader before v18, or discovery only)' end",
        "    if (loader_version or 0) < 18 then return 'not exposed (loader before v18, or discovery only)' end",
    ),
    # The handle Gui.text returns is thrown away and a made-up one is remembered, so
    # clear_hud destroys nothing and every redraw stacks another pair of lines on screen.
    'hud-ignores-text-handle': (
        "    remember('text', call(Gui.text, M.gui, txt, 'core/performance_hud/debug', 20 * s,\n"
        "        'core/performance_hud/debug', V2(x, y), Color(a, 255, 255, 255)))",
        "    call(Gui.text, M.gui, txt, 'core/performance_hud/debug', 20 * s,\n"
        "        'core/performance_hud/debug', V2(x, y), Color(a, 255, 255, 255))\n"
        "    remember('text', 0)",
    ),
    # An unidentified frame returns without clearing, so the last reading stays on screen
    # for good -- which is what outlived the mission.
    'hud-no-clear-when-unidentified': (
        "        clear_hud()\n        return\n    end\n    local txt = hp_text(c)",
        "        return\n    end\n    local txt = hp_text(c)",
    ),
    # The surface's world is never noticed to be gone, so the HUD is stranded on screen
    # after a mission change instead of being dropped.
    'no-world-loss-reset': (
        "            local gone = tostring(M.gui_world_key)\n            surface_reset(worlds)",
        "            local gone = tostring(M.gui_world_key)\n            local _no_reset = gone",
    ),
    # The HUD is serviced from inside the search again, so every early return skips it:
    # the surface is neither redrawn nor taken down.  This is the shape that let the bar
    # outlive the mission.
    'hud-behind-search': (
        "local function update(dt, ...)\n    search_frame(dt, ...)\n    return hud_tick(M.world)\nend",
        "local function update(dt, ...)\n    search_frame(dt, ...)\nend",
    ),
    # Worlds are compared by wrapper identity again.  Engine handles are fresh wrappers on
    # every call, so the surface looks stranded on every single frame and is torn down and
    # rebuilt continuously.
    'world-compared-by-identity': (
        "local function world_key(v) return tostring(v) end",
        "local function world_key(v) return v end",
    ),
    # The HUD is on with nothing to draw and the conclusion says nothing about it, so an
    # empty screen is indistinguishable from a mod that stopped drawing.
    'hud-silent-when-empty': (
        "    if not M.cal then\n        local head = tostring(STATUS_HEAD)",
        "    if false then\n        local head = tostring(STATUS_HEAD)",
    ),
    # The per-field movement cap is dropped, so a field that changes every probe pass --
    # a position, say -- is reported forever.  This is the log flood that produced 22438
    # identical scoreboard lines in one live session.
    'candidate-move-flood': (
        "                if moves[i] <= TRACK_MOVES and #shown < 12 then",
                "                if #shown < 12 then",
    ),
    # The verdict states absence without saying how much of the census was unreadable, so
    # "nothing was read" is reported as "nothing was there".
    'verdict-claims-absence': (
        "    local blind = string.format('%d of %d census object(s) returned no fields', n0, census_n)",
        "    local blind = 'the read was complete'",
    ),
    # A recognised candidate with no readable damage value shows nothing, so a Hive Lord
    # that has not been written to yet leaves a blank screen -- which is indistinguishable
    # from a broken mod, and is how it read in play.
    'no-candidate-line': (
        "    if top and (top.n150k or 0) >= 1 then",
        "    if false then",
    ),
    # The verdict writes the conclusion unconditionally again, overwriting the HUD state --
    # so the status file cannot explain an empty screen while the HUD is on.
    'verdict-owns-head': (
        "    if not C.hud then\n        status_head('VERDICT: ' .. verdict)\n    else",
        "    if true then\n        status_head('VERDICT: ' .. verdict)\n    else",
    ),
}


def all_checks(source):
    """Every check from every suite, for one source."""
    out = {}
    for fn, kw in ((run_suite, {}), (run_suite, {'hud': True}),
                   (run_hud_surface_suite, {}), (run_candidate_track_suite, {}),
                   (run_pure_suite, {}), (run_insurance_suite, {}),
                   (run_env_suite, {}), (run_session_suite, {}),
                   (run_sparse_suite, {}), (run_minimal_suite, {}),
                   (run_diag_suite, {}), (run_status_suite, {}),
                   (run_fault_suite, {}), (run_weakwatch_suite, {}),
                   (run_namespace_suite, {})):
        part, _ = fn(source, **kw)
        out.update(part)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mutate')
    ap.add_argument('--hud', action='store_true')
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

        # A mutation is caught only if it breaks a check that PASSED on the unmutated
        # source.  Reporting "caught" for any failure at all is how a baseline that is
        # already failing makes every mutation look caught -- which happened twice in one
        # session and both times produced a perfect score over a broken suite.
        base = all_checks(flat)
        already = sorted(k for k, v in base.items() if not v)
        if already:
            print(f'--- mutation {args.mutate} ---')
            print(f'BASELINE FAILING ({len(already)} check(s)) -- verdict suppressed:')
            for k in already[:8]:
                print('  already failing:', k)
            return 2

        checks = all_checks(mutated)
        failed = sorted(k for k, v in checks.items() if not v)
        print(f'--- mutation {args.mutate} ---')
        for k in failed:
            print('  caught by:', k)
        if failed:
            print('MUTATION CAUGHT')
            return 0
        print('MUTATION NOT CAUGHT -- the suite has a hole')
        return 1

    checks, detail = run_suite(src, hud=args.hud)
    ins, ins_detail = run_insurance_suite(src)
    checks.update(ins)
    detail.update(ins_detail)
    surf, surf_detail = run_hud_surface_suite(src)
    checks.update(surf)
    detail.update(surf_detail)
    track, track_detail = run_candidate_track_suite(src)
    checks.update(track)
    detail.update(track_detail)
    pure, pure_detail = run_pure_suite(src)
    checks.update(pure)
    detail.update(pure_detail)
    env, env_detail = run_env_suite(src)
    checks.update(env)
    detail.update(env_detail)
    ses, ses_detail = run_session_suite(src)
    checks.update(ses)
    detail.update(ses_detail)
    sp, sp_detail = run_sparse_suite(src)
    checks.update(sp)
    detail.update(sp_detail)
    mn, mn_detail = run_minimal_suite(src)
    checks.update(mn)
    detail.update(mn_detail)
    dg, dg_detail = run_diag_suite(src)
    checks.update(dg)
    detail.update(dg_detail)
    st, st_detail = run_status_suite(src)
    checks.update(st)
    detail.update(st_detail)
    fl, fl_detail = run_fault_suite(src)
    checks.update(fl)
    detail.update(fl_detail)
    ww, ww_detail = run_weakwatch_suite(src)
    checks.update(ww)
    detail.update(ww_detail)
    ns, ns_detail = run_namespace_suite(src)
    checks.update(ns)
    detail.update(ns_detail)
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
