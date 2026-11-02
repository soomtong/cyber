; Indentation hints for editors that read indents.scm (nvim-treesitter, Helix).

[
  (function_definition)
  (type_declaration)
  (if_statement)
  (else_if_clause)
  (else_clause)
  (while_statement)
  (for_statement)
  (switch_statement)
  (switch_expression)
  (case_clause)
  (switch_else_clause)
  (try_statement)
  (catch_clause)
  (begin_statement)
  (lambda)
  (unwrap_or_block)
  (arguments)
  (parameters)
  (initializer)
] @indent.begin

[
  ")"
  "]"
  "}"
] @indent.branch @indent.end

[
  (return_statement)
  (break_statement)
  (continue_statement)
  (pass_statement)
] @indent.dedent
