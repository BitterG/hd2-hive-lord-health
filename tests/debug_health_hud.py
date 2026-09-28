"""Why is the HUD not showing?  Print the log and the fixture's GUI state."""
import shutil
import sys

sys.path.insert(0, 'tests')
import test_health as T  # noqa: E402

tmp = T.new_tmp()
try:
    src = T.ENTRY.read_text(encoding='utf-8')
    r = T.Run(src, tmp)
    r.ticks(T.SHIP + 300)
    print('created =', r.g.__gui_created(), 'destroyed =', r.g.__gui_destroyed())
    print('all texts ever =', r.g.__gui_texts()[:160])
    print('live text      =', r.g.__gui_live_text()[:160])
    for line in r.log().splitlines():
        if 'ERROR' in line or 'HP goid' in line:
            print('LOG', line[:150])
finally:
    shutil.rmtree(tmp, ignore_errors=True)
