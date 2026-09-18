"""Exercise the built accessory app against a disposable owner, never a DSH Host."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

binary = Path(__file__).resolve().parents[1] / '.build/release/dsh-notch'
with tempfile.TemporaryDirectory(prefix='notch-lifetime-') as temp:
    root = Path(temp)
    owner = subprocess.Popen(['/bin/sleep', '60'])
    helper = None
    try:
        runtime = root / 'runtime.json'
        runtime.write_text(json.dumps(dict(pid=owner.pid, writtenAt=int(time.time() * 1000),
                                          origin='http://127.0.0.1:9', token='offline-test')))
        with (root / 'helper.log').open('wb') as log:
            helper = subprocess.Popen([str(binary)], env=dict(os.environ, DSH_NOTCH_RUNTIME_FILE=str(runtime)),
                                      stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
            time.sleep(4)
            assert helper.poll() is None, 'HTTP failures incorrectly closed a live-owner helper'
            owner.terminate()
            owner.wait(timeout=3)
            start = time.monotonic()
            assert helper.wait(timeout=6) == 0, 'Helper did not terminate cleanly'
            elapsed = time.monotonic() - start
        assert 'closing helper' in (root / 'helper.log').read_text()
        print(f'PASS built helper: stays through HTTP failures, exits after owner death in {elapsed:.2f}s')
    finally:
        for process in (helper, owner):
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
