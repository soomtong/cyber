--| Path strings with `/` as the separator. The functions only read and build strings: they do not look at the
--| file system, so `normalize('a/../b')` is `'b'` even when `a` is a link. This is the `path` package of Go,
--| not `path/filepath`: a Windows path with `\` is not split.
--| Sample usage:
--| ```cy
--| use path
--|
--| p := path.join('src', 'std/path.cy')   --> 'src/std/path.cy'
--| path.base(p)                           --> 'path.cy'
--| path.dir(p)                            --> 'src/std'
--| path.ext(p)                            --> '.cy'
--| path.stem(p)                           --> 'path'
--| path.normalize('a//b/./../c/')         --> 'a/c'
--| path.is_absolute('/usr/bin')           --> true
--| ```

--| Joins two paths with `/` and normalizes the result. An empty part is skipped, and a part that starts with `/`
--| does not drop the parts before it: `join('a', '/b')` is `'a/b'`. Joining only empty parts gives `''`.
fn join(a str, b str) -> str:
    return join({a, b})

--| Joins the parts with `/` and normalizes the result, like `join(a, b)`.
fn join(parts AsSpan[str]) -> str:
    res := ''
    for parts |part|:
        if part.len() == 0:
            continue
        if res.len() == 0:
            res = part
        else:
            res = res + '/' + part
    if res.len() == 0:
        return ''
    return normalize(res)

--| Returns the shortest path that names the same place, by reading the string only: it removes empty and `.`
--| parts, removes a `..` together with the part before it, and removes a trailing `/`. A `..` at the start of a
--| relative path stays, and a `..` right after the root is removed (`'/..'` is `'/'`). An empty path gives `'.'`.
fn normalize(p str) -> str:
    abs := is_absolute(p)
    parts := []str{}
    for p.split('/') |part|:
        if part.len() == 0 or part == '.':
            continue
        if part == '..':
            if parts.len() > 0 and parts.last() != '..':
                parts = parts.remove(parts.len() - 1)
            else !abs:
                parts += part
            continue
        parts += part
    res := parts.join('/')
    if abs:
        return '/' + res
    if res.len() == 0:
        return '.'
    return res

--| Returns the last part of the path. Trailing `/` are ignored: `base('a/b/')` is `'b'`.
--| `base('/')` is `'/'` and `base('')` is `'.'`.
fn base(p str) -> str:
    if p.len() == 0:
        return '.'
    s := trim_slashes(p)
    if s.len() == 0:
        return '/'
    if s.last_index('/') |i|:
        return s[i+1..]
    return s

--| Returns the path without its last part, normalized. Trailing `/` are ignored: `dir('a/b/')` is `'a'`.
--| A path with no `/` gives `'.'`, and `dir('/a')` and `dir('/')` give `'/'`.
fn dir(p str) -> str:
    s := trim_slashes(p)
    if s.len() == 0:
        if is_absolute(p):
            return '/'
        return '.'
    if s.last_index('/') |i|:
        if i == 0:
            return '/'
        return normalize(s[..i])
    return '.'

--| Returns the extension of the last part, from its last `.`: `ext('a/b.tar.gz')` is `'.gz'`.
--| A name without a `.` and a name that only starts with one (`'.bashrc'`) give `''`.
fn ext(p str) -> str:
    name := base(p)
    if name == '.' or name == '..':
        return ''
    if name.last_index('.') |i|:
        if i > 0:
            return name[i..]
    return ''

--| Returns the last part without its extension: `stem('a/b.tar.gz')` is `'b.tar'`, `stem('.bashrc')` is `'.bashrc'`.
fn stem(p str) -> str:
    name := base(p)
    e := ext(p)
    return name[..name.len() - e.len()]

--| Returns whether the path starts with `/`.
fn is_absolute(p str) -> bool:
    return p.starts_with('/')

fn trim_slashes(p str) -> str:
    return p.trim_right('/')
