#!/usr/bin/env python3
"""Plain local controls for the independent judge-change signal."""
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUBJECT = ROOT / 'scripts/check_gate_integrity.py'
GIT = shutil.which('git')
ZERO = '0' * 40


class Fixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='gate-integrity-control-')
        self.root = pathlib.Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0')
        self.git('init', '-q')
        self.git('symbolic-ref', 'HEAD', 'refs/heads/main')
        self.write('scripts/check_public_surface.sh', '#!/bin/sh\ntrue\n')
        self.write('scripts/public-gate.sh', '#!/bin/sh\ntrue\n')
        self.write('.github/workflows/ci.yml', 'name: Synthetic\n')
        self.write('docs/events.md', 'Synthetic documentation.\n')
        self.base = self.commit()
        self.remote = self.root / 'remote.git'
        self.git('init', '--bare', '-q', str(self.remote))
        self.git('remote', 'add', 'origin', str(self.remote))
        self.git('push', '-q', 'origin', 'HEAD:refs/heads/main')

    def git(self, *args):
        return subprocess.check_output([GIT, *args], cwd=self.repo,
                                       env=self.env, stderr=subprocess.PIPE).decode().strip()

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self):
        self.git('add', '-A')
        self.git('-c', 'user.name=Synthetic', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'Synthetic gate-integrity control')
        return self.git('rev-parse', 'HEAD')

    def run(self, base=None, head=None, program=SUBJECT, **overrides):
        env = dict(self.env, EVENT_NAME='pull_request', EVENT_DELETED='false',
                   HEAD_SHA=head or self.git('rev-parse', 'HEAD'),
                   PR_BASE_SHA=base or self.base, PUSH_BEFORE=self.base,
                   DEFAULT_BRANCH='main')
        env.update(overrides)
        return subprocess.run([sys.executable, str(program)], cwd=self.repo,
                              env=env, text=True, capture_output=True, timeout=60)


def assert_result(run, expected):
    assert run.returncode == expected, 'expected exit {}, got {}: {}'.format(
        expected, run.returncode, run.stdout + run.stderr)
    if expected == 1:
        assert 'alters the gate that judges it' in run.stderr
        assert 'a change may not supply its own judge\n' in run.stderr
    if expected == 2:
        assert 'STRUCTURAL REFUSAL:' in run.stderr
        assert 'a change may not supply its own judge' not in run.stderr


def scenario(fixture, name, program=SUBJECT):
    f = fixture
    options = {}
    expected = 1
    if name == 'helper':
        f.write('scripts/helpers/new.inc', 'synthetic_helper() { :; }\n')
        f.write('scripts/public-gate.sh', '. scripts/helpers/new.inc\n')
        for path in ['scripts/helpers/new.inc', 'scripts/public-gate.sh']:
            subprocess.run(['bash', '-n', str(f.repo / path)], check=True)
        adopted = f.commit()
        f.write('scripts/helpers/new.inc', 'synthetic_helper() { return 1; }\n')
        f.commit()
        options['base'] = adopted
    elif name == 'workflow':
        f.write('.github/workflows/ci.yml', 'name: Changed synthetic workflow\n')
        f.commit()
    elif name == 'deleted-helper':
        (f.repo / 'scripts/public-gate.sh').unlink()
        f.commit()
    elif name == 'pr-base':
        f.write('scripts/public-gate.sh', '# Synthetic target-branch judge change.\n')
        options['base'] = f.commit()
        f.write('docs/events.md', 'Synthetic PR documentation change.\n')
        f.commit()
        expected = 0
    elif name in ('push', 'new-ref'):
        f.write('scripts/public-gate.sh', '# Synthetic judge change.\n')
        f.commit()
        options['EVENT_NAME'] = 'push'
        if name == 'push':
            f.git('push', '-q', 'origin', 'HEAD:refs/heads/main')
        else:
            options['PUSH_BEFORE'] = ZERO
    elif name == 'empty':
        shutil.rmtree(f.repo / 'scripts')
        shutil.rmtree(f.repo / '.github')
        f.commit()
        expected = 2
    elif name == 'identity':
        f.write('docs/events.md', 'Synthetic newer tree.\n')
        f.commit()
        options['head'] = f.base
        expected = 2
    elif name == 'deletion':
        options['EVENT_DELETED'] = 'true'
        expected = 2
    elif name == 'unknown':
        options['EVENT_NAME'] = 'unknown'
        expected = 2
    else:
        raise AssertionError('unknown control')
    run = f.run(program=program, **options)
    assert_result(run, expected)
    if name == 'helper':
        paths = [json.loads(line) for line in run.stderr.splitlines() if line.startswith('"')]
        assert paths == ['scripts/helpers/new.inc'], paths
    return options, expected


class GateIntegrityTests(unittest.TestCase):
    def test_existing_workflow_control(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('  static:\n', workflow)
        self.assertIn('run: ./scripts/test_lane_b_ratchet.sh', workflow)

    def test_workflow_wires_independent_job(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        match = re.search(r'^  gate-integrity:\n(?P<body>(?:\n| {4}[^\n]*\n)+)',
                          workflow, re.MULTILINE)
        self.assertIsNotNone(match, 'current workflow has no independent gate-integrity job')
        job = match.group('body')
        self.assertIn('run: python3 scripts/check_gate_integrity.py', job)
        self.assertIn('a change may not supply its own judge', job)
        self.assertIn('alters the gate that judges it', job)
        self.assertIn('run: python3 scripts/test_gate_integrity.py', workflow)

    def test_documentation_only_and_unchanged_controls(self):
        f = Fixture()
        self.addCleanup(f.temp.cleanup)
        assert_result(f.run(), 0)
        f.write('docs/events.md', 'Synthetic documentation-only change.\n')
        f.commit()
        assert_result(f.run(), 0)

    def test_real_subject_scenarios(self):
        for name in ['helper', 'workflow', 'deleted-helper', 'pr-base', 'push',
                     'new-ref', 'empty', 'identity', 'deletion', 'unknown']:
            with self.subTest(name=name):
                f = Fixture()
                try:
                    scenario(f, name)
                finally:
                    f.temp.cleanup()

    def test_mode_rename_and_unusual_path(self):
        for change in ['mode', 'rename', 'unusual']:
            with self.subTest(change=change):
                f = Fixture()
                try:
                    if change == 'mode':
                        (f.repo / 'scripts/public-gate.sh').chmod(0o755)
                    elif change == 'rename':
                        (f.repo / 'scripts/public-gate.sh').rename(f.repo / 'moved.sh')
                    else:
                        f.write('scripts/helpers/space and\nnewline.inc', 'synthetic\n')
                    f.commit()
                    assert_result(f.run(), 1)
                finally:
                    f.temp.cleanup()

    def test_invalid_event_inputs_and_failed_fetch(self):
        f = Fixture()
        self.addCleanup(f.temp.cleanup)
        for overrides in [{'PR_BASE_SHA': ''}, {'PR_BASE_SHA': 'f' * 40},
                          {'HEAD_SHA': ''}, {'EVENT_NAME': 'push', 'PUSH_BEFORE': ''},
                          {'EVENT_DELETED': ''}, {'PR_BASE_SHA': '--help'}]:
            with self.subTest(overrides=overrides):
                assert_result(f.run(**overrides), 2)
        f.git('remote', 'remove', 'origin')
        assert_result(f.run(EVENT_NAME='push', PUSH_BEFORE=ZERO), 2)

    def test_failed_census_read_is_structural(self):
        f = Fixture()
        self.addCleanup(f.temp.cleanup)
        shim = f.root / 'bin'
        shim.mkdir()
        marker = f.root / 'read-fault-fired'
        script = shim / 'git'
        script.write_text('#!/bin/sh\nif [ "$1" = ls-tree ]; then\n  : > ' +
                          shlex.quote(str(marker)) + '\n  exit 73\nfi\nexec ' +
                          shlex.quote(GIT) + ' "$@"\n')
        script.chmod(0o755)
        subprocess.run(['bash', '-n', str(script)], check=True)
        assert_result(f.run(PATH=str(shim) + os.pathsep + os.environ['PATH']), 2)
        self.assertTrue(marker.is_file(), 'the injected read failure did not fire')

    def test_named_mutants(self):
        source = SUBJECT.read_text()
        mutants = [
            ('M_FROZEN_JUDGE_POPULATION', 'helper', 'def census(rev):\n',
             'def census(rev):\n    rev = {base!r}\n'),
            ('M_WORKFLOW_OMITTED', 'workflow', "'scripts/', '.github/workflows/'", "'scripts/'"),
            ('M_BASE_POPULATION_DROPPED', 'deleted-helper', 'judges = before | after', 'judges = after'),
            ('M_PR_CHARGES_TRUNK_DEBT', 'pr-base',
             "base = commit(env.get('PR_BASE_SHA', ''), 'PR base')",
             "base = git('rev-parse', 'refs/remotes/origin/main').decode().strip()"),
            ('M_EXISTING_PUSH_COMPARES_SELF', 'push', "base = commit(before, 'pre-push tip')", 'base = head'),
            ('M_NEW_REF_COMPARES_SELF', 'new-ref',
             "base = git('merge-base', head, trunk).decode().strip()", 'base = head'),
            ('M_EMPTY_POPULATION_IS_ELIGIBLE', 'empty', 'if not before or not after:', 'if False:'),
            ('M_HEAD_IDENTITY_SKIPPED', 'identity',
             "if git('rev-parse', 'HEAD').decode().strip() != head:", 'if False:'),
            ('M_DELETION_ALLOWED', 'deletion', "if env.get('EVENT_DELETED') != 'false':", 'if False:'),
            ('M_STRUCTURAL_IS_EXPECTED_RED', 'unknown', '        return 2\n', '        return 1\n'),
        ]
        for name, control, old, new in mutants:
            with self.subTest(mutant=name):
                f = Fixture()
                try:
                    self.assertEqual(source.count(old), 1, 'mutation did not identify one site')
                    mutated = source.replace(old, new.replace('{base!r}', repr(f.base)), 1)
                    self.assertNotEqual(mutated, source)
                    compile(mutated, name, 'exec')
                    program = f.root / 'mutant.py'
                    program.write_text(mutated)
                    # Establish the scene on the real subject, then apply the
                    # compiled mutant to those exact commits and event inputs.
                    options, expected = scenario(f, control)
                    with self.assertRaisesRegex(AssertionError, 'expected exit'):
                        assert_result(f.run(program=program, **options), expected)
                    assert_result(f.run(**options), expected)
                    print(name + ': applied, compiled, KILLED at ' + control + '; restored PASS', flush=True)
                finally:
                    f.temp.cleanup()
        self.assertEqual(SUBJECT.read_text(), source, 'the real subject was not restored')


if __name__ == '__main__':
    unittest.main(verbosity=2)
