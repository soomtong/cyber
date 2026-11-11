/**
 * @file Tree-sitter grammar for the Cyber language (soomtong/cyber fork, 0.4 syntax).
 * @license MIT
 *
 * Rewritten from scratch against src/tokenizer.zig and src/parser.zig.
 * The layout (external indent scanner, queries) follows the original
 * tree-sitter-cyber by instance.id (https://github.com/instance-id/tree-sitter-cyber).
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// Binary operator precedence mirrors `getBinOpPrecedence` in src/parser.zig.
const PREC = {
  lambda: -2,
  not: -1,
  default: 0, // ?else, !else
  range: 1,
  or: 2,
  and: 3,
  compare: 4,
  plus: 6,
  times: 7,
  power: 8,
  bitor: 9, // `||`, `~`
  bitand: 10, // `&&`
  shift: 11, // `<<`, `>>`
  prefix: 14, // `-x`, `!x`, `~x`, `&x`, `*x`, `^x`, `?T`
  type_prefix: 15, // `[]T`, `[N]T`, `[&]T`
  postfix: 16,
  call: 17,
};

const commaSep1 = (rule) => seq(rule, repeat(seq(',', rule)));
const commaSep = (rule) => optional(commaSep1(rule));
// Lists inside brackets may end with a trailing comma.
const commaSepTrail = (rule) => optional(seq(commaSep1(rule), optional(',')));

module.exports = grammar({
  name: 'cyber',

  word: ($) => $.identifier,

  externals: ($) => [
    $._newline,
    $._indent,
    $._dedent,
    ')',
    ']',
    '}',
    $._error_sentinel,
  ],

  extras: ($) => [/[\s\f\uFEFF\u2060\u200B]|\r?\n/, $.comment],

  supertypes: ($) => [$._simple_statement, $._compound_statement, $._expression],

  inline: ($) => [$._decl_name, $._suite_body],

  conflicts: ($) => [
    [$.parameter, $._type],
    [$.parameter, $._type_only],
    [$.if_expression, $.parenthesized_expression],
    [$.capture, $.infer_lambda],
  ],

  rules: {
    source_file: ($) => seq(optional($.shebang), repeat($._statement)),

    shebang: (_) => token(seq('#!', /[^\n]*/)),

    comment: (_) => token(seq('--', /[^\n]*/)),

    // ---------------------------------------------------------------------
    // Statements
    // ---------------------------------------------------------------------

    _statement: ($) => choice(seq($._simple_statement, $._newline), $._compound_statement),

    _simple_statement: ($) =>
      choice(
        $.expression_statement,
        $.assignment,
        $.augmented_assignment,
        $.variable_declaration,
        $.var_declaration,
        $.const_declaration,
        $.global_declaration,
        $.use_statement,
        $.return_statement,
        $.yield_statement,
        $.suspend_statement,
        $.break_statement,
        $.continue_statement,
        $.pass_statement,
        $.type_alias,
      ),

    _compound_statement: ($) =>
      choice(
        $.function_definition,
        $.type_declaration,
        $.if_statement,
        $.while_statement,
        $.for_statement,
        $.switch_statement,
        $.try_statement,
        $.begin_statement,
        $.with_declaration,
        $.decorated_definition,
        $.comptime_statement,
        $.case_clause,
      ),

    // A `:` followed by either one statement on the same line or an indented block.
    _suite: ($) =>
      choice(
        alias(seq($._simple_statement, $._newline), $.block),
        alias($._compound_statement, $.block),
        seq($._indent, $.block),
      ),

    // Same as `_suite`, but used inside an expression. The single statement
    // form leaves the line end to the enclosing statement.
    _expression_suite: ($) => choice(alias($._inline_statement, $.block), seq($._indent, $.block)),

    // Statements that may follow `:` on the same line inside an expression.
    _inline_statement: ($) =>
      choice(
        $.return_statement,
        $.break_statement,
        $.continue_statement,
        $.pass_statement,
        $.yield_statement,
        $.suspend_statement,
        alias($._inline_expression_statement, $.expression_statement),
        alias($._inline_assignment, $.assignment),
      ),

    _inline_expression_statement: ($) => prec.right($._expression),

    _inline_assignment: ($) => prec.right(1, seq(field('left', $._term), '=', field('right', $._expression))),

    block: ($) => seq(repeat($._statement), $._dedent),

    _suite_body: ($) => seq(':', field('body', $._expression_suite)),

    expression_statement: ($) => prec.right(seq($._expression, optional($._suite_body))),

    assignment: ($) =>
      prec.right(1, seq(field('left', $._term), '=', field('right', $._rhs), optional($._suite_body))),

    augmented_assignment: ($) =>
      prec.right(1, seq(
        field('left', $._term),
        field('operator', choice('+=', '-=', '*=', '/=', '<<=', '>>=', '||=', '&&=', '~=')),
        field('right', $._rhs),
        optional($._suite_body),
      )),

    // `name := expr`
    variable_declaration: ($) =>
      prec.right(seq(
        field('name', choice($.identifier, $.discard)),
        ':=',
        field('value', $._rhs),
        optional($._suite_body),
      )),

    // `var name Type = expr`
    var_declaration: ($) =>
      prec.right(seq(
        'var',
        field('name', $._decl_name),
        field('type', $._type),
        '=',
        field('value', $._rhs),
        optional($._suite_body),
      )),

    // `const name Type = expr`
    const_declaration: ($) =>
      prec.right(seq(
        optional($.visibility),
        'const',
        $._qualified_name,
        optional(field('type', $._type)),
        optional(seq('=', field('value', $._rhs))),
      )),

    // `global name Type = expr`
    global_declaration: ($) =>
      prec.right(seq(
        optional($.visibility),
        'global',
        $._qualified_name,
        field('type', $._type),
        optional(seq('=', field('value', $._rhs), optional($._suite_body))),
      )),

    // Right side of a declaration or assignment. `switch` is allowed here.
    _rhs: ($) => prec(-3, choice($._expression, $.switch_expression)),

    use_statement: ($) =>
      prec.right(seq(
        optional($.visibility),
        'use',
        choice(
          seq(
            field('name', $.module_path),
            optional($.template_parameters),
            optional(choice(field('source', $.string), seq('=', field('target', $._expression)))),
          ),
          seq(alias('*', $.wildcard), field('source', $.string)),
        ),
      )),

    module_path: ($) => prec.right(seq($._decl_name, repeat(seq('.', $._decl_name)))),

    return_statement: ($) => prec.right(seq('return', optional($._rhs))),

    yield_statement: ($) => prec.right(seq('yield', optional($._expression))),

    // Gives control back to the `resume` of the running fiber. It takes no value.
    suspend_statement: (_) => 'suspend',

    break_statement: (_) => 'break',

    continue_statement: (_) => 'continue',

    pass_statement: (_) => 'pass',

    // `-` before a declaration hides it from other modules.
    visibility: (_) => prec(20, '-'),

    // ---------------------------------------------------------------------
    // Declarations
    // ---------------------------------------------------------------------

    _decl_name: ($) =>
      choice(
        $.identifier,
        $.at_identifier,
        $.raw_string,
        $.comptime_expression,
        alias(
          choice('type', 'error', 'none', 'void', 'struct', 'enum', 'trait', 'global', 'scope', 'cstruct', 'cunion'),
          $.identifier,
        ),
      ),

    // `Parent :: name`, `Parent[] :: name`, `name`
    _qualified_name: ($) =>
      seq(
        optional(seq(field('parent', choice($._decl_name, $.generic_expand_name)), '::')),
        field('name', $._decl_name),
      ),

    generic_expand_name: ($) => prec(PREC.call, seq($._decl_name, token.immediate('[]'))),

    function_definition: ($) =>
      seq(
        optional($.visibility),
        choice('fn', $.generator_fn),
        choice(
          seq(field('receiver', $.receiver), field('name', $._decl_name)),
          seq($._qualified_name, optional(field('template', $.template_parameters))),
        ),
        field('parameters', $.parameters),
        optional(field('return_type', $.return_type)),
        choice(seq(':', field('body', $._suite)), $._newline),
      ),

    // `generator fn count() -> int:`. `generator` is not a reserved word. It is a modifier only
    // when `fn` follows it, so the two words are one token.
    generator_fn: (_) => token(seq('generator', /[ \t]+/, 'fn')),

    // `fn (&Account) deposit(...)`
    receiver: ($) => seq('(', optional(choice('scope', 'sink')), field('type', $._type), ')'),

    parameters: ($) => seq('(', commaSepTrail($.parameter), ')'),

    parameter: ($) =>
      seq(
        optional(field('modifier', choice('scope', 'sink', 'const'))),
        choice(
          prec.dynamic(1, seq(field('name', choice($.identifier, $.template_parameter)), optional(field('type', $._type)))),
          field('type', $._type_only),
        ),
      ),

    // `%T` declares a template parameter inferred from the argument.
    template_parameter: ($) => seq('%', token.immediate(/[A-Za-z_][A-Za-z0-9_]*/)),

    template_parameters: ($) => seq(token.immediate('['), commaSep1($.parameter), ']'),

    return_type: ($) => seq('->', optional('scope'), $._type),

    // `with [K Copyable, V Copyable]` followed by a function on the next line.
    with_declaration: ($) =>
      seq(
        'with',
        seq(choice('[', token.immediate('[')), commaSep1($.parameter), ']'),
        $._newline,
        $.function_definition,
      ),

    decorated_definition: ($) =>
      seq(
        $.attribute_list,
        optional($._newline),
        optional('#'),
        field(
          'definition',
          choice(
            $.function_definition,
            $.type_declaration,
            alias($._decorated_simple, $.declaration),
            $.with_declaration,
          ),
        ),
      ),

    _decorated_simple: ($) =>
      seq(choice($.global_declaration, $.use_statement, $.type_alias), $._newline),

    attribute_list: ($) => seq('#[', commaSep($.attribute), optional(','), ']'),

    attribute: ($) => seq(field('name', $.identifier), optional(seq('=', field('value', $._expression)))),

    // `type Name = Target`
    type_alias: ($) =>
      prec.right(seq(
        optional($.visibility),
        'type',
        optional(seq(field('parent', $._decl_name), '::')),
        field('name', $._decl_name),
        optional(field('template', $.template_parameters)),
        '=',
        field('target', $._rhs),
      )),

    type_declaration: ($) =>
      seq(
        optional($.visibility),
        'type',
        field('name', $._decl_name),
        optional(field('template', $.template_parameters)),
        choice(
          // `type Foo:` / `type Foo struct:` / `type Foo cstruct:`
          seq(optional(choice('struct', 'cstruct')), ':', $._indent, field('body', $.member_block)),
          // `type Foo` / `type Foo struct` (declaration only)
          seq(optional(choice('struct', 'cstruct', 'trait', 'cunion')), $._newline),
          // `type Vec2(x float, y float)`
          seq(
            optional(choice('struct', 'cstruct')),
            field('fields', $.tuple_fields),
            choice($._newline, seq(':', $._indent, field('body', $.member_block))),
          ),
          seq('enum', ':', $._indent, field('body', $.member_block)),
          seq('cunion', ':', $._indent, field('body', $.member_block)),
          seq('trait', ':', $._indent, field('body', $.block)),
          seq('const', ':', field('body', $._suite)),
          seq(alias('_', $.custom), $._newline),
        ),
      ),

    tuple_fields: ($) => seq('(', commaSepTrail($.field_declaration), ')'),

    member_block: ($) =>
      seq(repeat(seq(choice($.field_declaration, $.case_declaration, $.impl_declaration), $._newline)), $._dedent),

    // `-name Type = default`, `name use Type`
    field_declaration: ($) =>
      seq(
        optional($.visibility),
        field('name', $._decl_name),
        optional(alias('use', $.embed)),
        optional(field('type', $._type)),
        optional(seq('=', field('default', $._expression))),
      ),

    // Enum or cunion member: `case red`, `case circle Circle`.
    case_declaration: ($) => seq('case', field('name', $._decl_name), optional(field('type', $._type))),

    // `with Trait` inside a struct body.
    impl_declaration: ($) => seq('with', field('trait', $._expression)),

    comptime_statement: ($) => seq('#', choice(seq($._simple_statement, $._newline), $._compound_statement)),

    // ---------------------------------------------------------------------
    // Control flow
    // ---------------------------------------------------------------------

    if_statement: ($) =>
      prec.right(seq(
        'if',
        field('condition', $._expression),
        optional(field('capture', $.capture)),
        ':',
        field('body', $._suite),
        repeat(field('alternative', choice($.else_if_clause, $.else_clause))),
      )),

    else_if_clause: ($) =>
      seq(choice('else', '#else'), field('condition', $._expression), ':', field('body', $._suite)),

    else_clause: ($) => seq(choice('else', '#else'), ':', field('body', $._suite)),

    while_statement: ($) =>
      seq(
        'while',
        optional(seq(field('condition', $._expression), optional(field('capture', $.capture)))),
        ':',
        field('body', $._suite),
      ),

    for_statement: ($) =>
      seq(
        'for',
        field('iterable', $._expression),
        optional(field('capture', $.capture)),
        ':',
        field('body', $._suite),
      ),

    // `|x|`, `|i, x|`, `|{a, b}|`
    capture: ($) => seq('|', commaSep1(choice($.identifier, $.discard, $.destructure, $.borrow_expression)), '|'),

    destructure: ($) => seq('{', commaSepTrail($.identifier), '}'),

    switch_statement: ($) => $._switch,

    switch_expression: ($) => $._switch,

    _switch: ($) =>
      seq(
        'switch',
        field('value', $._expression),
        ':',
        $._indent,
        repeat1(choice($.case_clause, $.switch_else_clause, alias($._comptime_case, $.comptime_statement))),
        $._dedent,
      ),

    _comptime_case: ($) => seq('#', choice($.for_statement, $.case_clause)),

    case_clause: ($) =>
      seq(
        'case',
        commaSep1(field('pattern', $._expression)),
        optional(field('capture', $.capture)),
        choice(seq(':', field('body', $._suite)), seq('=>', field('body', $._rhs), $._newline), $._newline),
      ),

    switch_else_clause: ($) =>
      seq(
        optional('#'),
        'else',
        choice(seq(':', field('body', $._suite)), seq('=>', field('body', $._rhs), $._newline)),
      ),

    try_statement: ($) =>
      seq('try', ':', field('body', $._suite), $.catch_clause),

    // `else:` or `else |err|:`
    catch_clause: ($) =>
      seq('else', optional(seq('|', field('error', $.identifier), '|')), ':', field('body', $._suite)),

    begin_statement: ($) => seq('begin', ':', field('body', $._suite)),

    // ---------------------------------------------------------------------
    // Expressions
    // ---------------------------------------------------------------------

    _expression: ($) =>
      choice(
        $._term,
        $.binary_expression,
        $.range_expression,
        $.not_expression,
        $.move_expression,
        $.unwrap_or_expression,
        $.unwrap_or_block,
        $.lambda,
        $.infer_lambda,
        $.fiber_expression,
        alias($._borrow_lambda, $.borrow_expression),
        $.if_expression,
      ),

    // A term has no binary operator at the top. Types are terms.
    _term: ($) =>
      choice(
        $._primary,
        $.unary_expression,
        $.borrow_expression,
        $.pointer_type,
        $.ref_type,
        $.option_type,
        $.slice_type,
        $.span_type,
        $.vector_type,
        $.cast_expression,
      ),

    // Type position after a name (`a int`, `-> T`). Narrower than `_term` so that
    // a name followed by a type is not read as an expression.
    _type: ($) => choice($.identifier, $._type_only),

    _type_only: ($) =>
      choice(
        $.borrow_expression,
        $.pointer_type,
        $.ref_type,
        $.option_type,
        $.slice_type,
        $.span_type,
        $.vector_type,
        alias($._error_union_type, $.unary_expression),
        $.generic_type,
        alias($._member_type, $.member_expression),
        alias($._generic_expand_type, $.generic_expand),
        alias($._call_type, $.call_expression),
        $.function_type,
        $.symbol_function_type,
        $.extern_function_type,
        $.template_parameter,
        $.comptime_expression,
        $.parenthesized_expression,
        $._keyword_identifier,
      ),

    _keyword_identifier: ($) => alias(choice('type', 'void', 'error'), $.identifier),

    // `Sig.ret()`
    _call_type: ($) =>
      prec(PREC.call, seq(field('function', choice($.identifier, alias($._member_type, $.member_expression))), field('arguments', $.arguments))),

    _generic_expand_type: ($) =>
      prec(PREC.call, seq(choice($.identifier, alias($._member_type, $.member_expression)), token.immediate('[]'))),

    // `!T`
    _error_union_type: ($) => prec(PREC.prefix, seq(field('operator', '!'), field('argument', $._type))),

    _member_type: ($) =>
      prec(PREC.postfix, seq(field('object', choice($.identifier, alias($._member_type, $.member_expression))), '.', field('member', $._member_name))),

    _primary: ($) =>
      choice(
        $.identifier,
        $.at_identifier,
        $.number,
        $.string,
        $.raw_string,
        $.true,
        $.false,
        $.none,
        $.undef,
        $.discard,
        $.symbol_literal,
        $.error_literal,
        $.parenthesized_expression,
        $.initializer,
        $.member_expression,
        $.call_expression,
        $.index_expression,
        $.generic_expand,
        $.init_expression,
        $.unwrap_expression,
        $.unwrap_option,
        $.unwrap_choice,
        $.dereference,
        $.special_string,
        $.comptime_expression,
        $.template_parameter,
        $.function_type,
        $.symbol_function_type,
        $.extern_function_type,
        $._keyword_identifier,
      ),

    generic_type: ($) =>
      prec(PREC.call, seq(field('name', choice($.identifier, alias($._member_type, $.member_expression))), token.immediate('['), commaSep1($._expression), optional(','), ']')),

    binary_expression: ($) => {
      const table = [
        [prec.left, PREC.shift, choice('<<', '>>')],
        [prec.left, PREC.bitand, '&&'],
        [prec.left, PREC.bitor, choice('||', '~')],
        [prec.left, PREC.power, '**'],
        [prec.left, PREC.times, choice('*', '/', '%')],
        [prec.left, PREC.plus, choice('+', '-')],
        [prec.left, PREC.compare, choice('==', '!=', '<', '<=', '>', '>=')],
        [prec.left, PREC.and, 'and'],
        [prec.left, PREC.or, 'or'],
      ];
      return choice(
        ...table.map(([fn, p, op]) =>
          fn(p, seq(field('left', $._expression), field('operator', op), field('right', $._expression))),
        ),
      );
    },

    // `a..b`, `a..=b`, `a..>b`, `a..>=b`, `a..`, `..`
    range_expression: ($) =>
      choice(
        prec.left(
          PREC.range,
          seq(
            field('start', $._expression),
            field('operator', choice('..', '..=', '..>', '..>=')),
            field('end', $._expression),
          ),
        ),
        prec.left(PREC.range, seq(field('start', $._expression), '..')),
        prec.left(PREC.range, '..'),
      ),

    not_expression: ($) => prec(PREC.not, seq('not', field('argument', $._expression))),

    move_expression: ($) => prec(PREC.not, seq('move', field('argument', $._expression))),

    unary_expression: ($) =>
      prec(PREC.prefix, seq(field('operator', choice('-', '~', '!')), field('argument', $._term))),

    // `&x`, `&&x`
    borrow_expression: ($) => prec(PREC.prefix, seq(choice('&', '&&'), field('argument', $._term))),

    // `&|a, b| expr`
    _borrow_lambda: ($) => prec(PREC.lambda, seq(choice('&', '&&'), field('argument', $.infer_lambda))),

    pointer_type: ($) => prec(PREC.prefix, seq('*', $._term)),

    ref_type: ($) => prec(PREC.prefix, seq('^', $._term)),

    option_type: ($) => prec(PREC.prefix, seq('?', $._term)),

    // `[]T`
    slice_type: ($) => prec(PREC.type_prefix, seq('[', ']', field('element', $._term))),

    // `[&]T`
    span_type: ($) => prec(PREC.type_prefix, seq('[', '&', ']', field('element', $._term))),

    // `[N]T`, `[_]T`, `[..N]T`
    vector_type: ($) =>
      prec(
        PREC.type_prefix,
        seq('[', field('size', choice($._expression, seq('..', $._expression))), ']', field('element', $._term)),
      ),

    // `as[T] x`, `as x`
    cast_expression: ($) =>
      prec.right(
        PREC.prefix,
        seq('as', optional(seq(token.immediate('['), field('type', $._type), ']')), field('value', choice($._term, $.move_expression))),
      ),

    // `opt ?else default`, `res !else default`
    unwrap_or_expression: ($) =>
      prec.right(
        PREC.default,
        seq(field('value', $._expression), field('operator', choice('?else', '!else')), field('default', $._expression)),
      ),

    // `opt ?else:` block, `res !else |err|:` block
    unwrap_or_block: ($) =>
      prec.right(
        PREC.default,
        seq(
          field('value', $._expression),
          field('operator', choice('?else', '!else')),
          optional(field('capture', $.capture)),
          ':',
          field('body', $._expression_suite),
        ),
      ),

    if_expression: ($) =>
      prec.right(
        PREC.default,
        seq(
          'if',
          '(',
          field('condition', $._expression),
          ')',
          field('consequence', $._expression),
          'else',
          field('alternative', $._expression),
        ),
      ),

    parenthesized_expression: ($) => seq('(', $._expression, ')'),

    member_expression: ($) =>
      prec(PREC.postfix, seq(field('object', $._primary), '.', field('member', $._member_name))),

    _member_name: ($) =>
      choice(
        $.identifier,
        $.at_identifier,
        $.comptime_expression,
        alias(choice('type', 'error', 'none', 'void', 'struct', 'enum', 'trait', 'global', 'scope', 'with'), $.identifier),
      ),

    call_expression: ($) =>
      prec(PREC.call, seq(field('function', $._primary), field('arguments', $.arguments))),

    arguments: ($) => seq('(', commaSepTrail(choice($._rhs, $.named_argument)), ')'),

    named_argument: ($) => seq(field('name', $.identifier), ':', field('value', $._rhs)),

    index_expression: ($) =>
      prec(
        PREC.call,
        seq(field('object', $._primary), token.immediate('['), commaSep1(field('index', $._expression)), optional(','), ']'),
      ),

    // `Foo[]`
    generic_expand: ($) => prec(PREC.call, seq($._primary, token.immediate('[]'))),

    // `Foo{a=1}`
    init_expression: ($) => prec(PREC.call, seq(field('type', $._primary), field('initializer', $.initializer))),

    initializer: ($) => seq('{', commaSepTrail(choice($._expression, $.pair)), '}'),

    pair: ($) => seq(field('key', $._expression), '=', field('value', $._rhs)),

    // `res!`
    unwrap_expression: ($) => prec(PREC.postfix, seq($._primary, '!')),

    // `opt.?`
    unwrap_option: ($) => prec(PREC.postfix, seq($._primary, '.?')),

    // `choice.!case`
    unwrap_choice: ($) => prec(PREC.postfix, seq($._primary, '.!', field('case', $._member_name))),

    // `ptr.*`
    dereference: ($) => prec(PREC.postfix, seq($._primary, '.*')),

    // `c'a'`, `u'가'`
    special_string: ($) => prec(PREC.call, seq(field('prefix', $.identifier), $.string)),

    // `.name`, `.`
    symbol_literal: ($) => prec.right(seq('.', optional(choice($.identifier, alias(choice('none', 'error', 'type'), $.identifier))))),

    error_literal: ($) => prec(PREC.call, seq('error', '.', $.identifier)),

    // `#{expr}`
    comptime_expression: ($) => seq('#{', $._expression, '}'),

    // `|a, b| expr`
    infer_lambda: ($) =>
      prec.right(
        PREC.lambda,
        seq('|', choice(alias('_', $.discard), commaSepTrail(alias($.identifier, $.parameter))), '|', optional(field('body', $._expression))),
      ),

    // `fn(a int) -> int => expr`, `fn(a int) -> int:` block
    lambda: ($) =>
      prec.right(
        PREC.lambda,
        seq(
          'fn',
          field('parameters', $.parameters),
          optional(field('return_type', $.return_type)),
          choice(seq('=>', field('body', $._expression)), seq(':', field('body', $._expression_suite))),
        ),
      ),

    // `fiber work(a, b)`, `fiber:` block
    fiber_expression: ($) =>
      prec.right(
        PREC.lambda,
        seq('fiber', choice(field('call', $.call_expression), seq(':', field('body', $._expression_suite)))),
      ),

    function_type: ($) =>
      prec.right(PREC.lambda - 1, seq('fn', field('parameters', $.parameters), optional(field('return_type', $.return_type)))),

    symbol_function_type: ($) =>
      prec.right(seq('fnsym', field('parameters', $.parameters), optional(field('return_type', $.return_type)))),

    extern_function_type: ($) => seq($.attribute_list, $.function_type),

    // ---------------------------------------------------------------------
    // Literals
    // ---------------------------------------------------------------------

    identifier: (_) => /[A-Za-z][A-Za-z0-9_]*|_[A-Za-z_][A-Za-z0-9_]*/,

    at_identifier: (_) => /@[A-Za-z0-9_]*/,

    discard: (_) => '_',

    number: (_) =>
      token(
        choice(
          // `_` may separate digits: `100_000`, `0xff_ff`.
          /0x[0-9A-Za-z]+(_[0-9A-Za-z]+)*/,
          /0o[0-8]+(_[0-8]+)*/,
          /0b[01]+(_[01]+)*/,
          /\d+(_\d+)*u/,
          /\d+(_\d+)*\.\d+(_\d+)*(e-?\d+(_\d+)*)?/,
          /\d+(_\d+)*e-?\d+(_\d+)*/,
          /\d+(_\d+)*/,
        ),
      ),

    true: (_) => 'true',
    false: (_) => 'false',
    none: (_) => 'none',
    undef: (_) => 'undef',

    raw_string: (_) =>
      choice(token(seq('`', /[^`\n]*/, '`')), token(seq('```', repeat(choice(/[^`]/, /`[^`]/, /``[^`]/)), '```'))),

    string: ($) =>
      choice(
        seq("'", repeat(choice($._sq_content, $.escape_sequence, $.interpolation)), "'"),
        seq('"', repeat(choice($._dq_content, $.escape_sequence, $.interpolation)), '"'),
        seq("'''", repeat(choice($._sq3_content, $.escape_sequence, $.interpolation)), "'''"),
        seq('"""', repeat(choice($._dq3_content, $.escape_sequence, $.interpolation)), '"""'),
      ),

    _sq_content: ($) =>
      alias(choice(token.immediate(prec(1, /[^'\\%\n]+/)), token.immediate(prec(1, '%'))), $.string_content),

    _dq_content: ($) =>
      alias(choice(token.immediate(prec(1, /[^"\\%\n]+/)), token.immediate(prec(1, '%'))), $.string_content),

    _sq3_content: ($) =>
      alias(
        choice(
          token.immediate(prec(1, /[^'\\%]+/)),
          token.immediate(prec(1, '%')),
          token.immediate("'"),
          token.immediate("''"),
        ),
        $.string_content,
      ),

    _dq3_content: ($) =>
      alias(
        choice(
          token.immediate(prec(1, /[^"\\%]+/)),
          token.immediate(prec(1, '%')),
          token.immediate('"'),
          token.immediate('""'),
        ),
        $.string_content,
      ),

    escape_sequence: (_) => token.immediate(prec(1, /\\(x[0-9A-Fa-f]{2}|u\{[0-9A-Fa-f]+\}|.|\n)/)),

    // `%{expr}`
    interpolation: ($) => seq(token.immediate(prec(2, '%{')), $._expression, '}'),
  },
});
