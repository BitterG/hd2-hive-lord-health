#!/usr/bin/env python3
"""Offline simulation & mutation suite for Hive Lord Health v2.0.0 (MDL3 + HD2Data).

Proves all runtime contracts against `tests/fixture_health.lua` (PUC Lua 5.1 rules):
  1. Exact Hive Lord lifecycle via HD2Data API 1 (`entity_spawned`, `entity_damaged`,
     `entity_died`, decoy filtering, mid-fight attach, type-hash fallback, underground
     burrow retention + resurface carry-over, killing-blow zeroing, mission reset).
  2. MDL3 native game-UI font (`MDL3.ui.fonts`) + CJK glyph probe + `ModOptionsMenu`
     live ESC slider preview & foreground panel raise, with ZERO cross-frame `IdString64`
     reuse and ZERO `Gui.update_text`/`Gui.destroy_text` on native-font handles.
  3. HD2Data Hub resilience (late Hub arrival, incompatible `api` refusal, dropped
     subscription auto-recovery, live Hub reload, and clean `shutdown()` + reload).
  4. Stingray GUI safety fallbacks (`core/performance_hud/debug`, missing `Gui.update_text`,
     missing `Gui.text`, world churn `surface_cap <= 12`, fresh world wrappers).
  5. Config auto-creation (`hud = true`) and strict non-overwriting of user edits.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

import lupa

ROOT = Path(__file__).resolve().parent.parent
ENTRY = ROOT / "Source" / "mods" / "hivelord" / "hivelord_health.lua"
FIXTURE = Path(__file__).resolve().parent / "fixture_health.lua"


def new_tmp() -> str:
    tmp = tempfile.mkdtemp(prefix="hlhealth2_")
    (Path(tmp) / "Arrowhead" / "Helldivers2").mkdir(parents=True, exist_ok=True)
    return tmp


class Run:
    def __init__(self, src: str, tmp: str, flags: str | None = None, pre: str | None = None):
        os.environ["HIVELORD_TEST_APPDATA"] = str(tmp)
        self.tmp = tmp
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        if flags:
            self.lua.execute(flags)
        self.lua.execute(FIXTURE.read_text(encoding="utf-8"))
        if pre:
            self.lua.execute(pre)
        self.result = self.lua.execute(src)
        self.g = self.lua.globals()

    def frames(self, n: int, dt: float = 0.016) -> None:
        adv = self.g["__advance_frame"]
        for _ in range(n):
            adv(dt)

    def read(self, name: str) -> str:
        for d in (Path(self.tmp) / "Arrowhead" / "Helldivers2", Path(self.tmp)):
            p = d / name
            if p.exists():
                return p.read_text(encoding="utf-8", errors="replace")
        return ""

    def log(self) -> str:
        return self.read("hivelord_health.log")

    def status(self) -> str:
        return self.read("hivelord_health_STATUS.txt")


def run_combat_lifecycle_suite(src: str) -> tuple[dict[str, bool], dict[str, object]]:
    checks: dict[str, bool] = {}
    detail: dict[str, object] = {}
    tmp = new_tmp()
    try:
        # Pure ASCII source guarantee for PUC Lua 5.1 portability
        checks["source is pure 7-bit ASCII"] = all(ord(ch) < 128 for ch in src)

        r = Run(src, tmp)
        checks["addon installs and reports v2.0.0"] = (
            bool(r.result["installed"] is True) and str(r.result["version"]) == "2.0.0"
        )

        # Ship idle before mission starts
        r.frames(20)
        checks["ship idle draws nothing"] = (
            r.g.__gui_visible_texts() == "" and int(r.g.__gui_visible_rects()) == 0
        )
        checks["all 5 HD2Data subscriptions bound"] = int(r.g.__hub_sub_count()) == 5

        # Mission start + decoy enemies (including a 150,000 HP decoy!)
        r.g.__start_mission()
        r.frames(5)
        r.g.__spawn_entity(11, "enemy/v1/terminids/bile_titan", "77FD6676F5638DB2", 6000, 101)
        r.g.__damage_entity(11, "enemy/v1/terminids/bile_titan", "77FD6676F5638DB2", 3200, 6000, 2800, 101)
        r.g.__spawn_entity(12, "enemy/v1/terminids/impaler", "22ECB15EE7F6FD3A", 150000, 102)
        r.g.__damage_entity(12, "enemy/v1/terminids/impaler", "22ECB15EE7F6FD3A", 120000, 150000, 30000, 102)
        r.frames(5)
        checks["non-Hive-Lord enemies are ignored"] = (
            r.g.__gui_visible_texts() == "" and int(r.g.__gui_visible_rects()) == 0
        )

        # Hive Lord spawns at 150,000 HP
        r.g.__spawn_entity(101, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 777)
        r.frames(5)
        vis_spawn = str(r.g.__gui_visible_texts())
        detail["spawn_hud"] = vis_spawn.replace("\n", " // ")
        checks["spawn displays 150,000 / 150,000 (100.0%)"] = (
            "150,000 / 150,000  (100.0%)" in vis_spawn and "LIVE" in vis_spawn
        )
        checks["spawn paints 4 solid progress-bar rects"] = int(r.g.__gui_visible_rects()) == 4
        checks["status file reports live 150000 / 150000"] = (
            "HIVE LORD  150000 / 150000  (LIVE)" in r.status()
        )

        # Hive Lord takes heavy damage -> 92,400 / 150,000 (-57,600 DMG)
        r.g.__damage_entity(101, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 92400, 150000, 57600, 777)
        r.frames(60)
        vis_dmg = str(r.g.__gui_visible_texts())
        checks["damage updates exact HP and hit delta"] = (
            "92,400 / 150,000  (61.6%)" in vis_dmg and "-57,600 DMG" in vis_dmg
        )
        checks["debug font retains at most 2 text handles"] = int(r.g.__gui_live_text_handles()) <= 2

        # Hive Lord burrows underground (entity handle temporarily invalid)
        r.g.__submerge_entity(101)
        r.frames(10)
        vis_burrow = str(r.g.__gui_visible_texts())
        checks["burrowing retains last HP and marks SUBMERGED"] = (
            "92,400 / 150,000" in vis_burrow and "SUBMERGED" in vis_burrow
        )

        # Hive Lord resurfaces with a new entity_id -> carries 92,400 instead of resetting to 150,000
        r.g.__spawn_entity(202, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 888)
        r.frames(5)
        vis_resurf = str(r.g.__gui_visible_texts())
        checks["resurfacing carries prior HP instead of resetting to full"] = (
            "92,400 / 150,000" in vis_resurf
            and "LIVE" in vis_resurf
            and "HIVE_LORD_RESURFACE" in r.log()
        )

        # Killing blow in HD2Data emits entity_died directly (skipping entity_damaged)
        r.g.__kill_entity(202, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 888)
        r.frames(5)
        vis_dead = str(r.g.__gui_visible_texts())
        detail["slain_hud"] = vis_dead.replace("\n", " // ")
        checks["killing blow via entity_died zeroes HP to 0 / 150,000 SLAIN"] = (
            "0 / 150,000  (0.0%)" in vis_dead
            and "SLAIN" in vis_dead
            and "HIVE LORD  0 / 150000  (SLAIN)" in r.status()
        )

        # Hold expires after death_hold_seconds (5.0s)
        r.frames(350)
        checks["post-kill hold clears HUD after death_hold_seconds"] = (
            r.g.__gui_visible_texts() == "" and int(r.g.__gui_visible_rects()) == 0
        )

        # Mid-fight attach with nil semantic_id (type-hash fallback) + immediate mission_ended reset
        r.g.__damage_entity(303, None, "d465d9c7f77a07cb", 48500, 150000, 12000, 999)
        r.frames(5)
        vis_mid = str(r.g.__gui_visible_texts())
        checks["mid-fight attach + type-hash fallback tracks HP without prior spawn"] = (
            "48,500 / 150,000  (32.3%)" in vis_mid and "(mid-fight attach)" in r.log()
        )

        r.g.__end_mission()
        r.frames(3)
        checks["mission_ended immediately clears active HUD state"] = (
            r.g.__gui_visible_texts() == "" and "MISSION_RESET" in r.log()
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_mdl3_native_ui_suite(src: str) -> tuple[dict[str, bool], dict[str, object]]:
    checks: dict[str, bool] = {}
    detail: dict[str, object] = {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp, flags="__WITH_MDL3 = true\n")
        r.frames(5)
        checks["ModOptionsMenu options registered"] = "MOD_OPTIONS registered" in r.log()

        # Open MDL3 ESC Settings and tweak a visual slider -> live preview + foreground raise
        r.lua.execute(
            """
            MDL3.panel.visible = true
            MDL3.panel.page = 'settings'
            MDL3.panel.builds = 2
            ModOptionsMenu.set('hivelord_health.hud_scale', 1.25)
            """
        )
        r.frames(15)
        vis_prev = str(r.g.__gui_visible_texts())
        detail["mdl3_preview"] = vis_prev.replace("\n", " // ")
        checks["ESC settings slider triggers live preview"] = (
            "112,500 / 150,000  (75.0%)" in vis_prev and "PREVIEW" in vis_prev
        )
        checks["MDL3 native game-UI font renders Chinese label"] = (
            "\u9738\u738b\u866b HIVE LORD" in vis_prev and "font=native" in r.log()
        )
        checks["ESC foreground raise recreates GUI cleanly"] = (
            int(r.g.__world_destroys()) >= 1 and not bool(r.g.__stale_world_destroy())
        )

        # Closing ESC settings hides live preview automatically
        r.lua.execute("MDL3.panel.visible = false")
        r.frames(3)
        checks["closing ESC settings hides live preview"] = r.g.__gui_visible_texts() == ""

        # Multi-frame combat under MDL3 native font: verify IdString64 & native-handle invariants
        r.g.__start_mission()
        r.g.__spawn_entity(501, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 42)
        for step_i in range(1, 10):
            r.g.__damage_entity(
                501,
                "enemy/v1/terminids/hive_lord",
                "D465D9C7F77A07CB",
                150000 - step_i * 10000,
                150000,
                10000,
                42,
            )
            r.frames(5)
        checks["never reuses temporary IdString64 across frames"] = not bool(r.g.__stale_id64_used())
        checks["never passes native-font handles to update_text/destroy_text"] = not bool(
            r.g.__native_text_mutated()
        )
        checks["native-font live text handles stay bounded <= 2"] = (
            int(r.g.__gui_live_text_handles()) <= 2
        )

        # Latin-only game font atlas must fall back to ASCII 'HIVE LORD' instead of '???'
        tmp_latin = new_tmp()
        try:
            r_lat = Run(src, tmp_latin, flags="__WITH_MDL3 = true\n__LATIN_ONLY_ATLAS = true\n")
            r_lat.g.__start_mission()
            r_lat.g.__spawn_entity(601, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 55)
            r_lat.frames(5)
            lat_txt = str(r_lat.g.__gui_visible_texts())
            checks["Latin-only font atlas falls back cleanly to English label"] = (
                "HIVE LORD   150,000 / 150,000" in lat_txt
                and "\u9738\u738b\u866b" not in lat_txt
            )
        finally:
            shutil.rmtree(tmp_latin, ignore_errors=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_hub_resilience_suite(src: str) -> tuple[dict[str, bool], dict[str, object]]:
    checks: dict[str, bool] = {}
    detail: dict[str, object] = {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp, flags="__NO_HUB_AT_BOOT = true\n")
        r.frames(5)
        checks["missing HD2Data at boot waits gracefully"] = (
            "WAITING - HD2Data global not found yet" in r.status()
        )

        # Incompatible HD2Data API version is refused cleanly
        r.g.__install_hub(2)
        r.frames(20)
        checks["incompatible HD2Data.api == 2 is refused"] = (
            "HUB UNAVAILABLE - bad_api" in r.status()
        )

        # Valid HD2Data arrives late -> binds all 5 subscriptions
        r.g.__install_hub(1)
        r.frames(20)
        checks["late HD2Data arrival binds all 5 subscriptions"] = int(r.g.__hub_sub_count()) == 5

        # Dropped subscriptions are automatically re-registered on next poll
        r.lua.execute("HD2Data.__drop_subs()")
        checks["dropped subscriptions reduce count to 0 before poll"] = int(r.g.__hub_sub_count()) == 0
        r.frames(25)
        checks["dropped subscriptions auto-recover on poll"] = int(r.g.__hub_sub_count()) == 5

        # Live Hub reload (new HD2Data table) re-binds cleanly
        r.g.__install_hub(1)
        r.frames(25)
        checks["live HD2Data table replacement re-binds cleanly"] = int(r.g.__hub_sub_count()) == 5

        # Shutdown unsubscribes all handlers, clears sentinel, and allows clean reload
        r.lua.execute("shutdown()")
        checks["shutdown unsubscribes all HD2Data handlers"] = int(r.g.__hub_sub_count()) == 0
        res2 = r.lua.execute(src)
        r.frames(5)
        checks["addon can be cleanly reloaded after shutdown"] = (
            bool(res2["installed"] is True) and int(r.g.__hub_sub_count()) == 5
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return checks, detail


def run_surface_and_fallback_suite(src: str) -> tuple[dict[str, bool], dict[str, object]]:
    checks: dict[str, bool] = {}
    detail: dict[str, object] = {}

    # 1. Missing stingray global -> clean refusal
    tmp1 = new_tmp()
    try:
        r1 = Run(src, tmp1, pre="stingray = nil\n")
        checks["missing stingray global refuses cleanly"] = (
            bool(r1.result["installed"] is False) and "REFUSED" in r1.status()
        )
    finally:
        shutil.rmtree(tmp1, ignore_errors=True)

    # 2. Missing Gui.text -> refuses drawing with explicit reason
    tmp2 = new_tmp()
    try:
        r2 = Run(src, tmp2, pre="stingray.Gui.text = nil\n")
        r2.g.__start_mission()
        r2.g.__spawn_entity(1, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 1)
        r2.frames(5)
        checks["missing Gui.text logs explicit refusal"] = (
            "HUD_STATE refused (Gui.text missing)" in r2.log()
        )
    finally:
        shutil.rmtree(tmp2, ignore_errors=True)

    # 3. Missing Gui.update_text -> falls back to destroy_text + text with <= 2 handles
    tmp3 = new_tmp()
    try:
        r3 = Run(src, tmp3, pre="stingray.Gui.update_text = nil\n")
        r3.g.__start_mission()
        r3.g.__spawn_entity(1, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 1)
        r3.frames(5)
        for hp in (130000, 110000, 85000):
            r3.g.__damage_entity(1, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", hp, 150000, 20000, 1)
            r3.frames(5)
        vis3 = str(r3.g.__gui_visible_texts())
        checks["without Gui.update_text, destroy+recreate shows latest HP with <= 2 handles"] = (
            "85,000 / 150,000" in vis3 and int(r3.g.__gui_live_text_handles()) <= 2
        )
    finally:
        shutil.rmtree(tmp3, ignore_errors=True)

    # 4. Pathological world churn -> bounded by surface_cap (<= 12) and zero stale destroy_gui
    tmp4 = new_tmp()
    try:
        r4 = Run(src, tmp4, pre="__WORLD_CHURN = true\n")
        r4.g.__start_mission()
        r4.g.__spawn_entity(1, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 1)
        r4.frames(40)
        detail["churn_surfaces"] = int(r4.g.__gui_created())
        checks["world churn stops creating surfaces at surface_cap <= 12"] = (
            int(r4.g.__gui_created()) <= 12
            and "drawing disabled: too many surfaces created" in r4.log()
            and not bool(r4.g.__stale_world_destroy())
        )
    finally:
        shutil.rmtree(tmp4, ignore_errors=True)

    # 5. Fresh non-identical world wrappers -> zero stale destroy_gui and zero GUI leaks
    tmp5 = new_tmp()
    try:
        r5 = Run(src, tmp5, flags="__WITH_MDL3 = true\n__FRESH_WORLD_WRAPPERS = true\n")
        r5.g.__start_mission()
        r5.g.__spawn_entity(1, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 1)
        for hp in (140000, 120000, 100000):
            r5.g.__damage_entity(1, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", hp, 150000, 20000, 1)
            r5.frames(5)
        checks["fresh world wrappers never trigger stale destroy_gui or leak GUIs"] = (
            not bool(r5.g.__stale_world_destroy())
            and int(r5.g.__gui_created()) <= 2
            and "100,000 / 150,000" in str(r5.g.__gui_visible_texts())
        )
    finally:
        shutil.rmtree(tmp5, ignore_errors=True)

    return checks, detail


def run_config_suite(src: str) -> tuple[dict[str, bool], dict[str, object]]:
    checks: dict[str, bool] = {}
    detail: dict[str, object] = {}

    tmp1 = new_tmp()
    try:
        cfg_path = Path(tmp1) / "Arrowhead" / "Helldivers2" / "hivelord_health.cfg"
        r1 = Run(src, tmp1)
        r1.frames(5)
        checks["first run auto-creates hivelord_health.cfg with hud = true"] = (
            cfg_path.is_file() and "hud = true" in cfg_path.read_text(encoding="utf-8")
        )
    finally:
        shutil.rmtree(tmp1, ignore_errors=True)

    tmp2 = new_tmp()
    try:
        cfg_path2 = Path(tmp2) / "Arrowhead" / "Helldivers2" / "hivelord_health.cfg"
        sentinel = "# user custom sentinel\nhud = false\n"
        cfg_path2.write_text(sentinel, encoding="utf-8")
        r2 = Run(src, tmp2)
        r2.g.__start_mission()
        r2.g.__spawn_entity(1, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 1)
        r2.g.__damage_entity(1, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 77777, 150000, 72223, 1)
        r2.frames(10)
        checks["existing user config is never overwritten"] = (
            cfg_path2.read_text(encoding="utf-8") == sentinel
        )
        checks["hud = false creates zero GUI surfaces while still logging exact HP"] = (
            int(r2.g.__gui_created()) == 0
            and "HIVE LORD  77777 / 150000  (LIVE)" in r2.status()
        )
    finally:
        shutil.rmtree(tmp2, ignore_errors=True)

    return checks, detail


SUITES = [
    ("combat_lifecycle", run_combat_lifecycle_suite),
    ("mdl3_native_ui", run_mdl3_native_ui_suite),
    ("hub_resilience", run_hub_resilience_suite),
    ("surface_and_fallback", run_surface_and_fallback_suite),
    ("config", run_config_suite),
]


def run_all(src: str) -> tuple[dict[str, bool], dict[str, object]]:
    all_checks: dict[str, bool] = {}
    all_detail: dict[str, object] = {}
    for sname, fn in SUITES:
        c, d = fn(src)
        for k, v in c.items():
            all_checks[f"{sname}: {k}"] = v
        for k, v in d.items():
            all_detail[f"{sname}.{k}"] = v
    return all_checks, all_detail


MUTATIONS: dict[str, tuple[str, str]] = {
    "ignore-entity-died": (
        "    { 'entity_died',     on_entity_died     },",
        "    -- entity_died omitted",
    ),
    "accept-any-enemy": (
        "    if e.semantic_id == HIVE_LORD_SEMANTIC then return true end",
        "    if e.semantic_id ~= nil then return true end",
    ),
    "drop-type-fallback": (
        "    if type(e.type) == 'string' and e.type:upper() == HIVE_LORD_TYPE_HEX then return true end",
        "    -- type fallback omitted",
    ),
    "no-burrow-carry": (
        "    local old_k, carry = find_carry_record(id, e.network_id)",
        "    local old_k, carry = nil, nil",
    ),
    "no-mission-reset": (
        "    reset_records('mission_ended', type(e) == 'table' and e.epoch or nil)",
        "    -- mission reset omitted",
    ),
    "cache-id64-across-frames": (
        "        local fid = Id64.from_hex(fonts.font)",
        "        M._bad_fid = M._bad_fid or Id64.from_hex(fonts.font); local fid = M._bad_fid",
    ),
    "no-sub-recovery": (
        "        if not sub_is_active(M.subs[name]) then",
        "        if M.subs[name] == nil then",
    ),
    "no-surface-cap": (
        "            if M.surfaces > C.surface_cap then",
        "            if M.surfaces > 9999 then",
    ),
    "overwrite-user-cfg": (
        "        local f = io.open(p, 'r')\n        if not f then",
        "        local f = nil\n        if not f then",
    ),
}


def apply_mutation(src: str, name: str) -> str:
    old, new = MUTATIONS[name]
    if old not in src:
        raise RuntimeError(f"mutation target not found for {name!r}")
    return src.replace(old, new, 1)


def main() -> int:
    ap = argparse.ArgumentParser(description="Test Hive Lord Health v2.0.0 offline.")
    ap.add_argument("--mutate", choices=sorted(MUTATIONS))
    ap.add_argument("--all-mutations", action="store_true")
    args = ap.parse_args()

    base_src = ENTRY.read_text(encoding="utf-8")
    base_checks, base_detail = run_all(base_src)
    base_failed = [k for k, ok in base_checks.items() if not ok]

    if args.all_mutations:
        if base_failed:
            print("BASELINE FAILING:", base_failed)
            return 2
        uncaught = 0
        for mname in sorted(MUTATIONS):
            msrc = apply_mutation(base_src, mname)
            mchecks, _ = run_all(msrc)
            broken = [k for k, ok in mchecks.items() if not ok and base_checks.get(k)]
            if broken:
                print(f"  [CAUGHT]   {mname:<26} -> {broken[0]}")
            else:
                uncaught += 1
                print(f"  [UNCAUGHT] {mname:<26} -> NO CHECK FAILED!")
        print(f"\nMutations caught: {len(MUTATIONS) - uncaught}/{len(MUTATIONS)}")
        return 1 if uncaught else 0

    if args.mutate:
        if base_failed:
            print("BASELINE FAILING:", base_failed)
            return 2
        msrc = apply_mutation(base_src, args.mutate)
        mchecks, _ = run_all(msrc)
        broken = [k for k, ok in mchecks.items() if not ok and base_checks.get(k)]
        print(f"Mutation {args.mutate}: broken={broken}")
        return 0 if broken else 1

    for k, ok in base_checks.items():
        mark = "PASS" if ok else "FAIL"
        print(f"  [{mark}] {k}")
    print("\nDetails:")
    for k, v in base_detail.items():
        print(f"  {k} = {v}")
    print(f"\nTotal: {len(base_checks) - len(base_failed)}/{len(base_checks)} passed")
    return 1 if base_failed else 0


if __name__ == "__main__":
    sys.exit(main())
