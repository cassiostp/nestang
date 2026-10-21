#!/usr/bin/env python3
"""Exercise launcher scheduling and result reporting without simulator dependencies."""
import csv
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class LauncherTest(unittest.TestCase):
    def setUp(self):
        state = Path(__file__).resolve().parent / ".regress"
        state.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=state)
        self.addCleanup(self.temp.cleanup)
        self.sim = Path(self.temp.name) / 'sim'
        self.sim.mkdir()
        shutil.copy2(Path(__file__).with_name('regress.py'), self.sim / 'regress.py')
        self.env = dict(os.environ, TANGCORE_ROMS=str(self.sim / 'absent'))
        self.env.pop('REGRESS_JOBS', None)
        self.fields = 'bench tier variants runner seconds directory command rom pre post group container'.split()

    def catalog(self, rows):
        with (self.sim / 'regress.tsv').open('w') as f:
            writer = csv.DictWriter(f, fieldnames=self.fields, delimiter='\t')
            writer.writeheader()
            for row in rows:
                writer.writerow(dict(bench=row[0], tier=row[1], variants=row[2], runner='host', seconds='1',
                                     directory='.', command=row[3], rom=row[4], pre='', post='', group=row[5], container='host'))

    def launch(self, *args):
        return subprocess.run(['python3', str(self.sim / 'regress.py'), *args], env=self.env, capture_output=True, text=True)

    def test_results_and_selection(self):
        self.catalog([('ok', 'quick', 'shared', 'true', '', 'a'),
                      ('broken', 'quick', 'shared', 'exit 7', '', 'b'),
                      ('standard', 'quick', 'standard', 'true', '', 'c'),
                      ('missing', 'quick', 'shared', 'exit 8', 'absent.sfc', 'd'),
                      ('long', 'full', 'shared', 'true', '', 'e')])
        result = self.launch('quick', 'both')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout.count('\tPASS\t'), 2)
        self.assertEqual(result.stdout.count('\tFAIL\t'), 1)
        self.assertEqual(result.stdout.count('\tSKIP\t'), 2)
        self.assertNotIn('long\tshared', result.stdout)
        self.assertEqual(self.launch('--only', 'unknown').returncode, 2)
        self.assertIn('long\tfull', self.launch('--list').stdout)
        self.assertEqual(self.launch('full', '--only', 'long').returncode, 0)

    def test_scheduling_and_shared_resources(self):
        # Each child records the actual peak active process count under flock.
        (self.sim / 'probe.py').write_text('''import fcntl, pathlib, time
p = pathlib.Path('counter')
for step in (1, -1):
    with open('counter.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        active, peak = map(int, p.read_text().split()) if p.exists() else (0, 0)
        active += step
        p.write_text(f'{active} {max(active, peak)}')
    if step == 1: time.sleep(0.2)
''')
        for shared, peak in ((False, 2), (True, 1)):
            (self.sim / 'counter').unlink(missing_ok=True)
            self.catalog([(str(n), 'quick', 'shared', 'python3 probe.py', '', 'same' if shared else str(n)) for n in range(4)])
            result = self.launch()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.sim / 'counter').read_text(), f'0 {peak}')


if __name__ == '__main__':
    unittest.main()
