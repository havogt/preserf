add_executable(preserf_fortran_test_minimal test_minimal.f90)
target_link_libraries(preserf_fortran_test_minimal PRIVATE preserf_fortran)

# CMake's Fortran_STANDARD / Fortran_STANDARD_REQUIRED target
# properties do NOT propagate from the linked library to executables,
# so the same F2008 requirement that the preserf_fortran library
# carries has to be repeated here. test_minimal.f90 uses F2008
# constructs (BLOCK, ERROR STOP, deferred-length character) that
# would otherwise fail on compilers whose default dialect is older
# than F2008.
set_target_properties(preserf_fortran_test_minimal PROPERTIES
    Fortran_STANDARD 2008
    Fortran_STANDARD_REQUIRED ON
)
# Belt-and-braces for gfortran (see top-level CMakeLists.txt note):
# CMake 3.28 doesn't translate Fortran_STANDARD into a `-std=` flag
# for gfortran, so we add it explicitly.
if(CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
    target_compile_options(preserf_fortran_test_minimal PRIVATE -std=f2008)
endif()

# Pre-create the output directory and then run the test binary.
# Using `cmake -E make_directory` rather than a shell `mkdir -p` makes
# this portable across Windows/Unix and avoids quoting concerns.
#
# The directory creation is wired as a CTest *fixture* rather than a
# plain DEPENDS edge: DEPENDS only orders tests that are already in the
# selected set, so running just `preserf_fortran_minimal` (e.g. from an
# IDE or via `ctest -R '^preserf_fortran_minimal$'`) would skip the
# setup and hand the binary a non-existent output directory.
# FIXTURES_REQUIRED makes CTest automatically pull in the matching
# FIXTURES_SETUP test whenever the dependent test is run.
add_test(
    NAME preserf_fortran_minimal_setup
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "${CMAKE_CURRENT_BINARY_DIR}/test-output"
)
set_tests_properties(preserf_fortran_minimal_setup PROPERTIES
    FIXTURES_SETUP preserf_fortran_output_dir
)
add_test(
    NAME preserf_fortran_minimal
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal> "${CMAKE_CURRENT_BINARY_DIR}/test-output"
)
set_tests_properties(preserf_fortran_minimal PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: hello-world OK"
    # Match the 60-second cap the Python wrapper applies to the same
    # binary in tests/integration_tests/test_fortran_wire_compat.py, so a
    # netCDF/HDF5 deadlock cannot block ctest indefinitely either.
    TIMEOUT 60
)

# Slice D: the widened ppser_initialize keywords (realtype / rprecision /
# rperturb / mpi_rank). Driven through the same binary via the
# 'init-keywords' scenario argument.
add_test(
    NAME preserf_fortran_init_keywords
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" init-keywords
)
set_tests_properties(preserf_fortran_init_keywords PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: init-keywords OK"
    TIMEOUT 60
)

# Slice E: NCZarr V2 backend selector. backend='nczarr-v2' writes a
# `.zarr` directory store via netcdf-c's NCZarr backend; the scenario
# round-trips one real64 field through it.
add_test(
    NAME preserf_fortran_backend_nczarr
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" backend-nczarr
)
set_tests_properties(preserf_fortran_backend_nczarr PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: backend-nczarr OK"
    TIMEOUT 60
)

# Slice E negative: an unknown backend aborts at the ppser_initialize
# boundary (allowlist of 'netcdf4' / 'nczarr-v2').
add_test(
    NAME preserf_fortran_backend_bad
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" backend-bad
)
set_tests_properties(preserf_fortran_backend_bad PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "unknown backend"
    TIMEOUT 60
)

# Slice E negative: the nczarr-v2 backend needs an absolute directory for
# its file:// URL; a relative one must abort rather than build a malformed
# file://<authority>/... target.
add_test(
    NAME preserf_fortran_backend_nczarr_relpath
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" backend-nczarr-relpath
)
set_tests_properties(preserf_fortran_backend_nczarr_relpath PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "requires an absolute directory"
    TIMEOUT 60
)

# Slice E negative: the nczarr-v2 URL is raw-concatenated (not URI-encoded
# like the Python reference path), so a path with a URI-significant
# character (space / # / ? / %) must abort rather than emit a bad URL.
add_test(
    NAME preserf_fortran_backend_nczarr_badchar
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" backend-nczarr-badchar
)
set_tests_properties(preserf_fortran_backend_nczarr_badchar PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "needs URI-encoding"
    TIMEOUT 60
)

# -----------------------------------------------------------------------------
# Slice A-1: read-mode create-or-resolve-and-validate.
#
# Each scenario is driven through the same binary via its scenario
# argument. Positive scenarios assert their "... OK" marker; negative
# scenarios assert the specific abort message via PASS_REGULAR_EXPRESSION
# (which, when set, determines pass/fail from the output regardless of the
# non-zero exit code that `error stop` produces). A scenario that fails to
# abort prints a non-matching line and exits 0, so the regex fails to
# match and the test fails — catching a validation that silently accepts.
# -----------------------------------------------------------------------------

# Positive: read-mode round-trip (also covers sp_000000 → sp_000001).
add_test(
    NAME preserf_fortran_read_roundtrip
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" read-roundtrip
)
set_tests_properties(preserf_fortran_read_roundtrip PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: read-roundtrip OK"
    TIMEOUT 60
)

# Issue #32: `mode` is optional on ppser_initialize for pp_ser / Serialbox
# `!$SER INIT` drop-in compatibility. The scenario covers the default-write
# path (no mode, no prior set_mode), the derived read path (set_mode(1) +
# omitted mode), and read-perturb (set_mode(2)) preservation.
add_test(
    NAME preserf_fortran_init_default_mode
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" init-default-mode
)
set_tests_properties(preserf_fortran_init_default_mode PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: init-default-mode OK"
    TIMEOUT 60
)

# Issue #42: in write mode ppser_initialize must create the output
# `directory` (mkdir -p semantics) before nf90_create, matching Serialbox.
# The scenario points INIT at a fresh nested subdirectory that does not
# exist and asserts the store file gets created (so the directory was made
# first); a second init proves mkdir -p is idempotent.
add_test(
    NAME preserf_fortran_init_mkdir
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" init-mkdir
)
set_tests_properties(preserf_fortran_init_mkdir PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: init-mkdir OK"
    TIMEOUT 60
)

# Slice B: full type-coverage matrix. One round-trip per dtype (logical /
# int32 / int64 / real32 / real64) at rank 1, plus a 0-D scalar, a 4-D
# field, and a real32 read-perturb. The full (rank x dtype) on-disk type
# matrix is asserted by the Python cross-language test.
add_test(
    NAME preserf_fortran_type_matrix
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" type-matrix
)
set_tests_properties(preserf_fortran_type_matrix PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: type-matrix OK"
    TIMEOUT 60
)

# Slice B Phase 3: write one field of every (dtype, rank) combination plus
# array metainfo, for the Python cross-language matrix assertions. The
# native run just confirms the writer completes.
add_test(
    NAME preserf_fortran_wire_matrix
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" wire-matrix
)
set_tests_properties(preserf_fortran_wire_matrix PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: wire-matrix OK"
    TIMEOUT 60
)

# Slice A-2: read-perturb applies bounded multiplicative noise; scale 0 is
# the identity.
add_test(
    NAME preserf_fortran_perturb_roundtrip
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" perturb-roundtrip
)
set_tests_properties(preserf_fortran_perturb_roundtrip PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: perturb-roundtrip OK"
    TIMEOUT 60
)

# Issue #39: 5-arg fs_read_field perturb overloads for integer and logical.
# The perturb argument is accepted but ignored; the field is read identically
# to the 4-arg form. Covers int32, int64, and logical at ranks 0-4.
add_test(
    NAME preserf_fortran_perturb_noop
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" perturb-noop
)
set_tests_properties(preserf_fortran_perturb_noop PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: perturb-noop OK"
    TIMEOUT 60
)

# Positive: explicit reference-store read resolves the savepoint under the
# reference serializer (Phase 2).
add_test(
    NAME preserf_fortran_read_ref
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" read-ref
)
set_tests_properties(preserf_fortran_read_ref PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: read-ref OK"
    TIMEOUT 60
)

# Negative scenarios: each must abort with its specific message.
add_test(
    NAME preserf_fortran_read_bad_dtype
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" read-bad-dtype
)
set_tests_properties(preserf_fortran_read_bad_dtype PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "type_id mismatch"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_read_bad_dims
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" read-bad-dims
)
set_tests_properties(preserf_fortran_read_bad_dims PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "dims mismatch"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_read_bad_halo
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" read-bad-halo
)
set_tests_properties(preserf_fortran_read_bad_halo PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "halo .iminushalo. mismatch"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_read_bad_spname
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" read-bad-spname
)
set_tests_properties(preserf_fortran_read_bad_spname PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "savepoint name mismatch"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_read_bad_meta_value
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" read-bad-meta-value
)
set_tests_properties(preserf_fortran_read_bad_meta_value PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "value mismatch between run and store"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_read_bad_meta_typeid
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" read-bad-meta-typeid
)
set_tests_properties(preserf_fortran_read_bad_meta_typeid PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "type-id mismatch"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_read_bad_xtype
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" read-bad-xtype
)
set_tests_properties(preserf_fortran_read_bad_xtype PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "Registry / variable mismatch"
    TIMEOUT 60
)

# Slice C Phase 1: tracers. The 'tracers' scenario registers three real64
# tracers and writes them through every TRACER entry point; the Python
# cross-language test asserts the on-disk descriptors and data. The native
# run confirms the writer completes.
add_test(
    NAME preserf_fortran_tracers
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracers
)
set_tests_properties(preserf_fortran_tracers PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: tracers OK"
    TIMEOUT 60
)

# Slice C Phase 1 read-mode: re-open a tracer store read-only and validate
# each /_tracers descriptor via fs_RegisterAllTracers (no def_var on the
# read-only handle).
add_test(
    NAME preserf_fortran_tracers_roundtrip
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracers-roundtrip
)
set_tests_properties(preserf_fortran_tracers_roundtrip PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: tracers-roundtrip OK"
    TIMEOUT 60
)

# Slice C Phase 2: DATA_KBUFF. The 'kbuff' scenario writes a 3-D and a 2-D
# field one vertical level at a time via fs_write_kbuff; the Python
# cross-language test asserts the assembled fields. The native run
# confirms the buffer flush completes.
add_test(
    NAME preserf_fortran_kbuff
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" kbuff
)
set_tests_properties(preserf_fortran_kbuff PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: kbuff OK"
    TIMEOUT 60
)

# Slice C Phase 3: OPTION. fs_Option(verbosity=2) sets the runtime knob and
# records the _preserf_option_verbosity root attribute; the Python
# cross-language test reads it back.
add_test(
    NAME preserf_fortran_option
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" option
)
set_tests_properties(preserf_fortran_option PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: option OK"
    TIMEOUT 60
)

# Slice C: "last write wins" — a second tracer write omitting timelevel must
# clear a timelevel set by an earlier write at the same savepoint. The
# Python cross-language test asserts the attribute is absent; the native run
# confirms the writer completes.
add_test(
    NAME preserf_fortran_tracer_tl_overwrite
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracer-tl-overwrite
)
set_tests_properties(preserf_fortran_tracer_tl_overwrite PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: tracer-tl-overwrite OK"
    TIMEOUT 60
)

# Slice C negative scenarios: each must abort with its specific message.
add_test(
    NAME preserf_fortran_tracers_multi_session
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracers-multi-session
)
set_tests_properties(preserf_fortran_tracers_multi_session PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "preserf-fortran: tracers-multi-session OK"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_tracers_bad_dup
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracers-bad-dup
)
set_tests_properties(preserf_fortran_tracers_bad_dup PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "is already registered"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_tracers_bad_namelen
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracers-bad-namelen
)
set_tests_properties(preserf_fortran_tracers_bad_namelen PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "exceeds 64 characters"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_tracers_bad_name
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracers-bad-name
)
set_tests_properties(preserf_fortran_tracers_bad_name PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "is not registered"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_tracers_bad_idx
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracers-bad-idx
)
set_tests_properties(preserf_fortran_tracers_bad_idx PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "is out of range"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_tracers_bad_reorder
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracers-bad-reorder
)
set_tests_properties(preserf_fortran_tracers_bad_reorder PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "tracer_index mismatch"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_tracers_bad_range
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" tracers-bad-range
)
set_tests_properties(preserf_fortran_tracers_bad_range PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "descending index range"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_kbuff_bad_namelen
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" kbuff-bad-namelen
)
set_tests_properties(preserf_fortran_kbuff_bad_namelen PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "exceeds 64 characters"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_kbuff_bad_order
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" kbuff-bad-order
)
set_tests_properties(preserf_fortran_kbuff_bad_order PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "expected level 2 but got 3"
    TIMEOUT 60
)

add_test(
    NAME preserf_fortran_kbuff_bad_shape
    COMMAND $<TARGET_FILE:preserf_fortran_test_minimal>
            "${CMAKE_CURRENT_BINARY_DIR}/test-output" kbuff-bad-shape
)
set_tests_properties(preserf_fortran_kbuff_bad_shape PROPERTIES
    FIXTURES_REQUIRED preserf_fortran_output_dir
    PASS_REGULAR_EXPRESSION "inconsistent slice shape"
    TIMEOUT 60
)
