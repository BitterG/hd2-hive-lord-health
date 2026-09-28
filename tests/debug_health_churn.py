"""Why does world churn produce only one surface?"""
import shutil
import sys

sys.path.insert(0, 'tests')
import test_health as T  # noqa: E402

tmp = T.new_tmp()
try:
    src = T.ENTRY.read_text(encoding='utf-8')
    r = T.Run(src, tmp, pre='__WORLD_CHURN = true\n')
    r.ticks(T.SHIP + 400)
    print('surfaces created :', r.g.__gui_created())
    print('world destroys   :', r.g.__world_destroys())
    for line in r.log().splitlines():
        if 'HUD' in line or 'ERROR' in line:
            print('  ', line[:140])
finally:
    shutil.rmtree(tmp, ignore_errors=True)
