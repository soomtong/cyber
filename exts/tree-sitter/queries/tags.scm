(function_definition
  receiver: (receiver)
  name: (_) @name) @definition.method

(function_definition
  !receiver
  name: (_) @name) @definition.function

(type_declaration
  name: (_) @name) @definition.class

(type_alias
  name: (_) @name) @definition.type

(case_declaration
  name: (_) @name) @definition.constant

(const_declaration
  name: (_) @name) @definition.constant

(global_declaration
  name: (_) @name) @definition.variable

(use_statement
  name: (module_path) @name) @reference.module

(call_expression
  function: [
    (identifier) @name
    (member_expression
      member: (identifier) @name)
  ]) @reference.call
