"""Trace the HUD teardown sequence: identify -> target gone -> world gone."""
import shutil
import sys

sys.path.insert(0, 'tests')
import test_hp as T  # noqa: E402

tmp = T.new_tmp(True)
try:
    src = T.ENTRY.read_text(encoding='utf-8')
    r = T.Run(src, tmp)
    r.ticks(600)
    print('after identify   live=', r.g.__gui_live_texts(), 'created,destroyed=', r.g.__gui_counts())
    r.g.__remove_goid(31)
    r.ticks(140)
    print('target gone      live=', r.g.__gui_live_texts(), 'created,destroyed=', r.g.__gui_counts())
    r.g.__drop_gui_world()
    print('flag set         ', r.lua.eval("rawget(_G, '__GUI_WORLD_GONE')"))
    r.ticks(140)
    print('world gone       live=', r.g.__gui_live_texts(), 'created,destroyed=', r.g.__gui_counts())
    print('--- log tail ---')
    for line in r.read('hivelord_hp.log').splitlines()[-8:]:
        print('LOG', line[:150])
finally:
    shutil.rmtree(tmp, ignore_errors=True)
