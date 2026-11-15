#!/usr/bin/env python3
"""Drive Apelin on a vphone or a jailbroken device from the Mac.

The device half of "where things get tested". Everything privileged is
proven through the console (Documents/Console.md): a script dropped into
`~/Documents/wiki.qaq.apelin/console/inbox/`, the app brought to the front,
the result read from `console/out/<runID>.jsonl`. This tool does those three
things over ssh, follows the run as it writes, and does what a person at the
device used to do around it: the root setup a script lists, killing the
session host or the app at the step a resume test needs, opening the app
again after a respring took it down, the checks and the cleanup afterwards.
What each script needs and gets is `Documents/Console/device-harness.json`.

The target, first match wins:
  --machine NAME, or VPHONE      a vphone by its vphone-launchpad name; its
                                 address is read from the guest itself
  --host ADDRESS, or VPHONE_HOST a vphone or device answering ssh on port 22
  DEVICE_HOST (DEVICE_PORT)      a phone behind `iproxy 2333 22`
  nothing                        the one vphone that is running
DEVICE_USER (mobile) and DEVICE_PASSWORD (alpine; empty for ssh keys) log in.

One ssh connection is shared by every call (ControlMaster), so following a
run costs a few milliseconds a poll. Results are kept on the Mac in
build/Device/<target>/.

usage: device.py <command> [...]; device.py <command> --help for each.
"""
from __future__ import annotations

import argparse
import base64
import datetime
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONSOLE = ROOT / 'Documents' / 'Console'
SCRIPTS = CONSOLE / 'scripts'
DEMO = CONSOLE / 'demo'
MANIFEST = CONSOLE / 'device-harness.json'
PACKAGES = ROOT / 'build' / 'Packages'
RESULTS = ROOT / 'build' / 'Device'
INSTALLER = ROOT / 'Scripts' / 'install-device.sh'
LAUNCHPAD = Path('/Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli')

BUNDLE_ID = 'wiki.qaq.apelin'
APP_PROCESS = 'Apelin'
CRASH_PREFIXES = ('Apelin', 'apelind', 'apelin-', 'panic-')

# A non-login ssh shell on a guest can start with /usr/bin:/bin only, and a
# rootless bootstrap's tools are under /var/jb; roothide's shell already
# sees its own root as /.
REMOTE_PATH = 'PATH="$PATH:/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin"'
CONTROL_DIR = Path('/private/tmp') / f'apelin-device-ssh-{os.getuid()}'

ACTIONS = ('killSessionHost', 'killApp')
SCRIPT_KEYS = {'needs', 'before', 'during', 'verify', 'after', 'expectOutput', 'timeout', 'manual', 'note'}
DEFAULT_TIMEOUT = 900


class HarnessError(Exception):
    """A problem with the target or the harness itself, not a test result."""


# MARK: Output


class Style:
    enabled = sys.stdout.isatty() and os.environ.get('NO_COLOR') is None

    @classmethod
    def wrap(cls, code, text):
        return f'\033[{code}m{text}\033[0m' if cls.enabled else text

    @classmethod
    def ok(cls, text):
        return cls.wrap('32', text)

    @classmethod
    def bad(cls, text):
        return cls.wrap('31', text)

    @classmethod
    def warn(cls, text):
        return cls.wrap('33', text)

    @classmethod
    def dim(cls, text):
        return cls.wrap('2', text)

    @classmethod
    def bold(cls, text):
        return cls.wrap('1', text)


def status_colour(status):
    return {'PASS': Style.ok, 'SKIP': Style.warn}.get(status, Style.bad)


def say(text=''):
    print(text, flush=True)


def note(text):
    print(Style.dim(text), flush=True)


def warn(text):
    print(Style.warn(f'warning: {text}'), file=sys.stderr, flush=True)


def seconds(value):
    if value < 1:
        return f'{value * 1000:.0f} ms'
    if value < 120:
        return f'{value:.1f} s'
    return f'{int(value // 60)} min {int(value % 60)} s'


def compact(value, limit=160):
    text = json.dumps(value, separators=(',', ':'), ensure_ascii=False)
    return text if len(text) <= limit else text[:limit - 1] + '…'


# MARK: Debian versions (dpkg's verrevcmp)


def _order(character):
    if not character:
        return 0
    if character.isdigit():
        return 0
    if character.isalpha():
        return ord(character)
    if character == '~':
        return -1
    return ord(character) + 256


def _compare_part(left, right):
    i = j = 0
    while i < len(left) or j < len(right):
        while (i < len(left) and not left[i].isdigit()) or (j < len(right) and not right[j].isdigit()):
            a = _order(left[i] if i < len(left) else '')
            b = _order(right[j] if j < len(right) else '')
            if a != b:
                return a - b
            i += 1
            j += 1
        while i < len(left) and left[i] == '0':
            i += 1
        while j < len(right) and right[j] == '0':
            j += 1
        first = 0
        while i < len(left) and j < len(right) and left[i].isdigit() and right[j].isdigit():
            if not first:
                first = ord(left[i]) - ord(right[j])
            i += 1
            j += 1
        if i < len(left) and left[i].isdigit():
            return 1
        if j < len(right) and right[j].isdigit():
            return -1
        if first:
            return first
    return 0


def compare_versions(left, right):
    def split(version):
        epoch, _, rest = version.rpartition(':') if ':' in version else ('0', '', version)
        upstream, _, revision = rest.rpartition('-') if '-' in rest else (rest, '', '0')
        return int(epoch or 0), upstream, revision
    a, b = split(left), split(right)
    if a[0] != b[0]:
        return a[0] - b[0]
    return _compare_part(a[1], b[1]) or _compare_part(a[2], b[2])


# MARK: The manifest


def load_manifest():
    with MANIFEST.open() as handle:
        return json.load(handle)


def script_names():
    return sorted(path.stem for path in SCRIPTS.glob('*.json'))


def resolve_script(name):
    """The script file for a name in scripts/ or demo/, or a path."""
    path = Path(name)
    if path.suffix == '.json' and path.exists():
        return path.resolve()
    for folder in (SCRIPTS, DEMO):
        candidate = folder / (name if name.endswith('.json') else f'{name}.json')
        if candidate.exists():
            return candidate
    raise HarnessError(f'no script named {name} in Documents/Console/scripts/ or demo/, and no such file')


def read_script(path):
    with path.open() as handle:
        script = json.load(handle)
    steps = script if isinstance(script, list) else script.get('steps', [])
    return script, steps


def step_index(steps, label):
    for index, step in enumerate(steps):
        if step.get('label') == label:
            return index
    return None


NEED = re.compile(r'^(!?)(package):([A-Za-z0-9.+-]+?)(?:(>=|<=|>>|<<|=)(\S+))?$|^(!?)(toolchain|installed-toolchain|sdk|sdk-source)$|^(project):(.+)$')


def parse_need(text):
    match = NEED.match(text)
    if not match:
        raise HarnessError(f'cannot read the need "{text}"')
    if match.group(2):
        return {'kind': 'package', 'negated': bool(match.group(1)), 'id': match.group(3),
                'op': match.group(4), 'version': match.group(5)}
    if match.group(7):
        return {'kind': match.group(7), 'negated': bool(match.group(6))}
    return {'kind': 'project', 'negated': False, 'name': match.group(9)}


def unmet_needs(needs, facts):
    """The needs in `needs` that `facts` do not meet, as written."""
    unmet = []
    for text in needs:
        need = parse_need(text)
        met = need_met(need, facts)
        if met != (not need['negated']):
            unmet.append(text)
    return unmet


def need_met(need, facts):
    kind = need['kind']
    if kind == 'package':
        version = facts['packages'].get(need['id'])
        if version is None:
            return False
        if not need['op']:
            return True
        order = compare_versions(version, need['version'])
        return {'>=': order >= 0, '<=': order <= 0, '>>': order > 0, '<<': order < 0, '=': order == 0}[need['op']]
    if kind == 'toolchain':
        return bool(facts['toolchains'])
    if kind == 'installed-toolchain':
        return any(toolchain.get('installationID') for toolchain in facts['toolchains'])
    if kind == 'sdk':
        return bool(facts['sdks'])
    if kind == 'sdk-source':
        return bool(facts['sdks']) or 'iPhoneOS.sdk' in facts['inbox']
    if kind == 'project':
        return need['name'] in facts['projects']
    raise HarnessError(f'unknown need {kind}')


def lint(manifest=None):
    """Every problem with the manifest, against the scripts it names."""
    manifest = manifest or load_manifest()
    problems = []
    entries = manifest.get('scripts', {})
    suites = manifest.get('suites', {})
    names = script_names()
    for name in names:
        if name not in entries:
            problems.append(f'scripts/{name}.json has no entry in device-harness.json ▸ scripts')
    for name, entry in entries.items():
        if name not in names:
            problems.append(f'device-harness.json names {name}, which scripts/ does not have')
            continue
        unknown = set(entry) - SCRIPT_KEYS
        if unknown:
            problems.append(f'{name}: unknown keys {sorted(unknown)}')
        _, steps = read_script(SCRIPTS / f'{name}.json')
        for need in entry.get('needs', []):
            try:
                parse_need(need)
            except HarnessError as error:
                problems.append(f'{name}: {error}')
        for phase in ('before', 'verify', 'after'):
            for action in entry.get(phase, []):
                problem = action_problem(action)
                if problem:
                    problems.append(f'{name} ▸ {phase}: {problem}')
        for hook in entry.get('during', []):
            when = hook.get('when', {})
            if len(when) != 1 or next(iter(when)) not in ('start', 'result', 'task'):
                problems.append(f'{name} ▸ during: "when" is one of start, result or task, naming a step label')
            elif step_index(steps, next(iter(when.values()))) is None:
                problems.append(f'{name} ▸ during: no step labelled {next(iter(when.values()))}')
            if hook.get('do') not in ACTIONS:
                problems.append(f'{name} ▸ during: "do" is one of {", ".join(ACTIONS)}')
        for expectation in entry.get('expectOutput', []):
            if 'step' in expectation and step_index(steps, expectation['step']) is None:
                problems.append(f'{name} ▸ expectOutput: no step labelled {expectation["step"]}')
            if not ('event' in expectation) ^ ('line' in expectation):
                problems.append(f'{name} ▸ expectOutput: each holds an "event" (with "step") or a "line" (with "min")')
    regression = set(suites.get('regression', []))
    for suite, members in suites.items():
        for member in members:
            if member not in entries:
                problems.append(f'suite {suite} names {member}, which has no entry')
            elif entries[member].get('manual'):
                problems.append(f'suite {suite} names {member}, which is manual')
    for name, entry in entries.items():
        if not entry.get('manual') and name not in regression:
            problems.append(f'{name} is not manual and not in the regression suite')
    return problems


def action_problem(action):
    if not isinstance(action, dict) or len(action) not in (1, 2):
        return f'cannot read {compact(action)}'
    if 'root' in action or 'mobile' in action:
        return None if len(action) == 1 else f'cannot read {compact(action)}'
    if 'push' in action:
        if set(action) != {'push', 'to'}:
            return 'push takes "push" (a repository path) and "to" (a path in the data folder)'
        if not (ROOT / action['push']).is_file():
            return f'{action["push"]} does not exist'
        return None
    if 'removeProject' in action:
        name = action['removeProject']
        return None if name and '/' not in name and name not in ('.', '..') else f'not a project name: {name}'
    if 'stageSDK' in action:
        return None if '/' not in action['stageSDK'] else 'stageSDK names a folder in the inbox'
    return f'unknown action {compact(action)}'


# MARK: vphone-launchpad


def launchpad(*arguments, timeout=60):
    if not LAUNCHPAD.exists():
        return None
    try:
        completed = subprocess.run([str(LAUNCHPAD), *arguments], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    if completed.returncode != 0:
        return None
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None


def machines():
    listed = launchpad('vm', 'list')
    return listed if isinstance(listed, list) else []


def guest_rpc(machine, method, parameters=None, timeout=60):
    arguments = ['guest', 'rpc', machine, method]
    if parameters is not None:
        arguments.append(json.dumps(parameters))
    reply = launchpad(*arguments, timeout=timeout)
    return reply.get('result') if isinstance(reply, dict) and reply.get('ok') else None


def machine_address(machine):
    network = guest_rpc(machine, 'device.network') or {}
    candidates = []
    for entry in network.get('addresses', []):
        interface, _, address = entry.partition(' ')
        if re.fullmatch(r'\d+\.\d+\.\d+\.\d+', address) and not address.startswith(('127.', '169.254.')):
            candidates.append((interface != 'en0', address))
    return min(candidates)[1] if candidates else None


# MARK: The target


class Target:
    def __init__(self, label, host, port, user, password, machine=None):
        self.label = label
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.machine = machine
        self.facts = None

    @classmethod
    def resolve(cls, arguments):
        user = os.environ.get('DEVICE_USER', 'mobile')
        password = os.environ.get('DEVICE_PASSWORD', 'alpine')
        machine = getattr(arguments, 'machine', None) or os.environ.get('VPHONE')
        host = getattr(arguments, 'host', None) or os.environ.get('VPHONE_HOST')
        if machine:
            return cls.for_machine(machine, user, password)
        if host:
            known = next((m['name'] for m in machines() if m.get('state') == 'running'
                          and machine_address(m['name']) == host), None)
            return cls(known or host, host, 22, user, password, known)
        if os.environ.get('DEVICE_HOST'):
            host = os.environ['DEVICE_HOST']
            return cls(host, host, int(os.environ.get('DEVICE_PORT', '2333')), user, password)
        listed = machines()
        running = [m['name'] for m in listed if m.get('state') == 'running']
        if len(running) == 1:
            return cls.for_machine(running[0], user, password)
        if running:
            raise HarnessError(f'several vphones are running ({", ".join(running)}): pick one with --machine or VPHONE=<name>')
        if listed:
            stopped = ', '.join(m['name'] for m in listed)
            raise HarnessError(f'no vphone is running (known: {stopped}). Start one with\n'
                               f'  {LAUNCHPAD} vm start <name> --wait\n'
                               'or name a device with --host / DEVICE_HOST')
        raise HarnessError('no target: pass --machine, --host, or set VPHONE, VPHONE_HOST or DEVICE_HOST')

    @classmethod
    def for_machine(cls, name, user, password):
        listed = {m['name']: m for m in machines()}
        if not listed:
            raise HarnessError(f'vphone-launchpad-cli is not answering, so {name} cannot be found; pass --host instead')
        if name not in listed:
            raise HarnessError(f'no vphone named {name} (known: {", ".join(sorted(listed))})')
        if listed[name].get('state') != 'running':
            raise HarnessError(f'{name} is {listed[name].get("state")}. Start it with\n  {LAUNCHPAD} vm start {name} --wait')
        address = machine_address(name)
        if not address:
            raise HarnessError(f'{name} is running but its address cannot be read (is vphoned up? try `vm wait {name}`)')
        return cls(name, address, 22, user, password, name)

    def describe(self):
        where = f'{self.host}:{self.port}'
        return f'{self.label} ({where})' if self.label != self.host else where

    @property
    def results_folder(self):
        """Where this target's results are kept on the Mac."""
        return RESULTS / re.sub(r'[^A-Za-z0-9._-]', '_', self.label)

    # MARK: ssh

    def ssh_command(self, extra=()):
        CONTROL_DIR.mkdir(mode=0o700, exist_ok=True)
        options = [
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'LogLevel=ERROR',
            '-o', 'ConnectTimeout=10',
            '-o', 'ServerAliveInterval=10',
            '-o', 'ControlMaster=auto',
            '-o', f'ControlPath={CONTROL_DIR}/%C',
            '-o', 'ControlPersist=300',
        ]
        command = ['ssh', *options, *extra, '-p', str(self.port), f'{self.user}@{self.host}']
        if self.password:
            if not shutil.which('sshpass'):
                raise HarnessError('DEVICE_PASSWORD is set but sshpass is not installed; install it with your preferred '
                                   'package manager, or set DEVICE_PASSWORD= to use ssh keys')
            # Some guests answer keyboard-interactive only; an agent's keys
            # would use up the attempts first.
            command[1:1] = ['-o', 'PubkeyAuthentication=no',
                            '-o', 'PreferredAuthentications=keyboard-interactive,password',
                            '-o', 'NumberOfPasswordPrompts=1']
            command = ['sshpass', '-e', *command]
        return command

    def ssh_environment(self):
        environment = dict(os.environ)
        if self.password:
            environment['SSHPASS'] = self.password
            environment['SSH_AUTH_SOCK'] = ''
        return environment

    def exports(self):
        if not self.facts:
            return ''
        return (f'export DATA={shlex.quote(self.facts["data"])} JB={shlex.quote(self.facts["jb"])}; ')

    def run(self, script, root=False, stdin=b'', check=True, timeout=120):
        """Runs `script` with sh on the target; answers its stdout as bytes."""
        body = f'export {REMOTE_PATH}; {self.exports()}{script}'
        if root:
            if self.password:
                remote = f"sudo -S -p '' sh -c {shlex.quote(body)}"
                stdin = self.password.encode() + b'\n' + stdin
            else:
                remote = f'sudo -n sh -c {shlex.quote(body)}'
        else:
            remote = f'sh -c {shlex.quote(body)}'
        try:
            completed = subprocess.run(self.ssh_command() + [remote], input=stdin, capture_output=True,
                                       env=self.ssh_environment(), timeout=timeout)
        except subprocess.TimeoutExpired:
            raise HarnessError(f'{self.describe()} did not answer within {timeout} s')
        if completed.returncode == 255:
            message = completed.stderr.decode(errors='replace').strip()
            raise HarnessError(f'ssh to {self.describe()} failed: {message or "exit 255"}')
        if check and completed.returncode != 0:
            message = completed.stderr.decode(errors='replace').strip()
            raise HarnessError(f'on {self.describe()}{" as root" if root else ""}: `{script.strip()[:200]}` '
                               f'exited {completed.returncode}{": " + message if message else ""}')
        return completed.stdout if check else completed

    def text(self, script, root=False, check=True, **options):
        result = self.run(script, root=root, check=check, **options)
        return (result if check else result.stdout).decode(errors='replace')

    def interactive(self, command=None, root=False):
        remote = []
        if root:
            remote = ['sudo', '-i'] if not command else ['sudo', 'sh', '-c', command]
        elif command:
            remote = ['sh', '-c', command]
        arguments = self.ssh_command(['-t']) + ([' '.join(shlex.quote(part) for part in remote)] if remote else [])
        return subprocess.call(arguments, env=self.ssh_environment())

    # MARK: Facts

    def gather(self):
        """Reads what the harness decides by: where things are, what is installed."""
        output = self.text(r'''
data="$HOME/Documents/wiki.qaq.apelin"
echo; echo "@@home"; printf '%s\n' "$HOME"
echo; echo "@@arch"; dpkg --print-architecture 2>/dev/null
echo; echo "@@root"
daemon=$(dpkg -L wiki.qaq.apelin 2>/dev/null | grep '/usr/libexec/apelind$' | head -1)
[ -n "$daemon" ] && (cd -P "${daemon%/usr/libexec/apelind}/" 2>/dev/null && pwd -P)
echo; echo "@@app"; dpkg -L wiki.qaq.apelin 2>/dev/null | grep '/Applications/Apelin.app$' | head -1
echo; echo "@@packages"; dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\t${Provides}\n' 2>/dev/null | grep '^ii'
echo; echo "@@toolchains"; cat "$data/Environment/Toolchains/registry.json" 2>/dev/null
echo; echo "@@sdks"; ls -A "$data/SDKs" 2>/dev/null
echo; echo "@@sdk-records"; ls "$data/SDKs/.registry" 2>/dev/null
echo; echo "@@inbox"; ls -A "$data/inbox" 2>/dev/null
echo; echo "@@projects"; ls -A "$data/Projects" 2>/dev/null
echo; echo "@@console"
for folder in inbox running done out; do printf '%s %s\n' "$folder" "$(ls -A "$data/console/$folder" 2>/dev/null | grep -c '\.json')"; done
echo; echo "@@running"; ls -A "$data/console/running" 2>/dev/null
echo; echo "@@running-app"; killall -0 Apelin 2>/dev/null && echo yes
echo; echo "@@uname"; uname -srm
echo; echo "@@end"
''', timeout=60)
        sections = {}
        current = None
        for line in output.splitlines():
            if line.startswith('@@'):
                current = line[2:]
                sections[current] = []
            elif current:
                sections[current].append(line)

        def one(name):
            return next((line.strip() for line in sections.get(name, []) if line.strip()), '')

        home = one('home')
        if not home:
            raise HarnessError(f'could not read the shell environment on {self.describe()}')
        packages = {}
        provides = set()
        for line in sections.get('packages', []):
            parts = line.split('\t')
            if len(parts) >= 3:
                packages[parts[1]] = parts[2]
            if len(parts) == 4:
                provides.update(re.split(r'[\s(]', name.strip(), maxsplit=1)[0] for name in parts[3].split(',') if name.strip())
        try:
            registry = json.loads('\n'.join(sections.get('toolchains', [])) or '{}')
        except json.JSONDecodeError:
            registry = {}
        sdk_records = {name[:-5] for name in sections.get('sdk-records', []) if name.endswith('.json')}
        sdk_folders = [name for name in sections.get('sdks', []) if name and not name.startswith('.')]
        console = {}
        for line in sections.get('console', []):
            folder, _, count = line.partition(' ')
            console[folder] = int(count or 0)
        install_root = one('root')
        self.facts = {
            'home': home,
            'data': f'{home}/Documents/wiki.qaq.apelin',
            'arch': one('arch'),
            'root': install_root,
            'jb': install_root.rstrip('/'),
            'app': one('app'),
            'packages': packages,
            'provides': provides,
            'toolchains': registry.get('toolchains', []) if isinstance(registry, dict) else [],
            'sdks': sorted(sdk_records),
            'orphanSDKs': sorted(name for name in sdk_folders if name not in sdk_records),
            'inbox': [name for name in sections.get('inbox', []) if name],
            'projects': [name for name in sections.get('projects', []) if name],
            'console': console,
            'running': [name for name in sections.get('running', []) if name.endswith('.json')],
            'appRunning': one('running-app') == 'yes',
            'uname': one('uname'),
        }
        return self.facts

    def require_apelin(self):
        facts = self.facts or self.gather()
        if not facts['root']:
            raise HarnessError(f'Apelin is not installed on {self.describe()}. Install it once with your preferred '
                               'package manager; `device.py install` updates it from then on')
        return facts

    # MARK: The app

    def app_running(self):
        return self.run('killall -0 Apelin 2>/dev/null', check=False).returncode == 0

    def frontmost(self):
        """Whether Apelin is the app in front; None where nothing can say."""
        if not self.machine:
            return None
        result = guest_rpc(self.machine, 'apps.foreground')
        return None if result is None else result.get('bundle_id') == BUNDLE_ID

    def open_app(self, fresh=False):
        """Brings Apelin to the front. With `fresh`, an app already running
        is quit first, so the launch reads the inbox: one already in front
        never comes to the foreground again, and going through another app
        leaves that app beside it on an iPad, with the focus. Only for an
        idle app: the caller has seen console/running/ empty."""
        if self.machine:
            launchpad('guest', 'unlock', self.machine, timeout=30)
        if fresh and self.app_running():
            self.run('killall -TERM Apelin 2>/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do '
                     'killall -0 Apelin 2>/dev/null || exit 0; sleep 0.5; done; killall -9 Apelin 2>/dev/null; sleep 0.5',
                     check=False)
        return self.launch(BUNDLE_ID)

    def launch(self, bundle_id):
        if self.machine:
            reply = guest_rpc(self.machine, 'apps.launch', {'bundle_id': bundle_id}, timeout=30)
            if reply is not None:
                return True
        return self.run(f'uiopen --bundleid {shlex.quote(bundle_id)} >/dev/null 2>&1', check=False).returncode == 0

    def reopen_app(self, deadline=120):
        """After a respring or a kill: until SpringBoard takes the launch again."""
        end = time.time() + deadline
        time.sleep(3)
        while time.time() < end:
            self.open_app()
            time.sleep(2)
            if self.app_running():
                return True
            time.sleep(2)
        return False

    def kill_session_host(self):
        pid_file = f'{self.facts["jb"]}/var/lib/apelin/session.pid'
        old = self.text(f'cat {shlex.quote(pid_file)} 2>/dev/null', root=True, check=True).strip()
        if not old:
            raise HarnessError('no session host is running (no session.pid)')
        self.run(f'kill -9 {int(old)}', root=True)
        for _ in range(40):
            time.sleep(0.25)
            new = self.text(f'cat {shlex.quote(pid_file)} 2>/dev/null || true', root=True).strip()
            if new and new != old:
                return int(old), int(new)
        return int(old), None


# MARK: Running a script


class Run:
    """One script on the target: setup, drop, follow, checks, cleanup."""

    def __init__(self, target, name, path, entry, options):
        self.target = target
        self.name = name
        self.path = path
        self.entry = entry or {}
        self.options = options
        self.script, self.steps = read_script(path)
        self.lines = []
        self.run_id = None
        self.status = None
        self.reason = None
        self.failure = None
        self.local_output = None
        self.started = time.time()
        self.hooks = []
        self.returns = 0
        self.quarters = {}
        self.staged = []

    # MARK: Actions

    def act(self, action):
        target = self.target
        if 'root' in action:
            target.run(action['root'], root=True)
        elif 'mobile' in action:
            target.run(action['mobile'])
        elif 'push' in action:
            source = ROOT / action['push']
            destination = f'$DATA/{action["to"]}'
            folder = destination.rsplit('/', 1)[0]
            target.run(f'mkdir -p "{folder}" && cat > "{destination}.part" && mv -f "{destination}.part" "{destination}"',
                       stdin=source.read_bytes())
        elif 'removeProject' in action:
            name = action['removeProject']
            if not name or '/' in name:
                raise HarnessError(f'removeProject needs a folder name, not {name!r}')
            target.run(f'rm -rf "${{DATA:?}}/Projects/"{shlex.quote(name)}')
        elif 'stageSDK' in action:
            # The inbox import moves its source in; a registered SDK's tree is
            # an SDK folder too, so a copy of one stands in for a new one. An
            # import of an SDK already registered leaves the copy where it is,
            # so the run removes what it staged, and only that.
            name = shlex.quote(action['stageSDK'])
            staged = target.run(f'''
cd "$DATA" || exit 1
[ -e inbox/{name} ] && exit 0
source=$(for record in SDKs/.registry/*.json; do [ -e "$record" ] || continue; id=${{record##*/}}; id=${{id%.json}}; [ -d "SDKs/$id" ] && echo "SDKs/$id" && break; done)
[ -n "$source" ] || {{ echo "no registered SDK to copy into the inbox" >&2; exit 1; }}
mkdir -p inbox && cp -R "$source" inbox/.{action["stageSDK"]}.part && mv inbox/.{action["stageSDK"]}.part inbox/{name} && echo staged
''', timeout=600)
            if b'staged' in staged:
                self.staged.append(action['stageSDK'])
        else:
            raise HarnessError(f'unknown action {compact(action)}')

    # MARK: Hooks (on the device, so they fire within 50 ms of the line)

    def start_hooks(self, tag):
        for number, hook in enumerate(self.entry.get('during', [])):
            (kind, label), = hook['when'].items()
            index = step_index(self.steps, label)
            if kind == 'task':
                needles = ('"type":"step.task"', f'"index":{index},"kind"')
            else:
                needles = (f'"type":"step.{kind}"', f'"label":{json.dumps(label)}')
            if hook['do'] == 'killSessionHost':
                action = ('pid=$(cat "$JB/var/lib/apelin/session.pid") && kill -9 "$pid" '
                          '&& echo "killed the session host, pid $pid"')
            else:
                action = 'killall -9 Apelin && echo "killed the app"'
            stem = f'/tmp/.apelin-harness-{tag}-{number}'
            body = f'''
tag={shlex.quote(tag)}; first={shlex.quote(needles[0])}; second={shlex.quote(needles[1])}
deadline=$(( $(date +%s) + {int(self.timeout()) + 120} ))
out=
while [ -z "$out" ]; do
  for claimed in "$DATA"/console/running/*-"$tag" "$DATA"/console/done/*-"$tag"; do
    [ -e "$claimed" ] || continue
    name=${{claimed##*/}}; out="$DATA/console/out/${{name%-$tag}}.jsonl"
  done
  [ "$(date +%s)" -lt "$deadline" ] || {{ echo "gave up: the run never started"; exit 1; }}
  [ -n "$out" ] || sleep 0.05
done
until grep -F -- "$first" "$out" 2>/dev/null | grep -qF -- "$second"; do
  [ "$(date +%s)" -lt "$deadline" ] || {{ echo "gave up: no {kind} line for {label}"; exit 1; }}
  sleep 0.05
done
echo "saw the {kind} line of {label} at $(date +%H:%M:%S.%N | cut -c1-12)"
sleep {float(hook.get('delay', 0))}
{action}
echo "fired at $(date +%H:%M:%S.%N | cut -c1-12)"
'''
            self.target.run(f'cat > {stem}.sh', root=True, stdin=body.encode())
            pid = self.target.text(f'export DATA JB; nohup sh {stem}.sh > {stem}.log 2>&1 < /dev/null & echo $!',
                                   root=True).strip()
            self.hooks.append((hook, stem, pid))

    def finish_hooks(self):
        reports = []
        for hook, stem, pid in self.hooks:
            log = self.target.text(f'kill {pid} 2>/dev/null; cat {stem}.log 2>/dev/null; rm -f {stem}.sh {stem}.log',
                                   root=True, check=False)
            reports.append((hook, log.strip()))
        self.hooks = []
        return reports

    # MARK: The run

    def timeout(self):
        return self.options.timeout or self.entry.get('timeout', DEFAULT_TIMEOUT)

    def execute(self):
        target = self.target
        target.gather()
        facts = target.require_apelin()
        say(Style.bold(f'▸ {self.name}') + Style.dim(f'  {target.describe()}'))
        if self.entry.get('manual') and not self.options.explicit:
            return self.done('SKIP', f'manual: {self.entry["manual"]}')
        if not self.options.force:
            unmet = unmet_needs(self.entry.get('needs', []), facts)
            if unmet:
                return self.done('SKIP', 'needs ' + ', '.join(unmet))
        self.guard_orphans(facts)
        self.wait_for_idle()
        if not self.options.no_setup:
            for action in self.entry.get('before', []):
                self.act(action)
        tag = f'dh{int(time.time())}-{self.path.stem}.json'
        try:
            self.start_hooks(tag)
            target.run(f'mkdir -p "$DATA/console/inbox" && cat > "$DATA/console/inbox/.{tag}" '
                       f'&& mv "$DATA/console/inbox/.{tag}" "$DATA/console/inbox/{tag}"',
                       stdin=self.path.read_bytes())
            self.started = time.time()
            target.open_app(fresh=True)
            self.find_run(tag)
            self.follow()
        finally:
            hook_reports = self.finish_hooks()
            self.save()
        for hook, log in hook_reports:
            note(f'  hook {hook["do"]}: {log.splitlines()[-1] if log else "no output"}')
            if 'fired' not in log:
                self.fail('a hook did not fire: ' + (log or 'no output'))
        if self.status is None:
            self.check_output()
        if self.status is None and not self.options.no_setup:
            for action in self.entry.get('verify', []):
                try:
                    self.act(action)
                except HarnessError as error:
                    self.fail(f'verify: {error}')
                    break
        if not (self.options.keep or self.options.no_setup):
            for action in self.entry.get('after', []):
                try:
                    self.act(action)
                except HarnessError as error:
                    warn(f'cleanup after {self.name}: {error}')
            for name in self.staged:
                if name and '/' not in name:
                    target.run(f'rm -rf "${{DATA:?}}/inbox/"{shlex.quote(name)}', check=False)
        return self.done(self.status or 'PASS', self.reason)

    def guard_orphans(self, facts):
        if facts['orphanSDKs'] and not self.options.force:
            listed = ', '.join(f'SDKs/{name}' for name in facts['orphanSDKs'])
            raise HarnessError(
                f'{listed} has no record, and apelin-environment deletes every unregistered folder in SDKs/ when '
                'it starts (SDKStore.sweepOrphans). Move it into the inbox to import it:\n'
                f'  device.py exec -- mv "$DATA/SDKs/{facts["orphanSDKs"][0]}" "$DATA/inbox/iPhoneOS.sdk"\n'
                'or pass --force to let it go')

    def wait_for_idle(self):
        facts = self.target.facts
        if facts['console'].get('inbox'):
            warn(f'{facts["console"]["inbox"]} script(s) already wait in the inbox and run first')
        if not facts['running']:
            return
        note(f'  an earlier run is still in console/running/ ({", ".join(facts["running"])}); waiting for it')
        self.target.open_app()
        end = time.time() + 180
        while time.time() < end:
            time.sleep(3)
            if not self.target.gather()['running']:
                return
        raise HarnessError('an earlier run is still in console/running/; see `device.py out` and finish or clear it')

    def find_run(self, tag):
        end = time.time() + 60
        nudged = False
        while time.time() < end:
            claimed = self.target.text(f'ls "$DATA/console/running" "$DATA/console/done" 2>/dev/null '
                                       f'| grep -F -- "-{tag}" | head -1 || true').strip()
            if claimed:
                self.run_id = claimed[:-len(tag) - 1]
                note(f'  run {self.run_id}')
                return
            if not nudged and time.time() - self.started > 15:
                # Never quit it here: it may have claimed the script since
                # the last look, and quitting would interrupt that run.
                note('  the app has not picked the script up; bringing it to the front again')
                self.target.open_app()
                nudged = True
            time.sleep(0.5)
        running = self.target.app_running()
        self.target.run(f'rm -f "$DATA/console/inbox/{tag}"', check=False)
        raise HarnessError('the app did not pick the script up within 60 s '
                           f'({"it is running" if running else "it is not running"}; '
                           'a locked screen or a crash at launch both look like this — try `device.py open`, '
                           '`device.py screenshot` or `device.py crashes`)')

    def follow(self):
        target = self.target
        out = f'"$DATA/console/out/{self.run_id}.jsonl"'
        offset = 0
        pending = b''
        last_growth = time.time()
        last_alive = 0
        relaunches = 0
        deadline = self.started + self.timeout()
        while True:
            chunk = target.run(f'tail -c +{offset + 1} {out} 2>/dev/null || true', timeout=60)
            if chunk:
                offset += len(chunk)
                pending += chunk
                *complete, pending = pending.split(b'\n')
                for raw in complete:
                    if raw.strip():
                        self.take(raw)
                last_growth = time.time()
                if self.ended():
                    return
            now = time.time()
            if now > deadline:
                self.fail(f'no run.end within {seconds(self.timeout())}')
                return
            if now - last_growth > 5 and now - last_alive > 5:
                last_alive = now
                if not target.app_running():
                    if relaunches >= 4:
                        self.fail('the app went away four times; not opening it again')
                        return
                    relaunches += 1
                    note('  the app went away (a respring or a kill); opening it again')
                    if not target.reopen_app():
                        self.fail('the app could not be opened again within 2 min')
                        return
                elif target.frontmost() is False:
                    # A suspended app's follow stalls until it is in front
                    # again; something in the script sent it away.
                    self.returns += 1
                    note(Style.warn('  the app is not in front, so its run cannot go on; bringing it back'))
                    target.open_app()
            time.sleep(self.options.poll)

    def ended(self):
        return any(line.get('type') == 'run.end' for line in self.lines[-2:])

    def take(self, raw):
        try:
            line = json.loads(raw)
        except json.JSONDecodeError:
            note(f'  (unreadable line: {raw[:120]!r})')
            return
        self.lines.append(line)
        kind = line.get('type')
        verbose = self.options.verbose
        if kind == 'step.result':
            self.print_result(line)
        elif kind == 'step.task' and verbose:
            note(f'  ⋯ {line.get("index"):>3} task {line.get("kind")} {line.get("taskID")}')
        elif kind == 'step.event':
            event = line.get('event', {})
            payload = event.get('payload') if isinstance(event.get('payload'), dict) else {}
            if not verbose and event.get('kind') == 'progress' and payload.get('total'):
                # A long download or unpack shows every quarter, not every chunk.
                quarter = int(4 * payload.get('completed', 0) / payload['total'])
                key = (line.get('index'), payload.get('stage'))
                if quarter > self.quarters.get(key, 0):
                    self.quarters[key] = quarter
                    note(f'  ⋯ {line.get("index"):>3} {event.get("seq"):>4} {payload.get("stage", "progress")} '
                         f'{25 * quarter}% of {payload["total"] / 1e6:.0f} MB')
            elif verbose or event.get('kind') in ('stage', 'resumed', 'unreadable', 'approvalRequested'):
                payload = event.get('payload')
                detail = payload.get('stage') if isinstance(payload, dict) and 'stage' in payload else compact(payload, 100)
                note(f'  ⋯ {line.get("index"):>3} {event.get("seq"):>4} {event.get("kind")} {detail}')
        elif kind == 'step.note':
            note(f'  note: {line.get("message")}')
        elif kind == 'run.resumed':
            note(f'  run resumed at step {line.get("fromStep")}'
                 + (f', re-attached after event {line.get("afterSeq")}' if line.get('taskID') else ''))
        elif kind == 'run.interrupted':
            say(Style.bad(f'  run interrupted after step {line.get("lastStep")}'))
        elif kind == 'run.invalid':
            say(Style.bad(f'  the script did not read: {line.get("error")}'))
        elif kind == 'run.end' and not line.get('ok'):
            self.fail(self.failure or f'failed at step {line.get("failedStep")}')

    def print_result(self, line):
        index = line.get('index')
        step = self.steps[index] if isinstance(index, int) and index < len(self.steps) else {}
        name = line.get('op', '?') + (f' {line["label"]}' if line.get('label') else '')
        mark = Style.ok('✓') if line.get('ok') else Style.bad('✗')
        detail = line.get('state') or ''
        if not line.get('ok'):
            error = line.get('error') or {}
            message = str(error.get('message', ''))
            if len(message) > 300 and not self.options.verbose:
                message = message[:299] + '…'
            detail = f'{error.get("code", "?")}: {message}'
            if step.get('op') == 'expect':
                detail += f'  {compact(step.get("request", {}), 140)}'
            if step.get('allowError'):
                mark = Style.dim('~')
                detail = Style.dim('allowed: ') + detail
            elif not self.failure:
                self.failure = f'step {index} {name}: {detail}'
        elif step.get('op') == 'expect' and not self.options.verbose:
            return
        timing = Style.dim(f'{seconds(line.get("durationMs", 0) / 1000):>9}')
        say(f'  {mark} {index:>3} {name:<34} {timing}  {detail}'.rstrip())

    def check_output(self):
        if not any(line.get('type') == 'run.end' for line in self.lines):
            self.fail(self.failure or 'the run did not end')
            return
        for expectation in self.entry.get('expectOutput', []):
            if 'line' in expectation:
                count = sum(1 for line in self.lines if line.get('type') == expectation['line'])
                if count < expectation.get('min', 1):
                    self.fail(f'expected at least {expectation.get("min", 1)} {expectation["line"]} line(s), saw {count}')
                    return
            else:
                index = step_index(self.steps, expectation['step'])
                kinds = [line['event'].get('kind') for line in self.lines
                         if line.get('type') == 'step.event' and line.get('index') == index]
                for line in self.lines:
                    if line.get('type') == 'step.result' and line.get('index') == index:
                        response = line.get('response') or {}
                        kinds += [event.get('kind') for event in response.get('events', []) if isinstance(event, dict)]
                if expectation['event'] not in kinds:
                    self.fail(f'no {expectation["event"]} event in step {expectation["step"]} '
                              '(for a resume test: the kill came too late or too early)')
                    return

    def fail(self, reason):
        if self.status is None:
            self.status = 'FAIL'
            self.reason = reason

    def save(self):
        if not self.lines or not self.run_id:
            return
        folder = self.target.results_folder
        folder.mkdir(parents=True, exist_ok=True)
        self.local_output = folder / f'{self.run_id}-{self.path.stem}.jsonl'
        with self.local_output.open('w') as handle:
            for line in self.lines:
                handle.write(json.dumps(line, separators=(',', ':'), ensure_ascii=False) + '\n')

    def done(self, status, reason=None):
        self.status = status
        self.reason = reason
        elapsed = time.time() - self.started
        if self.returns:
            reason = ((reason + '; ') if reason else '') + f'the app was brought back to the front {self.returns} time(s)'
            self.reason = reason
        colour = status_colour(status)
        tail = f'  {reason}' if reason else ''
        say(f'{colour(status)} {self.name} {Style.dim(seconds(elapsed))}{tail}')
        if self.local_output:
            note(f'     {self.local_output.relative_to(ROOT)}')
        say()
        return self


def run_scripts(target, names, options):
    manifest = load_manifest()
    entries = manifest.get('scripts', {})
    target.require_apelin()
    results = []
    for name in names:
        path = resolve_script(name)
        stem = path.stem
        try:
            run = Run(target, stem, path, entries.get(stem, {}), options)
            run.execute()
        except HarnessError as error:
            run.status, run.reason = 'ERROR', str(error)
            say(f'{Style.bad("ERROR")} {stem}  {error}\n')
        results.append(run)
        if options.stop and run.status in ('FAIL', 'ERROR'):
            break
    if len(results) > 1:
        say(Style.bold('Summary') + Style.dim(f'  {target.describe()}'))
        for run in results:
            colour = status_colour(run.status)
            say(f'  {colour(f"{run.status:<5}")} {run.name:<24} {run.reason or ""}'.rstrip())
        counts = {status: sum(1 for run in results if run.status == status) for status in ('PASS', 'FAIL', 'ERROR', 'SKIP')}
        say('  ' + ', '.join(f'{count} {status.lower()}' for status, count in counts.items() if count))
    return 0 if all(run.status in ('PASS', 'SKIP') for run in results) else 1


# MARK: Commands


def command_status(target, arguments):
    facts = target.gather()
    machine = next((m for m in machines() if m['name'] == target.machine), None) if target.machine else None
    say(Style.bold('Target    ') + target.describe()
        + (f', iOS {machine.get("ios")}' if machine and machine.get('ios') else '')
        + (f', {facts["arch"]}' if facts['arch'] else '') + Style.dim(f'  {facts["uname"]}'))
    if not facts['root']:
        say(Style.bad('Apelin    not installed') + ' — install it once with your preferred package manager')
        return 1
    jailbreak = (guest_rpc(target.machine, 'device.info') or {}).get('jailbreak') if target.machine else None
    if jailbreak and jailbreak.get('jbroot'):
        root = f'{jailbreak["jbroot"]} ({jailbreak.get("layout")}; the ssh shell sees it as {facts["root"]})'
    else:
        layout = 'rootless' if facts['root'] == '/var/jb' or facts['root'].startswith('/private/preboot') else 'roothide'
        root = f'{facts["root"]} ({layout}, as the ssh shell sees it)'
    say(f'{Style.bold("Root      ")}{root}; data {facts["data"]}')
    build = installed_build(target, facts)
    local = subprocess.run(['git', '-C', str(ROOT), 'rev-list', '--count', 'HEAD'], capture_output=True, text=True).stdout.strip()
    version = facts['packages'].get(BUNDLE_ID, '?')
    # A local build's number is the commit count (make print-build-number).
    same = Style.ok('  (this checkout)') if build == local else Style.warn(f'  (this checkout builds {local})')
    say(f'{Style.bold("Apelin    ")}{version}, build {build or "?"}{same if build and local else ""}; '
        f'app {"running" if facts["appRunning"] else "not running"}')
    interesting = [(package, v) for package, v in sorted(facts['packages'].items())
                   if package.startswith('wiki.qaq.apelin.') or package in ('wiki.qaq.irisin', 'ellekit', 'wiki.qaq.icli')
                   or package.startswith('local.apelin.') or package == 'com.example.apelin-smoke']
    say(f'{Style.bold("Packages  ")}' + (', '.join(f'{p} {v}' for p, v in interesting) or 'none beside Apelin'))
    daemon = target.text(r'''
launchctl print system/wiki.qaq.apelind 2>/dev/null | awk -F' = ' '/^\t(state|pid) = /{printf "%s %s ", $1, $2}' | tr -d '\t'
pid=$(cat "$JB/var/lib/apelin/session.pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null && echo "session-host $pid"
''', root=True, check=False)
    say(f'{Style.bold("Daemon    ")}{" ".join(daemon.split()) or "not running (it starts on demand)"}')
    toolchains = ', '.join(t.get('id', '?')[:12] for t in facts['toolchains']) or 'none'
    say(f'{Style.bold("Toolchain ")}{toolchains}')
    say(f'{Style.bold("SDKs      ")}{", ".join(facts["sdks"]) or "none registered"}'
        + (f'; inbox: {", ".join(facts["inbox"])}' if facts['inbox'] else ''))
    say(f'{Style.bold("Projects  ")}{", ".join(facts["projects"]) or "none"}')
    console = facts['console']
    say(f'{Style.bold("Console   ")}inbox {console.get("inbox", 0)}, running {console.get("running", 0)}, '
        f'done {console.get("done", 0)}, runs {console.get("out", 0)}')
    if facts['orphanSDKs']:
        say(Style.warn(f'warning   SDKs/{", SDKs/".join(facts["orphanSDKs"])} has no record: apelin-environment deletes it '
                       'when it starts. Move it to inbox/iPhoneOS.sdk to import it.'))
    if facts['running']:
        say(Style.warn(f'warning   a run is left in console/running/: {", ".join(facts["running"])}'))
    return 0


def installed_build(target, facts):
    if not facts.get('app'):
        return None
    try:
        data = target.run(f'cat {shlex.quote(facts["app"] + "/Info.plist")}', timeout=30)
        return str(plistlib.loads(data).get('CFBundleVersion', ''))
    except (HarnessError, plistlib.InvalidFileException, ValueError):
        return None


def command_run(target, arguments):
    arguments.explicit = True
    return run_scripts(target, arguments.scripts, arguments)


def command_suite(target, arguments):
    suites = load_manifest().get('suites', {})
    if arguments.suite not in suites:
        raise HarnessError(f'no suite {arguments.suite}; there are {", ".join(suites)}')
    arguments.explicit = False
    return run_scripts(target, suites[arguments.suite], arguments)


def command_call(target, arguments):
    try:
        request = json.loads(arguments.request) if arguments.request else {}
    except json.JSONDecodeError as error:
        raise HarnessError(f'the request is not JSON: {error}')
    step = {'op': arguments.op, 'request': request, 'label': 'call'}
    if arguments.follow is not None:
        step['follow'] = arguments.follow
    folder = RESULTS / '.calls'
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f'call-{arguments.op}.json'
    path.write_text(json.dumps({'name': f'call {arguments.op}', 'steps': [step]}))
    arguments.explicit = True
    run = Run(target, f'call {arguments.op}', path, {}, arguments)
    run.execute()
    events = [l['event'] for l in run.lines if l.get('type') == 'step.event']
    for line in run.lines:
        if line.get('type') == 'step.result':
            shown = line.get('response') if line.get('ok') else line.get('error')
            say(json.dumps(shown, indent=2, ensure_ascii=False))
            if events:
                note(f'{len(events)} event(s); the last:')
                say(json.dumps(events[-1], indent=2, ensure_ascii=False))
    return 0 if run.status == 'PASS' else 1


def command_list(target, arguments):
    manifest = load_manifest()
    entries = manifest.get('scripts', {})
    membership = {}
    for suite, members in manifest.get('suites', {}).items():
        if suite == 'regression':
            continue
        for member in members:
            membership.setdefault(member, []).append(suite)
    facts = target.gather() if target else None
    for name in script_names():
        entry = entries.get(name, {})
        needs = entry.get('needs', [])
        state = ''
        if entry.get('manual'):
            state = Style.warn('manual')
        elif facts is not None:
            unmet = unmet_needs(needs, facts)
            state = Style.ok('ready') if not unmet else Style.warn('needs ' + ', '.join(unmet))
        suites = ','.join(membership.get(name, []))
        say(f'  {name:<24} {Style.dim(f"{suites:<24}")} {state or Style.dim(", ".join(needs))}')
    say()
    for suite, members in manifest.get('suites', {}).items():
        say(f'  {Style.bold(f"{suite:<12}")} {" ".join(members)}')
    return 0


def command_out(target, arguments):
    target.require_apelin()
    if arguments.run:
        run_id = arguments.run
    else:
        listing = target.text('cd "$DATA/console/out" 2>/dev/null && ls -t | head -n ' + str(arguments.last)).split()
        for name in listing:
            head = target.text(f'head -c 4096 "$DATA/console/out/{name}"; echo; tail -n 1 "$DATA/console/out/{name}"')
            script = re.search(r'"script":"([^"]*)"', head)
            ended = re.search(r'"type":"run.end"', head)
            ok = re.search(r'"ok":(true|false),"runID":"[^"]*","time":"[^"]*","type":"run.end"', head)
            state = Style.ok('ok') if ok and ok.group(1) == 'true' else Style.bad('failed') if ended else Style.warn('unfinished')
            say(f'  {name[:-6]}  {state:<10}  {script.group(1) if script else "?"}')
        return 0
    raw = target.run(f'cat "$DATA/console/out/{run_id}.jsonl"')
    if arguments.raw:
        sys.stdout.write(raw.decode(errors='replace'))
        return 0
    viewer = Run.__new__(Run)
    viewer.steps, viewer.lines, viewer.failure, viewer.status, viewer.reason = [], [], None, None, None
    viewer.options, viewer.quarters = argparse.Namespace(verbose=arguments.verbose), {}
    for line in raw.splitlines():
        if line.strip():
            viewer.take(line)
    say(Style.ok('ok') if viewer.ended() and viewer.status is None else Style.bad(viewer.reason or 'unfinished'))
    return 0


def command_open(target, arguments):
    target.require_apelin()
    target.open_app(fresh=arguments.fresh)
    say('opened' if target.app_running() else Style.bad('the app is not running after the launch'))
    return 0


def command_kill_host(target, arguments):
    target.require_apelin()
    old, new = target.kill_session_host()
    say(f'killed the session host {old}; ' + (f'the proxy started {new}' if new else 'no new one yet (it starts again when it has work)'))
    return 0


def command_exec(target, arguments):
    words = arguments.words[1:] if arguments.words[:1] == ['--'] else arguments.words
    if not words:
        raise HarnessError('usage: device.py exec [--root] -- <command>')
    target.gather()
    command = ' '.join(words)
    completed = target.run(command, root=arguments.root, check=False, timeout=arguments.timeout)
    sys.stdout.write(completed.stdout.decode(errors='replace'))
    sys.stderr.write(completed.stderr.decode(errors='replace'))
    return completed.returncode


def command_shell(target, arguments):
    return target.interactive(root=arguments.root)


def command_install(target, arguments):
    facts = target.gather()
    arch = facts['arch'] or 'iphoneos-arm64e'
    chosen = [Path(deb).resolve() for deb in arguments.debs]
    if arguments.all:
        arguments.extensions = arguments.agent_tools = True
    if not arguments.debs or arguments.app:
        apps = sorted(PACKAGES.glob(f'{BUNDLE_ID}_*_{arch}.deb'), key=lambda path: path.stat().st_mtime)
        if not apps:
            raise HarnessError(f'no {BUNDLE_ID}_*_{arch}.deb in build/Packages/: run `make deb-{"roothide" if arch.endswith("e") else "rootless"}` first')
        chosen.insert(0, apps[-1])
    if arguments.extensions:
        chosen += sorted(PACKAGES.glob(f'{BUNDLE_ID}.dev.*_{arch}.deb'))
    if arguments.agent_tools:
        chosen += sorted(PACKAGES.glob(f'{BUNDLE_ID}.agent-tools.*_{arch}.deb'))
    if not chosen:
        raise HarnessError('nothing to install')
    chosen = list(dict.fromkeys(chosen))
    app = [deb for deb in chosen if deb.name.startswith(f'{BUNDLE_ID}_')]
    others = []
    for deb in chosen:
        if deb in app:
            continue
        missing = missing_depends(deb, set(facts['packages']) | facts['provides'], {path.name for path in chosen})
        if missing:
            warn(f'skipping {deb.name}: it depends on {", ".join(missing)}, which the device does not have '
                 '(install it with your preferred package manager)')
        else:
            others.append(deb)
    # Apelin first: every extension depends on it at its own version.
    for deb in app:
        environment = dict(os.environ, DEVICE_HOST=target.host, DEVICE_PORT=str(target.port),
                           DEVICE_USER=target.user, DEVICE_PASSWORD=target.password)
        status = subprocess.call([str(INSTALLER), str(deb)] + ([] if arguments.no_launch else ['--launch']), env=environment)
        if status:
            return status
    if others:
        say(f'==> installing {", ".join(deb.name for deb in others)}')
        target.run('rm -rf /tmp/.apelin-harness-debs && mkdir -p /tmp/.apelin-harness-debs')
        for deb in others:
            target.run(f'cat > /tmp/.apelin-harness-debs/{shlex.quote(deb.name)}', stdin=deb.read_bytes(), timeout=600)
        # Irisin's installer, never apt or dpkg
        installed = target.run('irisin-cli install --yes /tmp/.apelin-harness-debs/*.deb 2>&1; status=$?; rm -rf /tmp/.apelin-harness-debs; exit $status',
                               root=True, check=False, timeout=600)
        if installed.returncode:
            for line in installed.stdout.decode(errors='replace').splitlines():
                note(f'    {line}')
            raise HarnessError(f'irisin-cli install exited {installed.returncode} (above)')
    return 0


def missing_depends(deb, installed, alongside):
    """What `deb` depends on that neither the device nor the debs beside it
    provide; a .deb installed from a file resolves nothing. Versions are not compared."""
    try:
        fields = subprocess.run(['dpkg-deb', '-f', str(deb), 'Package', 'Depends'], capture_output=True, text=True,
                                check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    depends = next((line.split(':', 1)[1] for line in fields.splitlines() if line.startswith('Depends:')), '')
    beside = {name.split('_', 1)[0] for name in alongside}
    missing = []
    for clause in filter(None, (part.strip() for part in depends.split(','))):
        names = [re.split(r'[\s(:]', option.strip(), maxsplit=1)[0] for option in clause.split('|')]
        if names == ['firmware']:
            continue
        if not any(name in installed or name in beside for name in names):
            missing.append(clause)
    return missing


def command_crashes(target, arguments):
    target.gather()
    folder = '$( [ -d /rootfs/private/var/mobile/Library/Logs/CrashReporter ] && echo /rootfs/private/var/mobile/Library/Logs/CrashReporter || echo /private/var/mobile/Library/Logs/CrashReporter )'
    pattern = '|'.join(re.escape(prefix) for prefix in CRASH_PREFIXES)
    listing = target.text(f'dir={folder}; cd "$dir" && ls -t 2>/dev/null | grep -E "^({pattern})" | head -n {arguments.last}',
                          root=True, check=False)
    names = listing.split()
    if not names:
        say('no crash reports from Apelin, apelind, its workers, or the kernel')
        return 0
    destination = target.results_folder / 'crashes'
    for name in names:
        line = f'  {name}'
        if arguments.pull:
            destination.mkdir(parents=True, exist_ok=True)
            data = target.run(f'dir={folder}; cat "$dir/{name}"', root=True)
            (destination / name).write_bytes(data)
            line += Style.dim(f'  → {(destination / name).relative_to(ROOT)}')
        say(line)
    if not arguments.pull:
        note('pass --pull to copy them to the Mac; symbolicate against the dSYM of that build (AGENTS.md ▸ A crash is read first)')
    return 0


def command_screenshot(target, arguments):
    if not target.machine:
        raise HarnessError('screenshots come from vphone-launchpad; this target is not a known vphone')
    result = guest_rpc(target.machine, 'screen.screenshot', timeout=60) or {}
    encoded = result.get('image') or result.get('data') or result.get('base64') or result.get('jpeg')
    if not encoded:
        raise HarnessError('the guest answered no image')
    folder = target.results_folder
    folder.mkdir(parents=True, exist_ok=True)
    path = Path(arguments.output) if arguments.output else folder / f'screen-{datetime.datetime.now():%Y%m%d-%H%M%S}.jpg'
    path.write_bytes(base64.b64decode(encoded))
    say(str(path))
    return 0


def command_logs(target, arguments):
    if not target.machine:
        raise HarnessError('a bounded log capture comes from vphone-launchpad; this target is not a known vphone')
    parameters = {'seconds': arguments.seconds, 'max_lines': arguments.lines}
    if arguments.process:
        parameters['process'] = arguments.process
    result = guest_rpc(target.machine, 'logs.syslog', parameters, timeout=arguments.seconds + 30) or {}
    lines = result.get('lines') or result.get('entries') or []
    for line in lines:
        say(line if isinstance(line, str) else compact(line, 400))
    if not lines:
        note('nothing logged in that window')
    return 0


def command_address(target, arguments):
    print(target.host)
    return 0


def command_lint(_, arguments):
    problems = lint()
    for problem in problems:
        print(f'error: Documents/Console/device-harness.json: {problem}', file=sys.stderr)
    if not problems:
        print(f'ok: device-harness.json covers the {len(script_names())} scripts in Documents/Console/scripts/')
    return 1 if problems else 0


# MARK: Arguments


def main():
    parser = argparse.ArgumentParser(
        prog='device.py',
        description='Drive Apelin on a vphone or a device: run console scripts and suites, install, inspect.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''examples:
  device.py status                    what is installed, registered and running
  device.py suite smoke               the quick suite; `device.py list` shows them all
  device.py run i1-smoke terminal     scripts by name, or a path to any script
  device.py call toolchainStatus      one operation, its response printed
  device.py install --all             the built packages from build/Packages/
  device.py out                       the latest runs on the device''')
    parser.add_argument('--machine', help='a vphone by name (or VPHONE)')
    parser.add_argument('--host', help='a vphone or device on port 22 (or VPHONE_HOST)')
    commands = parser.add_subparsers(dest='command', required=True)

    def runner(sub):
        sub.add_argument('-v', '--verbose', action='store_true', help='every event and expect, not just the outline')
        sub.add_argument('--timeout', type=float, help='seconds a script may run (default: its entry, else 900)')
        sub.add_argument('--keep', action='store_true', help="skip each script's cleanup")
        sub.add_argument('--no-setup', action='store_true', help='skip setup, checks and cleanup: drop the script as it is')
        sub.add_argument('--force', action='store_true', help='run whatever the device lacks')
        sub.add_argument('--stop', action='store_true', help='stop at the first failure')
        sub.add_argument('--poll', type=float, default=0.5, help=argparse.SUPPRESS)

    sub = commands.add_parser('status', help='what is installed, registered and running')
    sub.set_defaults(handler=command_status)
    sub = commands.add_parser('run', help='run console scripts by name or path')
    sub.add_argument('scripts', nargs='+')
    runner(sub)
    sub.set_defaults(handler=command_run)
    sub = commands.add_parser('suite', help='run a suite from device-harness.json')
    sub.add_argument('suite', nargs='?', default='smoke')
    runner(sub)
    sub.set_defaults(handler=command_suite)
    sub = commands.add_parser('call', help='one operation; prints its response')
    sub.add_argument('op')
    sub.add_argument('request', nargs='?', help='the request as JSON')
    sub.add_argument('--follow', dest='follow', action='store_true', default=None)
    sub.add_argument('--no-follow', dest='follow', action='store_false')
    runner(sub)
    sub.set_defaults(handler=command_call)
    sub = commands.add_parser('list', help='the scripts, their needs and suites (--check: against the device)')
    sub.add_argument('--check', action='store_true')
    sub.set_defaults(handler=command_list)
    sub = commands.add_parser('out', help='the latest runs on the device, or one run')
    sub.add_argument('run', nargs='?', help='a runID')
    sub.add_argument('--last', type=int, default=10)
    sub.add_argument('--raw', action='store_true')
    sub.add_argument('-v', '--verbose', action='store_true')
    sub.set_defaults(handler=command_out)
    sub = commands.add_parser('install', help='install the built packages over ssh')
    sub.add_argument('debs', nargs='*')
    sub.add_argument('--app', action='store_true', help='Apelin too when debs are named')
    sub.add_argument('--extensions', action='store_true', help='the development extensions')
    sub.add_argument('--agent-tools', action='store_true', help='the agent tool extensions')
    sub.add_argument('--all', action='store_true', help='Apelin and every extension')
    sub.add_argument('--no-launch', action='store_true')
    sub.set_defaults(handler=command_install)
    sub = commands.add_parser('open', help='bring Apelin to the front (it reads its inbox)')
    sub.add_argument('--fresh', action='store_true', help='quit it first, so the launch reads the inbox')
    sub.set_defaults(handler=command_open)
    sub = commands.add_parser('kill-host', help="kill the session host by its pid, as a resume test does")
    sub.set_defaults(handler=command_kill_host)
    sub = commands.add_parser('exec', help='run a command (DATA and JB are set)')
    sub.add_argument('--root', action='store_true')
    sub.add_argument('--timeout', type=float, default=300)
    sub.add_argument('words', nargs=argparse.REMAINDER, metavar='command')
    sub.set_defaults(handler=command_exec)
    sub = commands.add_parser('shell', help='an interactive shell')
    sub.add_argument('--root', action='store_true')
    sub.set_defaults(handler=command_shell)
    sub = commands.add_parser('crashes', help="Apelin's crash reports and kernel panics")
    sub.add_argument('--pull', action='store_true', help='copy them to build/Device/<target>/crashes/')
    sub.add_argument('--last', type=int, default=10)
    sub.set_defaults(handler=command_crashes)
    sub = commands.add_parser('screenshot', help="the vphone's screen, to build/Device/<target>/")
    sub.add_argument('-o', '--output')
    sub.set_defaults(handler=command_screenshot)
    sub = commands.add_parser('logs', help="a bounded capture of the vphone's log")
    sub.add_argument('--seconds', type=int, default=10)
    sub.add_argument('--process', help='apelind, Apelin, apelin-build, …')
    sub.add_argument('--lines', type=int, default=500)
    sub.set_defaults(handler=command_logs)
    sub = commands.add_parser('address', help='print the target\'s address (for make vphone)')
    sub.set_defaults(handler=command_address)
    sub = commands.add_parser('lint', help='check device-harness.json against the scripts (make check)')
    sub.set_defaults(handler=command_lint)

    arguments = parser.parse_args()
    try:
        offline = arguments.command == 'lint' or (arguments.command == 'list' and not arguments.check)
        target = None if offline else Target.resolve(arguments)
        return arguments.handler(target, arguments)
    except HarnessError as error:
        print(Style.bad(f'error: {error}'), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == '__main__':
    sys.exit(main())
