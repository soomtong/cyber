const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");
const test_config = @import("test_config");
const stdx = @import("stdx");
const t = stdx.testing;
const zeroInit = std.mem.zeroInit;

const cli = @import("cli.zig");
const log = std.log.scoped(.behavior_test);
const c = @import("capi.zig");
const setup = @import("test/setup.zig");
const eval = setup.eval;
const compile = setup.compile;
const evalPass = setup.evalPass;
const VMrunner = setup.VMrunner;
const Config = setup.Config;
const eqUserError = setup.eqUserError;
const EvalResult = setup.EvalResult;
const is_wasm = builtin.target.cpu.arch.isWasm();

const Case = struct {
    config: Config,
    skip: bool = false,
};

const Runner = struct {
    cases: std.ArrayList(Case),

    fn case(s: *Runner, path: []const u8) void {
        s.case2(.{ .uri = path });
    }

    fn case2(s: *Runner, config: Config) void {
        s.cases.append(t.alloc, Case{ .config = config }) catch @panic("error");
    }

    fn caseSkip(s: *Runner, path: []const u8) void {
        s.cases.append(t.alloc, Case{ .config = .{ .uri = path }, .skip = true }) catch @panic("error");
    }

    fn caseDebug(s: *Runner, path: []const u8) void {
        s.case2(.{ .debug=true, .uri=path});
    }
};

const caseFilter: ?[]const u8 = null;
// const caseFilter: ?[]const u8 = "meta.cy";
const failFast: bool = true;

pub fn isAot(backend: c.Backend) bool {
    return backend == c.BackendTCC or backend == c.BackendCC;
}

fn test_syntax(run: *Runner) void {
    run.case("syntax/adjacent_stmt_error.cy");
    run.case("syntax/range_no_end_error.cy");
    run.case("syntax/range_no_start_error.cy");
    run.case("syntax/range_decreasing_value_error.cy");
    run.case("syntax/slice_decreasing_range_error.cy");
    run.case("syntax/init_colon_error.cy");
    run.case("syntax/init_infer_empty_error.cy");
    run.case("syntax/init_infer_pairs_error.cy");
    run.case("syntax/bracket_list_literal_error.cy");
    run.case("syntax/bracket_list_one_error.cy");
    run.case("control_flow/for_range_no_start_error.cy");
    run.case("control_flow/for_in_error.cy");
    run.case("control_flow/for_comma_error.cy");
    run.case("syntax/vector_no_elem_type_error.cy");
    run.case("control_flow/switch_range_open_error.cy");
    run.case("syntax/block_no_child_error.cy");
    run.case("syntax/change_to_spaces_error.cy");
    run.case("syntax/change_to_tabs_error.cy");
    run.case("syntax/comment_first_line.cy");
    run.case("syntax/comment_last_line.cy");
    run.case("syntax/comment_multiple.cy");
    run.case("syntax/compact_block_error.cy");
    run.case("syntax/func_missing_param_type_error.cy");
    run.case("syntax/func_param_name_error.cy");
    run.case("syntax/float_exponent_separator_error.cy");
    run.case("syntax/oct_digit_separator_error.cy");
    run.case("syntax/dot_lit_space_error.cy");
    run.case("syntax/func_param_name_second_error.cy");
    run.case("syntax/lambda_param_name_error.cy");
    run.case("syntax/func_param_group.cy");
    run.case("syntax/indentation.cy");
    run.case("syntax/last_line_empty_indent.cy");
    run.case("syntax/no_stmts.cy");
    run.case("syntax/parse_end_error.cy");
    run.case("syntax/parse_middle_error.cy");
    run.case("syntax/parse_skip_shebang_error.cy");
    run.case("syntax/parse_skip_shebang_panic.cy");
    run.case("syntax/parse_start_error.cy");
    run.case("syntax/skip_utf8_bom.cy");
    run.case("syntax/stmt_end_error.cy");
    run.case("syntax/tabs_spaces_error.cy");
    run.case("syntax/tuple_field_group.cy");
    run.case("syntax/type_decl_eof.cy");
    run.case("syntax/type_missing_colon_error.cy");
    run.case("syntax/visibility.cy");
    run.case("syntax/wrap_stmts.cy");
}

fn test_functions(run: *Runner) void {
    run.case("functions/assign_capture_local_error.cy");
    run.case("functions/assign_error.cy");
    run.case("functions/call_at_ct.cy");
    run.case("functions/consteval_attr_error.cy");
    run.case("functions/unknown_hook_error.cy");
    run.case("functions/intrinsic_call_error.cy");
    run.case("meta/script_api.cy");
    run.case("core/symbol_at_lit_error.cy");
    run.case("functions/call_block.cy");
    run.case("functions/call_incompat_param_error.cy");
    run.case("functions/call_closure.cy");
    run.case("functions/call_closure_param_error.cy");
    run.case("functions/call_excess_args_error.cy");
    run.case("functions/call_excess_args_overloaded_error.cy");
    run.case("functions/call_overload_incompat_arg_error.cy");
    run.case("functions/call_overload_exact.cy");
    run.case("functions/cond_attr.cy");
    run.case("functions/cond_attr_skipped_error.cy");
    run.case("functions/cond_attr_skipped_method_error.cy");
    run.case("functions/call_overload_ret_only_error.cy");
    run.case("functions/overload_visibility_error.cy");
    run.case("functions/call_float_param_error.cy");
    run.case("functions/call_method_missing_error.cy");
    run.case("functions/call_method_sig_error.cy");
    run.case("functions/call_host.cy");
    run.case("functions/call_host_param_error.cy");
    run.case("functions/call_op.cy");
    run.case("functions/call_recursive.cy");
    run.case("functions/call_static_lambda_incompat_arg_error.cy");
    run.case("functions/call_struct_param.cy");
    run.case("functions/call_struct_param_error.cy");
    run.case("functions/call_template_method_error.cy");
    run.case("functions/call_typed_param.cy");
    run.case("functions/call_undeclared_error.cy");   
    run.case("functions/call_missing_assignment_error.cy");
    run.case("functions/decl_over_builtin.cy");
    run.case("functions/funcsym_type.cy");
    run.case("functions/inline_leaf.cy");
    run.case("functions/inline_leaf_panic.cy");
    run.case("functions/inline_call.cy");
    run.case("functions/inline_call_panic.cy");
    run.case("functions/inline_nested.cy");
    run.case("functions/inline_nested_panic.cy");
    run.case("functions/inline_loop.cy");
    run.case("functions/inline_loop_panic.cy");
    run.case("functions/inline_addr_param.cy");
    run.case("functions/func_type.cy");
    run.case("functions/func_type_closure_error.cy");
    run.case("functions/func_type_error.cy");
    run.case("functions/func_union_type.cy");
    run.case("functions/func_union_type_error.cy");
    run.case("functions/stack_grow_ptr_patch.cy");
    run.case("functions/too_many_locals_error.cy");
    run.case("functions/lambda.cy");
    run.case("functions/lambda_incompat_arg_error.cy");
    run.case("functions/main_func_overload_error.cy");
    run.case("functions/eval_order.cy");
    run.case("functions/main_func_panic.cy");
    run.case("functions/main_func_error_panic.cy");
    run.case("functions/main_func_error_ret_panic.cy");
    run.case("functions/main_func_result.cy");
    run.case("functions/main_func_sig_error.cy");
    run.case("functions/main_func_top_stmt_error.cy");
    run.case("functions/@init.cy");
    run.case("functions/overload.cy");
    run.case("functions/read_capture_local_error.cy");
    run.case("functions/capture_non_ref_error.cy");
    run.case("functions/static.cy");
    run.case("functions/struct_funcs.cy");
    run.case("functions/template_functions.cy");
    run.case("functions/template_method_error.cy");
}

fn test_memory(run: *Runner) void {
    run.case("memory/arc_cases.cy");
    run.case("memory/borrow.cy");
    run.case("memory/borrow_index_addr_error.cy");
    run.case("memory/call_with_ref_local.cy");
    run.case("memory/call_with_ref_rvalue.cy");
    run.case("memory/custom_deinit.cy");
    run.case("memory/host_str_params.cy");
    run.case("memory/slice_shared_buffer.cy");
    run.case("memory/future_resolver.cy");
    run.case("memory/return_local_move.cy");
    run.case("memory/release_expr_stmt_return.cy");
    run.case("memory/release_scope_end.cy");
    run.case("memory/lift_borrow_error.cy");
    run.case("memory/lift_borrow_container_error.cy");
    run.case("memory/lift_borrow_option_error.cy");
    run.case("memory/borrow_scope_release.cy");
    run.case("memory/array_append_move.cy");
    run.case("memory/array_nocopy_elem.cy");
    run.case("memory/array_nocopy_index_copy_error.cy");
    run.case("memory/array_nocopy_for_copy_error.cy");
    run.case("memory/array_nocopy_last_error.cy");
    run.case("memory/array_nocopy_literal_var_error.cy");
    run.case("memory/borrow_outlive_error.cy");
    run.case("memory/borrow_while_exclusive_error.cy");
    run.case("memory/exclusive_borrow_arg_conflict_error.cy");
    run.case("memory/exclusive_borrow_twice_error.cy");
    run.case("memory/receiver_borrow_while_exclusive_error.cy");
    run.case("memory/lift_moves_rvalue.cy");
    run.case("memory/move_local_to_return.cy");
    run.case("memory/move_use_after_error.cy");
    run.case("memory/override_copy.cy");
    run.case("memory/partial_move.cy");
    run.case("memory/partial_move_use_after_error.cy");
    run.case("memory/partial_move_ref_child_error.cy");
    run.case("memory/partial_move_struct_fields.cy");
    run.case("memory/partial_move_deinit_member_error.cy");
    run.case("memory/partial_move_copy_error.cy");
    run.case("memory/partial_move_borrow_error.cy");
    run.case("memory/partial_move_whole_error.cy");
    run.case("memory/partial_move_member_assign_block_error.cy");
    run.case("memory/program_deinit_order.cy");
    run.case("memory/return_moves_rvalue.cy");
    run.case("memory/return_borrow_scope_missing_error.cy");
    run.case("memory/return_borrow_container_scope_missing_error.cy");
    run.case("memory/scope_param_missing_error.cy");
    run.case("memory/scope_too_many_params_error.cy");
    run.case("memory/scope_return_error.cy");
    run.case("memory/scope_return_too_ephemeral_error.cy");
    run.case("memory/scope_return.cy");
    run.case("memory/scope_assign_shorter_span_lifetime_error.cy");
    run.case("memory/scope_assign_shorter_borrow_lifetime_error.cy");
    run.case("memory/sink_use_rec_after_error.cy");
    run.case("memory/sink_use_arg_after_error.cy");
}

fn test_types(run: *Runner) void {
    run.case("types/cast.cy");
    run.case("types/cast_error.cy");
    // // Failed to cast to abstract type at runtime.
    // try eval(.{ .silent = true },
    //     \\let a = 123
    //     \\print(a as string)
    // , struct { fn func(run: *VMrunner, res: EvalResult) !void {
    //     try run.expectErrorReport(res, error.Panic,
    //         \\panic: Can not cast `int` to `string`.
    //         \\
    //         \\main:2:9 main:
    //         \\print(a as string)
    //         \\        ^
    //         \\
    //     );
    // }}.func);
    run.case("types/choice_access_error.cy");
    run.case("types/choice_dup_case_error.cy");
    run.case("types/choice_type.cy");
    run.case("types/choice_unwrap_panic.cy");
    run.case("types/cstructs.cy");
    run.case("types/cunion_dup_case_error.cy");
    run.case("types/enum_dup_case_error.cy");
    run.case("types/enums.cy");
    run.case("types/func_return_type_error.cy");
    run.case("types/func_param_type_undeclared_error.cy");
    run.case("types/method_implicit_self_assign_error.cy");
    run.case("types/method_mut_self_array_field.cy");
    run.case("types/method_shadow_member.cy");
    run.case("types/objects.cy");
    run.case("types/object_downcast_panic.cy");
    run.case("types/object_init_object_field.cy");
    run.case("types/object_init_field.cy");
    run.case("types/object_init_field_error.cy");
    run.case("types/object_set_field.cy");
    run.case("types/object_set_field_error.cy");
    run.case("types/pointers.cy");
    run.case("types/PtrSpan.cy");
    run.case("types/Span.cy");
    run.case("types/Self.cy");
    run.case("types/struct_circular_dep_error.cy");
    run.case("types/struct_dup_field_error.cy");
    run.case("types/struct_init_field_name_error.cy");
    run.case("types/struct_init_mixed_error.cy");
    run.case("types/struct_init_mixed_const_error.cy");
    run.case("types/structs.cy");
    run.case("types/struct_default_initializer.cy");
    run.case("types/struct_init_undeclared_field_error.cy");
    run.case("types/struct_set_undeclared_field_error.cy");
    run.case("types/struct_too_many_fields_error.cy");
    run.case("types/struct_require_field_error.cy");
    run.case("types/struct_nested.cy");
    run.case("types/template_choices.cy");
    run.case("types/template_dep_param_type.cy");
    run.case("types/template_dep_param_type_error.cy");
    run.case("types/template_object_init_noexpand_error.cy");
    run.case("types/template_object_spec_noexpand_error.cy");
    run.case("types/template_object_expand_error.cy");
    run.case("types/template_structs.cy");
    run.case("types/template_const_params.cy");
    run.case("types/template_const_param_kinds.cy");
    run.case("types/template_const_param_type_error.cy");
    run.case("types/trait_error.cy");
    run.case("types/trait_param_type_error.cy");
    run.case("types/trait_param_count_error.cy");
    run.case("types/trait_param_extra_error.cy");
    run.case("types/trait.cy");
    run.case("types/tuple.cy");
    run.case("types/type_alias.cy");
    run.case("types/type_alias_path_decl_error.cy");
    run.case("types/type_embedding.cy");
    run.case("types/type_spec.cy");
    run.case("types/void.cy");
}

fn test_modules(run: *Runner) void {
    const backend = setup.fromTestBackend(test_config.test_backend);
    const aot = isAot(backend);
    if (!is_wasm) {
        run.case("modules/type_spec.cy");
        run.case("modules/type_alias.cy");
        run.case("modules/import_not_found_error.cy");
        run.case("modules/import_missing_sym_error.cy");
        run.case("modules/import_rel_path.cy");
        run.case("modules/import_implied_rel_path.cy");
        run.case("modules/import_stmt_error.cy");
        run.case("modules/import_unresolved_rel_path.cy");
        
        // Import when running main script in the cwd.
        run.case2(Config.init("./import_rel_path.cy").withChdir("./src/test/modules"));
        // Import when running main script in a child directory.
        run.case2(Config.init("../import_rel_path.cy").withChdir("./src/test/modules/test_mods"));

        run.case("modules/import.cy");
        run.case("modules/import_all.cy");
        run.case("modules/import_sym_alias.cy");
        run.case("modules/visibility.cy");
        run.case("modules/visibility_import_all.cy");
        run.case("modules/private_field_meta.cy");
        run.case("modules/private_func_error.cy");
        run.case("modules/private_method_error.cy");
        run.case("modules/private_field_error.cy");
        run.case("modules/private_field_init_error.cy");
        run.case("modules/private_field_assign_error.cy");
        run.case("modules/private_field_borrow_error.cy");
        run.case("modules/private_type_error.cy");
        run.case("modules/private_type_template_error.cy");
        run.case("modules/private_global_error.cy");
        run.case("modules/private_const_error.cy");
        run.case("modules/private_variant_func_error.cy");
        run.case("modules/private_variant_field_error.cy");
        run.case("modules/import_all_private_error.cy");
        run.case("modules/core_private_error.cy");
    }
    run.case("modules/core.cy");
if (!aot) {
    run.case("modules/cy.cy");
}

    run.case("modules/math.cy");
    run.case("modules/meta.cy");
    run.case("modules/test_eq_panic.cy");
    run.case("modules/test.cy");
    if (!is_wasm) {
        // Both call libc through extern functions, which need FFI.
        if (test_config.ffi and builtin.target.os.tag != .windows) {
            run.case("modules/libc.cy");
        }
        if (test_config.ffi and builtin.target.abi != .msvc) {
            run.case("modules/os.cy");
        }
    }
}

fn test_meta(run: *Runner) void {
    run.case("meta/ct_eval_loop.cy");
    run.case("meta/type_const.cy");
    run.case("meta/ct_if.cy");
    run.case("meta/ct_op_assign.cy");
    run.case("meta/ct_vector_index_error.cy");
    run.case("meta/get_panic.cy"); 
    run.case("meta/get_set.cy"); 
    run.case("meta/init_record.cy"); 
    run.case("meta/log.cy");
    run.case("meta/init_record_error.cy"); 
    run.case("meta/set_panic.cy"); 
    run.case("meta/type.cy");
}

fn test_concurrency(run: *Runner) void {
    const backend = setup.fromTestBackend(test_config.test_backend);
    const aot = isAot(backend);
if (!aot) {
    run.case("concurrency/await.cy");
    run.case("concurrency/generator.cy");
    run.case("concurrency/generator_method.cy");
    run.case("concurrency/yield_outside_generator_error.cy");
    run.case("concurrency/generator_borrow_param_error.cy");
    run.case("concurrency/generator_borrow_option_param_error.cy");
    run.case("concurrency/fiber.cy");
    run.case("concurrency/fiber_generator_entry_error.cy");
    run.case("concurrency/fiber_entry_ret_error.cy");
    run.case("concurrency/fiber_borrow_param_error.cy");
    run.case("concurrency/suspend_value_error.cy");
    run.case("concurrency/fiber_await.cy");
    run.case("concurrency/fiber_cancel.cy");
    run.case("concurrency/scope.cy");
    run.case("concurrency/scope_block.cy");
    run.case("concurrency/scope_block_no_result_error.cy");
    run.case("concurrency/scope_block_borrow.cy");
    run.case("concurrency/scope_block_borrow_inner_error.cy");
    run.case("concurrency/scope_block_borrow_exclusive_error.cy");
    run.case("concurrency/scope_start_borrow_error.cy");
    run.case("concurrency/scope_reentry_panic.cy");
    run.case("concurrency/scope_block_exit.cy");
    run.case("concurrency/fiber_method_entry_error.cy");
    run.case("concurrency/fiber_borrow_receiver_error.cy");
    run.case("concurrency/fiber_no_call_error.cy");
    run.case("concurrency/fiber_block_capture_error.cy");
    run.case("concurrency/fiber_in_progress_panic.cy");
    run.case("concurrency/fiber_running_panic.cy");
    run.case("concurrency/fiber_panic.cy");
    run.case("concurrency/future_wait_any.cy");
    run.case("concurrency/future_wait_any_empty_panic.cy");
    // The test sleeps with `os.sleep`, which calls an extern function.
    if (!is_wasm and test_config.ffi) {
        run.case("concurrency/fiber_await_spawn.cy");
    }
    if (!is_wasm) {
        run.case("concurrency/spawn.cy");
    }
}
}

fn test_core(run: *Runner) void {
    run.case("core/Array.cy");
    run.case("core/ArrayStore.cy");
    run.case("core/Array_oob_panic.cy");
    run.case("core/Array_neg_oob_panic.cy");
    run.case("core/arithmetic_ops.cy");
    run.case("core/arithmetic_unsupported_error.cy");
    run.case("core/bool.cy");
    run.case("core/byte.cy");
    run.case("core/raw_from_float_panic.cy");
    run.case("core/compare_eq.cy");
    run.case("core/compare_neq.cy");
    run.case("core/error_values.cy");
    run.case("core/escape_sequences.cy");
    run.case("core/floats.cy");
    run.case("core/ints.cy");
    run.case("core/int_unsupported_notation_error.cy");
    run.case("core/int_literal_overflow_error.cy");
    run.case("core/logic_ops.cy");
    run.case("core/map_index_panic.cy");
    run.case("core/Map.cy");
    run.case("core/op_precedence.cy");
    run.case("core/optionals_incompat_value_error.cy");
    run.case("core/optionals_unwrap_panic.cy");
    run.case("core/Option.cy");
    run.case("core/option_unwrap_block_reachable_error.cy");
    run.case("core/panic_panic.cy");
    run.case("core/PartialVector.cy");
    run.case("core/raw_string_single_quote_error.cy");
    run.case("core/raw_string_new_line_error.cy");
    run.case("core/Result.cy");
    run.case("core/print_result_error.cy");
    run.case("core/interpolate_result_error.cy");
    run.case("core/method_suggest_camel_error.cy");
    run.case("core/method_suggest_alias_error.cy");
    run.case("core/method_suggest_join_error.cy");
    run.case("core/method_suggest_none_error.cy");
    run.case("core/result_unwrap_block_reachable_error.cy");
    run.case("core/result_infer_return.cy");
    run.case("core/rune_empty_lit_error.cy");
    run.case("core/rune_multiple_lit_error.cy");
    run.case("core/rune_grapheme_cluster_lit_error.cy");
    run.case("core/set_index_unsupported_error.cy");
    run.case("core/Slice.cy");
    run.case("core/Slice_oob_panic.cy");
    run.case("core/Array_remove_oob_panic.cy");
    run.case("core/Array_size_up_neg_panic.cy");
    run.case("core/Array_init_neg_len_panic.cy");
    run.case("core/Array_init_overflow_len_panic.cy");
    run.case("core/Array_slice_neg_panic.cy");
    run.case("core/Slice_open_start_neg_panic.cy");
    run.case("core/Slice_remove_oob_panic.cy");
    run.case("core/Slice_size_up_neg_panic.cy");
    run.case("core/Slice_init_neg_len_panic.cy");
    run.case("core/Slice_slice_neg_panic.cy");
    run.case("core/Span_slice_neg_panic.cy");
    run.case("core/Buffer.cy");
    run.case("core/Buffer_slice_neg_panic.cy");
    run.case("core/str_repeat_overflow_panic.cy");
    run.case("core/Slice_neg_oob_panic.cy");
    run.case("core/str_new_line_error.cy");
    run.case("core/str_interpolation.cy");
    run.case("core/str_runeAt_neg_oob_panic.cy");
    run.case("core/str_runeAt_oob_panic.cy");
    run.case("core/str_index_neg_oob_panic.cy");
    run.case("core/str_index_oob_panic.cy");
    run.case("core/strings.cy");
    run.case("core/strings_ascii.cy");
    run.case("core/strings_utf8.cy");
    run.case("core/symbols.cy");
    run.case("core/Vector.cy");
    run.case("core/Vector_neg_oob_panic.cy");
    run.case("core/Vector_oob_panic.cy");
    run.case("core/wyhash.cy");
}

fn test_vars(run: *Runner) void {
    run.case("vars/const.cy");
    run.case("vars/const_init_rtval_error.cy");
    run.case("vars/const_init_ctval_error.cy");
    run.case("vars/const_write_error.cy");
    run.case("vars/local_assign_error.cy");
    run.case("vars/local_assign.cy");
    run.case("vars/local_attr_error.cy");
    run.case("vars/local_dup_error.cy");
    run.case("vars/local_init.cy");
    run.case("vars/local_shadow.cy");
    run.case("vars/local_no_shadow_for_capture.cy");
    run.case("vars/op_assign.cy");
    run.case("vars/read_undeclared_error.cy");
    run.case("vars/read_undeclared_diff_scope_error.cy");
    run.case("vars/read_outside_if_var_error.cy");
    run.case("vars/read_outside_for_iter_error.cy");
    run.case("vars/read_outside_for_var_error.cy");
    run.case("vars/set_undeclared_error.cy");
    run.case("vars/global_assign.cy");
    run.case("vars/global_init.cy");
    if (!is_wasm) {
        run.case("vars/global_init_call.cy");
    }
    run.case("vars/global_init_call_error.cy");
    run.case("vars/global_init_call_self_error.cy");
    run.case("vars/global_init_call_lambda_error.cy");
    run.case("vars/global_init_call_trait_error.cy");
    run.case("vars/global_init_call_deinit_error.cy");
    run.case("vars/global_init_capture_error.cy");
    run.case("vars/global_init_ref_error.cy");
    run.case("vars/global_init_ref_self_error.cy");
    run.case("vars/global_init_type_error.cy");
}

fn test_control_flow(run: *Runner) void {
    run.case("control_flow/for_iter.cy");
    run.case("control_flow/for_iter_unsupported_error.cy");
    run.case("control_flow/for_iter_borrow_unsupported_error.cy");
    run.case("control_flow/for_iter_index_borrow_error.cy");
    run.case("meta/infer_param_outside_func_error.cy");
    run.case("meta/infer_param_type_arg_error.cy");
    run.case("meta/type_size_str_arg_error.cy");
    run.case("meta/type_size_trait_error.cy");
    run.case("functions/template_func_value_error.cy");
    run.case("functions/builtin_func_value_error.cy");
    run.case("functions/func_sym_lift_error.cy");
    run.case("functions/func_sym_addr_error.cy");
    run.case("syntax/func_parent_no_name_error.cy");
    run.case("syntax/global_parent_no_name_error.cy");
    run.case("types/trait_option_child_error.cy");
    run.case("types/trait_field_error.cy");
    run.case("concurrency/generator_copy_error.cy");
    run.case("types/trait_func_type_arg_error.cy");
    run.case("meta/type_info_trait.cy");
    run.case("meta/ct_switch_top_level_error.cy");
    run.case("control_flow/for_iter_borrow_mutate_error.cy");
    run.case("control_flow/for_range.cy");
    run.case("control_flow/if_expr.cy");
    run.case("control_flow/if_expr_error.cy");
    run.case("control_flow/if_stmt.cy");
    run.case("control_flow/if_unwrap.cy");
    run.case("control_flow/return.cy");
    run.case("control_flow/switch.cy");
    run.case("control_flow/switch_error.cy");
    run.case("control_flow/switch_capture_non_choice_error.cy");
    run.case("control_flow/switch_choice_else_error.cy");
    run.case("control_flow/switch_choice_dup_case_error.cy");
    run.case("control_flow/switch_choice_unhandled_error.cy");
    run.case("control_flow/try_error.cy");
    run.case("control_flow/try.cy");
    run.case("control_flow/try_block.cy");
    run.case("control_flow/try_block_else_error.cy");
    run.case("control_flow/try_block_capture_error.cy");
    run.case("control_flow/try_panic.cy");
    run.case("control_flow/unreachable.cy");
    // Disabled: statements after an unreachable statement are allowed (sema.zig `semaStmt`).
    // run.case("control_flow/unreachable_error.cy");
    run.case("control_flow/while_cond.cy");
    run.case("control_flow/while_inf.cy");
    run.case("control_flow/while_unwrap.cy");
}

// TODO: This could be split into compiler only tests and backend tests.
//       Compiler tests would only need to be run once.
//       Right now we just run everything again since it's not that much.
test "Tests." {
    var run = Runner{ .cases = .empty };
    defer run.cases.deinit(t.alloc);

    test_syntax(&run);
    test_functions(&run);
    test_memory(&run);
    test_types(&run);
    test_modules(&run);
    test_meta(&run);
    test_concurrency(&run);
    test_core(&run);
    test_vars(&run);
    test_control_flow(&run);

    run.case("../tokenizer.cy");

    var numPassed: u32 = 0;
    var skipped: u32 = 0;
    defer std.debug.print("Tests passed: {}/{}, skipped: {}\n", .{numPassed, run.cases.items.len, skipped});
    for (run.cases.items) |run_case| {
        if (caseFilter) |filter| {
            if (std.mem.find(u8, run_case.config.uri, filter) == null) {
                continue;
            }
        }
        std.debug.print("test: {s}\n", .{run_case.config.uri});

        if (run_case.skip) {
            skipped += 1;
            continue;
        }

        errdefer std.debug.print("failed test: {s}\n", .{run_case.config.uri});
        case2(run_case.config) catch |err| {
            std.debug.print("Failed: {}\n", .{err});
            if (failFast) {
                return err;
            } else {
                continue;
            }
        };
        numPassed += 1;
    }
    if (numPassed < run.cases.items.len) {
        return error.Failed;
    }
}

test "Compile." {
    // examples.
    // try compileCase(.{}, "../examples/fiber.cy");
    try compileCase("../examples/fizzbuzz.cy");
    try compileCase("../examples/hello.cy");
    if (!is_wasm) {
        try compileCase("../examples/ffi.cy");
    }
    try compileCase("../examples/account.cy");
    try compileCase("../examples/fibonacci.cy");

    // tools.
    try compileCase("tools/bench.cy");
    if (!is_wasm) {
        // TODO: Temporary skipping these tests because they involve ffi binding. However, compilation shouldn't involve any binding.
        try compileCase("tools/clang_bs.cy");
        try compileCase("tools/llvm.cy");
        try compileCase("tools/md4c.cy");
        try compileCase("tools/cbindgen.cy");
        try compileCase("../docs/gen-docs.cy");
    }

    // benchmarks.
    try compileCase("test/bench/alloc/alloc.cy");
    try compileCase("test/bench/fib/fib.cy");
    try compileCase("test/bench/fiber/fiber.cy");
    try compileCase("test/bench/for/for.cy");
    try compileCase("test/bench/heap/heap.cy");
    try compileCase("test/bench/string/index.cy");
}

fn compileCase(path: []const u8) !void {
    std.debug.print("test: {s}\n", .{path});
    const fpath = try std.mem.concat(t.alloc, u8, &.{ "src/", path });
    defer t.alloc.free(fpath);
    try compile(.{ .uri = fpath, .silent = false }, null);
}

test "FFI." {
    if (is_wasm or !test_config.ffi or builtin.target.abi == .msvc) {
        return;
    }

    // TODO: Test callback failure and verify stack trace.
    // Currently, the VM aborts when encountering a callback error.
    // A config could be added to make the initial FFI call detect an error and throw a panic instead.

    try case("ffi/ffi.cy");
}

test "windows new lines" {
    try eval(.{ .silent = true }, "a = 123\r\nb = 234\r\nc =",
    struct { fn func(run: *VMrunner, res: EvalResult) !void {
        try run.expectErrorReport(res, c.ErrorCompile,
            \\ParseError: Expected right expression for assignment statement.
            \\
            \\@MainPath():3:4:
            \\c =
            \\   ^
            \\
        );
    }}.func);
}

// test "Function named parameters call." {
//     const run = VMrunner.create();
//     defer run.destroy();

//     var val = try run.eval(
//         \\func foo(a, b):
//         \\  return a - b
//         \\foo(a: 3, b: 1)
//     );
//     try t.eq(val.asF64toI32(), 2);
//     run.deinitValue(val);

//     val = try run.eval(
//         \\func foo(a, b):
//         \\  return a - b
//         \\foo(a: 1, b: 3)
//     );
//     try t.eq(val.asF64toI32(), -2);
//     run.deinitValue(val);

//     // New line as arg separation.
//     val = try run.eval(
//         \\func foo(a, b):
//         \\  return a - b
//         \\foo(
//         \\  a: 3
//         \\  b: 1
//         \\)
//     );
//     try t.eq(val.asF64toI32(), 2);
//     run.deinitValue(val);
// }

// test "@name" {
//     const run = VMrunner.create();
//     defer run.destroy();

//     const parse_res = try run.parse(
//         \\@name foo
//     );
//     try t.eqStr(parse_res.name, "foo");

//     if (build_options.cyEngine == .qjs) {
//         // Compile step skips the statement.
//         const compile_res = try run.compile(
//             \\@name foo
//         );
//         try t.eqStr(compile_res.output, "(function () {});");
//     }
// }

fn case(path: []const u8) !void {
    try case2(Config.init(path));
}

fn seekCommentEnd(str: []const u8, start: usize) usize {
    var idx = start;
    while (true) {
        if (str[idx..].len >= 3 and str[idx] == '\n' and str[idx+1] == '-' and str[idx+2] == '-') {
            idx += 1;
            if (std.mem.findScalarPos(u8, str, idx, '\n')) |nl| {
                idx = nl;
            } else {
                idx = str.len;
            }
        } else {
            break;
        }
    }
    return idx;
}

fn case2(config: Config) !void {
    var contents: []const u8 = undefined;
    var final_path: []const u8 = undefined;
    if (config.chdir) |chdir| {
        const path = try t.alloc.print("{s}/{s}", .{chdir, config.uri});
        defer t.alloc.free(path);
        contents = try std.Io.Dir.cwd().readFileAlloc(stdx.io(), path, t.alloc, .limited(1e9));
        final_path = try t.alloc.dupe(u8, config.uri);
    } else {
        final_path = try std.mem.concat(t.alloc, u8, &.{"src/test/", config.uri});
        contents = try std.Io.Dir.cwd().readFileAlloc(stdx.io(), final_path, t.alloc, .limited(1e9));
    }
    defer t.alloc.free(final_path);
    defer t.alloc.free(contents);

    var idx = std.mem.find(u8, contents, "cytest:") orelse {
        return error.MissingTestDefinition;
    };

    var rest = contents[idx+7..];
    idx = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
    const test_t = std.mem.trim(u8, rest[0..idx], " ");

    if (std.mem.eql(u8, test_t, "error")) {
        const start = idx+1;
        const end = seekCommentEnd(rest, idx);
        const exp = rest[start..end];

        var buf: [1024]u8 = undefined;
        const len = std.mem.replacementSize(u8, exp, "--", "");
        _ = std.mem.replace(u8, exp, "--", "", &buf);

        const Context = struct {
            exp: []const u8,
        };
        var ctx = Context{ .exp = buf[0..len]};
        var fconfig: Config = config;
        fconfig.uri = final_path;
        fconfig.silent = true;
        fconfig.ctx = &ctx;
        try eval(fconfig, null
        , struct { fn func(run: *VMrunner, res: EvalResult) !void {
            const ctx_: *Context = @ptrCast(@alignCast(run.ctx));
            try run.expectErrorReport2(res, ctx_.exp, false);
        }}.func);
    } else if (std.mem.eql(u8, test_t, "panic")) {
        const start = idx;
        var buf: [1024]u8 = undefined;
        const len = std.mem.replacementSize(u8, rest[start..], "\n--", "\n");
        _ = std.mem.replace(u8, rest[start..], "\n--", "\n", &buf);
        const cur = buf[0..len];
        _ = cur;

        var exp_str: []const u8 = undefined;
        const backend = setup.fromTestBackend(test_config.test_backend);
        const aot = isAot(backend);

        const trace_idx = std.mem.find(u8, buf[0..len], "[trace]") orelse {
            return error.MissingExpectedTrace;
        };
        if (!aot) {
            const starts_with = buf[1..trace_idx];
            const ends_with = buf[trace_idx+8..len];
            const Context2 = struct {
                exp_start: []const u8,
                exp_end: []const u8,
            };
            var ctx = Context2{ .exp_start = starts_with, .exp_end = ends_with };
            var fconfig: Config = config;
            fconfig.uri = final_path;
            fconfig.ctx = &ctx;
            try eval(fconfig, null
            , struct { fn func(run: *VMrunner, res: EvalResult) !void {
                const ctx_: *Context2 = @ptrCast(@alignCast(run.ctx));
                try run.expectErrorReport3(res, ctx_.exp_start, ctx_.exp_end);
            }}.func);
            return;
        } else {
            exp_str = buf[1..trace_idx-1];
        }

        const Context = struct {
            exp: []const u8,
        };
        var ctx = Context{ .exp = exp_str };
        var fconfig: Config = config;
        fconfig.uri = final_path;
        fconfig.silent = true;
        fconfig.ctx = &ctx;
        try eval(fconfig, null
        , struct { fn func(run: *VMrunner, res: EvalResult) !void {
            const ctx_: *Context = @ptrCast(@alignCast(run.ctx));
            const backend_ = setup.fromTestBackend(test_config.test_backend);
            const aot_ = isAot(backend_);
            try run.expectErrorReport2(res, ctx_.exp, aot_);
        }}.func);
    } else if (std.mem.eql(u8, test_t, "pass")) {
        var fconfig: Config = config;
        fconfig.silent = false;
        fconfig.uri = final_path;
        try evalPass(fconfig, null);
    } else {
        return error.UnsupportedTestType;
    }
}
