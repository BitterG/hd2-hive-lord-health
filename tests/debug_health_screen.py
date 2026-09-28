"""What is on the fixture's screen after the redraw sequence?"""
import shutil
import sys

sys.path.insert(0, 'tests')
import test_health as T  # noqa: E402

tmp = T.new_tmp()
try:
    src = T.ENTRY.read_text(encoding='utf-8')
    r = T.Run(src, tmp)
    r.ticks(T.SHIP + 900)
    j = r.g.__hive_j()
    cur = r.g.__hive_cur()
    print('cur =', cur)
    print('live before =', repr(r.g.__gui_live_text())[:90])
    for v in (cur, cur - 5000, cur - 9000):
        r.g.__set_hp(j, v)
        r.ticks(200)
    print('live after  =', repr(r.g.__gui_live_text())[:90])
    r.g.__set_hp(j, cur)
    r.ticks(200)
    print('live restored =', repr(r.g.__gui_live_text())[:90])
    print('creates =', r.g.__gui_text_creates(), 'updates =', r.g.__gui_updates(),
          'destroys =', r.g.__gui_destroys())
    for line in r.log().splitlines():
        if 'HUD_STATE' in line or 'HP goid' in line:
            print('  LOG', line[:130])
finally:
    shutil.rmtree(tmp, ignore_errors=True)
