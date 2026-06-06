# Changelog

All notable changes to `preserf` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Per-slice spec / plan dirs live under [`specs/`](specs/) (overview in
[`specs/README.md`](specs/README.md)). v0.1 gaps the specs close are
embedded in each spec's Problem section.

## [0.2.0-dev] — post-v0.1.0 main, unreleased

### Fixed

- Preprocessor: a trailing Fortran comment on a `!$SER` directive line (an
  unquoted `!`, e.g. `!$SER ACCDATA vn=vn  !! note`) is now stripped instead of
  being parsed as extra arguments, matching `pp_ser`. `VERBATIM` is excepted
  (its remainder is emitted as literal source), and a `!` inside a quoted
  string is left intact.

### Added

- Tracers (Slice C, Phase 1 — `!$SER REGISTERTRACERS` / `!$SER TRACER`):
  the Fortran helper gains `fs_RegisterAllTracers`,
  `ppser_write_tracer_by_name` / `_by_idx` / `_all`, and a host-side
  `ppser_register_tracer` that binds tracer data to a small built-in
  registry (the directive surface carries only a name/index + stype +
  integer timelevel, never the data — see
  [ADR 0003](docs/adr/0003-tracer-storage.md)). `fs_RegisterAllTracers`
  writes one `/_tracers/<name>` descriptor per registered tracer
  (`type_id`, C-order `dims`, `stype`, `tracer_index`), mirroring
  `/_fields`; the write entry points emit each tracer as an ordinary
  savepoint variable (byte-identical to a `!$SER DATA` field) with the
  integer timelevel as an optional `timelevel` attribute. One snapshot per
  `(savepoint, tracer)`, last-wins (`storage_mapping.md` §4a). The registry
  keeps a pointer to the host's `TARGET` array (not a copy), so a read-mode
  `!$SER TRACER` reads the stored field back into the same array; read mode
  also resolves-and-validates the `/_tracers` descriptors. v1.0 binds
  `real(real64)` tracers (ranks 1–4). A native `tracers` / `tracers-roundtrip`
  (write + Fortran read-back) ctest plus a
  `test_fortran_wire_compat.py` scenario assert the descriptors, per-entry-
  point data placement, the timelevel attribute, and axis-order through the
  Python reference reader.
- k-buffer serialization (Slice C, Phase 2 — `!$SER DATA_KBUFF`):
  `fs_write_kbuff(serializer, savepoint, name, data, k, k_size, mode)` is
  called once per vertical level with the horizontal slice at that level;
  the helper buffers each slice and, on the last level (`k == k_size`),
  assembles the full `(slice_shape…, k_size)` field and writes it through
  the field path, so the on-disk variable is byte-identical to a `!$SER
  DATA` write (`storage_mapping.md` §6, ADR 0003 §5). Read mode is the
  mirror: the stored field is loaded once and each level is copied back into
  the caller's slice (`data` is `intent(inout)`). v1.0 buffers
  `real(real64)` slices of rank 1–3 (fields rank 2–4). A native `kbuff` ctest
  (write + read-back) plus a `test_fortran_wire_compat.py` scenario assert
  the assembled fields against the per-level accumulation.
- Runtime options (Slice C, Phase 3 — `!$SER OPTION`): `fs_Option` exposes
  a single fixed keyword, `verbosity` (ADR 0003 §4) — Fortran cannot accept
  an arbitrary `key=value` dummy, so the preprocessor now rejects any other
  OPTION key with a clear directive error (was: passed through verbatim).
  `fs_Option(verbosity=N)` sets a module-level verbosity knob and records
  the value as the reserved `_preserf_option_verbosity` root attribute so it
  round-trips (`storage_mapping.md` §4b); the `on`/`off` → `1`/`0` mapping is
  unchanged. With this, Slice C (tracers + k-buffer + OPTION) and its
  predecessor ADR (C-0) are complete.
- Full numeric type-coverage matrix (Slice B): the Fortran helper's
  `fs_write_field` / `fs_read_field` overloads now cover every
  `{logical, int32, int64, real32, real64}` × `{0D, 1D, 2D, 3D, 4D}`
  combination (was `real64` 1D/2D/3D only), and read-perturb (the 5-arg
  `fs_read_field`) extends to `real32` alongside `real64`. Logical fields
  land as `NF90_BYTE` 0/1; 0-D (scalar) fields register with a zero-length
  `dims` attribute and a netCDF scalar variable. New 1D-array overloads of
  `fs_add_savepoint_metainfo` / `fs_add_serializer_metainfo` cover
  `logical / int32 / int64 / real32 / real64` (Serialbox
  `MetainfoValue::Array`), stored as native vector attributes whose
  `__preserf_type_id` shadow carries the array TypeID (`TID_ARRAY .or.
  base`). The 50 field overloads, 10 read-perturb overloads, and 10
  `apply_perturb` helpers are generated from `#include` templates:
  `m_preserf.f90` becomes `m_preserf.F90`, compiled with `-cpp` (the
  array-metainfo overloads and their write/validate helpers are
  hand-written, since they do not vary over rank) (see
  [ADR 0004](docs/adr/0004-fortran-cpp-templates.md)). A native
  `type-matrix` ctest scenario round-trips each dtype, a 0-D scalar, a 4-D
  field, real32 perturb, and array metainfo; a `wire-matrix` scenario plus
  a parametrised `test_fortran_wire_compat.py` matrix assert the on-disk
  netCDF type and registry `type_id` for all 25 `(rank, dtype)`
  combinations against `storage_mapping.md` §1. Array **string** metainfo
  (`NC_STRING`) is deferred to Slice B′ with string data fields.
- Backend selector + NCZarr URL targets (Slice E): `ppser_initialize` now
  accepts a `backend` keyword selecting `'netcdf4'` (default, the v0.1
  `.nc` file behaviour) or `'nczarr-v2'`. `preserf_open_serializer`
  constructs the on-disk target per backend — a plain `<dir>/<prefix>.nc`
  path for NetCDF4, or a `file://<dir>/<prefix>.zarr#mode=nczarr,zarr2`
  URL onto a `.zarr` directory store for NCZarr V2 — matching
  `open_url_for` in `tests/_support/storage.py` so a Fortran-written store
  and the Python reader agree on the URL. The same group-per-savepoint
  schema serves both (ADR 0002); the `#mode=` query drives netcdf-c's
  backend dispatch, so the `nf90_create` / `nf90_open` flags are unchanged.
  An unknown `backend` aborts at the `ppser_initialize` boundary. The
  `nczarr-v2` backend builds its store URL by raw concatenation, so it
  requires an absolute `directory` (its `file://` URL has no portable
  relative form) and a `directory` / `prefix` free of URI-significant
  characters (space, `#`, `?`, `%`); a relative directory or an
  un-encodable path aborts with a clear message instead of building a
  malformed `file://…` target that would point at the wrong store. A new
  `backend-nczarr` `tests-fortran/unit/m_preserf` ctest scenario
  round-trips a `real64` field through an NCZarr V2 store; `backend-bad`,
  `backend-nczarr-relpath`, and `backend-nczarr-badchar` negative
  scenarios cover the aborts; and a new `test_fortran_wire_compat.py` case
  decodes a Fortran-written `.zarr` store through the Python reference
  reader. Zarr V3 remains deferred until netcdf-c's NCZarr V3 PR lands.
- Read-perturb implementation (Slice A-2): the 5-arg
  `fs_read_field(..., perturb)` overloads (`real64` 1D/2D/3D) now read the
  stored field and apply symmetric multiplicative noise
  `data*(1 + perturb*(2*r - 1))` (`r ~ U[0,1)` via Fortran intrinsic
  `RANDOM_NUMBER`), matching the original COSMO `serialize` read-perturb
  (`mode=2`) semantics that pp_ser emits as `ppser_zrperturb`. The 5th arg
  carries the scale, so a zero scale is the identity. The previous
  compile-only `error stop` stub (`read_perturb_not_implemented`) is gone.
  A new `perturb-roundtrip` `tests-fortran/unit/m_preserf` ctest scenario
  writes a `real64` field, reads it back with scale `0.1` asserting every
  element stays within `[orig*0.9, orig*1.1]` with non-zero overall
  deviation, and confirms scale `0.0` reads back unperturbed.
- Read-mode create-or-resolve-and-validate (Slice A-1): `fs_register_field`,
  `fs_create_savepoint`, and the scalar `fs_add_savepoint_metainfo` /
  `fs_add_serializer_metainfo` overloads now resolve and validate the
  existing store entry when `ppser_get_mode()` is read (1) or read-perturb
  (2) instead of unconditionally creating netCDF objects, so a
  pp_ser-generated read run against a read-only store no longer aborts at
  the first create call. Each directive aborts with a specific message on a
  mismatch (field type_id / dims / per-direction halo; savepoint `name`;
  metainfo value or `__preserf_type_id`). `fs_read_field` re-resolves the
  savepoint group under its own serializer, so an explicit
  `directory_ref` / `prefix_ref` store reads from the reference file rather
  than the primary. New `tests-fortran/unit/m_preserf` ctest scenarios
  cover the read round-trip (including the `sp_000000` → `sp_000001`
  index advance), the explicit-reference read, and negative cases for each
  validation (including read-side `require_variable_xtype` rejection).
- `ppser_initialize` accepts the Serialbox-compatible keywords pp_ser
  passes through from `!$SER INIT`: `singlefile`, `mpi_rank`,
  `rprecision`, `rperturb`, `realtype`, `archive`, `unique_id`.
  `mpi_rank` suffixes the on-disk store name with `_rank<n>`
  (one store per rank); `realtype`/`rprecision` override
  `ppser_realtype`/`ppser_reallength`; `rperturb` threads to
  `ppser_zrperturb` (consumed by read-perturb, Slice A-2). The
  metadata-only `singlefile`/`archive`/`unique_id` keywords are recorded
  on the writable store as the `_preserf_singlefile` / `_preserf_archive`
  / `_preserf_unique_id` root attributes for round-trip fidelity
  (`docs/references/storage_mapping.md` §3.1); `tests/_support/storage.py`
  reads them back onto `SerialboxDump`. Completes Slice D Phase 3.
- End-to-end pipeline test (Slice D Phase 4): `tests-fortran/e2e/`
  carries a `!$SER`-annotated fixture that CMake expands through the
  `preserf` CLI, compiles against the helper, and runs;
  `tests/integration_tests/test_preprocessor_e2e.py` reads the resulting
  store back and asserts the field, savepoint, metainfo, data, and the
  Phase 3 init attrs all round-trip. Runs natively under
  `pixi run test-fortran` and is gated by `PRESERF_REQUIRE_FORTRAN=1`.
- `src/preserf/preprocessor.py`: typed, two-pass reimplementation of
  `pp_ser.py` expanding every `!$SER` directive ([#6](https://github.com/grAItools/preserf/pull/6)).
- `src/preserf/cli.py`: `preserf` CLI with single-file, output-dir, and
  recursive modes ([#6](https://github.com/grAItools/preserf/pull/6)).
- `src/preserf/errors.py`: `DirectiveError` carries file/line context
  ([#6](https://github.com/grAItools/preserf/pull/6)).
- `.github/workflows/ci.yml`: Fortran CI gate — builds the helper,
  runs ctest, then runs `pixi run verify` with
  `PRESERF_REQUIRE_FORTRAN=1` so a broken Fortran build cannot pass by
  silently skipping the wire-compat test. Closes roadmap Slice F
  ([#14](https://github.com/grAItools/preserf/pull/14), [#15](https://github.com/grAItools/preserf/pull/15)).
- `.devcontainer/`: pixi-based dev container ([#10](https://github.com/grAItools/preserf/pull/10), [#12](https://github.com/grAItools/preserf/pull/12)).

### Changed

- Test layout reorganized into `tests/unit_tests/`,
  `tests/integration_tests/`, and `tests-fortran/unit/m_preserf/`
  ([#17](https://github.com/grAItools/preserf/pull/17)).
- Build harness consolidated onto pixi tasks; legacy
  Makefile/scripts removed ([#13](https://github.com/grAItools/preserf/pull/13)).
- Agent harness scaffolded via the
  `grAItools/harness-copier-template` ([#8](https://github.com/grAItools/preserf/pull/8), [#9](https://github.com/grAItools/preserf/pull/9)).
- Agent harness synced to template `ea70ca1` → `42e06b6`: adds the
  role-based subagents (`product-owner`, `architect`, `developer`,
  `reviewer`), the `/build` command, and `docs/tool-bootstrap.md`;
  adopts Conventional Commits (`commit_convention`) with squash-merge
  PR titles, documented in [`docs/style.md`](docs/style.md#commit-messages).

### Fixed

- `ppser_initialize`'s `mode` argument is now **optional**, restoring
  drop-in compatibility with pp_ser / Serialbox `!$SER INIT` call sites,
  which never pass `mode` (Serialbox selects it separately via `!$SER MODE`
  → `ppser_set_mode`). When `mode` is omitted, the open mode is derived
  from the current runtime mode state: `1` (read) / `2` (read-perturb) open
  read-only, `0` (write, the default when no mode was set) creates the
  store; the omitted-mode path no longer overwrites the runtime mode, so a
  prior read-perturb (`2`) survives. A new `init-default-mode` ctest
  scenario covers all three paths
  ([#32](https://github.com/grAItools/preserf/issues/32)).
- `require_fits_int32` guard in `active_dims_c_order` / `put_halo_attr`
  closes a latent truncation on very large dim sizes / halo extents
  ([#16](https://github.com/grAItools/preserf/pull/16)).

## [0.1.0] — 2026-05

Initial usable preview: storage mapping decision + minimal Fortran helper
that pp_ser-generated source can link against in write mode for the most
common shapes.

### Added

- Storage mapping ADR and reference: Serialbox data model mapped onto
  NetCDF4 and Zarr V2 via NCZarr, with `tests/_support/storage.py` and
  `tests/_support/serialbox.py` reference readers and a Python
  round-trip test ([#3](https://github.com/grAItools/preserf/pull/3)).
- Minimal Fortran helper (`src/preserf-fortran/`):
  - `utils_preserf.f90` — lifecycle (`ppser_initialize`,
    `ppser_finalize`, `ppser_set_mode`, `ppser_get_mode`) plus the
    module-level state pp_ser-emitted code uses (`ppser_serializer`,
    `ppser_serializer_ref`, `ppser_savepoint`, `ppser_intlength`,
    `ppser_reallength`, `ppser_realtype`, `ppser_zrperturb`).
  - `m_preserf.f90` — `fs_register_field`, `fs_create_savepoint`,
    scalar `fs_add_savepoint_metainfo` / `fs_add_serializer_metainfo`
    (`logical` / `int32` / `int64` / `real32` / `real64` /
    `character`), `fs_write_field` / `fs_read_field` for `real64` 1D/2D/3D
    (4-arg and compile-only 5-arg perturb form),
    `fs_enable_serialization` / `fs_disable_serialization` /
    `fs_serialization_status`.
  - `m_serialize` / `utils_ppser` alias modules so pp_ser-generated
    source using the historical Serialbox module names compiles
    unchanged.
  - CMake 3.20+ build (`src/preserf-fortran/CMakeLists.txt`,
    `tests-fortran/CMakeLists.txt`); pkg-config discovery of
    `netcdf-fortran`; gfortran `-std=f2008`.
  - Native Fortran test (`tests-fortran/unit/m_preserf/test_minimal.f90`)
    plus cross-language wire-compat test
    (`tests/integration_tests/test_fortran_wire_compat.py`) that skips
    when the Fortran binary is absent ([#4](https://github.com/grAItools/preserf/pull/4)).
- Directive specification extracted from `pp_ser.py` as a reference
  document; initial project scaffolding (Python ≥3.12, pixi, MIT
  license) ([#1](https://github.com/grAItools/preserf/pull/1), [#2](https://github.com/grAItools/preserf/pull/2), [#5](https://github.com/grAItools/preserf/pull/5)).

[Unreleased]: https://github.com/grAItools/preserf/compare/v0.2.0-dev...HEAD
[0.2.0-dev]: https://github.com/grAItools/preserf/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/grAItools/preserf/releases/tag/v0.1.0
