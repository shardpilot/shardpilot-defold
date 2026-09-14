#!/usr/bin/env python3
"""Signal judge changes; a branch-controlled workflow can still replace this job."""
import json
import os
import re
import subprocess
import sys

ZERO = '0' * 40


class Refusal(Exception):
    pass


def git(*args):
    try:
        result = subprocess.run(['git', *args], capture_output=True, timeout=50)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Refusal('Git operation unavailable: ' + args[0]) from error
    if result.returncode:
        raise Refusal('Git operation failed: ' + args[0])
    return result.stdout


def commit(value, label):
    if not re.fullmatch(r'[0-9a-fA-F]{40}', value) or value == ZERO:
        raise Refusal(label + ' is not an immutable commit identifier')
    try:
        git('cat-file', '-e', value + '^{commit}')
    except Refusal:
        # A force-push can make the old tip unreachable from normal refs.
        git('fetch', '--no-tags', '--quiet', 'origin', value)
    return git('rev-parse', '--verify', value + '^{commit}').decode().strip()


def event_pair(env):
    event = env.get('EVENT_NAME', '')
    if event not in ('pull_request', 'push'):
        raise Refusal('unsupported event')
    if env.get('EVENT_DELETED') != 'false':
        raise Refusal('deletion or missing deletion state: no new tree to judge')
    head = commit(env.get('HEAD_SHA', ''), 'head')
    if git('rev-parse', 'HEAD').decode().strip() != head:
        raise Refusal('checked-out commit differs from the event head')
    if event == 'pull_request':
        base = commit(env.get('PR_BASE_SHA', ''), 'PR base')
    else:
        before = env.get('PUSH_BEFORE', '')
        if before != ZERO:
            base = commit(before, 'pre-push tip')
        else:
            default = env.get('DEFAULT_BRANCH', '')
            ref = 'refs/heads/' + default
            git('check-ref-format', ref)
            git('fetch', '--no-tags', '--quiet', 'origin', ref)
            trunk = git('rev-parse', '--verify', 'FETCH_HEAD^{commit}').decode().strip()
            base = git('merge-base', head, trunk).decode().strip()
    return base, head


def census(rev):
    # Closed judge namespaces: include data, future helpers and complete
    # workflows. Do not turn this into an extension filter or a frozen roster.
    return set(filter(None, git('ls-tree', '-rz', '--name-only', rev, '--',
                                'scripts/', '.github/workflows/').split(b'\0')))


def compare(base, head):
    before, after = census(base), census(head)
    if not before or not after:
        raise Refusal('empty judge population')
    judges = before | after
    changed = set(filter(None, git('diff', '--no-ext-diff', '--no-renames',
                                   '--name-only', '-z', base, head, '--').split(b'\0')))
    return judges, judges & changed


def main():
    try:
        if len(sys.argv) != 1:
            raise Refusal('unexpected arguments; event inputs belong in env')
        base, head = event_pair(os.environ)
        judges, affected = compare(base, head)
    except Refusal as error:
        print('STRUCTURAL REFUSAL: ' + str(error), file=sys.stderr)
        return 2
    if not affected:
        print('Judge population unchanged: {} files; base {}; head {}.'.format(
            len(judges), base, head))
        return 0
    print('REFUSING: this change alters the gate that judges it.', file=sys.stderr)
    print('a change may not supply its own judge', file=sys.stderr)
    for path in sorted(affected):
        print(json.dumps(os.fsdecode(path), ensure_ascii=True), file=sys.stderr)
    print('Deliberate judge changes require the coordinator/owner ACK_RED_CHECK route; '
          'all other gates still apply.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
