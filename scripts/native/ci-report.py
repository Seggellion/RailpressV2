"""Emit a bounded public CI receipt without exporting private runner data."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

engine, = sys.argv[1:]
if engine not in ('postgresql', 'mysql2'):
    raise ValueError('Unknown qualification engine')
temp = Path(os.environ['RUNNER_TEMP'])
source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
if source != os.environ['GITHUB_SHA']:
    raise ValueError('Checked-out source differs from the workflow SHA')
product = json.loads(Path('lib/railpress/product.json').read_text())
phase_file = temp / 'railpress-ci-phase'
phase = phase_file.read_text().strip() if phase_file.is_file() else 'bootstrap'
if phase not in ('bootstrap', 'provision', 'qualification', 'quality', 'cleanup', 'complete'):
    raise ValueError('Unknown qualification phase')
evidence = Path('docs/evidence/CI')
test_log = evidence / f'{engine}-tests.log'
counts = None
failed_locations = []
if test_log.is_file():
    log = test_log.read_text(errors='replace')
    summaries = re.findall(r'^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips$', log, re.M)
    if summaries:
        counts = dict(zip(('runs', 'assertions', 'failures', 'errors', 'skips'), map(int, summaries[-1])))
    failed_locations = sorted(set(re.findall(r'^bin/rails test (test/[a-zA-Z0-9_/]+\.rb:\d+)$', log, re.M)))[:30]
bootstrap = os.environ['BOOTSTRAP_OUTCOME']
qualification = os.environ['QUALIFICATION_OUTCOME']
if any(outcome not in ('success', 'failure', 'cancelled', 'skipped') for outcome in (bootstrap, qualification)):
    raise ValueError('Unknown Actions outcome')
passed = bootstrap == qualification == 'success' and phase == 'complete' and counts and counts['runs'] > 0 and counts['assertions'] > 0 and not any(counts[key] for key in ('failures', 'errors', 'skips'))
result = {
    'version': product['version'], 'channel': product['channel'], 'engine': engine,
    'source_commit': source, 'source_ref': os.environ['GITHUB_REF'],
    'runner_image': os.environ.get('ImageVersion'), 'bootstrap': bootstrap, 'qualification': qualification,
    'last_phase': phase, 'native_tests': counts, 'failed_test_locations': failed_locations,
    'tests_scans_build': 'PASS' if passed else 'INCOMPLETE',
    'signed_release': False, 'production_qualified': False,
}
if passed:
    result['asset_manifest_sha256'] = hashlib.sha256(Path('public/assets/.manifest.json').read_bytes()).hexdigest()
serialized = json.dumps(result, indent=2) + '\n'
(temp / 'railpress-ci-candidate.json').write_text(serialized)
print(serialized, end='')
if qualification == 'success' and not passed:
    raise SystemExit('Success was reported without complete local evidence')
