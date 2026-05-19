"""Tests for the !$SER directive preprocessor."""

import pytest

from preserf.errors import DirectiveError
from preserf.preprocessor import Options, Preprocessor


def expand(source: str, **opts: object) -> str:
    """Preprocess ``source`` and return the generated Fortran."""
    return Preprocessor("test.f90", source, Options(**opts)).process()  # type: ignore[arg-type]


# --- general behaviour -----------------------------------------------------


def test_acc_prefix_header_emitted_by_default() -> None:
    assert expand("x = 1\n").startswith("#define ACC_PREFIX !$acc\n")


def test_acc_prefix_header_suppressed() -> None:
    assert "ACC_PREFIX" not in expand("x = 1\n", acc_prefix=False)


def test_non_directive_source_is_passed_through() -> None:
    out = expand("x = 1\ny = 2\n", acc_prefix=False)
    assert out == "x = 1\ny = 2\n"


def test_directive_block_is_ifdef_guarded() -> None:
    out = expand("!$SER ON\n")
    assert "#ifdef SERIALIZE\n" in out
    assert out.rstrip().endswith("#endif")


def test_custom_ifdef_symbol() -> None:
    out = expand("!$SER ON\n", ifdef="MYGUARD")
    assert "#ifdef MYGUARD\n" in out
    assert "#ifdef SERIALIZE" not in out


def test_empty_ifdef_disables_guards() -> None:
    out = expand("!$SER ON\n", ifdef="")
    assert "#ifdef" not in out
    assert "call fs_enable_serialization()" in out


def test_bare_ser_line_produces_no_call() -> None:
    out = expand("!$SER\n")
    assert "call " not in out
    assert "#ifdef SERIALIZE\n!$SER\n#endif\n" in out


# --- INIT / CLEANUP --------------------------------------------------------


def test_init_expands_to_initialize_call() -> None:
    out = expand("!$SER INIT singlefile=.true.\n")
    assert "call ppser_initialize( &" in out
    assert "singlefile=.true.)" in out
    assert "WARNING: SERIALIZATION IS ON" in out


def test_init_with_if_clause() -> None:
    out = expand("!$SER INIT dir prefix IF myflag\n")
    assert "IF (myflag) THEN" in out
    assert "ENDIF" in out
    assert "dir, &" in out and "prefix)" in out


def test_cleanup_expands_to_finalize_call() -> None:
    assert "call ppser_finalize()" in expand("!$SER CLEANUP\n")


def test_cleanup_passes_arguments() -> None:
    assert "call ppser_finalize(foo,bar)" in expand("!$SER CLE foo bar\n")


# --- SAVEPOINT -------------------------------------------------------------


def test_savepoint_with_metainfo() -> None:
    out = expand("!$SER SAVEPOINT sp1 step=ntstep\n")
    assert "call fs_create_savepoint('sp1', ppser_savepoint)" in out
    assert "call fs_add_savepoint_metainfo(ppser_savepoint, 'step', ntstep)" in out


def test_savepoint_as_variable() -> None:
    out = expand("!$SER SAVEPOINT spvar\n", sp_as_var=True)
    assert "call fs_create_savepoint(spvar, ppser_savepoint)" in out


def test_savepoint_requires_exactly_one_name() -> None:
    with pytest.raises(DirectiveError, match="Must specify a name"):
        expand("!$SER SAVEPOINT a b\n")


# --- DATA / ACCDATA --------------------------------------------------------


def test_data_emits_all_three_modes() -> None:
    out = expand("!$SER DATA u=u(:,:,:,n)\n")
    assert "SELECT CASE ( ppser_get_mode() )" in out
    assert "CASE(0)" in out and "CASE(1)" in out and "CASE(2)" in out
    assert "call fs_write_field(ppser_serializer, ppser_savepoint, 'u'," in out
    assert "call fs_read_field(ppser_serializer_ref, ppser_savepoint, 'u'," in out
    assert "ppser_zrperturb)" in out
    assert "END SELECT" in out


def test_data_computed_field_is_write_only() -> None:
    out = expand("!$SER DATA v=a+b\n")
    assert "fs_write_field" in out
    assert "fs_read_field" not in out


def test_data_merge_expression_is_write_only() -> None:
    out = expand("!$SER DATA v=merge(1,0,mask)\n")
    assert "fs_write_field" in out
    assert "fs_read_field" not in out


def test_data_uppercase_merge_is_write_only() -> None:
    # Fortran intrinsic names are case-insensitive, so MERGE is computed too.
    out = expand("!$SER DATA v=MERGE(1,0,mask)\n")
    assert "fs_write_field" in out
    assert "fs_read_field" not in out


def test_data_field_named_like_merge_is_read_back() -> None:
    # "emerge" contains "merge" but is a plain field, not a computed value.
    out = expand("!$SER DATA emerge=emerge(:)\n")
    assert "fs_read_field" in out


def test_data_rejects_positional_argument() -> None:
    # A missing "=" (e.g. "v" instead of "v=v") must not be silently dropped.
    with pytest.raises(DirectiveError, match="field=value pairs"):
        expand("!$SER DATA u=u v\n")


def test_accdata_emits_openacc_updates() -> None:
    out = expand("!$SER ACCDATA u=u(:)\n")
    assert "ACC_PREFIX UPDATE HOST ( u(:) )" in out
    assert "ACC_PREFIX UPDATE DEVICE ( u(:) )" in out


def test_accdata_acc_if_clause() -> None:
    out = expand("!$SER ACC u=u(:)\n", acc_if="lacc")
    assert "ACC_PREFIX UPDATE HOST ( u(:) ), IF (lacc)" in out


# --- MODE ------------------------------------------------------------------


@pytest.mark.parametrize(
    ("mode", "expected"),
    [("write", "0"), ("read", "1"), ("read-perturb", "2"), ("GPU", "1")],
)
def test_mode_symbolic_values(mode: str, expected: str) -> None:
    assert f"call ppser_set_mode({expected})" in expand(f"!$SER MODE {mode}\n")


def test_mode_passthrough_for_expression() -> None:
    assert "call ppser_set_mode(my_mode)" in expand("!$SER MODE my_mode\n")


def test_mode_requires_argument() -> None:
    with pytest.raises(DirectiveError, match="exactly one serialization mode"):
        expand("!$SER MODE\n")


def test_mode_with_if_clause() -> None:
    out = expand("!$SER MODE write IF flag\n")
    assert "IF (flag) THEN" in out
    assert "call ppser_set_mode(0)" in out


def test_mode_if_keyword_without_value_is_error() -> None:
    with pytest.raises(DirectiveError, match="exactly one serialization mode"):
        expand("!$SER MODE IF flag\n")


def test_mode_rejects_extra_arguments() -> None:
    with pytest.raises(DirectiveError, match="exactly one serialization mode"):
        expand("!$SER MODE write extra\n")


# --- REGISTER --------------------------------------------------------------


def test_register_with_shortcut() -> None:
    out = expand("!$SER REGISTER u real IJK\n")
    assert (
        "call fs_register_field(ppser_serializer, 'u', ppser_realtype, "
        "ppser_reallength, ie, je, ke, 0, nboundlines, nboundlines, "
        "nboundlines, nboundlines, 0, 0, 0, 0)" in out
    )


def test_register_integer_type() -> None:
    out = expand("!$SER REGISTER n integer 1\n")
    assert "call fs_register_field(ppser_serializer, 'n', 'int', " in out
    assert "ppser_intlength, 1)" in out


def test_register_scalar_uses_empty_shortcut() -> None:
    out = expand("!$SER REGISTER dts real\n")
    assert "'dts', ppser_realtype, ppser_reallength, 1, 0, 0, 0, 0," in out


def test_register_unknown_type_is_error() -> None:
    with pytest.raises(DirectiveError, match="not understood"):
        expand("!$SER REGISTER u fs_realtype IJK\n")


def test_register_requires_name_and_type() -> None:
    with pytest.raises(DirectiveError, match="Must specify a name"):
        expand("!$SER REGISTER u\n")


def test_register_rejects_field_metainfo() -> None:
    with pytest.raises(DirectiveError, match="not yet implemented"):
        expand("!$SER REGISTER u real key=val\n")


# --- ZERO ------------------------------------------------------------------


def test_zero_assigns_fields() -> None:
    out = expand("!$SER ZERO a b\n", real="wp")
    assert "a = 0.0_wp" in out
    assert "b = 0.0_wp" in out


def test_zero_rejects_key_value() -> None:
    with pytest.raises(DirectiveError, match="Must specify a list of fields"):
        expand("!$SER ZERO a=1\n")


def test_zero_requires_fields() -> None:
    with pytest.raises(DirectiveError, match="Must specify a list of fields"):
        expand("!$SER ZERO\n")


# --- VERBATIM / METAINFO / OPTION ------------------------------------------


def test_verbatim_emits_code_without_annotation() -> None:
    out = expand("!$SER VERBATIM real :: x\n")
    assert "real :: x" in out
    assert "! file:" not in out


def test_metainfo_positionals_and_pairs() -> None:
    out = expand("!$SER METAINFO flag count=ntot\n")
    assert 'call fs_add_serializer_metainfo(ppser_serializer, "count", ntot)' in out
    assert 'call fs_add_serializer_metainfo(ppser_serializer, "flag", flag)' in out


def test_key_value_with_equals_in_value() -> None:
    # A '=' inside a quoted value must not break key=value splitting.
    out = expand("!$SER METAINFO tag='a=b'\n")
    assert "'a=b'" in out


def test_option_verbosity_mapping() -> None:
    assert "call fs_Option(verbosity=1)" in expand("!$SER OPTION verbosity=on\n")
    assert "call fs_Option(verbosity=0)" in expand("!$SER OPTION verbosity=off\n")


def test_option_rejects_positional() -> None:
    with pytest.raises(DirectiveError, match="key=value pairs"):
        expand("!$SER OPTION foo\n")


# --- DATA_KBUFF / tracers --------------------------------------------------


def test_data_kbuff_expansion() -> None:
    out = expand("!$SER DATA_KBUFF k=kidx k_size=ksz f=field\n")
    assert (
        "call fs_write_kbuff(ppser_serializer, ppser_savepoint, 'f', field, "
        "k=kidx, k_size=ksz, mode=ppser_get_mode())" in out
    )


def test_data_kbuff_requires_k_and_k_size() -> None:
    with pytest.raises(DirectiveError, match="k and k_size"):
        expand("!$SER DATA_KBUFF f=field\n")


def test_data_kbuff_rejects_positional_argument() -> None:
    with pytest.raises(DirectiveError, match="field=value pairs"):
        expand("!$SER DATA_KBUFF k=ki k_size=ks field\n")


def test_data_kbuff_imports_write_kbuff() -> None:
    src = "module m\n!$SER DATA_KBUFF k=ki k_size=ks f=field\nend module m\n"
    out = expand(src)
    use_block = out[out.index("USE m_serialize") : out.index("call fs_write_kbuff")]
    assert "fs_write_kbuff" in use_block


def test_data_kbuff_keeps_intent_of_index_variables() -> None:
    src = (
        "subroutine s(field, ki, ks)\n"
        "real, intent(in) :: field\n"
        "integer, intent(in) :: ki, ks\n"
        "!$SER DATA_KBUFF k=ki k_size=ks f=field\n"
        "end subroutine s\n"
    )
    out = expand(src)
    # The serialized field loses INTENT(IN); the k / k_size index variables
    # are never written, so their INTENT(IN) is preserved.
    assert "real :: field" in out
    assert "integer, intent(in) :: ki, ks" in out


def test_registertracers() -> None:
    assert "call fs_RegisterAllTracers()" in expand("!$SER REGISTERTRACERS\n")


def test_registertracers_rejects_arguments() -> None:
    with pytest.raises(DirectiveError, match="Takes no arguments"):
        expand("!$SER REGISTERTRACERS IF flag\n")


def test_tracer_by_name() -> None:
    out = expand("!$SER TRACER QV#tens@nnow\n")
    assert "call ppser_write_tracer_by_name('QV', stype='tens', timelevel=nnow)" in out


def test_tracer_by_index_range() -> None:
    out = expand("!$SER TRACER $a-b\n")
    assert "call ppser_write_tracer_by_idx(a, b, stype='')" in out


def test_tracer_all() -> None:
    assert "call ppser_write_tracer_all(stype='')" in expand("!$SER TRACER %all\n")


def test_tracer_invalid_spec() -> None:
    with pytest.raises(DirectiveError, match="invalid"):
        expand("!$SER TRACER ###\n")


def test_tracer_spec_with_trailing_junk_is_invalid() -> None:
    # An unrecognized type suffix must not be silently truncated away.
    with pytest.raises(DirectiveError, match="invalid"):
        expand("!$SER TRACER QV#badtype\n")


def test_tracer_imports_write_routine() -> None:
    src = "module m\n!$SER TRACER QV\nend module m\n"
    out = expand(src)
    use_block = out[
        out.index("USE utils_ppser") : out.index("call ppser_write_tracer_by_name")
    ]
    assert "ppser_write_tracer_by_name" in use_block


# --- ON / OFF --------------------------------------------------------------


def test_on_off() -> None:
    assert "call fs_enable_serialization()" in expand("!$SER ON\n")
    assert "call fs_disable_serialization()" in expand("!$SER OFF\n")


def test_on_rejects_arguments() -> None:
    with pytest.raises(DirectiveError, match="Takes no arguments"):
        expand("!$SER ON IF flag\n")


def test_off_rejects_arguments() -> None:
    with pytest.raises(DirectiveError, match="Takes no arguments"):
        expand("!$SER OFF extra\n")


# --- errors ----------------------------------------------------------------


def test_unknown_directive() -> None:
    with pytest.raises(DirectiveError, match="Unknown directive"):
        expand("!$SER FOOBAR\n")


def test_if_must_be_last() -> None:
    with pytest.raises(DirectiveError, match="IF statement must be last"):
        expand("!$SER DATA u=u IF a IF b\n")


def test_if_without_condition_is_error() -> None:
    with pytest.raises(DirectiveError, match="IF must be followed by a condition"):
        expand("!$SER DATA u=u IF\n")


def test_tracer_if_without_condition_is_error() -> None:
    with pytest.raises(DirectiveError, match="IF must be followed by a condition"):
        expand("!$SER TRACER QV IF\n")


def test_unterminated_module() -> None:
    with pytest.raises(DirectiveError, match="Unterminated module"):
        expand("module m\n!$SER ON\n")


def test_mismatched_end_module() -> None:
    with pytest.raises(DirectiveError, match="Was expecting"):
        expand("module m\n!$SER ON\nend module other\n")


def test_bad_line_continuation() -> None:
    with pytest.raises(DirectiveError, match="Incorrect line continuation"):
        expand("!$SER DATA u=u &\nx = 1\n")


def test_dangling_continuation_at_eof() -> None:
    with pytest.raises(DirectiveError, match="Incorrect line continuation"):
        expand("!$SER DATA u=u &\n")


def test_dangling_continuation_at_eof_without_guards() -> None:
    with pytest.raises(DirectiveError, match="Incorrect line continuation"):
        expand("!$SER DATA u=u &\n", ifdef="")


# --- line continuation -----------------------------------------------------


def test_directive_line_continuation() -> None:
    out = expand("!$SER DATA a=x &\n!$SER&     b=y\n")
    assert "'a', x)" in out
    assert "'b', y)" in out


def test_continuation_prefix_is_case_insensitive() -> None:
    out = expand("!$SER DATA a=x &\n!$SER&  b=y\n")
    assert "'a', x)" in out and "'b', y)" in out


# --- USE statement injection ----------------------------------------------


def test_use_statement_injected_after_module() -> None:
    out = expand("module m\n!$SER ON\nend module m\n")
    assert "USE m_serialize, ONLY: &" in out
    assert "fs_enable_serialization" in out
    assert "USE utils_ppser, ONLY:  &" in out
    use_idx = out.index("USE m_serialize")
    assert out.index("module m") < use_idx < out.index("call fs_enable")


def test_use_statement_after_standalone_subroutine() -> None:
    src = "subroutine s()\n!$SER ON\nend subroutine s\n"
    out = expand(src)
    assert out.index("subroutine s()") < out.index("USE m_serialize")


def test_use_block_not_repeated_in_program_subprograms() -> None:
    src = (
        "program p\n"
        "!$SER ON\n"
        "contains\n"
        "subroutine s()\n"
        "!$SER OFF\n"
        "end subroutine s\n"
        "end program p\n"
    )
    out = expand(src)
    # The program-level USE is host-associated into contained procedures,
    # so it must be injected exactly once.
    assert out.count("USE utils_ppser") == 1


def test_extra_modules_added_to_use_block() -> None:
    out = expand("module m\n!$SER ON\nend module m\n", modules=("extra_mod",))
    assert "USE extra_mod\n" in out


def test_use_block_is_deterministic() -> None:
    src = "module m\n!$SER DATA u=u\n!$SER SAVEPOINT sp\nend module m\n"
    assert expand(src) == expand(src)


def test_process_is_idempotent_on_reuse() -> None:
    src = "module m\n!$SER DATA u=u\n!$SER SAVEPOINT sp\nend module m\n"
    pp = Preprocessor("test.f90", src)
    assert pp.process() == pp.process()


# --- intent(in) removal ----------------------------------------------------


def test_intent_in_removed_for_read_fields() -> None:
    src = "subroutine s(u)\nreal, intent(in) :: u\n!$SER DATA u=u\nend subroutine s\n"
    out = expand(src)
    assert "#else" in out
    assert "real :: u" in out
    assert "real, intent(in) :: u" in out


def test_intent_in_removed_unconditionally_when_guards_disabled() -> None:
    src = "subroutine s(u)\nreal, intent(in) :: u\n!$SER DATA u=u\nend subroutine s\n"
    out = expand(src, ifdef="")
    assert "#ifdef" not in out
    assert "#else" not in out
    assert "real :: u" in out
    assert "intent(in)" not in out


def test_intent_in_kept_when_field_not_serialized() -> None:
    src = "subroutine s(u)\nreal, intent(in) :: u\n!$SER ON\nend subroutine s\n"
    out = expand(src)
    assert "#else" not in out
    assert "real, intent(in) :: u" in out


def test_intent_in_removed_across_continuation() -> None:
    src = (
        "subroutine s(a, b)\n"
        "real, intent(in) :: &\n"
        "  a, b\n"
        "!$SER DATA b=b\n"
        "end subroutine s\n"
    )
    out = expand(src)
    # Exactly one #ifdef pair for the declaration (no double wrap).
    assert out.count("#else") == 1


# --- error rendering -------------------------------------------------------


def test_directive_error_message_format() -> None:
    err = DirectiveError(
        "boom", filename="f.f90", lineno=7, directive="DATA", line="!$SER DATA"
    )
    rendered = str(err)
    assert 'File: "f.f90", line 7' in rendered
    assert "Invalid !$SER DATA directive" in rendered
    assert "Message: boom" in rendered
