#!/usr/bin/env python3
"""Source-level selection interleaving regressions, without a mobile SDK.

Evaluate the production completion predicates against deterministic deferred-read
scenarios. This verifies the guard/reset contract, not Kotlin/Swift compilation,
Compose/SwiftUI rendering, or PhotoKit/MediaStore behavior.
"""
import argparse
from pathlib import Path
import re
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
args, remaining = parser.parse_known_args()
ANDROID = args.root / 'clients/android/app/src/main/java/org/sarmg/xszc/LocalGridScreen.kt'
IOS = args.root / 'clients/ios/Xszc/LocalGalleryScreen.swift'


def block(source, marker):
    start = source.index('{', source.index(marker)) + 1
    depth = 1
    for index in range(start, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index]
    raise AssertionError(f'Unclosed function: {marker}')


class SourceContract:
    def __init__(self, platform):
        self.platform = platform
        self.source = (ANDROID if platform == 'android' else IOS).read_text()
        self.open = block(self.source, 'fun openEntry' if platform == 'android' else 'func openEntry')
        self.bulk = block(self.source, 'fun selectScope' if platform == 'android' else 'func selectScope')
        marker = 'fun resetSelection' if platform == 'android' else 'func resetSelection'
        self.reset = block(self.source, marker) if marker in self.source else ''
        self.toggle = block(self.source, 'fun toggle' if platform == 'android' else 'func toggle')

    def allows(self, kind, *, reset=False, reenter=False, filter_changed=False, toggle=False):
        # All reads start with selection active and the default query. Suspend at
        # the detail-read await, apply a user event, then evaluate its real guard.
        epoch = 'selectionGeneration' if kind == 'bulk' else 'entryGeneration'
        generation = 0
        current = int(reset and epoch in self.reset) + int(toggle and epoch in self.toggle)
        body = self.bulk if kind == 'bulk' else self.open
        local_query = ('profile', None, None, False)
        namespace = dict(generation=generation, selectionGeneration=current,
                         entryGeneration=current, selecting=not reset or reenter,
                         isSelecting=not reset or reenter, query=local_query,
                         profile='profile', identity='profile', album=None,
                         kind='video' if filter_changed else None, unbacked=False,
                         LocalGalleryQuery=lambda *a, **k: tuple(a) if a else tuple(k.values()))
        if self.platform == 'android':
            if kind == 'bulk':
                predicate = re.search(r'if \(([^\n]+)\) selection = selection \+ chosen', body).group(1)
                rejected = False
            else:
                match = re.search(r'if \(([^\n]+)\) return@launch', body)
                if not match:
                    return True
                predicate = match.group(1)
                rejected = True
            predicate = predicate.replace('&&', ' and ').replace('||', ' or ')
        else:
            if kind == 'bulk':
                # Skip the pre-read guard; select the guard after detached work.
                predicate = re.findall(r'guard (.*?) else \{ return \}', body, re.S)[-1]
            else:
                predicate = re.search(r'guard (.*?) else \{ return \}', body, re.S).group(1)
            predicate = predicate.replace('coordinator.profile', 'profile')
            predicate = re.sub(r'LocalGalleryQuery\(profile: (.*?), album: (.*?), kind: (.*?), unbacked: (.*?)\)',
                               r'LocalGalleryQuery(\1, \2, \3, \4)', predicate)
            # Swift guard commas are AND, while constructor commas separate args.
            depth = 0
            translated = []
            for char in predicate:
                if char == '(':
                    depth += 1
                elif char == ')':
                    depth -= 1
                translated.append(' and ' if char == ',' and depth == 0 else char)
            predicate = ' '.join(''.join(translated).split())
            rejected = False
        result = bool(eval(predicate, {'__builtins__': {}}, namespace))
        return not result if rejected else result


    def allows_preview(self, request, current, selecting=False):
        if self.platform == 'android':
            match = re.search(r'else if \((previewRequest == [^\n]+)\) setPreview\(row\)', self.open)
            predicate = match.group(1).replace('&&', ' and ').replace('!selecting', 'not selecting') if match else 'True'
        else:
            match = re.search(r'guard (previewRequest == .*?) else \{ return \}', self.open)
            predicate = match.group(1).replace(', ', ' and ').replace('!isSelecting', 'not selecting') if match else 'True'
        return bool(eval(predicate, {'__builtins__': {}}, dict(
            previewRequest=request, previewGeneration=current, selecting=selecting)))


    def allows_failure(self, kind, *, reset=False, filter_changed=False, older_preview=False, select=False):
        body = self.bulk if kind == 'bulk' else self.open
        if self.platform == 'android':
            failure = block(body, 'catch (e: Exception)')
            match = re.search(r'if \((.*?)\) notice =', failure, re.S)
        else:
            failure = block(body, '} catch {')
            match = (re.search(r'if (.*?) \{\s*message =', failure, re.S) if kind == 'bulk'
                     else re.search(r'guard (.*?) else \{ return \}', failure, re.S))
        if not match:
            return True
        predicate = match.group(1).replace('coordinator.profile', 'profile')
        predicate = re.sub(r'LocalGalleryQuery\(profile: (.*?), album: (.*?), kind: (.*?), unbacked: (.*?)\)',
                           r'LocalGalleryQuery(\1, \2, \3, \4)', predicate)
        if self.platform == 'ios':
            depth = 0
            translated = []
            for char in predicate:
                if char == '(':
                    depth += 1
                elif char == ')':
                    depth -= 1
                translated.append(') and (' if char == ',' and depth == 0 else char)
            predicate = '(' + ''.join(translated) + ')'
        predicate = ' '.join(predicate.replace('&&', ' and ').replace('||', ' or ')
                             .replace('!isSelecting', 'not isSelecting').replace('!selecting', 'not selecting').split())
        namespace = dict(generation=0, selectionGeneration=int(reset), entryGeneration=int(reset),
                         query=('profile', None, None, False), profile='profile', identity='profile',
                         album=None, kind='video' if filter_changed else None, unbacked=False,
                         selecting=(select if self.platform == 'ios' and kind == 'entry' else not reset),
                         isSelecting=not reset if kind == 'bulk' or select else False, select=select,
                         previewRequest=1, previewGeneration=2 if older_preview else 1,
                         LocalGalleryQuery=lambda *a: tuple(a))
        if self.platform == 'android' and kind == 'entry':
            namespace['selecting'] = select and not reset
        return bool(eval(predicate, {'__builtins__': {}}, namespace))


class SelectionRegressionTests(unittest.TestCase):
    def test_android_bulk_cancel_does_not_repopulate_hidden_selection(self):
        self.assertFalse(SourceContract('android').allows('bulk', reset=True))

    def test_android_bulk_cancel_then_reenter_does_not_restore_old_selection(self):
        self.assertFalse(SourceContract('android').allows('bulk', reset=True, reenter=True))

    def test_android_bulk_new_individual_choice_wins(self):
        self.assertFalse(SourceContract('android').allows('bulk', toggle=True))

    def test_bulk_unchanged_selection_and_filters_continue(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertTrue(SourceContract(platform).allows('bulk'))

    def test_entry_cancel_does_not_reenter_selection(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertFalse(SourceContract(platform).allows('entry', reset=True))

    def test_entry_cancel_then_reenter_rejects_old_read(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertFalse(SourceContract(platform).allows('entry', reset=True, reenter=True))

    def test_entry_filter_change_rejects_old_read(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertFalse(SourceContract(platform).allows('entry', filter_changed=True))

    def test_entry_normal_and_parallel_individual_choices_continue(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                contract = SourceContract(platform)
                self.assertTrue(contract.allows('entry'))
                self.assertTrue(contract.allows('entry', toggle=True))

    def test_preview_b_wins_when_a_completes_later(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                contract = SourceContract(platform)
                self.assertTrue(contract.allows_preview(request=2, current=2))
                self.assertFalse(contract.allows_preview(request=1, current=2))

    def test_preview_a_cannot_flash_after_b_was_requested(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertFalse(SourceContract(platform).allows_preview(request=1, current=2))

    def test_close_prevents_deferred_preview_from_reopening(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                contract = SourceContract(platform)
                marker = 'fun setPreview' if platform == 'android' else 'func setPreview'
                self.assertTrue(marker in contract.source, 'Preview close must invalidate requests')
                close = block(contract.source, marker)
                self.assertTrue('previewGeneration' in close)
                self.assertFalse(contract.allows_preview(request=2, current=3))
                if platform == 'ios':
                    self.assertTrue('previewGeneration' in block(contract.source, 'func setVideoPreview'))
                    self.assertTrue('set: { setVideoPreview($0) }' in contract.source)

    def test_entering_selection_prevents_deferred_preview_from_opening(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertFalse(SourceContract(platform).allows_preview(request=1, current=1, selecting=True))

    def test_only_preview_requests_advance_preview_request_generation(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                contract = SourceContract(platform)
                increment = 'if (!select) previewGeneration++' if platform == 'android' else 'if !selecting { previewGeneration += 1 }'
                self.assertTrue(increment in contract.open)
                self.assertTrue('previewGeneration' not in contract.toggle)
                self.assertTrue(contract.open.index(increment) < contract.open.index('details.resolve'))

    def test_canceled_bulk_failure_is_not_displayed(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertFalse(SourceContract(platform).allows_failure('bulk', reset=True))

    def test_canceled_entry_failure_is_not_displayed(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertFalse(SourceContract(platform).allows_failure('entry', reset=True, select=True))

    def test_old_filter_entry_failure_is_not_displayed(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertFalse(SourceContract(platform).allows_failure('entry', filter_changed=True, select=True))

    def test_superseded_preview_failure_is_not_displayed(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                self.assertFalse(SourceContract(platform).allows_failure('entry', older_preview=True))

    def test_current_failures_remain_visible(self):
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                contract = SourceContract(platform)
                self.assertTrue(contract.allows_failure('bulk'))
                self.assertTrue(contract.allows_failure('entry', select=True))
                self.assertTrue(contract.allows_failure('entry'))

    def test_android_cancel_and_submission_use_reset(self):
        source = SourceContract('android').source
        self.assertTrue('onClick = { resetSelection() }, modifier = Modifier.testTag("gallery.cancel")' in source, 'Cancel must invalidate pending selection')
        self.assertTrue('resetSelection(); onSubmitted()' in source, 'Successful submission must reset pending selection')

    def test_ios_navigation_and_filter_changes_invalidate_pending_entries(self):
        source = SourceContract('ios').source
        self.assertTrue('.onDisappear { entryGeneration += 1; selectionGeneration += 1; details.stop() }' in source, 'Leaving the gallery must invalidate pending reads')
        self.assertIn('entryGeneration += 1', block(source, 'func filtersChanged'))


if __name__ == '__main__':
    unittest.main(argv=[__file__, *remaining])
