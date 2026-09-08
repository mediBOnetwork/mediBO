#!/usr/bin/env python3
"""CHANGE #327 LAYER 1 — shard lib/screens/home_shell.dart into part files.

Mechanical and reversible: the file's text is CUT at declaration boundaries and
pasted, byte for byte, into `lib/screens/shell/*.dart` parts of the same
library. Part files share the library's imports AND its privacy scope, so the
~40 library-private widgets stay private and not one reference anywhere in the
repo changes. The script refuses to write unless the concatenation of what it
produced is identical to what it consumed.
"""
import os, re, sys

SRC = 'lib/screens/home_shell.dart'
OUT = 'lib/screens/shell'

# (part filename, first top-level declaration that belongs to it, blurb)
SPLITS = [
    ('shell_mobile_chrome.dart', '_LocationHeader',
     'Mobile chrome: the location header, the profile avatar, the cart icon, '
     'the search bar and the category chips.'),
    ('shell_cart_panel.dart', 'CartPanel',
     'The slide-in cart panel and its clear-cart confirmation.'),
    ('shell_login_panel.dart', 'LoginPanel',
     'The slide-in login panel: sign-in, OTP reset and the new-password step.'),
    ('shell_bottom_bars.dart', '_MobileBottomBar',
     'The bars that live at the bottom of the viewport: the mobile nav bar, the '
     'sticky cart bar and its desktop floating twin.'),
    ('shell_header_chrome.dart', '_DesktopHeader',
     'Desktop header, search row and the profile buttons on both breakpoints.'),
    ('shell_admin_chrome.dart', '_AdminDesktopHeader',
     'The admin chrome: the desktop admin header, the admin bottom bar and its '
     'nav item.'),
    ('shell_sidebar.dart', '_DesktopCategorySidebar',
     'The desktop category sidebar, its rows and the desktop nav link.'),
    ('shell_view_as.dart', '_FadingIndexedStack',
     'The page-swap animation and the whole view-as surface: the banner and the '
     'customer / company / delivery-partner previews.'),
]

DECL = re.compile(r'^(?:abstract\s+|sealed\s+|final\s+|base\s+)*(?:class|mixin|enum|extension)\s+([A-Za-z_][A-Za-z0-9_]*)')

def start_of(lines, i):
    """Walk back over the declaration's own doc comment / annotations."""
    j = i
    while j > 0:
        prev = lines[j - 1].rstrip()
        if prev.startswith('///') or prev.startswith('//') or prev.startswith('@'):
            j -= 1
        else:
            break
    return j

def main():
    src = open(SRC).read()
    lines = src.split('\n')

    index = {}
    for n, ln in enumerate(lines):
        m = DECL.match(ln)
        if m and m.group(1) not in index:
            index[m.group(1)] = n

    cuts = []
    for fname, anchor, blurb in SPLITS:
        if anchor not in index:
            sys.exit(f'shard: anchor {anchor} not found — home_shell.dart has moved on; re-read it')
        cuts.append((start_of(lines, index[anchor]), fname, blurb))
    cuts.sort()
    if [c[0] for c in cuts] != sorted(c[0] for c in cuts):
        sys.exit('shard: anchors are not in file order')

    head = lines[:cuts[0][0]]
    bodies = []
    for k, (at, fname, blurb) in enumerate(cuts):
        end = cuts[k + 1][0] if k + 1 < len(cuts) else len(lines)
        bodies.append((fname, blurb, lines[at:end]))

    # Nothing may be lost: head + every body must rebuild the original exactly.
    rebuilt = '\n'.join(head + [l for _, _, b in bodies for l in b])
    if rebuilt != src:
        sys.exit('shard: refusing to write — the cut is not lossless')

    os.makedirs(OUT, exist_ok=True)
    for fname, blurb, body in bodies:
        header = (
            f"part of '../home_shell.dart';\n"
            f"\n"
            f"// CHANGE #327 · LAYER 1 — sharded out of home_shell.dart.\n"
            f"//\n"
            f"// {blurb}\n"
            f"//\n"
            f"// It is a `part`, not a new library, on purpose: nearly every widget in\n"
            f"// the shell is library-private and used by the others, so extracting them\n"
            f"// into real libraries would force ~40 classes public and rewrite every\n"
            f"// reference. A part shares the library's imports and its privacy scope, so\n"
            f"// this is a pure move — and it gives this concern its own leasable path, so\n"
            f"// a cart command and a login command stop fighting over one file.\n"
        )
        text = header + '\n'.join(body).rstrip('\n') + '\n'
        open(os.path.join(OUT, fname), 'w').write(text)

    parts = '\n'.join(f"part 'shell/{f}';" for f, _, _ in bodies)
    lead = (
        "\n// CHANGE #327 · LAYER 1 — the shell is sharded.\n"
        "//\n"
        "// This file was 5,139 lines holding boot, routing, the mobile and desktop\n"
        "// chrome, the cart panel, the login panel, the admin chrome and the view-as\n"
        "// previews — nine concerns in one path. That is why a partner-routing fix\n"
        "// (#326) and a dashboard rebuild (#325) collided on it and one of them sat\n"
        "// parked mid-build, polling the lease 97 times in six minutes.\n"
        "//\n"
        "// What is left here is the shell itself: boot, routing and the two layouts.\n"
        "// Every other concern is a part below, with its own path and its own lease.\n"
        + parts + "\n"
    )
    # `part` directives live in the DIRECTIVE section — after the last import,
    # before the first declaration. Anywhere else is a compile error.
    last_import = max(i for i, l in enumerate(head)
                      if l.startswith('import ') or l.startswith('export '))
    head = head[:last_import + 1] + lead.split('\n') + head[last_import + 1:]
    new_head = '\n'.join(head).rstrip('\n') + '\n'
    open(SRC, 'w').write(new_head)
    print(f'sharded {len(bodies)} parts; home_shell.dart {len(lines)} -> {len(new_head.split(chr(10)))} lines')

main()
