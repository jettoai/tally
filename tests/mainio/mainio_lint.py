#!/usr/bin/env python3
"""Ratchet on blocking IO written directly in a main-thread context under Tally/.

usage: mainio_lint.py ROOT [--baseline FILE] [--allowlist FILE]   check, exit 1 on a new site
       mainio_lint.py ROOT --dump                                  print the current counts

A site counts when a line matches an API in io_api.txt and its innermost enclosing context runs
on the main thread: a @MainActor type (explicit, or a View/App/NSView family subclass, extensions
included), a @MainActor func, or a closure passed to MainActor.run / DispatchQueue.main /
`queue: .main` / Timer.scheduledTimer. `Task {}` inherits. A background closure (Task.detached,
a global or private queue, terminationHandler...) or a `nonisolated` func stops the count.

Sites are keyed by (file, Type.func, api category) with a count, so an unrelated edit that moves
line numbers does not turn anything red. Over the baseline plus the allowlist is red; under it is
green with a note that the baseline can come down.

Lexical approximation of Swift, not a type checker. Named blind spots: call chains (a sync helper
doing IO, called from the main thread, is not counted: only the direct site is), protocol
dispatch and function references, `nonisolated` helpers, macros, `#if` branches, and closure
shapes this brace tracker misreads.
"""
import os
import re
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))


def load_api(path):
    cats = []
    for raw in open(path, encoding='utf-8'):
        if raw.startswith('#') or not raw.strip():
            continue
        name, rx = raw.rstrip('\n').split('\t', 1)
        cats.append((name, re.compile(rx)))
    joined = '|'.join('(?P<c%d>%s)' % (i, rx.pattern) for i, (_, rx) in enumerate(cats))
    return re.compile(joined), [n for n, _ in cats]


def strip(src):
    """Blank comments and string contents, keeping newlines and length. '/usr/bin/security'
    survives inside a string because spawning it is the API being looked for."""
    out = list(src)
    i, n = 0, len(src)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = ' '
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            blank(i, j)
            i = j
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j < 0 else j + 3
            blank(i + 3, max(i + 3, j - 3))
            i = j
        elif src[i] == '"':
            j, depth = i + 1, 0
            while j < n:
                if src[j] == '\\' and j + 1 < n and src[j + 1] == '(':
                    depth += 1
                    j += 2
                    continue
                if depth and src[j] == ')':
                    depth -= 1
                    j += 1
                    continue
                if src[j] == '\\':
                    j += 2
                    continue
                if (src[j] == '"' and not depth) or src[j] == '\n':
                    break
                j += 1
            if '/usr/bin/security' not in src[i + 1:j]:
                blank(i + 1, j)
            i = j + 1
        else:
            i += 1
    return ''.join(out)


ATTRS = r'((?:@\w+(?:\([^)]*\))?\s+)*)'
TYPE_RE = re.compile(ATTRS + r'(?:(?:public|private|fileprivate|internal|final|nonisolated|indirect)\s+)*'
                     r'(class|struct|enum|actor|extension|protocol)\s+([A-Za-z_][\w.]*)([^{]*)$')
FUNC_RE = re.compile(ATTRS + r'((?:(?:public|private|fileprivate|internal|static|class|final|override|'
                     r'nonisolated|mutating|convenience|required|@objc)\s+)*)'
                     r'(func\s+([A-Za-z_]\w*)|init\??|deinit|var\s+([A-Za-z_]\w*)\s*:[^{=]*)([^{]*)$')
MAIN_SUPER = re.compile(r'\b(View|App|Scene|ViewModifier|NSViewRepresentable|NSViewControllerRepresentable|'
                        r'NSViewController|NSWindowController|NSView|NSPanel|NSWindow|NSApplicationDelegate|'
                        r'NSHostingController)\b')
BG_CLOSURE = re.compile(r'Task\.detached|DispatchQueue\.global|DispatchQueue\(label|\bqueue\.async|Queue\.async|'
                        r'\.async\s*\(|Thread\s*\{|Thread\(block|detachNewThread|OperationQueue|\.addOperation|'
                        r'withCheckedContinuation|withCheckedThrowingContinuation|\.run\s*\{|\bpipe\b|'
                        r'readabilityHandler|terminationHandler|DispatchSource|setEventHandler')
MAIN_CLOSURE = re.compile(r'@MainActor|MainActor\.run|DispatchQueue\.main|queue:\s*\.main\b|'
                          r'Timer\.scheduledTimer')


def header_before(s, pos):
    k, depth = pos - 1, 0
    while k >= 0:
        ch = s[k]
        if ch in ')]':
            depth += 1
        elif ch in '([':
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and ch in '{};':
            break
        k -= 1
    return s[k + 1:pos]


def main_types(stripped_files):
    names = set()
    decl = re.compile(ATTRS + r'(?:(?:public|private|fileprivate|internal|final)\s+)*'
                      r'(class|struct|enum|actor)\s+([A-Za-z_]\w*)([^{]*)\{')
    for s in stripped_files:
        for m in decl.finditer(s):
            attrs, _, name, rest = m.groups()
            if '@MainActor' in attrs or MAIN_SUPER.search(rest):
                names.add(name)
        for m in re.finditer(r'extension\s+([A-Za-z_]\w*)([^{]*)\{', s):
            if re.search(r'\bView\b', m.group(2)):
                names.add(m.group(1))
    return names


def scope(s, i, mains):
    h = header_before(s, i)
    lines = [x for x in h.split('\n') if x.strip()]
    tm = fm = None
    for k in range(len(lines) - 1, -1, -1):
        cand = ' '.join(' '.join(lines[k:]).split())
        tm, fm = TYPE_RE.match(cand), FUNC_RE.match(cand)
        if fm and fm.group(5) and '=' in (cand.split(':', 1)[1] if ':' in cand else ''):
            fm = None
        if tm or fm:
            # An attribute on its own line above (`@MainActor` then `static func ...`) belongs
            # to this declaration.
            while k > 0 and re.fullmatch(r'\s*(@\w+(\([^)]*\))?\s*)+', lines[k - 1]):
                k -= 1
            cand = ' '.join(' '.join(lines[k:]).split())
            tm, fm = TYPE_RE.match(cand), FUNC_RE.match(cand)
            break
    full = ' '.join(h.split())
    if tm and not fm:
        attrs, kind, name, _ = tm.groups()
        base = name.split('.')[-1]
        return {'kind': 'type', 'name': base, 'actor': kind == 'actor',
                'main': kind != 'actor' and ('@MainActor' in attrs or base in mains)}
    if fm:
        attrs, mods, _, fname, vname, _ = fm.groups()
        return {'kind': 'func', 'name': fname or vname or ('deinit' if 'deinit' in full else 'init'),
                'main': '@MainActor' in attrs,
                'noniso': 'nonisolated' in (mods or '') + attrs or '@concurrent' in attrs}
    main = bool(MAIN_CLOSURE.search(full))
    return {'kind': 'closure', 'main': main, 'bg': not main and bool(BG_CLOSURE.search(full))}


def verdict(stack):
    types = [e for e in stack if e['kind'] == 'type']
    fidx = max([k for k, e in enumerate(stack) if e['kind'] == 'func'], default=-1)
    fn = stack[fidx] if fidx >= 0 else None
    on_main = None
    for e in stack[fidx + 1:]:
        if e['kind'] == 'closure' and (e['bg'] or e['main']):
            on_main = e['main']
    if on_main is not None:
        return on_main
    if fn and fn['noniso']:
        return False
    if fn and fn['main']:
        return True
    if types and types[-1]['actor']:
        return False
    return any(t['main'] for t in types)


def sites(root, api_rx, cat_names):
    files = {}
    for dp, _, fns in os.walk(os.path.join(root, 'Tally')):
        for f in fns:
            if f.endswith('.swift'):
                p = os.path.join(dp, f)
                src = open(p, encoding='utf-8').read()
                files[os.path.relpath(p, root)] = (src, strip(src))
    mains = main_types(s for _, s in files.values())
    out = []
    for rel in sorted(files):
        src, s = files[rel]
        hits = list(api_rx.finditer(s))
        src_lines = src.split('\n')
        stack, hi = [], 0
        for i, ch in enumerate(s + '\0'):
            while hi < len(hits) and hits[hi].start() <= i:
                m = hits[hi]
                pos = m.start()
                hi += 1
                if verdict(stack):
                    cat = cat_names[int(m.lastgroup[1:])]
                    types = [e['name'] for e in stack if e['kind'] == 'type']
                    funcs = [e['name'] for e in stack if e['kind'] == 'func']
                    fn = '.'.join(filter(None, [types[-1] if types else '', funcs[-1] if funcs else '-']))
                    line = s.count('\n', 0, pos) + 1
                    out.append((rel, fn, cat, line, src_lines[line - 1].strip()))
            if ch == '{':
                stack.append(scope(s, i, mains))
            elif ch == '}' and stack:
                stack.pop()
    return out


def read_tsv(path, cols):
    rows = []
    if path and os.path.exists(path):
        for n, raw in enumerate(open(path, encoding='utf-8'), 1):
            if raw.startswith('#') or not raw.strip():
                continue
            parts = raw.rstrip('\n').split('\t')
            parts += [''] * (cols - len(parts))
            rows.append((n, parts[:cols]))
    return rows


def main(argv):
    root = argv[1]
    opt = dict(zip(argv[2::2], argv[3::2])) if '--dump' not in argv else {}
    api_rx, cat_names = load_api(os.path.join(HERE, 'io_api.txt'))
    found = sites(root, api_rx, cat_names)
    counts = Counter((f, fn, c) for f, fn, c, _, _ in found)
    if '--dump' in argv:
        print('# file\tfunc\tapi\tcount  (direct main-thread IO sites; only ever decreases)')
        for k in sorted(counts):
            print('%s\t%s\t%s\t%d' % (*k, counts[k]))
        return 0
    bad = 0
    allowed = set()
    for n, (f, fn, c, reason) in read_tsv(opt.get('--allowlist'), 4):
        if not reason.strip():
            print('RED allowlist line %d has no reason: %s %s %s' % (n, f, fn, c))
            bad = 1
        allowed.add((f, fn, c))
    base = {tuple(p[:3]): int(p[3]) for _, p in read_tsv(opt.get('--baseline'), 4)}
    by_key = defaultdict(list)
    for f, fn, c, line, text in found:
        by_key[(f, fn, c)].append((line, text))
    slack = 0
    for k in sorted(set(counts) | set(base)):
        if k in allowed:
            continue
        have, limit = counts.get(k, 0), base.get(k, 0)
        if have > limit:
            bad = 1
            print('RED new main-thread IO in %s (%s, %s): %d > baseline %d' % (k[1], k[2], k[0], have, limit))
            for line, text in by_key[k]:
                print('    %s:%d  %s' % (k[0], line, text))
        elif have < limit:
            slack += limit - have
    total = sum(counts.values())
    print('mainio: %d direct main-thread IO sites, %d keys, baseline %d rows' % (total, len(counts), len(base)))
    if slack:
        print('mainio: baseline can come down by %d site(s); regenerate it with --dump' % slack)
    return bad


if __name__ == '__main__':
    sys.exit(main(sys.argv))
