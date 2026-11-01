# Based on the WinUI-macOS system-theme audit at f2b79e2f6d7555252e6c0c978604184316830b07
#!/usr/bin/env python3
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
errors = []
checks = 0


def check(value, message):
    global checks
    checks += 1
    if not value:
        errors.append(message)


def ink_matches(ink, dark):
    return len(ink) == 4 and all(abs(value - int(dark)) < 0.01 for value in ink[:3])


states = 0
for scenario in ['general', 'search', 'preview']:
    for preference in ['system', 'light', 'dark']:
        rows = json.loads((root / f'final-{scenario}' / preference / 'results.json').read_text())
        states += len(rows)
        for row in rows:
            label = f'{scenario}/{preference}/{row["state"]}'
            app_dark = row['appAppearance'] == 'NSAppearanceNameDarkAqua'
            dark = preference == 'dark' or (preference == 'system' and app_dark)
            expected = 'NSAppearanceNameDarkAqua' if dark else 'NSAppearanceNameAqua'
            check(row['windowAppearance'] == expected, label + ' window')
            check(ink_matches(row['searchInk'], dark), label + ' search ink')
            check(row['searchIdentity'], label + ' search identity')
            check(all(ink_matches(c, app_dark) for c in row['rawFieldInks']), label + ' raw input system palette')
            for menu in row.get('menus', []):
                check(menu['appearance'] == expected, label + ' existing menu')
            if 'candidateAppearance' in row:
                check(row['candidateAppearance'] == expected, label + ' candidate')
                check(row['emojiAppearance'] == expected, label + ' emoji')
                check(ink_matches(row['emojiInk'], dark), label + ' emoji ink')
                check(row['candidateVisible'] and row['emojiVisible'], label + ' panels visible')
                check(row['emojiQuery'] == 'smile', label + ' query retained')
        if scenario == 'search':
            check(all(r['editorIdentity'] and r['marked'] for r in rows[:3]), preference + ' search editing retained')
        if scenario == 'preview':
            check(all(r['previewIdentity'] and r['previewFocused'] and r['previewMarked'] for r in rows[:3]), preference + ' preview editing retained')
            check(len({r['previewText'] for r in rows[:3]}) == 1, preference + ' preview text retained')
        panels = [r for r in rows if 'candidateChoices' in r]
        for key in ['candidateChoices', 'emojiItems']:
            check(len(panels) == 3 and bool(panels[0][key]) and all(r[key] == panels[0][key] for r in panels), f'{scenario}/{preference}/{key} identity')
        menus = [r['menus'] for r in rows if 'menus' in r]
        if scenario == 'general':
            check(len(menus) == 3 and all(len(m) == 1 for m in menus), preference + ' menu remains open')
            check(len({m[0]['identity'] for m in menus if m}) == 1, preference + ' menu identity')

gallery = []  # This application's audit covers the IME; Gallery belongs to FluentKit.
for row in gallery:
    label = f'Gallery/{row["page"]}/{row["dark"]}'
    check(all(row[key] == row['dark'] for key in ['coordinatorDark', 'storeDark', 'backgroundDark']), label + ' coordinator/store/background')
    check(bool(row['titleInks']) and all(ink_matches(c, row['dark']) for c in row['titleInks']), label + ' title')
    check(bool(row['controls']) and all(c['dark'] == row['dark'] for c in row['controls']), label + ' controls')

result = {'imeStates': states, 'galleryStates': len(gallery), 'checks': checks, 'errors': errors}
(root / 'checks.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
sys.exit(bool(errors))
