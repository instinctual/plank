#!/usr/bin/env python3
"""Dispatch reviewed Host source from a trusted default-branch PR command.

Never check out or execute PR code, accept build arguments from comments, or
handle Apple credentials. The existing environment-protected build owns signing.
"""
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = 'instinctual/plank'
REPOSITORY_ID = 1369459741
COMMAND = '/build-macos-host'
REQUESTERS = frozenset((65196962, 625982))  # cnoellert and the project owner.
WORKFLOW = 'build.yml'
ROOT = Path(__file__).resolve().parents[2]


class Rejected(Exception):
    """A safe, fixed explanation for an authorized requester."""


class APIError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise APIError('Unexpected GitHub API redirect; no credentials forwarded.')


class GitHub:
    def __init__(self, token):
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def __call__(self, method, path, body=None):
        assert path.startswith('/') and '://' not in path
        request = urllib.request.Request(
            'https://api.github.com/repos/' + REPOSITORY + path,
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={'Authorization': 'Bearer ' + self.token,
                     'Accept': 'application/vnd.github+json',
                     'Content-Type': 'application/json',
                     'X-GitHub-Api-Version': '2026-03-10'})
        try:
            with self.opener.open(request, timeout=20) as response:
                data = response.read(2 * 1024 * 1024 + 1)
        except urllib.error.HTTPError as error:
            raise APIError(f'GitHub API request failed (HTTP {error.code}).') from None
        except (OSError, urllib.error.URLError):
            raise APIError('GitHub API request failed; check the workflow run before retrying.') from None
        if len(data) > 2 * 1024 * 1024:
            raise APIError('GitHub API response exceeded the expected size.')
        try:
            return json.loads(data) if data else {}
        except (ValueError, UnicodeDecodeError):
            raise APIError('GitHub API returned an invalid response.') from None


def eligible(event, context):
    """Unrecognized users/events do not receive any token-backed side effect."""
    comment = event.get('comment', {})
    issue = event.get('issue', {})
    user = comment.get('user', {})
    sender = event.get('sender', {})
    return (context.get('GITHUB_EVENT_NAME') == 'issue_comment'
            and context.get('GITHUB_REPOSITORY') == REPOSITORY
            and context.get('GITHUB_REF') == 'refs/heads/main'
            and context.get('GITHUB_RUN_ATTEMPT') == '1'
            and event.get('action') == 'created'
            and event.get('repository', {}).get('id') == REPOSITORY_ID
            and event.get('repository', {}).get('full_name') == REPOSITORY
            and event.get('repository', {}).get('default_branch') == 'main'
            and user.get('id') in REQUESTERS and user.get('type') == 'User'
            and sender.get('id') == user.get('id') and sender.get('type') == 'User'
            and context.get('GITHUB_ACTOR_ID') == str(user.get('id'))
            and type(issue.get('number')) is int and issue['number'] > 0
            and bool(issue.get('pull_request'))
            and type(comment.get('id')) is int and comment['id'] > 0
            and comment.get('body') == COMMAND)


def approved_request(event, registry, api):
    number = event['issue']['number']
    if registry.get('schema_version') != 1:
        raise Rejected('The maintainer approval file is invalid.')
    approval = registry.get('pull_requests', {}).get(str(number))
    if not isinstance(approval, dict):
        raise Rejected('This PR has no approved signed Host candidate yet.')
    branch, source, pr_head = (approval.get(key, '') for key in ('branch', 'source_sha', 'pr_head_sha'))
    if (not all(isinstance(value, str) for value in (branch, source, pr_head))
            or not re.fullmatch(r'macos-host-test(?:-[a-z0-9-]+)?', branch)
            or not re.fullmatch(r'[0-9a-f]{40}', source)
            or not re.fullmatch(r'[0-9a-f]{40}', pr_head)
            or type(approval.get('head_repository_id')) is not int
            or type(approval.get('author_id')) is not int):
        raise Rejected('The maintainer approval entry is invalid.')

    # Recheck the live comment: an edited or deleted command is not authorization.
    comment = api('GET', f"/issues/comments/{event['comment']['id']}")
    if (comment.get('id') != event['comment']['id'] or comment.get('body') != COMMAND
            or comment.get('user', {}).get('id') != event['sender']['id']
            or comment.get('user', {}).get('type') != 'User'
            or not comment.get('created_at')
            or comment.get('updated_at') != comment.get('created_at')
            or comment.get('issue_url') != f'https://api.github.com/repos/{REPOSITORY}/issues/{number}'):
        raise Rejected('The command changed. Post a new /build-macos-host comment.')

    pr = api('GET', f'/pulls/{number}')
    if (pr.get('number') != number or pr.get('state') != 'open'
            or pr.get('base', {}).get('repo', {}).get('id') != REPOSITORY_ID
            or pr.get('base', {}).get('ref') != 'main'
            or pr.get('user', {}).get('id') != approval['author_id']
            or (pr.get('head', {}).get('repo') or {}).get('id') != approval['head_repository_id']):
        raise Rejected('The PR is closed or no longer matches its approval.')
    if pr.get('head', {}).get('sha') != pr_head:
        raise Rejected('The PR has changed since review. A maintainer must approve the new revision first.')
    ref = api('GET', '/git/ref/heads/' + branch)
    if (ref.get('ref') != 'refs/heads/' + branch or ref.get('object', {}).get('type') != 'commit'
            or ref.get('object', {}).get('sha') != source):
        raise Rejected('The test branch moved. A maintainer must update its exact-commit approval first.')

    query = urllib.parse.urlencode({'branch': branch, 'event': 'workflow_dispatch',
                                    'head_sha': source, 'per_page': 100})
    runs = api('GET', '/actions/workflows/' + WORKFLOW + '/runs?' + query)
    for run in runs.get('workflow_runs', []):
        if (run.get('head_branch') == branch and run.get('head_sha') == source
                and run.get('event') == 'workflow_dispatch' and run.get('status') != 'completed'
                and type(run.get('id')) is int and run['id'] > 0):
            return f'An approved build is already running: https://github.com/{REPOSITORY}/actions/runs/{run["id"]} . No duplicate was started.'

    result = api('POST', '/actions/workflows/' + WORKFLOW + '/dispatches', {
        'ref': branch,
        'inputs': {'product': 'macos-host', 'signed': 'true', 'source_sha': source,
                   'macos_host_min_os': '26.7', 'clean_bootstrap': 'false'}})
    run_id = result.get('workflow_run_id')
    url = (f'https://github.com/{REPOSITORY}/actions/runs/{run_id}' if type(run_id) is int and run_id > 0
           else f'https://github.com/{REPOSITORY}/actions/workflows/{WORKFLOW}?query=branch%3A{branch}')
    return (f'Signed macOS Host test build requested from `{branch}` at `{source}`.\n\n'
            f'[Build status and candidate PKG]({url}). Download the signed artifact after the run succeeds. '
            'This does not publish a release or merge the PR.')


def handle(event, context, registry, api):
    if not eligible(event, context):
        return 'Ignored: not an authorized new build command. Post a new comment instead of rerunning this request job.'
    try:
        message = approved_request(event, registry, api)
    except Rejected as error:
        message = 'Build not started: ' + str(error)
    number = event['issue']['number']
    comment_id = event['comment']['id']
    api('POST', f'/issues/{number}/comments', {
        'body': f'[Build request](https://github.com/{REPOSITORY}/pull/{number}#issuecomment-{comment_id}):\n\n{message}'})
    return message


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    registry = json.loads((ROOT / '.github/macos-host-test-approvals.json').read_text())
    message = handle(event, os.environ, registry, GitHub(os.environ['GITHUB_TOKEN']))
    print(message)
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(message + '\n')


if __name__ == '__main__':
    try:
        main()
    except (APIError, OSError, ValueError, KeyError) as error:
        print(str(error) if isinstance(error, APIError) else 'Build request failed: invalid local workflow state.', file=sys.stderr)
        sys.exit(1)
