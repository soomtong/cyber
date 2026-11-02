; Scopes

[
  (source_file)
  (block)
  (function_definition)
  (lambda)
  (infer_lambda)
  (for_statement)
  (while_statement)
  (if_statement)
  (case_clause)
] @local.scope

; Definitions

(parameter
  name: (identifier) @local.definition.parameter)

(infer_lambda
  (parameter) @local.definition.parameter)

(capture
  (identifier) @local.definition.var)

(variable_declaration
  name: (identifier) @local.definition.var)

(var_declaration
  name: (identifier) @local.definition.var)

(const_declaration
  name: (identifier) @local.definition.constant)

(global_declaration
  name: (identifier) @local.definition.var)

(function_definition
  name: (identifier) @local.definition.function)

(type_declaration
  name: (identifier) @local.definition.type)

(type_alias
  name: (identifier) @local.definition.type)

(use_statement
  name: (module_path
    (identifier) @local.definition.import .))

; References

(identifier) @local.reference
