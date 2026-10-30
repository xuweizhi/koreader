#!/usr/bin/env python3
"""Install official SDK emulator components in the existing isolated toolchain."""
from pathlib import Path
import datetime
import json
import os
import subprocess
from urllib.parse import urlparse

sdk = Path('/data/koreader/base/toolchain/android-sdk-linux')
evidence = Path('/data/koreader-anx-work/evidence/W35/toolchain') / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
evidence.mkdir(parents=True, exist_ok=True)
command = [str(sdk / 'cmdline-tools/latest/bin/sdkmanager'), '--verbose', '--sdk_root=' + str(sdk)]
proxy = urlparse(os.environ.get('HTTPS_PROXY', os.environ.get('https_proxy', '')))
if proxy.hostname and proxy.port:
    command += ['--proxy=http', '--proxy_host=' + proxy.hostname, '--proxy_port=' + str(proxy.port)]
command += ['emulator', 'system-images;android-30;default;x86_64']
environment = os.environ.copy()
environment['ANDROID_USER_HOME'] = '/data/koreader-anx-work/android-sdk-user'
with (evidence / 'sdk-install.log').open('w') as log:
    result = subprocess.run(command, input='y\n' * 30, text=True, env=environment, stdout=log, stderr=subprocess.STDOUT)
(evidence / 'install-result.json').write_text(json.dumps({
    'exit_code': result.returncode, 'sdk': str(sdk),
    'packages': ['emulator', 'system-images;android-30;default;x86_64'],
    'kvm_available': Path('/dev/kvm').exists(),
    'log': str(evidence / 'sdk-install.log'),
}, indent=2) + '\n')
print(str(evidence / 'install-result.json'))
raise SystemExit(result.returncode)
