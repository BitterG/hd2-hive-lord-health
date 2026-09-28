"""Why is no candidate movement reported?  Look at what the probe actually does."""
import shutil
import sys

sys.path.insert(0, 'tests')
import test_hp as T  # noqa: E402

tmp = T.new_tmp(False)
try:
    src = T.ENTRY.read_text(encoding='utf-8')
    r = T.Run(src, tmp)
    r.ticks(600)
    log = r.read('hivelord_hp.log')
    print('SCAN goid=40 lines:', sum(1 for l in log.splitlines() if l.startswith('SCAN goid=40')))
    print('probe lines for 40 :', sum(1 for l in log.splitlines() if 'goid=40' in l))
    r.g.__set_field(40, 1, 123)
    r.ticks(400)
    log2 = r.read('hivelord_hp.log')
    print('after move:')
    print('  CAND_MOVED lines :', sum(1 for l in log2.splitlines() if l.startswith('CAND_MOVED')))
    print('  SCAN goid=40     :', sum(1 for l in log2.splitlines() if l.startswith('SCAN goid=40')))
    print('  SCOREBOARD #1    :', [l for l in log2.splitlines() if l.startswith('SCOREBOARD #1')][-1:])
    print('  last 4 lines     :')
    for line in log2.splitlines()[-4:]:
        print('   ', line[:130])
finally:
    shutil.rmtree(tmp, ignore_errors=True)
