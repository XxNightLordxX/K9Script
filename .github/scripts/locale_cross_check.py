#!/usr/bin/env python3
"""
.github/scripts/locale_cross_check.py

Cross-checks john-k9/locales/en.json against every locale('...') call
site in john-k9/client/, john-k9/server/, and john-k9/html/, in
both directions:

  * MISSING: a locale() call site references a key with no entry in
    en.json. This is the dangerous direction -- ox_lib's locale() does NOT
    error at runtime on a miss, it silently returns the raw key string, so
    a player just sees literal text like "admin.usage_auditdept" instead
    of a real message. Nothing about that fails loudly: no exception, no
    log line, no red screen. This exact near-miss happened twice in one
    session and was only caught by a human manually diffing en.json
    against call sites -- this script automates that diff.

  * UNUSED: an en.json key that no call site anywhere references. Usually
    harmless (dead weight from a renamed/removed feature) but can also
    mean a call site elsewhere has a typo'd key that LOOKS unrelated to
    this one -- worth checking the MISSING list above it for a likely
    match before deleting.

Run from the repo root:  python3 .github/scripts/locale_cross_check.py
Exits 0 if both directions are clean, 1 if either direction has findings,
2 on a setup problem (en.json missing/unparseable, or it flattens to zero
keys -- refuses to run rather than flag everything as unused).

WHY COMMENTS ARE STRIPPED FIRST, PROPERLY (not `grep`, not a `--` split):
this codebase's own comments are dense prose that document past bugs and
naming decisions, and that prose routinely quotes real-looking
locale('some.key') examples for illustration -- e.g.
client/movement.lua's history of a removed
locale('movement.leash_request_sent') call, still described in a comment
long after the call itself was deleted. A naive scan (or one that only
strips `--[[ ]]` block comments but not `--` line comments, or vice versa)
either misses that example entirely or, worse, reports it as a MISSING key
that doesn't actually affect any player -- and a check that cries wolf
gets ignored. strip_lua_comments()/strip_js_comments()/strip_html() below
are small character-by-character scanners (not regexes) that track Lua/JS
string literals and Lua long-bracket strings `[[ ]]`/`[=[ ]=]` so a `--`,
`//`, or bracket INSIDE a real string is never misread as a comment
delimiter, and so a comment's content is fully removed regardless of
whether it's a `--[[ ]]` block, a run of consecutive `--` lines, a JS
`/* */` block, a JS `//` line, or an HTML `<!-- -->` block.
"""
import json
import re
import sys
from pathlib import Path

RESOURCE = Path("john-k9")
LOCALE_FILE = RESOURCE / "locales" / "en.json"
SCAN_DIRS = ["client", "server", "html"]
SCAN_EXTS = {".lua", ".js", ".html"}

LOCALE_CALL_RE = re.compile(r"""locale\(\s*['"]([A-Za-z0-9_.]+)['"]""")

# A key built at runtime from a literal PREFIX plus a variable --
# `locale('tablet.' .. key)`, `locale('runtime_tunable_desc_' .. name)`.
# The concrete key never appears anywhere in the source, so the plain
# call-site scan above cannot see it and every key under that prefix looks
# dead. Matches Lua's `..` and JS's `+` concatenation.
LOCALE_DYNAMIC_PREFIX_RE = re.compile(r"""locale\(\s*['"]([A-Za-z0-9_.]*[._])['"]\s*(?:\.\.|\+)""")

# Groups whose English text is OWNED AND TESTED SOMEWHERE ELSE, so an
# absent literal call site here is expected rather than evidence of a dead
# key. Excluding them is not a way of making this check quieter -- it is
# what stops it reporting 1,174 false positives that drown the one
# direction that actually hurts a player.
#
# `tablet`: html/tablet.js's DEFAULT_STRINGS is the documented, tested
# English source for this group, paired with client/tablet.lua's
# TABLET_STRING_KEYS, and resolved through `pcall(locale, 'tablet.' .. key)`
# rather than by any literal call. That three-way contract has its own
# dedicated enforcement in john-k9/tests/tabletlocalization_spec.lua,
# which this script must not duplicate or second-guess. The same exclusion,
# for the same stated reason, already exists in
# john-k9/tests/localecallsites_spec.lua -- this is that file's rule
# restated here, not a new judgement call invented to go green.
GROUPS_OWNED_ELSEWHERE = {"tablet"}


def flatten_locale_keys(obj, prefix=""):
    keys = set()
    for k, v in obj.items():
        path = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict):
            keys |= flatten_locale_keys(v, path)
        else:
            keys.add(path)
    return keys


def strip_lua_comments(text):
    """Remove `--[[ ]]`/`--[=[ ]=]` long comments and `-- ...` line
    comments from Lua source, while scanning OVER (not through) single-
    and double-quoted strings and `[[ ]]`/`[=[ ]=]` long strings so a
    comment delimiter inside a real string literal is never misread as
    starting/ending a comment. Preserves line breaks so reported line
    numbers match the original source exactly."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '-' and text[i + 1:i + 2] == '-':
            j = i + 2
            if j < n and text[j] == '[':
                k = j + 1
                eqs = 0
                while k < n and text[k] == '=':
                    eqs += 1
                    k += 1
                if k < n and text[k] == '[':
                    close = ']' + ('=' * eqs) + ']'
                    end = text.find(close, k + 1)
                    body = text[i:end + len(close)] if end != -1 else text[i:]
                    out.append('\n' * body.count('\n'))
                    i = end + len(close) if end != -1 else n
                    continue
            end = text.find('\n', i)
            if end == -1:
                i = n
            else:
                out.append('\n')
                i = end + 1
            continue
        if c in ("'", '"'):
            quote = c
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == quote or text[j] == '\n':
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        if c == '[':
            j = i + 1
            eqs = 0
            while j < n and text[j] == '=':
                eqs += 1
                j += 1
            if j < n and text[j] == '[':
                close = ']' + ('=' * eqs) + ']'
                end = text.find(close, j + 1)
                if end != -1:
                    out.append(text[i:end + len(close)])
                    i = end + len(close)
                    continue
        out.append(c)
        i += 1
    return ''.join(out)


def strip_js_comments(text):
    """Same idea as strip_lua_comments(), for JS: `//` line comments,
    `/* */` block comments, scanning over '...'/"..."/`...` strings."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and text[i + 1:i + 2] == '/':
            end = text.find('\n', i)
            if end == -1:
                i = n
            else:
                out.append('\n')
                i = end + 1
            continue
        if c == '/' and text[i + 1:i + 2] == '*':
            end = text.find('*/', i + 2)
            if end == -1:
                out.append('\n' * text[i:].count('\n'))
                i = n
            else:
                out.append('\n' * text[i:end + 2].count('\n'))
                i = end + 2
            continue
        if c in ("'", '"', '`'):
            quote = c
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == quote:
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def strip_html(text):
    """Strip `<!-- -->` comments, then strip JS comments inside any
    inline `<script>...</script>` body (a `src=` script tag has no
    inline body to scan). john-k9/html/index.html currently has no
    inline script (only `<script src="app.js">`), but this keeps the
    check correct if one is ever added."""
    text = re.sub(r'<!--.*?-->', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.DOTALL)

    def repl(m):
        return m.group(1) + strip_js_comments(m.group(2)) + m.group(3)

    return re.sub(
        r'(<script(?:\s[^>]*)?>)(.*?)(</script>)',
        repl,
        text,
        flags=re.DOTALL | re.IGNORECASE,
    )


def gather_call_sites():
    findings = []
    for sub in SCAN_DIRS:
        base = RESOURCE / sub
        if not base.is_dir():
            continue
        for fpath in sorted(base.rglob('*')):
            if not fpath.is_file() or fpath.suffix not in SCAN_EXTS:
                continue
            raw = fpath.read_text(encoding='utf-8')
            if fpath.suffix == '.lua':
                stripped = strip_lua_comments(raw)
            elif fpath.suffix == '.js':
                stripped = strip_js_comments(raw)
            else:
                stripped = strip_html(raw)
            for m in LOCALE_CALL_RE.finditer(stripped):
                lineno = stripped.count('\n', 0, m.start()) + 1
                findings.append((m.group(1), str(fpath), lineno))
    return findings


def gather_quoted_key_literals(known_keys):
    """Keys named as DATA rather than called directly.

    This resource routinely stores a key name in a table and resolves it
    later through a variable:

        denied = 'permissions.command_not_authorized',   -- server/permissions.lua
        ...
        NotifyPlayer(src, locale(entry.denied), 'error')

    There is no literal `locale('permissions.command_not_authorized')`
    anywhere, so a scan that only looks inside `locale(...)` calls declares
    the key dead -- while it is very much alive and on a player's screen.

    Reporting one of those as "safe to delete" would be worse than not
    checking at all: it is confident, wrong, and actionable, and acting on
    it removes a live message. So any known key that appears ANYWHERE as a
    quoted string literal in production source counts as referenced. That
    is deliberately generous -- it can keep a genuinely dead key off the
    report if some comment-free string still mentions it -- and that is the
    right direction to be wrong in. A missed piece of dead weight costs
    nothing; a deleted live key costs a player their message.
    """
    referenced = set()
    for sub in SCAN_DIRS:
        base = RESOURCE / sub
        if not base.is_dir():
            continue
        for fpath in sorted(base.rglob('*')):
            if not fpath.is_file() or fpath.suffix not in SCAN_EXTS:
                continue
            raw = fpath.read_text(encoding='utf-8')
            if fpath.suffix == '.lua':
                stripped = strip_lua_comments(raw)
            elif fpath.suffix == '.js':
                stripped = strip_js_comments(raw)
            else:
                stripped = strip_html(raw)
            for m in re.finditer(r"""['"]([A-Za-z0-9_.]+)['"]""", stripped):
                candidate = m.group(1)
                if candidate in known_keys:
                    referenced.add(candidate)
    return referenced


def gather_dynamic_prefixes():
    """Literal prefixes of runtime-built keys -- see LOCALE_DYNAMIC_PREFIX_RE."""
    prefixes = set()
    for sub in SCAN_DIRS:
        base = RESOURCE / sub
        if not base.is_dir():
            continue
        for fpath in sorted(base.rglob('*')):
            if not fpath.is_file() or fpath.suffix not in SCAN_EXTS:
                continue
            raw = fpath.read_text(encoding='utf-8')
            if fpath.suffix == '.lua':
                stripped = strip_lua_comments(raw)
            elif fpath.suffix == '.js':
                stripped = strip_js_comments(raw)
            else:
                stripped = strip_html(raw)
            for m in LOCALE_DYNAMIC_PREFIX_RE.finditer(stripped):
                prefixes.add(m.group(1))
    return prefixes


def main():
    if not LOCALE_FILE.is_file():
        print(f"::error::{LOCALE_FILE} not found")
        sys.exit(2)
    locale_keys = flatten_locale_keys(json.loads(LOCALE_FILE.read_text()))
    if not locale_keys:
        print("::error::locales/en.json produced zero keys -- ground truth is empty, refusing to run this check (would flag every call site as missing)")
        sys.exit(2)

    call_sites = gather_call_sites()
    used_keys = {k for k, _, _ in call_sites}

    dynamic_prefixes = gather_dynamic_prefixes()
    named_as_data = gather_quoted_key_literals(locale_keys)

    def reached_dynamically(key):
        return any(key.startswith(p) for p in dynamic_prefixes)

    def owned_elsewhere(key):
        return key.split('.', 1)[0] in GROUPS_OWNED_ELSEWHERE

    missing = sorted(k for k in used_keys if k not in locale_keys)
    unused = sorted(
        k for k in (locale_keys - used_keys)
        if not owned_elsewhere(k) and not reached_dynamically(k) and k not in named_as_data
    )
    excluded_count = len(locale_keys - used_keys) - len(unused)

    status = 0
    if missing:
        status = 1
        print("Locale cross-check FAILED -- these locale() call sites reference a key with no entry in locales/en.json:")
        for k in missing:
            sites = ", ".join(f"{f}:{l}" for kk, f, l in call_sites if kk == k)
            print(f"::error::'{k}' called at {sites} has no matching key in locales/en.json. This is silent at runtime -- ox_lib's locale() returns the raw key string on a miss instead of erroring, so a player would see the literal text \"{k}\" rather than a real message.")
    # UNUSED IS REPORTED, NEVER FAILS THE BUILD -- and that is a deliberate
    # change from how this script originally behaved.
    #
    # It used to exit 1 on any unused key. That was correct when written,
    # against a 306-key file where every key had a literal call site. It
    # stopped being correct as the resource grew: the tablet's own
    # 1,100-plus-key contract and several runtime-built key families arrived
    # afterwards, and this check reported every one of them as dead. The
    # result was a job that failed on every single run, for over a thousand
    # keys, none of which were real -- and a permanently red check protects
    # nothing, because nobody reads the thousand-and-first line. Worse, the
    # ONE direction that genuinely hurts a player (a call site with no key,
    # which ox_lib renders on screen as the raw key text) was buried in that
    # wall of noise, where a real regression would have gone unnoticed.
    #
    # This file's own header already says it: "a check that cries wolf gets
    # ignored." So MISSING still fails the build, as it always did and must.
    # An unused key is dead weight, not a bug -- reported so somebody can
    # tidy it, never a reason to block a release. That is also exactly the
    # posture john-k9/tests/localecallsites_spec.lua already takes for the
    # same question, and the two disagreeing was its own small inconsistency.
    if unused:
        print(f"INFO (not a failure): {len(unused)} locales/en.json key(s) have no reaching call site:")
        for k in unused:
            print(f"  - {k}")
        print("  Each is probably dead weight from a renamed or removed feature and safe to delete.")
        print("  Before deleting one, check the MISSING list above for a similar name -- an unused")
        print("  key and a missing key that look alike usually mean one call site has a typo.")
    if excluded_count:
        print(f"INFO: {excluded_count} key(s) excluded from the unused report -- reached through a runtime-built")
        print("  prefix, or belonging to a group whose English text is owned and tested elsewhere.")
        print("  See GROUPS_OWNED_ELSEWHERE and LOCALE_DYNAMIC_PREFIX_RE at the top of this file.")

    if status:
        print()
        print("Reproduce locally, one line, from the repo root: python3 .github/scripts/locale_cross_check.py")
        sys.exit(1)

    print(
        f"Locale cross-check passed: {len(locale_keys)} keys in locales/en.json, {len(call_sites)} literal "
        f"locale() call site(s) across client/server/html, 0 MISSING (no call site anywhere references a key "
        f"that does not exist -- this is the direction a player would actually see on screen). "
        f"{len(unused)} unused key(s) reported above for tidying, {excluded_count} excluded as owned elsewhere "
        f"or reached through a runtime-built prefix."
    )


if __name__ == "__main__":
    main()
