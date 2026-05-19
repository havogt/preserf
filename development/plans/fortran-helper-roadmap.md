---
status: proposed
date: 2026-05-18
owners: preserf maintainers
related:
  - development/decisions/0001-storage-model-mapping.md
  - development/references/storage_mapping.md
  - development/references/directives_specification.md
  - src/preserf-fortran/README.md
---

# Fortran helper module — implementation roadmap

This document tracks the slices that take `src/preserf-fortran/` from the
v0.1 write-mode subset (merged in PR #4) to a complete drop-in replacement
for the Serialbox Fortran helpers that `pp_ser`-generated source links
against. It is descriptive, not prescriptive — each slice still needs its
own design review when it lands.

## 1. What is already shipped

Already on `main`:

- **PR #3 — storage mapping**
  (`development/references/storage_mapping.md`, plus the
  `tests/_storage.py` / `tests/_serialbox.py` reference reader and a
  Serialbox ↔ preserf Python round-trip test).
- **PR #4 — minimal Fortran helper** (`src/preserf-fortran/`):
  - `utils_preserf.f90` — lifecycle (`ppser_initialize` /
    `ppser_finalize` / `ppser_set_mode` / `ppser_get_mode`) and the
    module-level state pp_ser-emitted code uses (`ppser_serializer`,
    `ppser_serializer_ref`, `ppser_savepoint`, `ppser_intlength`,
    `ppser_reallength`, `ppser_realtype`, `ppser_zrperturb`).
  - `m_preserf.f90` — `fs_register_field`, `fs_create_savepoint`,
    `fs_add_savepoint_metainfo` / `fs_add_serializer_metainfo`
    (scalar `logical` / `int32` / `int64` / `real32` / `real64` /
    `character`), `fs_write_field` / `fs_read_field` for `real64`
    1D/2D/3D (4-arg and compile-only 5-arg perturb form),
    `fs_enable_serialization` / `fs_disable_serialization` /
    `fs_serialization_status`.
  - `m_serialize` / `utils_ppser` alias modules so pp_ser-generated
    source using the historical Serialbox module names compiles
    unchanged.
  - `CMakeLists.txt` + `test/CMakeLists.txt` (CMake 3.20+,
    `pkg-config` discovery of `netcdf-fortran`, `Fortran_STANDARD
    2008` plus an explicit gfortran `-std=f2008`, project version
    threaded via `preserf_version.f90.in`).
  - `test/test_minimal.f90` native Fortran test +
    `tests/test_fortran_minimal.py` cross-language wire-compat test
    (skips when the Fortran binary is absent).

The schema documented in
[`storage_mapping.md`](../references/storage_mapping.md) is now exercised
by both a Python writer (`tests/_storage.py`) and a Fortran writer
(`src/preserf-fortran/`).

## 2. Known gaps after PR #4

These are gaps in the current shipped code, not future enhancements.
They are the things pp_ser-generated source can already hit today.

1. **Read mode is structurally partial.** `fs_register_field`,
   `fs_create_savepoint`, `fs_add_savepoint_metainfo` and
   `fs_add_serializer_metainfo` unconditionally **create** their
   netCDF objects. pp_ser-generated source calls these directives
   *outside* the `SELECT CASE (ppser_get_mode())` that gates DATA
   blocks, so pointing a generated read run at an existing read-only
   store aborts at the first create call — `fs_register_field`'s
   `nf90_def_var` on the registry carrier, or `fs_create_savepoint`'s
   `nf90_def_grp(sp_NNNNNN)`, whichever the generated source reaches
   first. Additionally, the read
   path validates the registry on `s%fields_grpid` but pulls the data
   variable from `sp%grpid` — `ppser_savepoint` lives on
   `ppser_serializer` rather than `ppser_serializer_ref`, so an
   *explicit* reference store would validate against one file and
   read from another.
2. **Read-perturb is a stub.** The 5-arg
   `fs_read_field(..., perturb)` overloads exist so pp_ser-emitted
   `CASE(2)` branches compile, but `error stop` at runtime. The
   perturbation algorithm itself is unimplemented.
3. **`ppser_initialize` keyword surface is narrower than Serialbox's.**
   v0.1 takes `directory`, `prefix`, `mode`, `directory_ref`,
   `prefix_ref`. Serialbox accepts additional `singlefile`,
   `mpi_rank`, `rprecision`, `rperturb`, `realtype`, `archive`,
   `unique_id`. pp_ser passes those through verbatim from
   `!$SER INIT` directives.
4. **Append mode (`'a'`) is rejected**, not half-implemented.
5. **Type-coverage matrix is `real64`-only for fields, scalar-only
   for metainfo.** No `bool` / `int32` / `int64` / `float32` field
   overloads, no 0D or 4D field overloads, no array-metainfo
   variants of *any* type — `fs_add_savepoint_metainfo` and
   `fs_add_serializer_metainfo` only have scalar overloads
   (`_l` / `_i4` / `_i8` / `_r4` / `_r8` / `_s`); 1D-array overloads
   are part of Slice B. **String data fields** (Serialbox
   `TypeID::String` for data, not metainfo) are also not supported —
   see `storage_mapping.md` §9 "String data fields" — and there is
   no `NF90_STRING` write path for field variables yet. *Scalar*
   string metainfo is supported (both reference writers produce
   `NC_CHAR`); *array* string metainfo is supported by the Python
   reference writer (as `NC_STRING`) but not by the Fortran helper
   in v0.1 (per `storage_mapping.md` §1's String-storage note).
6. **No tracer / k-buffer / OPTION support.** `!$SER TRACER`,
   `!$SER DATA_KBUFF`, `!$SER OPTION` would fail to link.
7. **NCZarr targets unreachable.** `preserf_open_serializer` builds
   `<directory>/<prefix>.nc` and passes `NF90_NETCDF4`. No backend
   selector at the `ppser_initialize` boundary.
8. **No CI for the Fortran build.** `tests/test_fortran_minimal.py`
   skips by default; nothing on `main` blocks a Fortran regression.

## 3. Slice plan

Each slice is intended to land as one PR. Slices are roughly ordered
by how much they unblock real pp_ser-generated source. They are not
strictly sequential — Slice B can land before or after Slice A.

### Slice A — Read-mode "create-or-resolve-and-validate"

Closes gap §1 and §2's runtime side.

- Switch `fs_register_field`, `fs_create_savepoint`,
  `fs_add_savepoint_metainfo`, `fs_add_serializer_metainfo` to a
  create-or-resolve-and-validate shape: on a writable store they
  create as today; on a read-only store they resolve the existing
  group/var/attr and validate that the runtime arguments match.
  Specifically:
  - `fs_register_field`: type, dims, halos must match the
    `/_fields/<name>` registry entry.
  - `fs_create_savepoint`: the runtime `name` argument must match the
    existing savepoint group's `name` attribute (per
    `storage_mapping.md` §5 — savepoints are identified by index
    `sp_NNNNNN` *plus* the `name` attribute, since Serialbox permits
    multiple savepoints to share a name and they're disambiguated by
    metainfo).
  - metainfo helpers: value plus `__preserf_type_id` must match the
    existing attribute.

  Mismatch aborts with a clear error.
- Resolve the `ppser_serializer` vs `ppser_serializer_ref`
  savepoint-grpid mismatch: either savepoints carry per-serializer
  grpids, or `fs_read_field` re-resolves the savepoint under `s`
  before reading. Pick one in the design notes; the second is less
  state but more I/O.
- Add a native Fortran test that round-trips a write run and then a
  read run against the same store, exercising the resolve+validate
  branch end-to-end. Add a *second* scenario that uses an explicit
  `directory_ref`/`prefix_ref` pair pointing at a different store
  (or otherwise deliberately mismatched `s` / `sp` pairing) so the
  `ppser_serializer` vs `ppser_serializer_ref` savepoint-grpid case
  is actually covered — the same-store round-trip alone hits the
  implicit-ref path.
- Implement read-perturb (5-arg `fs_read_field`). Algorithm matches
  Serialbox's `zrperturb` semantics (multiplicative noise scaled by
  `ppser_zrperturb`). Cross-language test covering at least `real64`
  3D.

### Slice B — Full type-coverage matrix

Closes gap §5.

- `fs_register_field` already takes a generic `type` string, so the
  registry side is mostly there. The field write/read overloads need
  to be filled out: `logical`, `integer(int32)`, `integer(int64)`,
  `real(real32)`, `real(real64)` × 0D / 1D / 2D / 3D / 4D.
- Array-metainfo overloads (`fs_add_savepoint_metainfo` /
  `fs_add_serializer_metainfo` for 1D arrays of each scalar type,
  per Serialbox `MetainfoValue::Array`).
- **String data fields are explicitly deferred** to a separate slice
  (call it Slice B′). Storage mapping §9 says `TypeID::String` for
  data lands as `NF90_STRING` variables under the same
  group-per-savepoint layout, with no schema-version bump expected,
  but the Python reference reader (`numpy_dtype_for` in
  `tests/_serialbox.py`, imported by `tests/_storage.py`) currently
  rejects the type and there's no `NF90_STRING` write path in
  `fs_write_field`. Bundling it into
  Slice B would expand scope; tracking it separately keeps the
  primary numeric matrix tractable.
- The cross-language test (`tests/test_fortran_minimal.py`) grows a
  parametrised matrix: for each (rank, dtype), assert raw netCDF
  type via `Dataset[…].dtype` matches the TypeID → netCDF-type table
  in `storage_mapping.md §1`.

### Slice C — Tracers, k-buffer, OPTION

Closes gap §6.

- `fs_RegisterAllTracers` (from `!$SER REGISTERTRACERS`) and the
  tracer write API — `ppser_write_tracer_by_name`,
  `ppser_write_tracer_by_idx`, `ppser_write_tracer_all` (from
  `!$SER TRACER`, per
  `development/references/directives_specification.md` §§3.11 / 3.14).
  Needs the storage mapping to spell out where tracer descriptors
  live — candidate is a `/_tracers` sibling of `/_fields`. Document
  the decision in a new ADR.
- `fs_write_kbuff` (`!$SER DATA_KBUFF`). Needs the k-buffer flush
  semantics from `pp_ser.py` to be re-derived.
- `fs_Option` (`!$SER OPTION`). pp_ser emits OPTION entries as
  Fortran keyword arguments (e.g. `call fs_Option(verbosity=1)`)
  rather than as a `(name, value)` pair, so this slice must first
  define the supported `fs_Option` optional-argument surface (or
  change the pp_ser port's emission shape) before deciding how
  options land in the store.
- All three need cross-language coverage in
  `tests/test_fortran_minimal.py` (or a sibling test program).

### Slice D — `pp_ser.py` port

Independent of slices A–C; can land in parallel.

**Status:** the preprocessor port has landed (PR #6); the
`ppser_initialize` widening and the end-to-end test below remain.

- **Done (PR #6).** `pp_ser.py` (a reference file under
  `development/references/`) is ported into the distributed Python
  package as `src/preserf/preprocessor.py` — a typed, two-pass
  reimplementation expanding every `!$SER` directive — alongside
  `errors.py` (`DirectiveError` with file/line context) and a real
  `cli.py` (single-file, output-dir and recursive modes). Generated
  output uses preserf's helper API (`USE m_serialize` / `utils_ppser`).
  Directive-by-directive unit tests live in `tests/test_preprocessor.py`
  and `tests/test_cli.py`; deviations from the reference (all toward
  correctness) are enumerated in the PR description.
- Widen `ppser_initialize` to accept the keyword surface pp_ser
  emits (gap §3): `singlefile`, `mpi_rank`, `rprecision`,
  `rperturb`, `realtype`, `archive`, `unique_id`. Several of these
  are *not* purely metadata:
  - `mpi_rank`: per `storage_mapping.md` §9, this maps to a
    `_rank<n>` suffix on the store name. `preserf_open_serializer`
    must apply the suffix, otherwise parallel runs would clobber
    each other's stores.
  - `realtype` and `rprecision`: pp_ser-generated REGISTER calls
    pass `ppser_realtype` / `ppser_reallength` for `real` fields
    (see `pp_ser.py` "datatypes" map). The helper currently exposes
    those as fixed constants; the port must let `ppser_initialize`
    update them so single-precision real fields get registered with
    the right type metadata. `rperturb` threads through to the
    read-perturb path from Slice A.
  - `singlefile`, `archive`, `unique_id`: metadata-only on the
    preserf side; record them in root attrs for round-trip fidelity.
- End-to-end test: run the ported preprocessor on a representative
  `!$SER`-annotated Fortran source, compile the generated output
  against preserf's helpers, run it, and read the store back with
  `tests/_storage.py`.

### Slice E — Backend selector and NCZarr URL targets

Closes gap §7.

- Add a backend selector at `ppser_initialize`
  (`backend='netcdf4'|'nczarr-v2'`, default `netcdf4`). The
  `nczarr-v2` label matches the selector already used by the Python
  reference path (`tests/_storage.py`).
- Rework `preserf_open_serializer` to construct
  `file://<directory>/<prefix>.zarr#mode=nczarr,zarr2` when the
  backend is NCZarr, and pass appropriate creation flags.
- Cross-language test wiring `tests/_storage.py`'s Zarr V2 reader
  against a Fortran-written NCZarr store. This test exists today on
  the Python side (`tests/test_round_trip.py`) for both backends;
  extend it to also accept Fortran-written input.
- Zarr V3 (NCZarr V3 PR) explicitly deferred until the netcdf-c PR
  lands. See `development/decisions/0001-storage-model-mapping.md`.

### Slice F — CI for the Fortran build

Closes gap §8.

- GitHub Actions workflow on `ubuntu-latest` that installs
  `gfortran` + `libnetcdff-dev`, runs
  `cmake -S src/preserf-fortran -B src/preserf-fortran/build`
  followed by `cmake --build src/preserf-fortran/build`, then
  `ctest --test-dir src/preserf-fortran/build`, then
  `pytest tests/test_fortran_minimal.py`. The build directory must
  match `_BUILD_TEST_DIR` in `tests/test_fortran_minimal.py`
  (`src/preserf-fortran/build/test`); a top-level `build/` would
  not be found.
- The pytest fixture currently `pytest.skip`s when the binary is
  missing. Once CI provides the binary, gate that skip to local
  runs only (e.g. an env-var override or a `--require-fortran`
  pytest flag) so the CI run fails outright when the binary is
  absent. `xfail` is *not* enough — an xfailed test still lets the
  suite pass, so a CI regression could hide behind a non-executed
  test.

### Slice G — Append mode

Closes gap §4. Lowest priority — pp_ser-generated source rarely uses
`'a'`, and `'w'` + `'r'` cover the typical run/replay loop.

- Implement `nf90_inq_grps` resumption of the savepoint group index.
- Sanity-check that the existing `_preserf_*` housekeeping attrs
  match what the new run would write, otherwise abort (don't
  silently fork the store).

## 4. Carry-over Copilot review notes from PR #4

These are advisory comments that arrived on the PR around merge time.
They are tracked here so they don't get lost; promoting any of them to
a slice is a judgement call.

- `m_preserf.f90` — write-side registry validation has no explicit
  negative test. `fs_write_field` validates only overload type and
  runtime shape against the registry (it does not take halo
  arguments), so the missing cases are mismatched dtype and
  mismatched dims; halo-mismatch validation belongs to the
  Slice A resolve-and-validate path on `fs_register_field`, not to
  the write side.
- `m_preserf.f90` — read-side `require_variable_xtype` rejection has
  no negative test.
- `m_preserf.f90` — savepoint-metainfo native test coverage is
  limited to `int32` and `real64`; the `logical`, `int64`, `real32`,
  and `character` savepoint overloads are not exercised by the
  native Fortran test. (The serializer-metainfo side already covers
  `logical`, `int64`, and `real32` in the native test, and the
  cross-language test asserts their raw netCDF dtypes — those rows
  are not a gap.)
- `m_preserf.f90` — dimension sizes and halo extents are cast to
  `int32` without an explicit upper-bound check; a 64-bit default
  integer build could silently truncate.
- `test/test_minimal.f90` — disabled-savepoint round-trip checks
  `grpid` and `idx` but not `owner_ncid`.
- `test/test_minimal.f90` — only one enabled savepoint is created,
  so the `next_sp_index` increment and `sp_000001` naming aren't
  exercised end-to-end.

Most of these fold into Slice A (read-mode tests) or Slice B
(type-coverage tests). The int32 truncation note (4th bullet above)
is a correctness fix that should land standalone before either,
since it's a latent bug rather than missing coverage.

## 5. Out of scope

- A second backend implementation (e.g. native HDF5, native Zarr
  without going through netcdf-c). The whole point of the schema is
  that one Fortran helper produces both NetCDF4 and NCZarr.
- Distributed / MPI-aware writes beyond what Serialbox itself
  supported. The `mpi_rank` keyword that Slice D wires up only
  controls the `_rank<n>` suffix on the store name (one independent
  store per rank, per `storage_mapping.md` §9); parallel HDF5 /
  parallel NCZarr is a future option, not part of this roadmap.
- A C API. pp_ser only generates Fortran.
