"""What owns the conclusion line in the diagnostics suite (HUD off)?"""
import shutil
import sys

sys.path.insert(0, 'tests')
import test_hp as T  # noqa: E402

tmp = T.new_tmp(False)
try:
    src = T.ENTRY.read_text(encoding='utf-8')
    r = T.Run(src, tmp)
    r.g.__set_ship_ticks(T.SHIP_TICKS)
    r.ticks(T.SHIP_TICKS + 40)
    r.ticks(T.TICKS)
    status = r.read('hivelord_hp_STATUS.txt')
    for i, line in enumerate(status.splitlines()[:8]):
        print(f'{i}: {line[:120]}')
finally:
    shutil.rmtree(tmp, ignore_errors=True)
