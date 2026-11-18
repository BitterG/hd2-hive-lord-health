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
        checks["addon installs and reports v2.3.0"] = (
            bool(r.result["installed"] is True) and str(r.result["version"]) == "2.3.0"
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
            "150,000 / 150,000  (100.0%)" in vis_spawn
            and "LIVE" in vis_spawn
            and "STERNA" not in vis_spawn
            and "DORSAL" not in vis_spawn
        )
        checks["spawn paints 4 main bar rects (no armor rects)"] = (
            int(r.g.__gui_visible_rects()) == 4
        )
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

        # English locale auto-detection, dead SLAIN radar text, & active EN -> ZH switch
        tmp_en = new_tmp()
        try:
            r_en = Run(src, tmp_en, flags="__WITH_MDL3 = true\n__MDL3_LANG = 'en'\n")
            r_en.frames(5)
            checks["English MDL3 locale selects English addon title and ModOptionsMenu labels"] = (
                str(r_en.result["name"]) == "Hive Lord HP & Locator"
                and str(r_en.lua.eval("MDL3.__mom_opts['hivelord_health.hud'].label()")) == "Show Boss Health Bar"
                and str(r_en.lua.eval("MDL3.__mom_opts['hivelord_health.language'].label()")) == "Display Language"
            )
            r_en.g.__start_mission()
            r_en.g.__set_player_pose(0, 0, 0, 0, 1, 0)
            r_en.lua.execute(
                "__spawn_entity(611, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 150000, 61, {x=100, y=100, z=0})"
            )
            r_en.frames(8)
            en_bar = str(r_en.g.__gui_visible_texts())
            en_loc = r_en.g.__mdl_gui_locator_snapshot()
            checks["English locale renders pure English Boss Bar and HIVE LORD RADAR"] = (
                "HIVE LORD   150,000 / 150,000" in en_bar
                and "141m FR" in en_bar
                and "\u9738\u738b\u866b" not in en_bar
                and en_loc is not None
                and "HIVE LORD RADAR" in str(en_loc["texts"])
                and "LIVE | RANGE 250m" in str(en_loc["texts"])
            )
            r_en.lua.execute(
                "__kill_entity(611, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 150000, 61, {x=100, y=100, z=0})"
            )
            r_en.frames(5)
            en_dead_loc = r_en.g.__mdl_gui_locator_snapshot()
            checks["English locale locator death shows SLAIN instead of LAST SEEN"] = (
                en_dead_loc is not None
                and "SLAIN" in str(en_dead_loc["texts"])
                and "LAST SEEN" not in str(en_dead_loc["texts"])
            )
            # Wait out death hold, then actively switch language to Chinese (choice 2) in ESC settings
            r_en.frames(350)
            r_en.lua.execute(
                "MDL3.panel.visible = true\n"
                "MDL3.panel.page = 'settings'\n"
                "ModOptionsMenu.set('hivelord_health.language', 2)\n"
            )
            r_en.frames(5)
            zh_sw_bar = str(r_en.g.__gui_visible_texts())
            zh_sw_loc = r_en.g.__mdl_gui_locator_snapshot()
            checks["active ESC switch to Chinese overrides English client UI immediately"] = (
                "\u9738\u738b\u866b HIVE LORD" in zh_sw_bar
                and zh_sw_loc is not None
                and "\u9738\u738b\u866b\u5b9a\u4f4d" in str(zh_sw_loc["texts"])
                and "\u663e\u793a\u9738\u738b\u866b\u8840\u6761"
                in str(r_en.lua.eval("MDL3.__mom_opts['hivelord_health.hud'].label()"))
                and "language = zh" in r_en.read("hivelord_health.cfg")
            )
        finally:
            shutil.rmtree(tmp_en, ignore_errors=True)

        # Chinese client actively switched to English (choice 3) persists across restart
        tmp_zh2en = new_tmp()
        try:
            s_z1 = Run(src, tmp_zh2en, flags="__WITH_MDL3 = true\n")
            s_z1.frames(5)
            s_z1.lua.execute(
                "MDL3.panel.visible = true\n"
                "MDL3.panel.page = 'settings'\n"
                "ModOptionsMenu.set('hivelord_health.language', 3)\n"
            )
            s_z1.frames(5)
            sw_bar = str(s_z1.g.__gui_visible_texts())
            sw_loc = s_z1.g.__mdl_gui_locator_snapshot()
            checks["active ESC switch to English overrides Chinese client UI immediately"] = (
                "HIVE LORD   112,500 / 150,000" in sw_bar
                and "\u9738\u738b\u866b" not in sw_bar
                and sw_loc is not None
                and "HIVE LORD RADAR" in str(sw_loc["texts"])
                and str(s_z1.lua.eval("MDL3.__mom_opts['hivelord_health.hud'].label()")) == "Show Boss Health Bar"
                and "language = en" in s_z1.read("hivelord_health.cfg")
            )
            s_z2 = Run(src, tmp_zh2en, flags="__WITH_MDL3 = true\n")
            s_z2.frames(5)
            s_z2.g.__start_mission()
            s_z2.lua.execute(
                "__spawn_entity(612, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 150000, 62, {x=0, y=100, z=0})"
            )
            s_z2.frames(8)
            re_bar = str(s_z2.g.__gui_visible_texts())
            re_loc = s_z2.g.__mdl_gui_locator_snapshot()
            checks["saved language = en survives restart under Chinese MDL3 locale"] = (
                int(s_z2.lua.eval("ModOptionsMenu.get('hivelord_health.language')")) == 3
                and str(s_z2.lua.eval("MDL3.__mom_opts['hivelord_health.hud'].label()")) == "Show Boss Health Bar"
                and "HIVE LORD   150,000 / 150,000" in re_bar
                and "\u9738\u738b\u866b" not in re_bar
                and re_loc is not None
                and "HIVE LORD RADAR" in str(re_loc["texts"])
            )
        finally:
            shutil.rmtree(tmp_zh2en, ignore_errors=True)
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

    # 3. ESC -> MDL Settings adjustments persist to hivelord_health.cfg and survive game restart
    #    (even when ModOptionsMenu starts fresh on restart without ModOptionsMenu.values, and even
    #     when the user exits without shutdown() via Alt+F4 after rapid slider dragging).
    tmp3 = new_tmp()
    try:
        # Simulate a legacy v1.x hivelord_health.cfg already sitting on disk before launch #1
        cfg_path3 = Path(tmp3) / "Arrowhead" / "Helldivers2" / "hivelord_health.cfg"
        cfg_path3.write_text(
            "# Legacy v1 settings\nhud = true\npoll_seconds = 1\nhud_scale = 1.0\n"
            "hud_offset_y = 120\nhud_alpha = 0.95\ndraw_every = 6\nstart_delay = 300\n",
            encoding="utf-8",
        )
        s1 = Run(src, tmp3, flags="__WITH_MDL3 = true\n")
        s1.frames(5)
        s1.lua.execute(
            """
            MDL3.panel.visible = true
            MDL3.panel.page = 'settings'
            MDL3.panel.builds = 2
            ModOptionsMenu.set('hivelord_health.hud_preview', true)
            ModOptionsMenu.set('hivelord_health.hud_position', 2)
            ModOptionsMenu.set('hivelord_health.hud_scale', 1.20)
            ModOptionsMenu.set('hivelord_health.hud_offset_x', -150)
            ModOptionsMenu.set('hivelord_health.locator_range', 400)
            ModOptionsMenu.set('hivelord_health.locator_radar_scale', 1.25)
            ModOptionsMenu.set('hivelord_health.locator_radar_x', -650)
            ModOptionsMenu.set('hivelord_health.locator_radar_y', 120)
            ModOptionsMenu.set('hivelord_health.locator_pointer_radius', 220)
            ModOptionsMenu.set('hivelord_health.locator_pointer', false)
            for _, v in ipairs({ 115, 100, 85, 70, 50 }) do
                ModOptionsMenu.set('hivelord_health.hud_offset_y', v)
            end
            """
        )
        # Advance 10 frames (~0.16s) so trailing slider debounce flushes, then drop s1 WITHOUT shutdown()!
        s1.frames(10)
        saved_cfg = cfg_path3.read_text(encoding="utf-8")
        checks["armor option is removed from ModOptionsMenu and hivelord_health.cfg"] = (
            bool(s1.lua.eval("ModOptionsMenu.get('hivelord_health.hud_armor') == nil"))
            and "hud_armor" not in saved_cfg
        )
        checks["in-game ESC position & slider adjustments save to hivelord_health.cfg"] = (
            "hud_position = bottom" in saved_cfg
            and "hud_offset_y = 50" in saved_cfg
            and "hud_offset_x = -150" in saved_cfg
            and "hud_scale = 1.20" in saved_cfg
            and "locator_range = 400" in saved_cfg
            and "locator_radar_scale = 1.25" in saved_cfg
            and "locator_radar_x = -650" in saved_cfg
            and "locator_radar_y = 120" in saved_cfg
            and "locator_pointer_radius = 220" in saved_cfg
            and "locator_pointer = false" in saved_cfg
        )

        # Restart game in a brand-new VM where ModOptionsMenu has zero persisted state of its own
        s2 = Run(src, tmp3, flags="__WITH_MDL3 = true\n")
        s2.frames(5)
        checks["temporary hud_preview toggle does not stay stuck ON after restart"] = (
            s2.g.__gui_visible_texts() == ""
            and bool(s2.lua.eval("ModOptionsMenu.get('hivelord_health.hud_preview') == false"))
        )
        checks["restarted game syncs saved config back into ModOptionsMenu widgets"] = bool(
            s2.lua.eval(
                "ModOptionsMenu.get('hivelord_health.hud_position') == 2 "
                "and ModOptionsMenu.get('hivelord_health.hud_offset_y') == 50 "
                "and ModOptionsMenu.get('hivelord_health.hud_offset_x') == -150 "
                "and math.abs(ModOptionsMenu.get('hivelord_health.hud_scale') - 1.20) < 1e-4 "
                "and ModOptionsMenu.get('hivelord_health.locator_range') == 400 "
                "and ModOptionsMenu.get('hivelord_health.locator_radar_x') == -650 "
                "and ModOptionsMenu.get('hivelord_health.locator_pointer') == false"
            )
        )

        # Simulate silent stale ModOptionsMenu overwrite before user opens ESC settings -> auto-healed
        s2.lua.execute(
            "ModOptionsMenu.__silent_corrupt('hivelord_health.hud_position', 1)\n"
            "ModOptionsMenu.__silent_corrupt('hivelord_health.hud_offset_y', 135)\n"
            "MDL3.panel.visible = true\n"
            "MDL3.panel.page = 'settings'\n"
        )
        s2.frames(2)
        s2.lua.execute("MDL3.panel.visible = false")
        s2.frames(2)
        checks["opening ESC settings heals stale ModOptionsMenu state from loaded config"] = bool(
            s2.lua.eval(
                "ModOptionsMenu.get('hivelord_health.hud_position') == 2 "
                "and ModOptionsMenu.get('hivelord_health.hud_offset_y') == 50"
            )
        )

        # Spawn Hive Lord in restarted session -> verify actual screen coordinates match saved position!
        s2.g.__start_mission()
        s2.g.__spawn_entity(901, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 901)
        s2.frames(5)
        rect2 = s2.g.__gui_main_bar_rect()
        # Expected at 1920x1080 with scale=1.20, pos=bottom, offset_y=50, offset_x=-150:
        #   by = 50 * 1.20 = 60.0 (instead of default top 1080 - 135 = 945!)
        #   cx = 960 + (-150 * 1.20) = 780.0
        detail["restarted_bar_y"] = float(rect2["y"]) if rect2 else None
        detail["restarted_bar_cx"] = float(rect2["cx"]) if rect2 else None
        checks["restarted game renders health bar at saved bottom/offset_y/offset_x coordinates"] = (
            rect2 is not None
            and abs(float(rect2["y"]) - 60.0) < 1.0
            and abs(float(rect2["cx"]) - 780.0) < 1.0
            and int(s2.g.__gui_visible_rects()) == 4
        )
    finally:
        shutil.rmtree(tmp3, ignore_errors=True)

    # 4. Manual Notepad edit with UTF-8 BOM + CRLF + quoted values is parsed cleanly without overwrite
    tmp4 = new_tmp()
    try:
        cfg_path4 = Path(tmp4) / "Arrowhead" / "Helldivers2" / "hivelord_health.cfg"
        bom_cfg = b'\xef\xbb\xbfhud_position = "bottom"\r\nhud_offset_y = 75 ; custom bottom margin\r\nhud_offset_x = 120\r\nhud_armor = false\r\n'
        cfg_path4.write_bytes(bom_cfg)
        s4 = Run(src, tmp4, flags="__WITH_MDL3 = true\n")
        s4.g.__start_mission()
        s4.g.__spawn_entity(902, "enemy/v1/terminids/hive_lord", "D465D9C7F77A07CB", 150000, 902)
        s4.frames(5)
        rect4 = s4.g.__gui_main_bar_rect()
        checks["UTF-8 BOM + CRLF + quoted manual config loads exact coordinates without overwriting"] = (
            cfg_path4.read_bytes() == bom_cfg
            and rect4 is not None
            and abs(float(rect4["y"]) - 75.0) < 1.0
            and abs(float(rect4["cx"]) - (960.0 + 120.0)) < 1.0
        )
    finally:
        shutil.rmtree(tmp4, ignore_errors=True)

    return checks, detail


def run_locator_suite(src: str) -> tuple[dict[str, bool], dict[str, object]]:
    checks: dict[str, bool] = {}
    detail: dict[str, object] = {}
    tmp = new_tmp()
    try:
        r = Run(src, tmp, flags="__WITH_MDL3 = true\n")
        r.frames(5)
        checks["ship idle keeps locator hidden"] = int(r.g.__mdl_gui_visible_canvases()) == 0

        # ESC preview immediately shows locator radar & pointer with mock distance
        r.lua.execute(
            "MDL3.panel.visible = true\n"
            "MDL3.panel.page = 'settings'\n"
            "ModOptionsMenu.set('hivelord_health.hud_preview', true)\n"
        )
        r.frames(10)
        snap_prev = r.g.__mdl_gui_locator_snapshot()
        checks["ESC preview renders MDL3.gui radar and pointer"] = (
            snap_prev is not None
            and int(snap_prev["blip_a"]) > 0
            and int(snap_prev["ptr_a"]) > 0
            and "135 m" in str(snap_prev["texts"])
            and "135m" in str(snap_prev["texts"])
        )
        r.lua.execute("MDL3.panel.visible = false\nModOptionsMenu.set('hivelord_health.hud_preview', false)")
        r.frames(3)

        # Combat locator: player at (0,0,0) facing North (0,1); Hive Lord at (100,100,0) -> ~141.4m @ +45 deg (FR)
        r.g.__start_mission()
        r.g.__set_player_pose(0, 0, 0, 0, 1, 0)
        r.lua.execute(
            "__set_squad({ { name='Bravo', slot=1, alive=true, x=-50, y=50, z=0 }, "
            "{ name='Charlie', slot=2, alive=true, x=60, y=-20, z=0 } })"
        )
        r.lua.execute(
            "__spawn_entity(701, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 150000, 71, {x=100, y=100, z=0})"
        )
        # Frame 1 handles HD2Data 1-frame lease nil cleanly; frames 2..12 get full live player+aim
        r.frames(1)
        checks["first-frame nil lease never triggers MDL3.gui errors"] = int(r.g.__mdl_gui_errors()) == 0
        r.frames(12)
        snap_ne = r.g.__mdl_gui_locator_snapshot()
        detail["loc_ne_texts"] = str(snap_ne["texts"]).replace("\n", " // ") if snap_ne else ""
        checks["North-facing player sees (100,100) Hive Lord at ~141m right-front"] = (
            snap_ne is not None
            and snap_ne["blip_x"] is not None and snap_ne["radar_cx"] is not None
            and snap_ne["ptr_tip_x"] is not None and snap_ne["ptr_tip_y"] is not None
            and float(snap_ne["blip_x"]) > float(snap_ne["radar_cx"])
            and float(snap_ne["blip_y"]) < float(snap_ne["radar_cy"])
            and float(snap_ne["ptr_tip_x"]) > 960.0
            and float(snap_ne["ptr_tip_y"]) < 540.0
            and int(snap_ne["rim_a"]) == 0
            and int(snap_ne["squad1_a"]) > 0
            and int(snap_ne["squad2_a"]) > 0
            and "141 m" in str(snap_ne["texts"])
            and "\u53f3\u524d 45" in str(snap_ne["texts"])
        )
        checks["Boss HP bar subtitle includes live distance"] = (
            "141 m" in str(r.g.__gui_visible_texts())
        )

        # Rotate player East (1, 0) -> (100, 100) is now Left-Front (-45 deg, upper-left on radar!)
        r.g.__set_player_pose(0, 0, 0, 1, 0, 0)
        r.frames(10)
        snap_e = r.g.__mdl_gui_locator_snapshot()
        checks["East-facing player sees (100,100) Hive Lord in left-front quadrant"] = (
            snap_e is not None
            and snap_e["blip_x"] is not None and snap_e["ptr_tip_x"] is not None
            and float(snap_e["blip_x"]) < float(snap_e["radar_cx"])
            and float(snap_e["blip_y"]) < float(snap_e["radar_cy"])
            and float(snap_e["ptr_tip_x"]) < 960.0
            and "\u5de6\u524d 45" in str(snap_e["texts"])
        )

        # Rotate South (0, -1) -> (100, 100) is now Back-Left (-135 deg, lower-left on radar & pointer below center)
        r.g.__set_player_pose(0, 0, 0, 0, -1, 0)
        r.frames(10)
        snap_s = r.g.__mdl_gui_locator_snapshot()
        checks["South-facing player sees (100,100) Hive Lord behind-left"] = (
            snap_s is not None
            and snap_s["blip_x"] is not None and snap_s["ptr_tip_y"] is not None
            and float(snap_s["blip_x"]) < float(snap_s["radar_cx"])
            and float(snap_s["blip_y"]) > float(snap_s["radar_cy"])
            and float(snap_s["ptr_tip_y"]) > 540.0
        )

        # Smooth camera spin + beyond-radar-range (400m > 250m) -> rim arrow lights up, ZERO shape rebuilds!
        r.g.__set_player_pose(0, 0, 0, 0, 1, 0)
        r.lua.execute(
            "__damage_entity(701, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 120000, 150000, 30000, 71, {x=0, y=400, z=0})"
        )
        for k in range(15):
            import math
            ang = k * 0.2
            r.g.__set_player_pose(k * 2.0, 0, 0, math.sin(ang), math.cos(ang), 0)
            r.frames(1)
        snap_far = r.g.__mdl_gui_locator_snapshot()
        detail["shape_rebuilds"] = int(snap_far["shape_rebuilds"]) if snap_far else -1
        detail["shape_updates"] = int(snap_far["shape_updates"]) if snap_far else -1
        checks["out-of-range Hive Lord activates radar rim arrow"] = (
            snap_far is not None and int(snap_far["rim_a"]) > 0
        )
        checks["shape canvas updates in-place across rotation & range changes with 1 initial build"] = (
            snap_far is not None
            and int(snap_far["shape_rebuilds"]) == 1
            and int(snap_far["shape_updates"]) >= 25
            and int(r.g.__mdl_gui_errors()) == 0
        )

        # Burrow retains last position & marks submerged; resurface snaps to new position (-80, 60, 0) -> 100m
        r.g.__set_player_pose(0, 0, 0, 0, 1, 0)
        r.g.__submerge_entity(701)
        r.frames(10)
        snap_sub = r.g.__mdl_gui_locator_snapshot()
        checks["submerged Hive Lord retains last position and marks submerged on locator"] = (
            snap_sub is not None and "\u6f5c\u5730" in str(snap_sub["texts"])
        )
        r.lua.execute(
            "__spawn_entity(702, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 150000, 72, {x=-80, y=60, z=0})"
        )
        r.frames(10)
        snap_res = r.g.__mdl_gui_locator_snapshot()
        checks["resurface snaps locator to new coordinates (~100m left-front)"] = (
            snap_res is not None
            and snap_res["blip_x"] is not None
            and float(snap_res["blip_x"]) < float(snap_res["radar_cx"])
            and "100 m" in str(snap_res["texts"])
            and "\u5de6\u524d" in str(snap_res["texts"])
        )

        # Killing blow hides center pointer while showing SLAIN on radar, then expires cleanly
        r.lua.execute(
            "__kill_entity(702, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 150000, 72, {x=-80, y=60, z=0})"
        )
        r.frames(10)
        snap_dead = r.g.__mdl_gui_locator_snapshot()
        checks["death hides center pointer arrow while keeping radar death marker"] = (
            snap_dead is not None and int(snap_dead["ptr_a"]) == 0 and int(snap_dead["blip_a"]) > 0
        )
        r.frames(350)
        checks["post-kill hold hides MDL3.gui locator canvases"] = (
            int(r.g.__mdl_gui_visible_canvases()) == 0
        )

        # Shutdown destroys locator canvases cleanly
        r.lua.execute("shutdown()")
        checks["shutdown destroys MDL3.gui canvases"] = int(r.g.__mdl_gui_canvas_count()) == 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # Pre-dev.41 fallback: MDL3 without MDL3.gui still renders Boss HP Bar distance with zero errors
    tmp_nogui = new_tmp()
    try:
        rn = Run(src, tmp_nogui, flags="__WITH_MDL3 = true\n__NO_MDL3_GUI = true\n")
        rn.g.__start_mission()
        rn.g.__set_player_pose(0, 0, 0, 0, 1, 0)
        rn.lua.execute(
            "__spawn_entity(801, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 150000, 81, {x=0, y=150, z=0})"
        )
        rn.frames(10)
        checks["pre-dev.41 fallback without MDL3.gui keeps Boss Bar distance working"] = (
            "150 m (\u6b63\u524d)" in str(rn.g.__gui_visible_texts())
            and "STEP_ERR" not in rn.log()
        )
    finally:
        shutil.rmtree(tmp_nogui, ignore_errors=True)

    # Real-time GameSession position tracking (linked sibling goid, anti-snapback on frozen hit, net_id=nil fallback)
    tmp_live = new_tmp()
    try:
        rl = Run(src, tmp_live, flags="__WITH_MDL3 = true\n")
        rl.g.__start_mission()
        rl.g.__set_player_pose(0, 0, 0, 0, 1, 0)
        rl.lua.execute(
            "__set_goid_fields(714, { [1]=__sr_quat(0,0,0,1), [7]=1, [12]=__sr_vec3(0, 120, 0), [17]=150000, [33]={711, 713}, [44]=16383 })\n"
            "__set_goid_fields(713, { [4]=__sr_vec3(0, 120, 0) })\n"
            "__spawn_entity(901, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 150000, 714, {x=0, y=120, z=0})"
        )
        rl.frames(6)
        snap_init = rl.g.__mdl_gui_locator_snapshot()
        checks["GameSession live tracker initializes at spawn position"] = (
            snap_init is not None and "120 m" in str(snap_init["texts"])
        )

        # Linked sibling goid 713 moves to (60, 0, 0) while primary 714[12] remains frozen at emerge spot; NO hit events
        rl.lua.execute(
            "__set_goid_fields(713, { [4]=__sr_vec3(60, 0, 0) })"
        )
        rl.frames(10)
        snap_moved = rl.g.__mdl_gui_locator_snapshot()
        detail["goid_moved_texts"] = str(snap_moved["texts"]).replace("\n", " // ") if snap_moved else ""
        checks["linked goid movement updates radar & Boss Bar without entity_damaged"] = (
            snap_moved is not None
            and snap_moved["blip_x"] is not None
            and float(snap_moved["blip_x"]) > float(snap_moved["radar_cx"])
            and "60 m" in str(snap_moved["texts"])
            and "60 m" in str(rl.g.__gui_visible_texts())
            and "GOID_LIVE_LOCK" in rl.log()
        )

        # Frozen emerge-spot entity_damaged must NOT snap position back while GameSession moves to (80, 0, 0)
        # First advance 1 frame (between 30 Hz polls) and move via Damage only -> radar & status must NOT jump to (0,120)
        rl.lua.execute(
            "__damage_entity(901, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 140000, 150000, 10000, 714, {x=0, y=120, z=0})"
        )
        rl.frames(1)
        snap_hit_imm = rl.g.__mdl_gui_locator_snapshot()
        no_jitter = (
            snap_hit_imm is not None
            and float(snap_hit_imm["blip_x"]) > float(snap_hit_imm["radar_cx"]) + 10.0
            and "pos_src=goid_live" in rl.status()
        )
        rl.lua.execute("__set_goid_fields(713, { [4]=__sr_vec3(80, 0, 0) })")
        rl.frames(14)
        snap_hit = rl.g.__mdl_gui_locator_snapshot()
        checks["frozen entity_damaged emerge coordinates do not overwrite moving GameSession pos"] = (
            no_jitter
            and snap_hit is not None
            and "80 m" in str(snap_hit["texts"])
            and "120 m" not in str(snap_hit["texts"])
            and "80 m" in str(rl.g.__gui_visible_texts())
        )

        # network_id == nil falls back to bounded GameSession goid scan near spawn position
        rl.g.__start_mission()
        rl.g.__set_player_pose(0, 0, 0, 0, 1, 0)
        rl.lua.execute(
            "__set_goid_fields(500, { [5]=__sr_vec3(0, 200, 0), [17]=150000 })\n"
            "__spawn_entity(902, 'enemy/v1/terminids/hive_lord', 'D465D9C7F77A07CB', 150000, nil, {x=0, y=200, z=0})"
        )
        rl.frames(6)
        rl.lua.execute("__set_goid_fields(500, { [5]=__sr_vec3(0, 50, 0), [17]=150000 })")
        rl.frames(6)
        snap_nilnet = rl.g.__mdl_gui_locator_snapshot()
        checks["nil network_id falls back to bounded GameSession goid scan"] = (
            snap_nilnet is not None
            and "50 m" in str(snap_nilnet["texts"])
            and "STEP_ERR" not in rl.log()
        )
    finally:
        shutil.rmtree(tmp_live, ignore_errors=True)

    return checks, detail


SUITES = [
    ("combat_lifecycle", run_combat_lifecycle_suite),
    ("mdl3_native_ui", run_mdl3_native_ui_suite),
    ("locator", run_locator_suite),
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
    "drop-mom-config-save": (
        "                    request_config_save(key, immediate)",
        "                    -- config save omitted",
    ),
    "drop-cfg-to-mom-sync": (
        "        spec.default = to_mom()",
        "        spec.default = (key == 'hud_position') and 1 or DEFAULTS[key]; cfg_explicit = {}",
    ),
    "flip-radar-left-right": (
        "    local right_m = dx * fy - dy * fx",
        "    local right_m = dy * fx - dx * fy",
    ),
    "drop-spawn-position-capture": (
        "        update_record_pos(rec, pos, 'spawn')",
        "        -- spawn pos omitted",
    ),
    "break-shape-slot-invariance": (
        "    else\n        put_tri(OFF, OFF, OFF + 8, OFF, OFF + 4, OFF + 6, CLEAR)\n    end\n\n    -- Slot 20:",
        "    end\n\n    -- Slot 20:",
    ),
    "disable-goid-live-polling": (
        "    poll_live_positions()",
        "    -- poll_live_positions omitted",
    ),
    "allow-frozen-emerge-snapback": (
        "        if not freeze_at_emerge then",
        "        if true then",
    ),
    "ignore-config-language-override": (
        "    if C.language == 'zh' then return true end\n    if C.language == 'en' then return false end",
        "    -- manual language override omitted",
    ),
    "revert-locator-english-slain": (
        "                line2_s = use_zh and ZH.slain or EN.slain",
        "                line2_s = use_zh and ZH.slain or EN.loc_last_seen",
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
