import copy
import importlib.util
import json
from pathlib import Path
import unittest
import urllib.error
from unittest.mock import MagicMock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('macos_requests', ROOT / 'scripts/ci/request-macos-host-build.py')
requests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(requests)


class BuildRequestTests(unittest.TestCase):
    def setUp(self):
        self.context = dict(GITHUB_EVENT_NAME='issue_comment', GITHUB_REPOSITORY='instinctual/plank',
                            GITHUB_REF='refs/heads/main', GITHUB_RUN_ATTEMPT='1', GITHUB_ACTOR_ID='65196962')
        self.event = {
            'action': 'created',
            'repository': {'id': 1369459741, 'full_name': 'instinctual/plank', 'default_branch': 'main'},
            'issue': {'number': 33, 'pull_request': {'url': 'https://api.github.com/repos/instinctual/plank/pulls/33'}},
            'comment': {'id': 100, 'body': '/build-macos-host', 'user': {'id': 65196962, 'type': 'User'}},
            'sender': {'id': 65196962, 'type': 'User'},
        }
        self.registry = {'schema_version': 1, 'pull_requests': {'33': {
            'branch': 'macos-host-test', 'source_sha': 'a' * 40, 'pr_head_sha': 'b' * 40,
            'head_repository_id': 1373991422, 'author_id': 65196962}}}
        self.comment = dict(copy.deepcopy(self.event['comment']), created_at='2026-01-01T00:00:00Z',
                            updated_at='2026-01-01T00:00:00Z',
                            issue_url='https://api.github.com/repos/instinctual/plank/issues/33')
        self.pr = {'number': 33, 'state': 'open', 'user': {'id': 65196962},
                   'base': {'ref': 'main', 'repo': {'id': 1369459741}},
                   'head': {'sha': 'b' * 40, 'repo': {'id': 1373991422}}}
        self.ref = {'ref': 'refs/heads/macos-host-test', 'object': {'type': 'commit', 'sha': 'a' * 40}}
        self.runs = []
        self.dispatch_response = {'workflow_run_id': 123, 'html_url': 'https://untrusted.example/'}
        self.calls = []

    def api(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path == '/issues/comments/100':
            return self.comment
        if path == '/pulls/33':
            return self.pr
        if path == '/git/ref/heads/macos-host-test':
            return self.ref
        if path.startswith('/actions/workflows/build.yml/runs?'):
            return {'workflow_runs': self.runs}
        if method == 'POST' and path == '/actions/workflows/build.yml/dispatches':
            return self.dispatch_response
        if method == 'POST' and path == '/issues/33/comments':
            return {}
        self.fail(f'Unexpected API request: {method} {path}')

    def handle(self):
        return requests.handle(self.event, self.context, self.registry, self.api)

    def dispatches(self):
        return [call for call in self.calls if call[1].endswith('/dispatches')]

    def assert_rejected(self):
        self.assertIn('Build not started:', self.handle())
        self.assertFalse(self.dispatches())
        self.assertEqual(self.calls[-1][0:2], ('POST', '/issues/33/comments'))

    def test_reviewed_revision_uses_only_fixed_signed_host_inputs(self):
        message = self.handle()
        self.assertEqual(self.dispatches(), [('POST', '/actions/workflows/build.yml/dispatches', {
            'ref': 'macos-host-test', 'inputs': {'product': 'macos-host', 'signed': 'true',
                'source_sha': 'a' * 40, 'macos_host_min_os': '26.7', 'clean_bootstrap': 'false'}})])
        self.assertIn('https://github.com/instinctual/plank/actions/runs/123', message)
        self.assertNotIn('untrusted.example', message)
        self.assertIn('#issuecomment-100', self.calls[-1][2]['body'])

    def test_owner_can_exercise_the_same_path(self):
        self.event['sender']['id'] = self.event['comment']['user']['id'] = self.comment['user']['id'] = 625982
        self.context['GITHUB_ACTOR_ID'] = '625982'
        self.handle()
        self.assertEqual(len(self.dispatches()), 1)

    def test_untrusted_events_have_no_api_side_effects(self):
        cases = [
            (('sender', 'id'), 900), (('sender', 'type'), 'Bot'),
            (('comment', 'user', 'id'), 900), (('comment', 'user', 'type'), 'Bot'),
            (('comment', 'body'), '/build-macos-host main'), (('comment', 'body'), '/build-macos-host\n'),
            (('comment', 'id'), True), (('action',), 'edited'), (('action',), 'deleted'),
            (('repository', 'id'), 900), (('repository', 'full_name'), 'fork/plank'),
            (('repository', 'default_branch'), 'untrusted'), (('issue', 'number'), -1),
            (('issue', 'pull_request'), None),
        ]
        original = copy.deepcopy(self.event)
        for path, value in cases:
            with self.subTest(path=path, value=value):
                self.event = copy.deepcopy(original)
                target = self.event
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                self.assertIn('Ignored:', self.handle())
                self.assertFalse(self.calls)

    def test_wrong_workflow_context_or_rerun_has_no_side_effects(self):
        for key, value in [('GITHUB_EVENT_NAME', 'pull_request_target'), ('GITHUB_REPOSITORY', 'fork/plank'),
                           ('GITHUB_REF', 'refs/heads/macos-host-test'), ('GITHUB_RUN_ATTEMPT', '2'),
                           ('GITHUB_ACTOR_ID', '900')]:
            with self.subTest(key=key):
                context = dict(self.context, **{key: value})
                self.assertIn('Ignored:', requests.handle(self.event, context, self.registry, self.api))
                self.assertFalse(self.calls)

    def test_missing_or_invalid_approval_never_dispatches(self):
        valid = copy.deepcopy(self.registry)
        for key, value in [('branch', 'main'), ('branch', 'macos-host-test/other'), ('branch', None),
                           ('source_sha', 'a' * 39), ('pr_head_sha', 'main'), ('author_id', '65196962')]:
            with self.subTest(key=key, value=value):
                self.registry = copy.deepcopy(valid)
                self.registry['pull_requests']['33'][key] = value
                self.assert_rejected()
        self.registry = {'schema_version': 1, 'pull_requests': {}}
        self.assert_rejected()
        self.registry = {'schema_version': 2}
        self.assert_rejected()

    def test_changed_pr_requires_new_review(self):
        self.pr['head']['sha'] = 'c' * 40
        self.assert_rejected()

    def test_closed_retargeted_or_substituted_pr_requires_new_review(self):
        original = copy.deepcopy(self.pr)
        for path, value in [(('state',), 'closed'), (('base', 'ref'), 'other'),
                            (('base', 'repo', 'id'), 900), (('user', 'id'), 900),
                            (('head', 'repo'), None), (('head', 'repo', 'id'), 900)]:
            with self.subTest(path=path):
                self.pr = copy.deepcopy(original)
                target = self.pr
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                self.assert_rejected()

    def test_moved_test_branch_cannot_sign_new_code(self):
        self.ref['object']['sha'] = 'c' * 40
        self.assert_rejected()

    def test_comment_edit_or_substitution_cannot_dispatch(self):
        original = copy.deepcopy(self.comment)
        for key, value in [('body', '/build-macos-host main'), ('updated_at', '2026-01-01T00:00:01Z'),
                           ('id', 101), ('user', {'id': 900, 'type': 'User'}),
                           ('issue_url', 'https://api.github.com/repos/instinctual/plank/issues/34')]:
            with self.subTest(key=key):
                self.comment = dict(copy.deepcopy(original), **{key: value})
                self.assert_rejected()

    def test_active_matching_build_is_reused(self):
        for status in ('queued', 'in_progress', 'waiting'):
            with self.subTest(status=status):
                self.runs = [{'id': 456, 'head_sha': 'a' * 40, 'head_branch': 'macos-host-test',
                              'event': 'workflow_dispatch', 'status': status}]
                self.assertIn('/actions/runs/456', self.handle())
                self.assertFalse(self.dispatches())

    def test_completed_or_unrelated_build_does_not_suppress_request(self):
        self.runs = [{'id': 456, 'head_sha': 'a' * 40, 'head_branch': 'macos-host-test',
                      'event': 'workflow_dispatch', 'status': 'completed'},
                     {'id': 457, 'head_sha': 'c' * 40, 'head_branch': 'macos-host-test',
                      'event': 'workflow_dispatch', 'status': 'in_progress'}]
        self.handle()
        self.assertEqual(len(self.dispatches()), 1)

    def test_empty_dispatch_response_does_not_repeat_dispatch(self):
        self.dispatch_response = {}
        self.assertIn('/actions/workflows/build.yml?query=branch%3Amacos-host-test', self.handle())
        self.assertEqual(len(self.dispatches()), 1)

    def test_api_failure_never_retries_dispatch(self):
        def failure(method, path, body=None):
            result = self.api(method, path, body)
            if path.endswith('/dispatches'):
                raise requests.APIError('Request failed')
            return result
        with self.assertRaises(requests.APIError):
            requests.handle(self.event, self.context, self.registry, failure)
        self.assertEqual(len(self.dispatches()), 1)
        self.assertNotEqual(self.calls[-1][1], '/issues/33/comments')

    def test_http_errors_do_not_echo_response_or_token(self):
        api = requests.GitHub('fixture-token')
        api.opener = MagicMock()
        api.opener.open.side_effect = urllib.error.HTTPError('https://api.github.com/', 403,
                                                            'fixture-token', {}, None)
        with self.assertRaises(requests.APIError) as failure:
            api('POST', '/actions/workflows/build.yml/dispatches', {})
        self.assertNotIn('fixture-token', str(failure.exception))
        self.assertIn('403', str(failure.exception))

    def test_redirects_cannot_forward_credentials(self):
        with self.assertRaises(requests.APIError):
            requests.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://untrusted.example/')

    def test_workflow_uses_default_source_without_signing_secrets(self):
        workflow = (ROOT / '.github/workflows/request-macos-host-build.yml').read_text()
        self.assertIn('issue_comment:', workflow)
        self.assertIn('types: [created]', workflow)
        self.assertIn('ref: ${{ github.sha }}', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('cancel-in-progress: false', workflow)
        self.assertNotIn('pull_request_target:', workflow)
        self.assertNotIn('secrets.', workflow)
        self.assertNotIn('environment:', workflow)
        self.assertNotIn('github.event.pull_request.head', workflow)
        registry = json.loads((ROOT / '.github/macos-host-test-approvals.json').read_text())
        self.assertEqual(registry['schema_version'], 1)
        self.assertTrue(registry['pull_requests'])


if __name__ == '__main__':
    unittest.main()
