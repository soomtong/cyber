#!cyber

-- Writes the public API of the core and std modules as JSON, for tools and prompts that need the list of
-- methods of a type (`str`, `[]T`, `Map[K, V]`) without reading `api.html`.
-- Usage: cyber docs/gen-api-json.cy [-out=<path>] [-version=<string>]
-- The default output is `docs/api.json`. Unlike `gen-docs.cy`, it does not need md4c.
--
-- Shape:
--   {"version": "...", "types": [Type], "funcs": [Func]}
--   Type: {"module", "name", "syntax", "kind", "tparams", "doc", "methods": [Func], "funcs": [Func],
--          "aliases": {"startswith": "starts_with", ...}}
--   Func: {"name", "recv", "sig", "tparams", "cond", "doc"}
-- `methods` take a receiver (`recv` is its type, `&str`). `funcs` of a type are called on the type (`str.fromRune`).
-- `syntax` is how a program writes the type (`[]T` for `Slice`). `cond` is the `#[cond=...]` attribute: the method
-- exists only for the instances where it holds. `aliases` maps names from other languages to the members of the
-- type, the table that the compiler uses for `Did you mean ...?` (`sema.zig` `member_aliases`).
-- Members whose name starts with `_` or `@` and declarations hidden with `-` are left out. Operators (`+`, `<`)
-- are methods whose name is not an identifier.

use cy
use os
use meta

args := os.parseArgs({'version', 'out'})
version := args.get('version') ?else 'DEV'
cur_dir := os.dirname(meta.mod_uri()).?
out_path := args.get('out') ?else '%{cur_dir}/api.json'

type ModulePair:
    path    str
    section str

type FuncEntry:
    name    str
    recv    str
    sig     str
    tparams str
    cond    str
    doc     str

type TypeEntry:
    module  str
    name    str
    kind    str
    tparams str
    doc     str
    methods []FuncEntry
    funcs   []FuncEntry

type Alias:
    from str
    to   str

-- How a program writes a type: `[]T` for `Slice`, `Array[T]` for a template.
fn type_syntax(name str, tparams str) -> str:
    switch name:
        case 'Slice': return '[]T'
        case 'Span': return '[&]T'
        case 'Vector': return '[N]T'
        case 'PartialVector': return '[..N]T'
        case 'Option': return '?T'
        else:
            if tparams.len() == 0:
                return name
            -- `[K Any, const N int]` to `[K, N]`.
            names := []str{}
            for tparams[1..tparams.len()-1].split(',') |part|:
                words := part.trim().split(' ')
                if words[0] == 'const' and words.len() > 1:
                    names += words[1]
                else:
                    names += words[0]
            return '%{name}[%{names.join(', ')}]'

fn json_str(s str) -> str:
    res := s.replace('\\', '\\\\')
    res = res.replace('"', '\\"')
    res = res.replace('\n', '\\n')
    res = res.replace('\r', '\\r')
    res = res.replace('\t', '\\t')
    return '"%{res}"'

fn get_base_type(node ^cy.Node) -> ^cy.Node:
    switch node.*:
        case .ident:
            return node
        case .generic_expand |n|:
            return get_base_type(n.left)
        case .borrow |n|:
            return get_base_type(n.child)
        case .ex_borrow |n|:
            return get_base_type(n.child)
        else:
            panic('unsupported %{meta.choice_tag(node.*)}')

fn params_text(res &cy.ParseResult, nodes []^cy.Node) -> str:
    parts := []str{}
    for nodes |node|:
        param := node.!func_param
        s := res.node_text(param.name_type)
        if param.type |type_|:
            s += ' ' + res.node_text(type_)
        parts += s
    return parts.join(', ')

-- The `cy` AST does not keep the value of an attribute, so the `#[cond=...]` line is read from the source.
-- A declaration with attributes starts at its first `#[` line.
fn cond_text(src str, pos int) -> str:
    start := pos
    while start < src.len():
        end := src[start..].index('\n') ?else src.len() - start
        line := src[start..start+end].trim()
        if !line.starts_with('#['):
            break
        if line.starts_with('#[cond=') and line.ends_with(']'):
            return line[7..line.len()-1]
        start += end + 1
    return ''

fn is_public_name(name str) -> bool:
    if name.len() == 0:
        return false
    return !name.starts_with('_') and !name.starts_with('@')

fn func_entry(res &cy.ParseResult, stmt ^cy.Node, decl cy.FuncDecl, tparams str) -> FuncEntry:
    name := decl.name.name()
    -- An operator is declared as `` `+` ``.
    if name.len() > 2 and name.starts_with('`') and name.ends_with('`'):
        name = name[1..name.len()-1]
    recv := ''
    params := decl.params
    if decl.sig_t == .method:
        recv = res.node_text(decl.params[0].!func_param.type.?)
        params = decl.params[1..]
    sig := '%{name}(%{params_text(res, params)})'
    if decl.ret |ret|:
        sig += ' -> ' + res.node_text(ret)
    return {
        name = name,
        recv = recv,
        sig = sig,
        tparams = tparams,
        cond = cond_text(res.src, stmt.pos()),
        doc = res.stmt_docs(stmt) ?else '',
    }

fn type_decl_info(stmt ^cy.Node) -> ?TypeEntry:
    switch stmt.*:
        case .struct_decl |decl|:
            if decl.hidden: return none
            return TypeEntry{module='', name=decl.name.name(), kind='struct', tparams='', doc='', methods={}, funcs={}}
        case .custom_type_decl |decl|:
            if decl.hidden: return none
            return TypeEntry{module='', name=decl.name.name(), kind='builtin', tparams='', doc='', methods={}, funcs={}}
        case .cunion_decl |decl|:
            if decl.hidden: return none
            return TypeEntry{module='', name=decl.name.name(), kind='cunion', tparams='', doc='', methods={}, funcs={}}
        case .enum_decl |decl|:
            if decl.hidden: return none
            kind := if (decl.isChoiceType) 'choice' else 'enum'
            return TypeEntry{module='', name=decl.name.name(), kind=kind, tparams='', doc='', methods={}, funcs={}}
        case .trait_decl |decl|:
            return TypeEntry{module='', name=decl.name.name(), kind='trait', tparams='', doc='', methods={}, funcs={}}
        case .type_const_decl |decl|:
            if decl.hidden: return none
            return TypeEntry{module='', name=decl.name.name(), kind='const', tparams='', doc='', methods={}, funcs={}}
        else:
            return none

-- Reads the pairs of `member_aliases` from `sema.zig`: `.{ "startswith", "starts_with" }`.
fn read_aliases(path str) -> ![]Alias:
    src := str(os.read_file(path)!)
    start := src.index('const member_aliases') ?else:
        return error.MissingAliases
    end := src[start..].index('};') ?else:
        return error.MissingAliases
    table := src[start..start+end]
    res := []Alias{}
    for table.split('\n') |line|:
        rest := line
        while rest.index('.{ "') |i|:
            rest = rest[i+4..]
            from_end := rest.index('"') ?else: break
            from := rest[..from_end]
            rest = rest[from_end+1..]
            to_start := rest.index('"') ?else: break
            rest = rest[to_start+1..]
            to_end := rest.index('"') ?else: break
            res += Alias{from=from, to=rest[..to_end]}
            rest = rest[to_end+1..]
    return res

fn func_json(f FuncEntry, indent str) -> str:
    s := '%{indent}{"name": %{json_str(f.name)}'
    if f.recv.len() > 0:
        s += ', "recv": %{json_str(f.recv)}'
    s += ', "sig": %{json_str(f.sig)}'
    if f.tparams.len() > 0:
        s += ', "tparams": %{json_str(f.tparams)}'
    if f.cond.len() > 0:
        s += ', "cond": %{json_str(f.cond)}'
    if f.doc.len() > 0:
        s += ', "doc": %{json_str(f.doc)}'
    return s + '}'

fn funcs_json(funcs []FuncEntry, indent str) -> str:
    if funcs.len() == 0:
        return '[]'
    lines := []str{}
    for funcs |f|:
        lines += func_json(f, indent + '  ')
    return '[\n' + lines.join(',\n') + '\n%{indent}]'

fn has_member(t TypeEntry, name str) -> bool:
    for t.methods |m|:
        if m.name == name: return true
    for t.funcs |f|:
        if f.name == name: return true
    return false

fn aliases_json(t TypeEntry, aliases []Alias) -> str:
    parts := []str{}
    seen := Map[str, int]{}
    for aliases |a|:
        if seen.contains(a.from): continue
        if has_member(t, a.from): continue
        if !has_member(t, a.to): continue
        seen[a.from] = 1
        parts += '%{json_str(a.from)}: %{json_str(a.to)}'
    return '{' + parts.join(', ') + '}'

core_mods := []ModulePair{
    {path='../src/builtins/core.cy', section='core'},
    {path='../src/builtins/cy.cy', section='cy'},
    {path='../src/builtins/meta.cy', section='meta'},
}
std_mods := []ModulePair{
    {path='../src/std/cli.cy', section='cli'},
    {path='../src/std/io.cy', section='io'},
    {path='../src/std/math.cy', section='math'},
    {path='../src/std/os.cy', section='os'},
    {path='../src/std/test.cy', section='test'},
}

types := []TypeEntry{}
funcs := []str{}
-- Key: `module.Type`.
type_idx := Map[str, int]{}

for {core_mods, std_mods} |mods|:
    for mods |m|:
        src := str(os.read_file('%{cur_dir}/%{m.path}')!)
        res := cy.parse(src)
        root := res.root ?else:
            panic('parse error: %{m.path}')

        for root.!root.stmts |stmt|:
            decl_stmt := stmt
            tparams := ''
            if meta.choice_tag(stmt.*) == .template:
                template := stmt.!template
                decl_stmt = template.child_decl
                tparams = '[%{params_text(&res, template.params)}]'

            if type_decl_info(decl_stmt) |info|:
                entry := info
                entry.module = m.section
                entry.tparams = tparams
                entry.doc = res.stmt_docs(stmt) ?else ''
                type_idx['%{m.section}.%{entry.name}'] = types.len()
                types += entry
                continue

            if meta.choice_tag(decl_stmt.*) != .func_decl:
                continue
            decl := decl_stmt.!func_decl
            if decl.hidden or !is_public_name(decl.name.name()):
                continue
            f := func_entry(&res, stmt, decl, tparams)

            owner := ''
            if decl.sig_t == .method:
                owner = get_base_type(decl.params[0].!func_param.type.?).name()
            else:
                if decl.parent |parent|:
                    owner = get_base_type(parent).name()
            if owner.len() == 0:
                funcs += '    {"module": %{json_str(m.section)}, ' + func_json(f, '')[1..]
                continue

            idx := type_idx.get('%{m.section}.%{owner}') ?else:
                -- A method on a type of another module (`fn (&str) ...` in `cy`) or a hidden type.
                continue
            if decl.sig_t == .method:
                types[idx].methods += f
            else:
                types[idx].funcs += f

aliases := read_aliases('%{cur_dir}/../src/sema.zig')!

type_lines := []str{}
for types |t|:
    s := '    {"module": %{json_str(t.module)}, "name": %{json_str(t.name)}, "syntax": %{json_str(type_syntax(t.name, t.tparams))}'
    s += ', "kind": %{json_str(t.kind)}'
    if t.tparams.len() > 0:
        s += ', "tparams": %{json_str(t.tparams)}'
    if t.doc.len() > 0:
        s += ', "doc": %{json_str(t.doc)}'
    s += ',\n      "methods": %{funcs_json(t.methods, '      ')}'
    s += ',\n      "funcs": %{funcs_json(t.funcs, '      ')}'
    s += ',\n      "aliases": %{aliases_json(t, aliases)}}'
    type_lines += s

out := '{\n  "version": %{json_str(version)},\n'
out += '  "types": [\n' + type_lines.join(',\n') + '\n  ],\n'
out += '  "funcs": [\n' + funcs.join(',\n') + '\n  ]\n}\n'
os.write_file(out_path, out)!
eprint('wrote %{out_path}: %{types.len()} types, %{funcs.len()} functions')
