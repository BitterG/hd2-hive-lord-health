"""Offline simulation + mutation tests for hivelord_roster.lua.

The roster reader is pointer arithmetic over four small blocks, so every failure mode
worth catching is reachable offline:

  * it trusts a build whose gate signature is not there (the offsets are RVAs into
    game.dll and a different build means a confident, wrong answer);
  * it dereferences an implausible pointer instead of rejecting it;
  * it reads a roster with an implausible count;
  * it gets the stride or the entity offset wrong, which silently reports "the Hive Lord
    is not here" -- the exact ambiguity this addon exists to remove;
  * it cannot tell "read the roster" from "read something plausible", which is what the
    captured-roster overlap self-check is for.

Run:  python HiveLord-HP/tests/test_roster.py
      python HiveLord-HP/tests/test_roster.py --mutate <name>
      python HiveLord-HP/tests/test_roster.py --list
"""
import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
ENTRY = ROOT / 'Source/mods/hivelord/hivelord_roster.lua'
FIXTURE = Path(__file__).resolve().parent / 'fixture_roster.lua'

TICKS = 1200
POLL_TICKS = 200


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

    def tick(self, n=1, dt=0.016667):
        f = self.g.update
        for _ in range(n):
            f(dt)

    def read(self, name):
        for d in (Path(self.tmp) / 'Arrowhead/Helldivers2', Path(self.tmp)):
            p = d / name
            if p.exists():
                return p.read_text(encoding='utf-8', errors='replace')
        return ''

    def find(self, name):
        for d in (Path(self.tmp) / 'Arrowhead/Helldivers2', Path(self.tmp)):
            if (d / name).exists():
                return True
        return False


def new_tmp():
    # The addon writes into %APPDATA%/Arrowhead/Helldivers2, which exists on a real
    # machine.  If the harness does not create it the addon falls back down its
    # candidate-directory chain and writes into the current directory instead -- which
    # makes every file assertion here silently test nothing.
    tmp = tempfile.mkdtemp(prefix='hlroster_')
    (Path(tmp) / 'Arrowhead/Helldivers2').mkdir(parents=True, exist_ok=True)
    return tmp


def last_line(text, prefix):
    hits = [l for l in text.splitlines() if l.startswith(prefix)]
    return hits[-1] if hits else ''


def run_suite(src):
    checks, detail = {}, {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp)
        checks['the addon installs'] = bool(r.result and r.result['installed'])
        r.tick(TICKS)
        log = r.read('hivelord_roster.log')
        status = r.read('hivelord_roster_STATUS.txt')

        # ---- the build gate -----------------------------------------------------
        checks['the module base is resolved and the gate is verified'] = \
            'MODULE game.dll base=' in log and 'gate=0x93F159 ok' in log
        checks['a gate mismatch is not reported anywhere'] = 'BUILD_GATE failed' not in log

        # ---- the roster ---------------------------------------------------------
        roster = last_line(log, 'ROSTER ')
        detail['roster_line'] = roster
        checks['a roster line is logged'] = 'ROSTER ' in roster
        checks['all three faction slots are inspected'] = \
            '0x660' in roster and '0x668' in roster and '0x670' in roster
        row = r.g.__hive_row_index()
        checks['the Hive Lord is located by entity id'] = f'hive_lord=0x660#{row}' in roster
        checks['the Terminid roster has the captured row count'] = '/44' in roster
        # The self-check: the live roster must intersect the independently captured one.
        # Without it, a wrong stride would report a clean, confident "not here".
        checks['the captured-roster overlap is counted'] = 'overlap=39' in roster

        # ---- the status conclusion ---------------------------------------------
        # Once the exact health is available it owns the first line, because "present
        # and here is its health" is strictly stronger than "present".  The roster
        # details are therefore asserted on the log line, and the conclusion is asserted
        # to still carry the roster states -- a slot that could not be read must not
        # vanish from the file just because a different read succeeded.
        checks['the roster answer is logged with its slot and row'] = \
            f'hive_lord=0x660#{row}' in roster
        checks['the conclusion carries the exact reading'] = \
            'OK - Hive Lord HP' in status
        checks['the conclusion keeps the roster states visible'] = \
            'roster 0x660:ok/44' in status
        checks['the status file reports the reader health'] = 'lines=' in status
        # The loader's JIT cache state decides how this mod's own timings should be read:
        # a flush discards every compiled trace.  It is asserted here because the loader's
        # `version` field is not a usable signal (v18 still reports 17).
        checks['the status reports the loader JIT cache state'] = \
            'loader jit: managed 16384 KB / 8000 traces' in status
        checks['the staged status write left no .new file'] = \
            not r.find('hivelord_roster_STATUS.txt.new')

        # ---- the dump -----------------------------------------------------------
        dump = r.read('hivelord_roster.txt')
        checks['the roster is dumped'] = dump != ''
        checks['the dump tags the Hive Lord row'] = 'HIVE_LORD' in dump
        checks['the dump tags the reference rows'] = 'terminid(reference)' in dump
        rows_dumped = len([l for l in dump.splitlines() if l.startswith('0x660\t')])
        detail['rows_dumped'] = rows_dumped
        checks['the dump carries every row of the Terminid roster'] = rows_dumped == 44
        checks['the staged dump write left no .new file'] = \
            not r.find('hivelord_roster.txt.new')

        # ---- read discipline ----------------------------------------------------
        checks['no read landed outside a mapped region'] = int(r.g.__read_errors()) == 0
        total_reads = int(r.g.__reads_count())
        detail['reads'] = total_reads
        # 44 rows * 0x80 = 5632 bytes per poll in one read, plus a handful of pointers.
        # A per-frame poll or an unbounded count would dwarf this.
        checks['the reads stay bounded'] = 0 < total_reads <= 400

        # ---- polling is deduped -------------------------------------------------
        before = len([l for l in log.splitlines() if l.startswith('ROSTER ')])
        r.tick(POLL_TICKS * 3)
        log2 = r.read('hivelord_roster.log')
        after = len([l for l in log2.splitlines() if l.startswith('ROSTER ')])
        detail['roster_lines'] = after
        checks['an unchanged roster is not re-logged'] = after == before

        # ---- the live health manager -------------------------------------------
        # The roster answers "is it here"; this answers "how much health is left",
        # which the networked field array provably cannot answer (nothing in it reaches
        # zero when the entity dies).  The reference enemy-HP mod reads exact per-enemy
        # health from this manager, so the same read has to work for the Hive Lord.
        hp_line = last_line(r.read('hivelord_roster.log'), 'HIVELORD_HP ')
        detail['hp_line'] = hp_line
        j = r.g.__hp_hive_j()
        cur = r.g.__hp_hive_value()
        checks['the health manager is located from the code, not a hardcoded RVA'] = \
            'HEALTH_MANAGER global=' in r.read('hivelord_roster.log')
        checks['the manager entry is the one holding the type hash'] = f'j={j}' in hp_line
        checks['the exact current health is read'] = f'hp={cur}' in hp_line
        checks['the maximum is the offline-verified constant'] = 'max=150000' in hp_line
        checks['the status conclusion carries the exact reading'] = \
            f'OK - Hive Lord HP {cur} / 150000' in r.read('hivelord_roster_STATUS.txt')

        # The value must follow the record it came from, not a cached copy.
        r.g.__set_hp(j, 91337)
        r.tick(POLL_TICKS)
        checks['a changed health value is re-read'] = \
            'hp=91337' in last_line(r.read('hivelord_roster.log'), 'HIVELORD_HP ')
        # A value that cannot be a Hive Lord's health must be flagged, not shown as fact.
        r.g.__set_hp(j, 999999)
        r.tick(POLL_TICKS)
        checks['an out-of-range reading is flagged rather than trusted'] = \
            'OUT OF RANGE' in r.read('hivelord_roster_STATUS.txt')
        r.g.__set_hp(j, cur)
        r.tick(POLL_TICKS)

        # ---- the Hive Lord leaves the roster -----------------------------------
        r.g.__drop_hive_lord()
        r.tick(POLL_TICKS)
        log3 = r.read('hivelord_roster.log')
        checks['the change is logged when the Hive Lord goes'] = \
            'hive_lord=no' in log3
        status3 = r.read('hivelord_roster_STATUS.txt')
        checks['the absent conclusion states it is not in any roster'] = \
            'OK - Hive Lord NOT in any roster' in status3
        # "not present" and "the layout is wrong" must not read the same.  With a valid
        # roster the overlap is still high, and the conclusion says so.
        checks['the absent conclusion keeps the overlap as evidence'] = \
            'match the captured Terminid roster' in status3
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_gate_suite(src):
    """A build whose gate signature is absent must be refused, not guessed at."""
    checks = {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp)
        r.g.__break_gate()
        r.tick(TICKS)
        log = r.read('hivelord_roster.log')
        status = r.read('hivelord_roster_STATUS.txt')
        checks['a build-gate mismatch is logged'] = 'BUILD_GATE failed' in log
        checks['the wrong instruction is named'] = 'expected 498b4008' in log
        checks['the status refuses instead of guessing'] = 'REFUSED - build gate failed' in status
        checks['no roster is read after a gate failure'] = 'ROSTER ' not in log
        # And it must refuse before touching anything: no roster dump exists.
        checks['nothing is dumped after a gate failure'] = \
            not r.find('hivelord_roster.txt')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks


def run_wait_suite(src):
    """No director yet, and no game.dll at all, must both read as waiting -- not as
    'the Hive Lord is absent'."""
    checks = {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp)
        r.g.__clear_director()
        r.tick(TICKS)
        log = r.read('hivelord_roster.log')
        status = r.read('hivelord_roster_STATUS.txt')
        checks['an unset director reads as waiting'] = \
            'WAITING - the director is not set yet' in status
        checks['waiting does not claim the Hive Lord is absent'] = \
            'NOT in any roster' not in status
        checks['the gate is still verified while waiting'] = 'MODULE game.dll base=' in log
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre="__MODULE_HIDDEN = true\n")
        r.tick(TICKS)
        status = r.read('hivelord_roster_STATUS.txt')
        checks['a missing game.dll reads as waiting'] = \
            'game.dll is not loaded' in status or 'WAITING' in status
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks


def run_count_suite(src):
    """An implausible roster count must be rejected before the rows are read."""
    checks = {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp)
        reads_before = int(r.g.__reads_count())
        # 100000 rows * 0x80 would be a 12 MB read at a pointer that is probably garbage.
        r.g.__set_count(0x30000000, 100000)
        r.tick(TICKS)
        log = r.read('hivelord_roster.log')
        status = r.read('hivelord_roster_STATUS.txt')
        # The check names the slot: slots B and C hold count 0 and report "implausible
        # count" too, so a bare substring match is satisfied by them and the bound on
        # slot A is never actually tested.
        checks['an implausible count is reported for the slot that has it'] = \
            '0x660:implausible count/100000' in log
        # 100000 rows * 0x80 would be a 12 MB read at a pointer that is probably garbage.
        # The bound allows for the health-manager scan, one chunk per poll.
        checks['an implausible count is not read'] = \
            int(r.g.__reads_count()) - reads_before <= 120
        checks['the conclusion does not hide a rejected roster slot'] = \
            'implausible' in status
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks


def run_health_suite(src):
    """The health-manager path: discovery, validation, and its failure modes.

    Every interesting case here is a *negative*: the manager cannot be found, its count
    is implausible, or the entry is absent.  Each must read differently from "the Hive
    Lord has 0 health".
    """
    checks, detail = {}, {}

    def fresh():
        tmp = new_tmp()
        return tmp, Run(src, tmp)

    # 1. no accessor bytes -> no candidate global -> no manager, and no HP claim.
    # The scan walks the module's executable bytes one chunk per poll, so this has to
    # run long enough to exhaust the walk and reach its verdict.
    tmp, r = fresh()
    try:
        r.g.__remove_code()
        r.tick(8000)
        log = r.read('hivelord_roster.log')
        status = r.read('hivelord_roster_STATUS.txt')
        checks['a missing accessor is reported, not guessed'] = \
            'HEALTH_MANAGER not found' in log
        checks['no health is claimed when the manager is missing'] = \
            'HIVELORD_HP' not in log and 'Hive Lord HP' not in status
        checks['the roster answer still stands without the manager'] = \
            'OK - Hive Lord present' in status or 'Hive Lord' in status
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 2. an implausible entry count must make the candidate fail validation
    tmp, r = fresh()
    try:
        r.g.__break_manager()
        r.tick(TICKS)
        log = r.read('hivelord_roster.log')
        checks['an implausible manager count is rejected'] = \
            ('HEALTH_MANAGER not found' in log) or ('n=' not in log)
        checks['no health is claimed for a rejected manager'] = 'HIVELORD_HP ' not in log
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 3. the manager is fine but holds no entry with this type hash
    tmp, r = fresh()
    try:
        r.g.__set_desc_type(r.g.__hp_hive_j(), 'aabbccddeeff0011')
        r.tick(TICKS)
        log = r.read('hivelord_roster.log')
        checks['an absent entry is reported as absent'] = \
            'HIVELORD_HP absent' in log
        checks['an absent entry does not fabricate a value'] = 'hp=' not in \
            last_line(log, 'HIVELORD_HP ')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 4. pure: the code scan itself
    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre="__HIVELORD_ROSTER_EXPOSE_PURE = true\n")
        res = r.lua.execute(
            "local p = __HIVELORD_ROSTER_PURE\n"
            "local va = __code_va()\n"
            "local blob = __code_blob()\n"
            "local sites = p.sites_with_disp(blob, 0x1058)\n"
            "local g = sites[1] and p.global_load_before(blob, sites[1], va) or nil\n"
            "local cands = p.manager_candidates(blob, va)\n"
            "return {\n"
            "  n_sites = #sites,\n"
            "  first = sites[1] or -1,\n"
            "  g = g or -1,\n"
            "  want = __hm_global_addr(),\n"
            "  ncands = #cands,\n"
            "  cand1 = cands[1] or -1,\n"
            "  other = p.sites_with_disp(blob, 0x9999) and #p.sites_with_disp(blob, 0x9999) or 0,\n"
            "}\n")
        detail['scan'] = {k: res[k] for k in ('n_sites', 'first', 'g', 'want', 'ncands')}
        checks['the recs-array displacement is found in the code'] = res['n_sites'] == 1
        checks['it is found at the expected offset'] = res['first'] == 0x50
        checks['the global load is recovered from the site'] = res['g'] == res['want']
        checks['the candidate list contains that global'] = \
            res['ncands'] >= 1 and res['cand1'] == res['want']
        checks['an absent displacement yields no sites'] = res['other'] == 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_pure_suite(src):
    """Exact-value tests of the pure helpers, reachable through the test seam.

    Everything runs inside Lua and only numbers and hex text come back: lupa decodes a
    binary Lua string as UTF-8 and raises, so a byte blob must never cross that boundary.
    """
    checks, detail = {}, {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre="__HIVELORD_ROSTER_EXPOSE_PURE = true\n")
        pure = r.g.__HIVELORD_ROSTER_PURE
        checks['the pure helpers are exposed'] = pure is not None and pure.entities_in is not None
        if not checks['the pure helpers are exposed']:
            return checks, detail

        res = r.lua.execute(
            "local p = __HIVELORD_ROSTER_PURE\n"
            "local t = {}\n"
            "for i = 1, 3 * 0x80 do t[i] = string.char(0) end\n"
            "local function put(id, row)\n"
            "  local off = row * 0x80 + 8\n"
            "  for i = 1, 8 do t[off + i] = string.char(tonumber(id:sub(i*2-1, i*2), 16)) end\n"
            "end\n"
            "put('cb077af7c7d965d4', 0)\n"
            "put('aabbccddeeff0011', 1)\n"
            "local blob = table.concat(t)\n"
            "local ents = p.entities_in(blob, 3, 0x80, 8)\n"
            "return {\n"
            "  n = #ents,\n"
            "  first = p.hex_of(ents[1]),\n"
            "  want = p.hex_of(p.HIVE_LORD),\n"
            "  refs = #p.REFERENCE,\n"
            "  find1 = p.find_entity(ents, p.HIVE_LORD) or -1,\n"
            "  findnone = p.find_entity(ents, 'zzzzzzzz') and 1 or 0,\n"
            "  overlap = p.reference_overlap(ents),\n"
            "  ptr_big = p.ptr_at(2^46) and 1 or 0,\n"
            "  ptr_zero = p.ptr_at(0) and 1 or 0,\n"
            "  read_zero = p.read(0x140000000, 0) and 1 or 0,\n"
            "  read_big = p.read(0x140000000, 8 * 1024 * 1024) and 1 or 0,\n"
            "  read_frac = p.read(1.5, 8) and 1 or 0,\n"
            "  read_ok = p.read(0x140000000, 4) and 1 or 0,\n"
            "}\n")
        detail['pure'] = {k: res[k] for k in
                          ('n', 'first', 'want', 'refs', 'find1', 'findnone', 'overlap')}
        checks['the entity ids are pulled at the right stride'] = res['n'] == 3
        checks['the first row is the Hive Lord'] = res['first'] == 'cb077af7c7d965d4'
        checks['the Hive Lord id is the documented one'] = res['want'] == 'cb077af7c7d965d4'
        checks['the reference set is populated'] = res['refs'] >= 39
        checks['the finder reports the row it matched'] = res['find1'] == 1
        checks['the finder reports nothing when absent'] = res['findnone'] == 0
        # One reference row is present in the three-row blob, and the other row is not a
        # reference, so the self-check must say exactly one.
        checks['the overlap counts the reference entities present'] = res['overlap'] == 1
        checks['an implausible pointer is rejected'] = res['ptr_big'] == 0
        checks['a null pointer is rejected'] = res['ptr_zero'] == 0
        checks['a zero-length read is rejected'] = res['read_zero'] == 0
        checks['an oversized read is rejected'] = res['read_big'] == 0
        checks['a non-integer address is rejected'] = res['read_frac'] == 0
        checks['a sane read is allowed'] = res['read_ok'] == 1

        # The bounds must be enforced by the reader itself, before the OS is asked.  The
        # fixture counts a read that lands outside a mapped region, so a guard that only
        # exists downstream of the call cannot hide here.
        before = int(r.g.__read_errors())
        r.lua.execute(
            "local p = __HIVELORD_ROSTER_PURE\n"
            "p.read(2^47, 8)\n"
            "p.read(0x10, 8)\n"
            "p.read(1.5, 8)\n"
            "p.read(0x140000000, 0)\n")
        checks['an implausible read never reaches the OS'] = \
            int(r.g.__read_errors()) == before
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_env_suite(src):
    """A reader that cannot work must say so rather than appear to do nothing."""
    checks = {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp, pre=(
            "ffi = nil\n"
            "require = function(n) if n == 'ffi' then return nil end\n"
            "  error('module not found: ' .. tostring(n)) end\n"))
        status = r.read('hivelord_roster_STATUS.txt')
        installed = None
        if r.result is not None:
            try:
                installed = r.result['installed']
            except Exception:
                installed = None
        checks['a missing ffi is stated in STATUS'] = 'ffi builtin is unavailable' in status
        checks['a missing ffi reports that it did not install'] = installed is False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks


MUTATIONS = {
    # The row stride is wrong, so nothing in the roster looks like an entity id.
    'wrong-stride': ("    row_stride = 0x80,", "    row_stride = 0x40,"),
    # The entity lives at +8; reading +0x10 gets whatever follows it.
    'wrong-entity-offset': ("    row_entity_off = 0x08,", "    row_entity_off = 0x10,"),
    # The wrong id is searched for, so a real Hive Lord reads as absent.
    'wrong-hive-lord-id': (
        "local HIVE_LORD = le_hex('cb077af7c7d965d4')",
        "local HIVE_LORD = le_hex('0000000000000000')",
    ),
    # The build gate is believed unconditionally: the offsets are RVAs, so this turns a
    # game update into a confident wrong answer instead of a refusal.
    'no-build-gate': ("    if hex ~= '498b4008' then", "    if false then"),
    # A roster count is trusted, so a garbage header produces a huge read.
    'no-count-bound': ("    if count == 0 or count > C.max_rows then", "    if count == 0 then"),
    # The reader's own address/size bounds are dropped, so an implausible read is handed
    # to the OS instead of being refused.  (This replaces a mutation on ptr_at's range
    # check: that check is *redundant by construction* -- `hi >= 32768` implies
    # `v >= 2^47`, which is the same bound `read` applies -- so no honest test can tell
    # whether it is present.  It stays as defence in depth; it is not mutation-testable,
    # and pretending otherwise would be a check that cannot fail.)
    'read-guard-removed': (
        "    if type(addr) ~= 'number' or addr % 1 ~= 0 or addr < 65536 or addr >= 2 ^ 47 then",
        "    if type(addr) ~= 'number' then",
    ),
    # Every poll is logged, which is the flood this project already suffered.
    'no-dedupe': ("    if line ~= M.last_line then", "    if true then"),
    # The self-check always reports zero, so a wrong layout reads as "absent".
    'overlap-always-zero': ("    return n\nend\n\nlocal function u64_at",
                            "    return 0\nend\n\nlocal function u64_at"),
    # Nothing is dumped, so a failed identification leaves no evidence.
    'no-dump': ("        dump(slots)", "        -- dump suppressed"),
    # The current health is at record+0x14; reading +0x18 gets the next field.
    'hp-value-offset-wrong': ("    hp_value_off = 0x14,", "    hp_value_off = 0x18,"),
    # The record stride is 0x1B8; a wrong stride lands in a different entry's record.
    'hp-stride-wrong': ("    hp_record_stride = 0x1B8,", "    hp_record_stride = 0x1C8,"),
    # The count is a u32 AT hm+0x1020, not a pointer to one.  This is the mistake the
    # reference's double decode invites, and it must not pass validation.
    'count-read-as-pointer': (
        "    local n = u32_at(read(hm + C.hp_count_off, 4), 0)",
        "    local n = u32_at(read(ptr_at(hm + C.hp_count_off) or 0, 4), 0)",
    ),
    # Only mod=00 forms are matched, so the [reg+disp32] accesses are never found and no
    # manager is ever located.  This is the exact shape of the bug the fixture caught:
    # a mod-field test that is always false.
    'no-modrm-mod10': (
        "        if (b0 == 0x48 or b0 == 0x4C) and b1 == 0x8B and modrm_mod(b2) == 2 then",
        "        if (b0 == 0x48 or b0 == 0x4C) and b1 == 0x8B and modrm_mod(b2) == 0 then",
    ),
    # The RIP-relative form is no longer recognised, so no global can be recovered.
    'no-rip-relative': (
        "            if (b0 == 0x48 or b0 == 0x4C) and b1 == 0x8B and modrm_mod(b2) == 0\n"
        "                and modrm_rm(b2) == 5 then",
        "            if (b0 == 0x48 or b0 == 0x4C) and b1 == 0x8B and modrm_mod(b2) == 0\n"
        "                and modrm_rm(b2) == 4 then",
    ),
    # Any value is treated as plausible, so a garbage read is displayed as fact.
    'no-range-flag': (
        "            local sane = hp and hp >= 0 and hp <= MAX_HP",
        "            local sane = true",
    ),
    # The exact reading never reaches the conclusion, so the weaker roster sentence wins.
    # Only the format text is changed: replacing the whole `conclude(string.format(` call
    # leaves the call's closing paren behind and the mutant will not even compile -- which
    # the harness reported as a syntax error rather than a caught mutation.
    'no-hp-conclusion': (
        "                    'OK - Hive Lord HP %s / %d -- exact, from the live health manager '",
        "                    'OK - Hive Lord %s %s '",
    ),
    # The overlap has no floor, so a region tail smaller than the overlap moves the
    # cursor backwards and the scan never reaches a verdict.
    'no-progress-guard': (
        "    local step = want - 16\n    if step < 1 then step = want end",
        "    local step = want - 16\n    if false then step = want end",
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
    # The scan chunk is raised past the reader's own per-call cap, so every chunk read
    # returns nil and the scan silently finds nothing.
    'scan-chunk-over-read-cap': (
        "local SCAN_CHUNK = 1024 * 1024",
        "local SCAN_CHUNK = 4 * 1024 * 1024",
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
        # Line endings: the Lua sources are CRLF on Windows, so a multi-line anchor
        # written with \n never matches and the mutation silently reports SKIP.  A sweep
        # that requires an explicit verdict is what caught this; every suite normalises
        # here for the same reason.  Only the mutation harness normalises -- the shipped
        # file keeps its own endings.
        flat = src.replace('\r\n', '\n')
        if old not in flat:
            print(f'SKIP {args.mutate}: anchor not found')
            return 2
        mutated = flat.replace(old, new, 1)
        # A mutation run that raises produces no verdict, and "no verdict" was being
        # counted as "caught" by the sweep that drives this.  Say so explicitly instead.
        try:
            checks, _ = run_suite(mutated)
            checks.update(run_gate_suite(mutated))
            checks.update(run_wait_suite(mutated))
            checks.update(run_count_suite(mutated))
            health_checks, _health_detail = run_health_suite(mutated)
            checks.update(health_checks)
            pure_checks, _pure_detail = run_pure_suite(mutated)
            checks.update(pure_checks)
            checks.update(run_env_suite(mutated))
        except Exception as exc:                      # noqa: BLE001 - reported, not hidden
            print(f'--- mutation {args.mutate} ---')
            print(f'MUTATION HARNESS ERROR: {type(exc).__name__}: {exc}')
            return 2
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
    checks.update(run_gate_suite(src))
    checks.update(run_wait_suite(src))
    checks.update(run_count_suite(src))
    health_checks, health_detail = run_health_suite(src)
    checks.update(health_checks)
    detail.update(health_detail)
    pure_checks, pure_detail = run_pure_suite(src)
    checks.update(pure_checks)
    detail.update(pure_detail)
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
