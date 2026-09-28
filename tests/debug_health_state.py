"""What does the HUD state say in the one-world case, and in the normal case?"""
import shutil
import sys

sys.path.insert(0, 'tests')
import test_health as T  # noqa: E402

src = T.ENTRY.read_text(encoding='utf-8')
for pre in (None, '__ONE_WORLD = true\n'):
    tmp = T.new_tmp()
    try:
        r = T.Run(src, tmp, pre=pre)
        r.ticks(T.SHIP + 300)
        print(f'--- pre={pre!r} ---')
        for line in r.log().splitlines():
            if 'HUD_STATE' in line or 'HP goid' in line or 'ERROR' in line:
                print('   ', line[:150])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
