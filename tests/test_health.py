"""Offline suite for hivelord_health -- the Enemy HP method on this build.

What this has to prove, in order of how badly it would hurt to get wrong:

  1. the build gate refuses on a foreign build, and reads NOTHING after refusing;
  2. the manager layout is read as Enemy HP describes it (count, descriptor array, record
     array, record stride, hp offset);
  3. the health-table lookup finds the maximum through the real open-addressed algorithm,
     from the real slot, and stops at an empty slot;
  4. a manager that does not contain the Hive Lord's key is reported as exactly that --
     with the 150000-holder named -- and never as "the Hive Lord is absent";
  5. the HUD shows the exact number, tracks real text handles, and takes its surface down.

A mutation is only counted as caught if it breaks a check that PASSED on the unmutated
source; a baseline that is already failing reports BASELINE FAILING instead of a verdict.
"""
import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
ENTRY = ROOT / 'Source/mods/hivelord/hivelord_health.lua'
FIXTURE = Path(__file__).resolve().parent / 'fixture_health.lua'

SHIP = 400          # frames before the first poll
TICKS = 900


def new_tmp():
    tmp = tempfile.mkdtemp(prefix='hlhealth_')
    (Path(tmp) / 'Arrowhead/Helldivers2').mkdir(parents=True, exist_ok=True)
    return tmp


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

    def log(self):
        return self.read('hivelord_health.log')

    def status(self):
        return self.read('hivelord_health_STATUS.txt')


def run_suite(src):
    checks, detail = {}, {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp)
        detail['installed'] = str(r.result['installed'])
        detail['build'] = str(r.result['build'])
        checks['the addon installs'] = r.result['installed'] is True
        checks['the installed build is reported'] = str(r.result['build']) == '25480438'
        r.ticks(SHIP + TICKS)
        log = r.log()
        status = r.status()

        # ---- the build gate --------------------------------------------------
        checks['the build is verified and named'] = 'BUILD 25480438 verified' in log
        checks['the offsets are stated in the log'] = 'manager_rva=0x3326688' in log

        # ---- the manager read ------------------------------------------------
        checks['the manager is found at its build RVA'] = 'HP goid=' in log
        # A manager holding no entry and a table pointer that cannot be read both end up as
        # "no entry", and they need opposite fixes -- so the state has to be in the log.
        checks['the manager and table state is reported'] = 'DIAG hm=' in log
        checks['the table slot is reported'] = 'slot0=' in log
        # The maximum the health table gives FOR THE HIVE LORD'S KEY, whether or not its
        # descriptor is present.  That value is what proves the key, the table location and
        # the probe are all right -- and it is available even on the ship.
        checks['the table value for the Hive Lord key is reported'] = \
            'hive_lord_max=150000 (table)' in log
        # The three asset ids are reported even with the HUD switched off, because whether
        # they are readable decides whether drawing is safe at all.
        checks['the asset ids are reported'] = 'ids[font=' in log
        checks['the descriptors the manager holds are listed'] = 'DIAG_DESC' in log
        hp_line = [l for l in log.splitlines() if 'HP goid=' in l]
        hp_line = hp_line[-1] if hp_line else ''
        detail['hp_line'] = hp_line[:120]
        j = r.g.__hive_j()
        cur = r.g.__hive_cur()
        checks['the Hive Lord entry is the one carrying its key'] = f'j={j}' in hp_line
        checks['the exact current health is read'] = f'hp={cur}' in hp_line
        checks['the maximum comes from the health table'] = 'max=150000 (table)' in hp_line
        checks['the descriptor names the entity and unit'] = \
            f'entity={1000 + j}' in hp_line and f'unit={2000 + j}' in hp_line
        # The goid lives at descriptor +0x10, past the entity and unit fields, so a
        # truncated descriptor read is invisible unless this is asserted: it was, and the
        # mutation that shortened the descriptor went unnoticed.
        checks['the descriptor names the goid'] = f'goid={3000 + j}' in hp_line
        checks['the conclusion carries the exact reading'] = \
            f'Hive Lord {cur} / 150000 exact' in status

        # The value must follow the record, not a cached copy.
        r.g.__set_hp(j, 91337)
        r.ticks(200)
        hp_lines = [l for l in r.log().splitlines() if 'HP goid=' in l]
        checks['a changed health value is re-read'] = \
            bool(hp_lines) and 'hp=91337' in hp_lines[-1]
        r.g.__set_hp(j, cur)
        # The HUD only redraws when the reading changes, so the value has to be read back
        # before the screen is asserted on -- without this tick the screen still shows the
        # temporary value above.
        r.ticks(200)

        # ---- the HUD ---------------------------------------------------------
        checks['the HUD shows the exact number'] = \
            f'HIVE LORD  {cur} / 150000' in r.g.__gui_live_text()
        checks['the HUD names the source'] = 'from the health manager' in r.g.__gui_live_text()
        checks['the HUD holds one reading, not a stack'] = int(r.g.__gui_live_count()) <= 2
        # Every exit from the HUD path was a silent return, so "the value is read but
        # nothing is drawn" left no trace anywhere -- no error, no line.  The state line is
        # what makes that diagnosable, so it is asserted on.
        checks['the HUD reports how far it got'] = 'HUD_STATE' in log
        checks['the HUD reports a successful paint'] = 'painted=true' in log
        checks['the HUD state names what it drew'] = 'HIVE LORD' in log
        # The font the engine is handed decides whether anything becomes visible: a call
        # with a font it cannot resolve is accepted and renders nothing, which is how the
        # value was read correctly while the screen stayed empty.  The ids come from the
        # game's own globals, exactly as the shipped Enemy HP mod gets them.
        detail['fonts'] = r.g.__gui_fonts()[:60]
        # The drawing call is the FIRST mod's, the only shape in this project that has been
        # seen to render on screen (overlapping lines prove visible text).  Everything that
        # replaced it -- font/material/alpha ids from the game's globals, IdString64,
        # Gui.material and Material.set_* -- is a different API surface, and four crashes came
        # from guessing at it.  So: assert the proven call, and assert the other path is not
        # touched at all.
        detail['fonts'] = r.g.__gui_fonts()[:60]
        checks['the HUD uses the proven debug-font call'] = \
            'core/performance_hud/debug' in r.g.__gui_fonts()
        checks['the HUD reports which font it used'] = 'font=debug-font' in log
        detail['material_calls'] = r.g.__material_calls()[:70]
        checks['the drawing path touches no material API'] = r.g.__material_calls() == ''
        # The first mod passed a Vector2 position; the reference's Vector3 belongs to the path
        # that is no longer used.
        checks['the HUD position is a Vector2'] = \
            all(len(p.split(',')) == 2 for p in r.g.__gui_pos().split('|') if p)
        # A redraw must retire the previous pair, which is only true if the handles the
        # engine returned are the ones tracked.
        for v in (cur, cur - 5000, cur - 9000):
            r.g.__set_hp(j, v)
            r.ticks(200)
        checks['redrawing does not accumulate live handles'] = \
            int(r.g.__gui_live_count()) <= 2
        checks['redrawing never creates more text objects'] = \
            int(r.g.__gui_text_creates()) <= 2
        # The lifecycle: two text objects made once, then updated in place.  Creating a fresh
        # pair per change and "destroying" a handle the engine returned as 0 accumulated text
        # objects without bound -- which took a live session down after a few minutes.
        detail['text_creates'] = int(r.g.__gui_text_creates())
        detail['text_updates'] = int(r.g.__gui_updates())
        checks['at most two text objects are ever created'] = \
            int(r.g.__gui_text_creates()) <= 2
        checks['the text is updated in place'] = int(r.g.__gui_updates()) > 0
        # The screen must follow the value, so restore it and let the reading settle before
        # asserting on what is displayed -- the loop above deliberately left it at cur-9000.
        r.g.__set_hp(j, cur)
        r.ticks(200)
        checks['the screen shows the latest reading, not a stale one'] = \
            f'{cur}' in r.g.__gui_live_text()

        # ---- read discipline -------------------------------------------------
        checks['no read landed outside a mapped region'] = int(r.g.__read_errors()) == 0
        detail['reads'] = int(r.g.__reads())
        checks['the reads stay bounded'] = 0 < int(r.g.__reads()) <= 200000
        # The log must stay readable.  A live session produced 3054 lines / 250 KB in two
        # minutes because two state lines alternated and defeated their own de-duplication.
        detail['log_lines'] = len(r.log().splitlines())
        checks['the HUD does not flood the log'] = detail['log_lines'] <= 60
        checks['the surface is recorded exactly once'] = \
            len([l for l in r.log().splitlines() if 'HUD_SURFACE created' in l]) == 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_gate_suite(src):
    """A foreign build must refuse, and must not read any structure after refusing."""
    checks, detail = {}, {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre='__break_build()\n')
        before = int(r.g.__reads())
        r.ticks(SHIP + 200)
        log = r.log()
        status = r.status()
        detail['conclusion'] = (status.splitlines()[4] if len(status.splitlines()) > 4 else '')[:100]
        checks['a foreign build is refused'] = 'unsupported game build' in status
        checks['the refusal names the mismatched values'] = 'game.dll' in log
        checks['no health is claimed on a foreign build'] = 'HP goid=' not in log
        checks['the manager is not read after a refusal'] = \
            'MANAGER not available' not in log
        # The gate reads the PE headers only: two small reads per module.
        checks['a refusal costs only the header reads'] = int(r.g.__reads()) - before <= 8
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_absent_suite(src):
    """The key is not in the manager, but a 150000-holder is: say which, not "absent"."""
    checks, detail = {}, {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre='__break_key()\n')
        r.ticks(SHIP + 300)
        log = r.log()
        status = r.status()
        detail['status'] = (status.splitlines()[4] if len(status.splitlines()) > 4 else '')[:110]
        checks['a missing key is reported as a missing entry'] = 'NO_ENTRY' in log
        checks['the manager is still reported as readable'] = 'entries=6' in log
        checks['the conclusion does not claim the Hive Lord is absent'] = \
            'no Hive Lord entry in the health manager' in status
        checks['nothing is drawn without a reading'] = r.g.__gui_live_text() == ''

        # The entry leaving the manager for a moment must not blank the bar: a live log had
        # the HP line and a NO_ENTRY line alternating inside one second while the Hive Lord
        # was being registered, which would make the bar flicker.
        r2 = Run(src, new_tmp())
        r2.ticks(SHIP + 400)
        had = 'HP goid=' in r2.log()
        r2.g.__break_key()
        r2.ticks(30)                     # ~0.5 s: still inside the grace period
        detail['held_after_key_lost'] = r2.g.__gui_live_text()[:60]
        checks['the reading is present before the entry goes'] = had
        checks['a reading is held while the entry is briefly gone'] = \
            bool(r2.g.__gui_live_text())
        r2.ticks(200)                    # past the grace period
        checks['the reading is dropped once the grace period ends'] = \
            'HIVE LORD' not in r2.g.__gui_live_text()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_surface_suite(src):
    """The surface must survive a live world and be dropped when its world goes."""
    checks, detail = {}, {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp)
        r.ticks(SHIP + 300)
        created_before = int(r.g.__gui_created())
        # Engine handles are fresh wrappers per call, so comparing them by identity would
        # tear the surface down every frame and nothing would ever be visible.
        checks['a live world keeps its surface'] = created_before == 1
        # Only one world on offer: there is no "other" world to pick, and refusing to build
        # a surface at all is how a working reading ends up with an empty screen.
        r2 = Run(src, new_tmp(), pre='__ONE_WORLD = true\n')
        r2.ticks(SHIP + 300)
        detail['one_world_state'] = [l for l in r2.log().splitlines()
                                     if 'HUD_STATE' in l][-1:][:1]
        checks['a single world still gets a surface'] = \
            'painted=true' in r2.log() or 'HUD_SURFACE created' in r2.log()
        # Eleven worlds that all render the same string: a rendered comparison cannot tell
        # them apart, so the identity branch is what has to pick one.
        r3 = Run(src, new_tmp(), pre='__SAME_RENDER = true\n')
        r3.ticks(SHIP + 300)
        detail['same_render'] = [l for l in r3.log().splitlines()
                                 if 'HUD_SURFACE created' in l][-1:][:1]
        checks['identical-rendering worlds still get a surface'] = \
            'HUD_SURFACE created' in r3.log()
        checks['the surface line records how the world was chosen'] = \
            'identity=' in r3.log() and 'surface #' in r3.log()
        r.lua.execute('__NO_WORLDS = true')
        r.ticks(60)
        # Clearing BLANKS the text rather than destroying it (the reference's way, and the
        # only one that works when the engine returns 0 as the handle), so what matters is
        # that no reading is left on screen.
        checks['an empty world list leaves no reading on screen'] = \
            'HIVE LORD' not in r.g.__gui_live_text()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_manager_swap_suite(src):
    """The manager global moves when the world does.

    The ship and a mission each have their own manager, and the game re-points the global.
    An addon that caches the pointers keeps reading the ship's manager inside the mission:
    a live session showed entries=1 for the eleven minutes spanning a mission change, and
    the Hive Lord was never seen even while it was being damaged.
    """
    checks, detail = {}, {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre='__use_ship_manager()\n')
        r.ticks(SHIP + 200)
        log1 = r.log()
        detail['before_swap'] = [l for l in log1.splitlines() if 'MANAGER' in l][-1:][:1]
        checks['the ship manager is read first'] = 'NO_ENTRY entries=1' in log1
        checks['no reading is claimed from the ship manager'] = 'HP goid=' not in log1

        r.g.__use_mission_manager()
        r.ticks(400)
        log2 = r.log()
        checks['the manager change is reported'] = 'MANAGER changed' in log2
        checks['the mission manager is found after the swap'] = 'HP goid=' in log2
        checks['the reading starts without a restart'] = \
            f'hp={r.g.__hive_cur()}' in log2

        # An empty manager is a state ("nothing is loaded yet"), not a suspected bad offset:
        # the two need opposite next steps, and the live log conflated them.
        r.g.__set_manager_count(0)
        r.ticks(200)
        log3 = r.log()
        checks['an empty manager is reported as a state'] = \
            'the manager holds no entries yet' in log3
        checks['an empty manager is not called implausible'] = \
            'implausible entry count' not in log3
        r.g.__set_manager_count(r.g.__entries())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_api_refusal_suite(src):
    """Gui.text is the only thing required; nothing else may be needed to draw.

    The proven call needs no material API and no IdString64, so their absence must not stop
    the HUD -- and the absence of Gui.text itself must stop it safely rather than crash.
    """
    checks, detail = {}, {}

    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre='_G.stingray.Gui.text = nil\n')
        r.ticks(SHIP + 300)
        log = r.log()
        detail['no_text_api'] = [l for l in log.splitlines() if 'HUD_STATE' in l][-1:][:1]
        checks['no text is drawn without Gui.text'] = r.g.__gui_texts() == ''
        checks['the refusal is reported without Gui.text'] = 'refused' in log
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # Without update_text the destroy-and-recreate path runs; it must still hold at most two
    # live objects, because that accumulation is what crashed a session after a few minutes.
    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre='_G.stingray.Gui.update_text = nil\n')
        r.ticks(SHIP + 900)
        detail['no_update_api'] = [l for l in r.log().splitlines() if 'HUD_STATE' in l][-1:][:1]
        checks['the HUD still draws without Gui.update_text'] = r.g.__gui_texts() != ''
        checks['the create/destroy path holds at most two live objects'] = \
            int(r.g.__gui_live_count()) <= 2
        # ...and when the reading goes, that path does destroy what it made, so nothing is
        # left behind on the surface.
        r.g.__break_key()
        r.ticks(400)
        checks['the create/destroy path cleans up when the reading goes'] = \
            int(r.g.__gui_live_count()) <= 2 and 'HIVE LORD' not in r.g.__gui_live_text()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_surface_lifecycle_suite(src):
    """No surface is ever destroyed, and no more than the cap are ever made.

    World.destroy_gui is the call that took the game down on mission entry: entering a mission
    is exactly when the world list changes and the handle it was given is stale.  The shipped
    reference mod never calls it -- it blanks the old surface and abandons it -- so "never
    called" is a property, not a style preference.  And because surfaces are abandoned rather
    than destroyed, a world comparison that fails to hold would make one per frame, so
    creation is capped too.
    """
    checks, detail = {}, {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp)
        r.ticks(SHIP + 400)
        checks['a surface is created'] = int(r.g.__gui_created()) >= 1
        checks['no surface is ever destroyed'] = int(r.g.__world_destroys()) == 0
        checks['no text is ever destroyed'] = int(r.g.__gui_destroys()) == 0
        detail['surfaces'] = int(r.g.__gui_created())
        checks['surfaces do not accumulate'] = int(r.g.__gui_created()) <= 12

        # The world key changes on every call: an uncapped version makes a surface per frame.
        r2 = Run(src, new_tmp(), pre='__WORLD_CHURN = true\n')
        r2.ticks(SHIP + 400)
        detail['churn_surfaces'] = int(r2.g.__gui_created())
        checks['surface creation is capped under world churn'] = \
            int(r2.g.__gui_created()) <= 12
        checks['giving up on drawing is reported'] = 'giving up' in r2.log()
        checks['a capped run never destroys a surface either'] = \
            int(r2.g.__world_destroys()) == 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def all_checks(source):
    out = {}
    for fn in (run_suite, run_gate_suite, run_absent_suite, run_surface_suite,
               run_manager_swap_suite, run_api_refusal_suite, run_surface_lifecycle_suite):
        part, _ = fn(source)
        out.update(part)
    return out


MUTATIONS = {
    # The count is a u32 AT hm+0x1020.  Reading a different offset yields a garbage count.
    'wrong-count-offset': ("    count_off = 0x1020,", "    count_off = 0x1028,"),
    # Records are 0x1B8 apart with health at +0x14.
    'wrong-record-stride': ("    record_stride = 0x1B8,", "    record_stride = 0x1C8,"),
    'wrong-hp-offset': ("    hp_off = 0x14,", "    hp_off = 0x18,"),
    # NOTE: there is deliberately no mutation for `descriptor_size`.  The descriptor is 24
    # bytes and the addon reads all 24, but every field it uses ends at +20 (type 0-7,
    # entity 8-11, unit 12-15, goid 16-19), so shortening the read to 20 changes nothing
    # observable -- the mutation was measured and could not be caught.  It is kept at the
    # true size because it documents the layout and bounds the read, and an unobservable
    # mutation in this list would report a hole forever.
    # The table probe starts at key % 1002.  Starting anywhere else misses (the Hive Lord's
    # slot is 981, far outside a 63-step scan from 0).
    'wrong-table-start': (
        "    local start = (lo % C.table_slots + (hi % C.table_slots) * (4294967296 % C.table_slots))\n"
        "        % C.table_slots",
        "    local start = 0",
    ),
    # The build gate is skipped, so a foreign build is read as if the offsets applied.
    'no-build-gate': (
        "        if g[1] == b.game[1] and g[2] == b.game[2] and g[3] == b.game[3]\n"
        "            and x[1] == b.exe[1] and x[2] == b.exe[2] and x[3] == b.exe[3] then",
        "        if true then",
    ),
    # NOTE: there is deliberately no mutation for "the returned handle is ignored" any more.
    # The addon no longer destroys text at all -- it keeps the two objects and updates them
    # in place, as the reference does -- so there is no handle-tracking code left to break.
    # The accumulation that mutation used to model is covered by the create cap instead
    # (`at most two text objects are ever created`), and `hud-recreate-each-change` is the
    # mutation that trips it.
    # Worlds are compared by identity; engine handles are fresh per call, so the surface is
    # torn down on every frame and nothing is visible.
    'world-by-identity': (
        "local function world_key(v) return tostring(v) end",
        "local function world_key(v) return v end",
    ),
    # The state line is dropped, so "the manager holds nothing" and "the table pointer is
    # unreadable" become indistinguishable in the log.
    'no-state-diag': (
        "            wf('%s', diag)\n            wf('%s', desc)",
        "            local _quiet = diag .. desc",
    ),
    # The manager pointers are cached, so a world change leaves the addon reading the ship's
    # manager for the rest of the session -- the bug that produced eleven minutes of
    # "entries=1" while the Hive Lord was being damaged.
    'manager-cached': (
        "local function find_manager()\n    local hm = ptr_at(M.base + C.manager_rva)",
        "local function find_manager()\n    if M.hm then return M.hm end\n"
        "    local hm = ptr_at(M.base + C.manager_rva)",
    ),
    # An empty manager is treated as a refusal, so the state before anything is loaded looks
    # like a wrong offset.
    'empty-manager-is-an-error': (
        "    if n == 0 then return nil, 'the manager holds no entries yet' end\n",
        "    if n == 0 then return nil, 'implausible entry count 0' end\n",
    ),
    # The HUD path goes back to silent returns, so "read but not drawn" is undiagnosable.
    'hud-silent': (
        "        local ok, id, source = paint(w, h, txt, sub)\n"
        "        hud_state(string.format('painted=%s id=%s font=%s text=\"%s\"', tostring(ok),\n"
        "            tostring(id), tostring(source), txt))",
        "        paint(w, h, txt, sub)",
    ),
    # NOTE: the mutations that used to model the reference's font-id / material path
    # (`hud-debug-font`, `no-material-config`, `hud-alpha-optional`) are gone with that path.
    # The drawing call is now the first mod's proven one and touches no material API at all;
    # `hud-material-path-restored` below is the guard against that path creeping back.
    # The API check is dropped, so a missing Gui.text is used anyway -- a native fault shape.
    'draw-without-api-check': (
        "    local okapi, why = draw_api()\n    if not okapi then\n"
        "        M.draw_key = nil\n"
        "        return false, nil, 'refused (' .. tostring(why) .. ')'\n    end",
        "    local okapi = true",
    ),
    # The material API is used again, which is where four live crashes came from: it is a
    # different engine surface from the one this build has been seen to render.
    'hud-material-path-restored': (
        "    local function line(i, str, dy, size, grey)\n"
        "        local pos = sr.Vector2(x, y + dy * s)",
        "    local function line(i, str, dy, size, grey)\n"
        "        if M.gui and type(sr.Gui.material) == 'function' and not M.ink then\n"
        "            M.ink = sr.Gui.material(M.gui, 'core/performance_hud/debug')\n"
        "        end\n"
        "        local pos = sr.Vector2(x, y + dy * s)",
    ),
    # The position goes back to the reference's Vector3, which belongs to the path that is no
    # longer used.
    'hud-vector3-position': (
        "        local pos = sr.Vector2(x, y + dy * s)          -- Vector2, as the first mod passed it",
        "        local pos = sr.Vector3(x, y + dy * s, 952)",
    ),
    # NOTE: `hud-alpha-optional` is gone with the material path it belonged to, and
    # `hud-recreate-each-change` is gone because it can no longer be tripped: with the update
    # path present a text object is updated in place, and the create cap bounds creation
    # regardless.  Accumulation is guarded where it can actually happen -- the surface cap
    # (`hud-surface-flood`) and the live-object bounds asserted on both drawing paths.
    # A per-frame state line alternating with the outcome line defeats the de-duplication and
    # writes a line every frame -- 3054 lines in two minutes in a live session.  Modelled by
    # removing the de-duplication itself: the surface flag this used to target became dead
    # code once the world pick moved to identity.
    'hud-state-flood': (
        "local function hud_state(text)\n    if text ~= M.last_hud then\n        M.last_hud = text\n"
        "        wf('HUD_STATE %s', text)\n    end\nend",
        "local function hud_state(text)\n    M.last_hud = text\n    wf('HUD_STATE %s', text)\nend",
    ),
    # The surface is destroyed on a world change again -- with a handle that is stale exactly
    # when a mission starts.  This is the call that crashed the game on mission entry.
    'hud-surface-destroyed': (
        "        M.gui, M.gui_world_key, M.ink, M.texts = nil, nil, nil, nil\n    end\n    if not M.gui then",
        "        pcall(World.destroy_gui, world, M.gui)\n"
        "        M.gui, M.gui_world_key, M.ink, M.texts = nil, nil, nil, nil\n    end\n    if not M.gui then",
    ),
    # The surface cap is dropped, so a world comparison that fails to hold makes a surface on
    # every frame instead of stopping.
    'hud-surface-flood': (
        "            if M.surfaces > C.surface_cap then",
        "            if false then",
    ),
}


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
        flat = src.replace('\r\n', '\n')
        if old not in flat:
            print(f'SKIP {args.mutate}: anchor not found')
            return 2
        mutated = flat.replace(old, new, 1)
        base = all_checks(flat)
        already = sorted(k for k, v in base.items() if not v)
        if already:
            print(f'--- mutation {args.mutate} ---')
            print(f'BASELINE FAILING ({len(already)}) -- verdict suppressed:')
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

    # One list, used by both the plain run and the mutation run.  When the plain path called
    # a different set of suites than all_checks(), the baseline and the mutation baseline
    # disagreed and every mutation reported BASELINE FAILING.
    checks = all_checks(src)
    failed = sorted(k for k, v in checks.items() if not v)
    for k in failed:
        print('FAIL ', k)
    for fn in (run_suite, run_gate_suite, run_absent_suite, run_surface_suite,
               run_manager_swap_suite, run_api_refusal_suite,
               run_surface_lifecycle_suite):
        _, d = fn(src)
        for k, v in d.items():
            print(f'  {k} = {v}')
    print(f'{len(checks) - len(failed)}/{len(checks)} checks passed')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
