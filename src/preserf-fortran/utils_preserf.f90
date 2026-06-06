!> preserf Fortran helper: serializer / savepoint state + lifecycle.
!>
!> This module owns the global state that `pp_ser`-expanded directives
!> rely on (`ppser_serializer`, `ppser_serializer_ref`, `ppser_savepoint`,
!> `ppser_realtype`, `ppser_zrperturb`, plus the mode getter/setter).
!>
!> The actual netCDF operations live in m_preserf; this module only
!> handles dataset open/close and mode state. The `backend` keyword on
!> `ppser_initialize` selects between NetCDF4 (`.nc` files, the default)
!> and NCZarr V2 (`.zarr` directory stores via a `file://...#mode=`
!> URL); the same group-per-savepoint schema serves both (ADR 0002).
!> Zarr V3 stays deferred until netcdf-c's NCZarr V3 PR lands.
!>
!> Backed by the schema documented in
!> `docs/references/storage_mapping.md`.
module utils_preserf
   use, intrinsic :: iso_fortran_env, only: int8, int32, real64
   use netcdf
   implicit none
   private

   ! -------------------------------------------------------------------------
   ! Public type definitions
   ! -------------------------------------------------------------------------
   !
   ! t_serializer wraps a netCDF dataset plus the schema group IDs.
   ! ncid == -1 means "not initialised".
   !
   type, public :: t_serializer
      integer :: ncid = -1
      integer :: fields_grpid = -1
      integer :: tracers_grpid = -1
      integer :: savepoints_grpid = -1
      integer :: next_sp_index = 0
      logical :: writable = .true.
   end type t_serializer

   !
   ! t_savepoint refers to one /savepoints/sp_NNNNNN subgroup.
   !
   ! `owner_ncid` records the `ncid` of the serializer that created
   ! the group. fs_write_field validates the field registry through
   ! its serializer argument but writes the data variable under
   ! `grpid`; cross-checking `owner_ncid` rejects a savepoint that
   ! belongs to a different store, which would otherwise let the
   ! registry and the data variable diverge into different files.
   !
   type, public :: t_savepoint
      integer :: grpid = -1
      integer :: idx = -1
      integer :: owner_ncid = -1
   end type t_savepoint

   ! -------------------------------------------------------------------------
   ! Module-level state (mirrors Serialbox's utils_ppser surface)
   ! -------------------------------------------------------------------------
   type(t_serializer), public, save, target :: ppser_serializer
   type(t_serializer), public, save, target :: ppser_serializer_ref
   type(t_savepoint), public, save :: ppser_savepoint

   ! Byte-length constants for pp_ser-emitted `fs_register_field`
   ! calls. Declared in default `integer` kind (not int32) so they
   ! match the `bytes_per_element` dummy argument's kind on builds
   ! that compile with `-fdefault-integer-8` or similar — Fortran's
   ! explicit-interface kind checking would otherwise fail when
   ! generated code passes `ppser_reallength` to `fs_register_field`.
   integer, parameter, public :: ppser_intlength = 4

   ! Real-field type metadata for pp_ser-emitted `fs_register_field`
   ! calls. These are mutable `save` state (not `parameter`) so the
   ! `realtype` keyword on `!$SER INIT` can override them via
   ! `ppser_initialize`; the `PPSER_DEFAULT_*` parameters
   ! below are the Serialbox double-precision defaults, used both as
   ! the initial values here and as the reset target on every fresh
   ! `ppser_initialize` (so a prior override does not stick across a
   ! later init that omits the keyword). `ppser_realtype` is
   ! fixed-length (padded with blanks); `type_id_from_datatype` trims
   ! before matching, so the padding is harmless.
   integer, parameter, public :: PPSER_DEFAULT_REALLENGTH = 8
   character(len=*), parameter, public :: PPSER_DEFAULT_REALTYPE = 'double'
   real(real64), parameter, public :: PPSER_DEFAULT_RPERTURB = 0.0_real64
   integer, public, save :: ppser_reallength = PPSER_DEFAULT_REALLENGTH
   character(len=16), public, save :: ppser_realtype = PPSER_DEFAULT_REALTYPE
   real(real64), public, save :: ppser_zrperturb = PPSER_DEFAULT_RPERTURB

   ! Serialbox defaults for the metadata-only `!$SER INIT` keywords.
   ! These do not change runtime behaviour on the preserf side; they
   ! are recorded verbatim in `_preserf_*` root attributes so a store
   ! round-trips the values pp_ser passed through (Slice D Phase 3).
   ! The effective value written is the keyword when supplied, else the
   ! default below, so the reader always finds a complete set.
   logical, parameter, public :: PPSER_DEFAULT_SINGLEFILE = .false.
   character(len=*), parameter, public :: PPSER_DEFAULT_ARCHIVE = 'Binary'
   integer, parameter, public :: PPSER_DEFAULT_UNIQUE_ID = 0

   ! Storage backend selector (Slice E). 'netcdf4' writes a `.nc` file
   ! (the v0.1 behaviour, kept as the default for backward compatibility);
   ! 'nczarr-v2' writes a `.zarr` directory store via netcdf-c's NCZarr
   ! backend. The label matches the selector used by the Python reference
   ! path in tests/_support/storage.py so a Fortran-written store and the
   ! Python reader agree on the on-disk URL.
   character(len=*), parameter, public :: PPSER_DEFAULT_BACKEND = 'netcdf4'

   ! Mode: 0 = write, 1 = read, 2 = read-perturb.
   integer, save :: ppser_mode_state = 0

   ! ON / OFF gate for the fs_* I/O entry points in m_preserf.
   ! 1 = enabled (default), 0 = disabled. Owned here (rather than in
   ! m_preserf) so `ppser_initialize` can reset it on a fresh session;
   ! without that reset, a process that called `fs_disable_serialization`
   ! before a previous `ppser_finalize` would silently no-op every
   ! subsequent fs_* call in the same process.
   integer, save, public :: serialisation_enabled = 1

   ! Verbosity level set by `!$SER OPTION verbosity=` via fs_Option
   ! (ADR 0003 §4). A runtime knob with no on-disk effect beyond the
   ! `_preserf_option_verbosity` round-trip attribute the helper records;
   ! reset to 0 on every fresh ppser_initialize.
   integer, save, public :: ppser_verbosity = 0

   ! Schema version written into _preserf_schema_version. Must match
   ! tests/_support/storage.py SCHEMA_VERSION.
   integer(int32), parameter, public :: PRESERF_SCHEMA_VERSION = 1

   ! Cap matching storage_mapping.md §5 (sp_{idx:06d} naming).
   integer, parameter, public :: PRESERF_SAVEPOINT_INDEX_LIMIT = 1000000

   ! -------------------------------------------------------------------------
   ! Tracer registry (ADR 0003 §3, storage_mapping.md §4a)
   ! -------------------------------------------------------------------------
   !
   ! pp_ser's tracer directives carry only a name/index + stype + an
   ! integer timelevel — never the data array (real Serialbox resolves
   ! it from the host model's tracer module). preserf has no host model,
   ! so the helper owns a small built-in registry that host code / tests
   ! populate via `ppser_register_tracer` (m_preserf). `fs_RegisterAllTracers`
   ! then writes one `/_tracers/<name>` descriptor per entry, and the
   ! `ppser_write_tracer_*` entry points resolve the data from here.
   !
   ! v1.0 binds real(real64) tracer data. The registry holds a *pointer*
   ! to the host's array (rank-specific component, one set per rank) rather
   ! than a copy, so a read-mode `!$SER TRACER` can read the stored field
   ! back into the host's array. The host array MUST have the TARGET
   ! attribute and outlive the run (F2008 12.5.2.4: a pointer associated
   ! with a TARGET dummy stays associated with the TARGET actual after
   ! return). Extending to other dtypes is a template-stanza change.
   integer, parameter, public :: PPSER_MAX_TRACERS = 256
   integer, parameter, public :: PPSER_TRACER_NAME_LEN = 64
   integer, parameter, public :: PPSER_TRACER_STYPE_LEN = 16
   ! Serialbox TypeID for real(real64); mirrors TID_FLOAT64 in m_preserf.
   integer(int32), parameter, public :: PPSER_TRACER_TID_FLOAT64 = 5

   type, public :: t_tracer_entry
      character(len=PPSER_TRACER_NAME_LEN) :: name = ''
      character(len=PPSER_TRACER_STYPE_LEN) :: stype = ''
      integer(int32) :: type_id = PPSER_TRACER_TID_FLOAT64
      integer :: rank = 0
      integer :: fshape(4) = 0
      real(real64), pointer :: d1(:) => null()
      real(real64), pointer :: d2(:, :) => null()
      real(real64), pointer :: d3(:, :, :) => null()
      real(real64), pointer :: d4(:, :, :, :) => null()
   end type t_tracer_entry

   type(t_tracer_entry), public, save :: ppser_tracers(PPSER_MAX_TRACERS)
   integer, public, save :: ppser_tracer_count = 0

   ! -------------------------------------------------------------------------
   ! k-buffer table (DATA_KBUFF, ADR 0003 §5, storage_mapping.md §6)
   ! -------------------------------------------------------------------------
   !
   ! `fs_write_kbuff` is called once per vertical level `k` with the
   ! horizontal slice at that level; the helper buffers each slice and, on
   ! the last level (k == k_size), assembles the full field and writes it
   ! like a !$SER DATA field. One active buffer per (savepoint group, field
   ! name); a slot is freed on flush. v1.0 buffers real(real64) slices of
   ! rank 1-3 (full fields rank 2-4). `fshape` is the full field's Fortran
   ! shape: the slice shape followed by k_size.
   integer, parameter, public :: PPSER_MAX_KBUFF = 64

   type, public :: t_kbuff_entry
      integer :: grpid = -1
      character(len=PPSER_TRACER_NAME_LEN) :: name = ''
      integer :: full_rank = 0
      integer :: fshape(4) = 0
      integer :: slice_size = 0
      integer :: k_size = 0
      integer :: filled = 0
      real(real64), allocatable :: buffer(:)
   end type t_kbuff_entry

   type(t_kbuff_entry), public, save :: ppser_kbuffers(PPSER_MAX_KBUFF)
   integer, public, save :: ppser_kbuff_count = 0

   ! -------------------------------------------------------------------------
   ! Public procedures
   ! -------------------------------------------------------------------------
   public :: ppser_initialize, ppser_finalize
   public :: ppser_get_mode, ppser_set_mode
   public :: ppser_reset_tracers, ppser_reset_kbuffers
   public :: preserf_check_nf, preserf_check_nf_with_msg
   public :: preserf_writer_version
   public :: preserf_logical_to_byte

contains

   !> Check a netCDF return code; abort the program with a helpful message
   !> if it indicates an error.
   subroutine preserf_check_nf(ncerr)
      integer, intent(in) :: ncerr
      if (ncerr /= NF90_NOERR) then
         write (*, '(a,a)') 'preserf: netCDF error: ', trim(nf90_strerror(ncerr))
         error stop 1
      end if
   end subroutine preserf_check_nf

   subroutine preserf_check_nf_with_msg(ncerr, where)
      integer, intent(in) :: ncerr
      character(len=*), intent(in) :: where
      if (ncerr /= NF90_NOERR) then
         write (*, '(a,a,a,a)') 'preserf: netCDF error in ', trim(where), &
            ': ', trim(nf90_strerror(ncerr))
         error stop 1
      end if
   end subroutine preserf_check_nf_with_msg

   function preserf_writer_version() result(s)
      use preserf_version_mod, only: PRESERF_VERSION
      character(len=:), allocatable :: s
      s = 'preserf '//PRESERF_VERSION
   end function preserf_writer_version

   !> Encode a logical as the NF90_BYTE 0/1 sentinel used for every
   !> boolean netCDF attribute in preserf (storage_mapping.md §1). Shared
   !> by the housekeeping writer here and the boolean metainfo overloads
   !> in m_preserf so the convention has a single source of truth.
   pure function preserf_logical_to_byte(value) result(b)
      logical, intent(in) :: value
      integer(int8) :: b
      b = merge(1_int8, 0_int8, value)
   end function preserf_logical_to_byte

   !> Return the 1-based index of the first character in `s` that needs
   !> URI percent-encoding to appear safely in a `file://...#mode=...`
   !> NCZarr URL, or 0 if every character is URL-safe. Only the
   !> structurally significant delimiters are treated as unsafe: a space,
   !> '#' (fragment), '?' (query) or '%' (percent-escape introducer).
   !> preserf builds the NCZarr URL by raw concatenation (unlike the
   !> Python reference path's `Path.as_uri()`), so `preserf_open_serializer`
   !> uses this to reject such inputs up front rather than emit a malformed
   !> URL that would target a different on-disk store than the NetCDF4
   !> backend does for the same inputs.
   pure function uri_unsafe_char(s) result(pos)
      character(len=*), intent(in) :: s
      integer :: pos, i
      pos = 0
      do i = 1, len(s)
         select case (s(i:i))
         case (' ', '#', '?', '%')
            pos = i
            return
         end select
      end do
   end function uri_unsafe_char

   !> Initialise the global serializer (and optionally a read-reference
   !> serializer) by opening a dataset under `directory` with name
   !> `prefix`. The `backend` keyword selects the store format:
   !>   * `'netcdf4'` (default) — a plain NetCDF4 `.nc` file
   !>     (`directory/prefix.nc`).
   !>   * `'nczarr-v2'` — an NCZarr V2 `.zarr` directory store, opened via
   !>     a `file://directory/prefix.zarr#mode=nczarr,zarr2` URL. This
   !>     backend additionally requires `directory` to be **absolute**
   !>     (the `file://` URL has no portable relative form); a relative
   !>     directory aborts with a clear message. An unrecognised `backend`
   !>     aborts at this boundary. The same group-per-savepoint schema
   !>     serves both backends (see docs/adr/0002-storage-model-mapping.md).
   !>
   !> **Output directory:** in write mode `directory` is created with
   !> `mkdir -p` semantics before `nf90_create` (issue #42), matching
   !> Serialbox — whose serializer creation made the output directory, so
   !> drop-in `!$SER INIT directory='...'` call sites (e.g. ICON) never
   !> mkdir it themselves. Without this a fresh run would abort inside
   !> `nf90_create` with netCDF's generic "Permission denied" (the real
   !> cause being the missing parent directory). The Python reference
   !> writer in `tests/_support/storage.py` likewise creates the directory
   !> with `mkdir(parents=True, exist_ok=True)`. Read mode does not create
   !> the directory: the store must already exist to be opened.
   !>
   !> `mode` is one of: 'w' (write, create or truncate), 'r' (read-only).
   !> Append mode ('a') is reserved but currently rejected — see
   !> src/preserf-fortran/README.md follow-ups.
   !>
   !> `mode` is **optional** for drop-in compatibility with pp_ser /
   !> Serialbox `!$SER INIT` call sites, which never pass it: Serialbox
   !> selects the mode separately via `!$SER MODE` → `ppser_set_mode`.
   !> When `mode` is omitted, the open mode is derived from the current
   !> runtime mode state a prior `ppser_set_mode` left behind — read /
   !> read-perturb (1 / 2) open read-only, write (0, the default when no
   !> mode was ever set) creates the store. When `mode` is given, it both
   !> drives the open and resets the runtime DATA mode to match (see
   !> below).
   !>
   !> When mode is 'r', the schema-version attribute on the root group is
   !> validated. In 'r' mode, `ppser_serializer_ref` is also populated:
   !>   * If `directory_ref` AND `prefix_ref` are both supplied, the
   !>     reference serializer opens that distinct store read-only.
   !>   * Otherwise it opens the same `directory/prefix` store read-only,
   !>     so pp_ser-generated DATA branches that use
   !>     `fs_read_field(ppser_serializer_ref, ...)` work without
   !>     further setup.
   !>
   !> When `directory_ref`/`prefix_ref` are supplied, the reference
   !> store is opened *before* the main store, so a wrong reference
   !> path aborts cleanly without truncating an existing target file
   !> in write mode.
   subroutine ppser_initialize(directory, prefix, mode, &
                               directory_ref, prefix_ref, &
                               singlefile, mpi_rank, rprecision, &
                               rperturb, realtype, archive, unique_id, &
                               backend)
      character(len=*), intent(in) :: directory
      character(len=*), intent(in) :: prefix
      ! Optional for pp_ser / Serialbox `!$SER INIT` compatibility: those
      ! call sites never pass `mode` (it is set separately via `!$SER MODE`
      ! → ppser_set_mode). When absent, `eff_mode` below is derived from the
      ! current runtime mode state.
      character(len=*), intent(in), optional :: mode
      character(len=*), intent(in), optional :: directory_ref
      character(len=*), intent(in), optional :: prefix_ref
      ! Serialbox-compatible keywords pp_ser passes through from
      ! `!$SER INIT`. Defaults match Serialbox so existing call sites
      ! are unaffected when a keyword is absent.
      logical, intent(in), optional :: singlefile
      integer, intent(in), optional :: mpi_rank
      real(real64), intent(in), optional :: rprecision
      real(real64), intent(in), optional :: rperturb
      character(len=*), intent(in), optional :: realtype
      character(len=*), intent(in), optional :: archive
      integer, intent(in), optional :: unique_id
      ! Storage backend selector (Slice E): 'netcdf4' (default) or
      ! 'nczarr-v2'. Threaded through to preserf_open_serializer, which
      ! turns it into the right on-disk URL / extension.
      character(len=*), intent(in), optional :: backend

      ! Effective open mode passed to preserf_open_serializer. Deferred
      ! length so it mirrors `mode` exactly when present (preserving the
      ! existing unknown-mode validation), or holds the single-character
      ! mode derived from the runtime state when `mode` is omitted.
      character(len=:), allocatable :: eff_mode

      ! Resolve the effective open mode. pp_ser's `!$SER INIT` never passes
      ! `mode`; Serialbox sets it earlier via `!$SER MODE` → ppser_set_mode,
      ! which lands in `ppser_mode_state`. Map that state to an open mode so
      ! an omitted `mode` keeps working: 1 (read) / 2 (read-perturb) open
      ! read-only, 0 (write, the default when nothing was set) creates the
      ! store.
      if (present(mode)) then
         eff_mode = mode
      else
         select case (ppser_mode_state)
         case (1, 2)
            eff_mode = 'r'
         case default
            eff_mode = 'w'
         end select
      end if

      ! Validate optional-argument coherence BEFORE creating/truncating
      ! the main store, so a partial-arg mistake doesn't trash an
      ! existing target file.
      if (present(directory_ref) .neqv. present(prefix_ref)) then
         write (*, '(a)') 'preserf: ppser_initialize requires either both '// &
            'directory_ref and prefix_ref, or neither'
         error stop 1
      end if

      ! Reject an unknown backend at the user-facing boundary, before any
      ! store is opened, so a typo'd `!$SER INIT` backend keyword aborts
      ! with a clear message rather than a deep netCDF URL error.
      if (present(backend)) then
         if (backend /= 'netcdf4' .and. backend /= 'nczarr-v2') then
            write (*, '(a,a)') 'preserf: unknown backend: ', backend
            write (*, '(a)') "preserf: backend must be 'netcdf4' or 'nczarr-v2'"
            error stop 1
         end if
      end if

      ! Behaviour-changing keywords: update the module state that
      ! pp_ser-generated REGISTER / DATA calls consume. `rprecision`
      ! is a Serialbox-compatible real tolerance value (e.g. the ICON
      ! caller passes `10.0**(-PRECISION(1.0))`, ~1e-6); it is accepted
      ! here for interface compatibility but not currently used — the
      ! real byte length is determined by `realtype` / the real kind.
      ! `realtype` is the type string passed to `fs_register_field`;
      ! `rperturb` feeds the read-perturb path (Slice A-2) via
      ! `ppser_zrperturb`.
      !
      ! Reset to the Serialbox defaults FIRST. All three of
      ! `ppser_reallength`, `ppser_realtype`, and `ppser_zrperturb` are
      ! module SAVE state, so without a reset an override from a prior
      ! init in the same process would stick across a later init that
      ! omits the keyword — the omitting init must see the documented
      ! default, not the stale override. (`ppser_reallength` is reset
      ! alongside `ppser_realtype` because it is re-derived from
      ! `realtype` below, so a stale length must not survive either.)
      ppser_reallength = PPSER_DEFAULT_REALLENGTH
      ppser_realtype = PPSER_DEFAULT_REALTYPE
      ppser_zrperturb = PPSER_DEFAULT_RPERTURB
      if (present(realtype)) then
         ! `realtype` comes from a user-authored `!$SER INIT` directive,
         ! so reject an over-long value loudly rather than silently
         ! truncating it into the fixed-length `ppser_realtype` (which
         ! would then mis-register every real field).
         if (len_trim(realtype) > len(ppser_realtype)) then
            write (*, '(a,i0,a)') &
               'preserf: realtype string exceeds ', len(ppser_realtype), &
               ' characters'
            error stop 1
         end if
         ppser_realtype = realtype
         ! Derive the byte length from the type name so `ppser_reallength`
         ! is always consistent with `ppser_realtype`. Serialbox convention:
         ! 'float'/'single' → 4 bytes; 'double' → 8 bytes; 'real' → 8 bytes
         ! (the Serialbox default); any other name leaves the default intact.
         ! Match case-insensitively (mirroring `type_id_from_datatype`'s
         ! `to_lower` on the datatype) so e.g. `realtype='FLOAT'` derives a
         ! length of 4 instead of silently keeping the default 8, which
         ! would later abort `fs_register_field` on a byte-length mismatch.
         select case (preserf_to_lower(trim(realtype)))
         case ('float', 'single')
            ppser_reallength = 4
         case ('double', 'real')
            ppser_reallength = 8
         end select
      end if
      if (present(rperturb)) ppser_zrperturb = rperturb

      ! Open the read-only reference store FIRST when an explicit
      ! `directory_ref`/`prefix_ref` pair is supplied. In write or
      ! append mode the main `nf90_create` truncates the target file
      ! on success, so a wrong reference path discovered after the
      ! main open would have already destroyed the user's data. By
      ! opening the reference first, a bad reference path aborts
      ! cleanly without touching the writable target.
      if (present(directory_ref) .and. present(prefix_ref)) then
         call preserf_open_serializer(ppser_serializer_ref, &
                                      directory_ref, prefix_ref, 'r', &
                                      rank=mpi_rank, backend=backend)
      end if

      ! Thread the metadata-only keywords into the open so they are
      ! recorded in `_preserf_*` root attributes at store-creation time,
      ! alongside the other housekeeping attrs (single-sourced in
      ! preserf_write_root_housekeeping). They are written only on the
      ! 'w' path; read-mode opens ignore them, so the read-only reference
      ! store below is left untouched.
      call preserf_open_serializer(ppser_serializer, directory, prefix, &
                                   eff_mode, &
                                   rank=mpi_rank, singlefile=singlefile, &
                                   archive=archive, unique_id=unique_id, &
                                   backend=backend)

      if (.not. (present(directory_ref) .and. present(prefix_ref))) then
         if (eff_mode == 'r' .or. eff_mode == 'R') then
            ! pp_ser-generated read/read-perturb DATA branches call
            ! `fs_read_field(ppser_serializer_ref, ...)`. In a plain
            ! read-mode init without explicit reference args, point
            ! the ref serializer at the same store so those branches
            ! just work. Both serializers open their own netCDF
            ! handle to the same on-disk file (HDF5 allows multiple
            ! read-only opens).
            call preserf_open_serializer(ppser_serializer_ref, &
                                         directory, prefix, 'r', &
                                         rank=mpi_rank, backend=backend)
         end if
      end if

      ! When `mode` is given explicitly, default the runtime DATA mode to
      ! match the open mode, so pp_ser-generated `SELECT CASE
      ! (ppser_get_mode())` blocks take the matching branch out of the box:
      ! 'w' → 0 (write), 'r' → 1 (read). Callers that want read-perturb
      ! (mode 2) or some other override still need to call
      ! `ppser_set_mode(...)` explicitly. Without this default, a read-only
      ! init would leave the mode at 0 and a generated DATA block would
      ! attempt to write into the read-only store.
      !
      ! When `mode` is omitted, the runtime mode state set earlier by
      ! `ppser_set_mode` (`!$SER MODE`) is authoritative and left untouched
      ! — `eff_mode` was derived from it above, so the open already matches.
      ! In particular read-perturb (2) is preserved here; a blind 'r' → 1
      ! sync would otherwise clobber it back to plain read.
      if (present(mode)) then
         select case (mode)
         case ('w', 'W')
            ppser_mode_state = 0
         case ('r', 'R')
            ppser_mode_state = 1
         end select
      end if

      ! Re-enable the ON/OFF gate. The flag is module SAVE state and
      ! survives a previous ppser_finalize, so a caller that ran
      ! fs_disable_serialization() before its last finalize would
      ! otherwise leave every subsequent fs_* call in this process a
      ! silent no-op even after a fresh INIT.
      serialisation_enabled = 1

      ! Start the tracer registry empty (ADR 0003 §3). It is module SAVE
      ! state, so a tracer registered before a prior finalize would
      ! otherwise carry into this session and get re-emitted.
      call ppser_reset_tracers()
      call ppser_reset_kbuffers()

      ! Verbosity is a runtime knob; start each session at the default so
      ! a prior `!$SER OPTION verbosity=` does not stick across a re-init.
      ppser_verbosity = 0
   end subroutine ppser_initialize

   !> Close the dataset(s) opened by ppser_initialize.
   subroutine ppser_finalize()
      call preserf_close_serializer(ppser_serializer)
      call preserf_close_serializer(ppser_serializer_ref)
      ppser_savepoint%grpid = -1
      ppser_savepoint%idx = -1
      ppser_savepoint%owner_ncid = -1
      ppser_mode_state = 0
      call ppser_reset_tracers()
      call ppser_reset_kbuffers()
      ! Also restore the ON/OFF gate to its default. ppser_initialize
      ! re-sets this on every fresh session as belt-and-braces, but
      ! resetting here too means an explicit finalize + later code
      ! that touches fs_* without a fresh init at least starts from
      ! a clean state.
      serialisation_enabled = 1
   end subroutine ppser_finalize

   function ppser_get_mode() result(m)
      integer :: m
      m = ppser_mode_state
   end function ppser_get_mode

   !> Empty the built-in tracer registry (ADR 0003 §3). Called on every
   !> fresh `ppser_initialize` and on `ppser_finalize` so a tracer
   !> registered in a previous session does not leak into the next one.
   !> Only nullifies the data pointers and clears metadata — the registry
   !> holds pointers to caller-owned TARGET arrays and owns no storage to
   !> release.
   subroutine ppser_reset_tracers()
      integer :: i
      ! Only nullify — the registry does not own the pointed-to host arrays.
      do i = 1, ppser_tracer_count
         ppser_tracers(i)%name = ''
         ppser_tracers(i)%stype = ''
         ppser_tracers(i)%rank = 0
         ppser_tracers(i)%fshape = 0
         nullify (ppser_tracers(i)%d1)
         nullify (ppser_tracers(i)%d2)
         nullify (ppser_tracers(i)%d3)
         nullify (ppser_tracers(i)%d4)
      end do
      ppser_tracer_count = 0
   end subroutine ppser_reset_tracers

   !> Drop every active k-buffer (DATA_KBUFF, ADR 0003 §5). Called on a
   !> fresh `ppser_initialize` and on `ppser_finalize`; a buffer still
   !> active here means a k-loop was left incomplete, so releasing it
   !> avoids leaking the partial accumulation into the next session.
   subroutine ppser_reset_kbuffers()
      integer :: i
      do i = 1, ppser_kbuff_count
         if (allocated(ppser_kbuffers(i)%buffer)) &
            deallocate (ppser_kbuffers(i)%buffer)
         ppser_kbuffers(i)%grpid = -1
         ppser_kbuffers(i)%name = ''
         ppser_kbuffers(i)%full_rank = 0
         ppser_kbuffers(i)%fshape = 0
         ppser_kbuffers(i)%slice_size = 0
         ppser_kbuffers(i)%k_size = 0
         ppser_kbuffers(i)%filled = 0
      end do
      ppser_kbuff_count = 0
   end subroutine ppser_reset_kbuffers

   !> Set the runtime DATA mode. Only 0 (write), 1 (read), and 2
   !> (read-perturb) are accepted; pp_ser-generated SELECT CASE blocks
   !> only branch on these three values, so silently storing an
   !> out-of-range mode would make subsequent DATA directives behave
   !> as no-ops without explanation.
   subroutine ppser_set_mode(m)
      integer, intent(in) :: m
      if (m < 0 .or. m > 2) then
         write (*, '(a,i0,a)') &
            'preserf: ppser_set_mode(', m, &
            ') is out of range; expected 0 (write), 1 (read), '// &
            'or 2 (read-perturb)'
         error stop 1
      end if
      ppser_mode_state = m
   end subroutine ppser_set_mode

   ! -------------------------------------------------------------------------
   ! Internal helpers
   ! -------------------------------------------------------------------------

   subroutine preserf_open_serializer(s, directory, prefix, mode, rank, &
                                      singlefile, archive, unique_id, &
                                      backend)
      type(t_serializer), intent(inout) :: s
      character(len=*), intent(in) :: directory
      character(len=*), intent(in) :: prefix
      character(len=*), intent(in) :: mode
      integer, intent(in), optional :: rank
      ! Metadata-only `!$SER INIT` keywords, recorded as root attributes
      ! on the 'w' path only (ignored when opening read-only).
      logical, intent(in), optional :: singlefile
      character(len=*), intent(in), optional :: archive
      integer, intent(in), optional :: unique_id
      ! Storage backend (Slice E); defaults to PPSER_DEFAULT_BACKEND.
      character(len=*), intent(in), optional :: backend

      character(len=:), allocatable :: path, base, eff_backend
      character(len=32) :: rank_suffix
      integer :: ncerr, version

      eff_backend = PPSER_DEFAULT_BACKEND
      if (present(backend)) eff_backend = backend

      ! `mpi_rank` maps to a `_rank<n>` suffix on the on-disk store
      ! name (storage_mapping.md §9) so parallel runs write one store
      ! per rank instead of clobbering a shared file. The suffix is
      ! applied here, the single point where the path is built, and
      ! only to the store name — the logical `prefix` recorded in the
      ! `_preserf_serialbox_prefix` root attribute stays unsuffixed.
      ! `base` is the suffixed store name shared by both backends; the
      ! backend only decides the extension / URL wrapper below.
      if (present(rank)) then
         write (rank_suffix, '(a,i0)') '_rank', rank
         base = trim(prefix)//trim(rank_suffix)
      else
         base = trim(prefix)
      end if

      ! Build the on-disk target per backend. NetCDF4 is a plain `.nc`
      ! file path; NCZarr V2 is a `file://...#mode=nczarr,zarr2` URL onto
      ! a `.zarr` directory store, matching open_url_for() in
      ! tests/_support/storage.py so writer and reader agree. The mode
      ! query is what makes netcdf-c dispatch to the NCZarr backend, so
      ! the nf90_create / nf90_open flags below stay NF90_NETCDF4 /
      ! NF90_NOWRITE for both backends.
      select case (eff_backend)
      case ('netcdf4')
         path = trim(directory)//'/'//base//'.nc'
      case ('nczarr-v2')
         ! NCZarr's file:// URL needs an absolute directory: 'file://'
         ! prepended to an absolute '/dir' yields the well-formed
         ! file:///dir, but a relative directory would be parsed as
         ! file://<authority>/... and silently target the wrong store.
         ! The Python reference path sidesteps this with Path.resolve();
         ! the Fortran helper has no portable realpath, so require an
         ! absolute directory and abort with a clear message otherwise.
         ! Nested ifs (not a single `.or.`) so directory(1:1) is never
         ! evaluated on a zero-length string — Fortran does not guarantee
         ! short-circuit evaluation of `.or.`.
         if (len(directory) == 0) then
            write (*, '(a)') &
               'preserf: nczarr-v2 backend requires a non-empty, '// &
               'absolute directory'
            error stop 1
         else if (directory(1:1) /= '/') then
            write (*, '(a,a,a)') &
               "preserf: nczarr-v2 backend requires an absolute directory "// &
               "(got: '", trim(directory), "')"
            error stop 1
         end if
         ! The URL is built by raw concatenation, not URI-encoded like
         ! open_url_for()'s Path.as_uri() on the Python side. Characters
         ! that carry syntactic meaning in a `file://...#mode=...` URL
         ! (space, '#', '?', '%') would either break the URL or be decoded
         ! to a different on-disk path than the NetCDF4 backend uses for
         ! the same inputs, so reject them with a clear message rather than
         ! silently targeting the wrong store. pp_ser-generated paths are
         ! simple, so this is a precondition, not a functional limit.
         if (uri_unsafe_char(trim(directory)) /= 0) then
            write (*, '(a,a,a)') &
               "preserf: nczarr-v2 directory contains a character that "// &
               "needs URI-encoding (space, #, ? or %): '", trim(directory), "'"
            error stop 1
         end if
         if (uri_unsafe_char(base) /= 0) then
            write (*, '(a,a,a)') &
               "preserf: nczarr-v2 store name contains a character that "// &
               "needs URI-encoding (space, #, ? or %): '", base, "'"
            error stop 1
         end if
         path = 'file://'//trim(directory)//'/'//base//'.zarr#mode=nczarr,zarr2'
      case default
         ! ppser_initialize validates the backend up front, so this is a
         ! defensive guard for any other internal caller.
         write (*, '(a,a)') 'preserf: unknown backend: ', eff_backend
         error stop 1
      end select

      select case (mode)
      case ('w', 'W')
         ! Create `directory` (mkdir -p semantics) before nf90_create,
         ! matching Serialbox: its serializer creation made the output
         ! directory, so real `!$SER INIT directory='...'` call sites (and
         ! the runscripts that drive them) never mkdir it. Without this a
         ! fresh run aborts inside nf90_create with netCDF's generic
         ! "Permission denied" (the real cause is the missing parent dir).
         ! Only the 'w' path needs it — a read open requires the store to
         ! already exist. For nczarr-v2 the `.zarr` store is itself a
         ! directory under `directory`, so creating `directory` (its parent)
         ! is the right target there too.
         call preserf_ensure_directory(directory)
         ncerr = nf90_create(path, NF90_NETCDF4, s%ncid)
         call preserf_check_nf_with_msg(ncerr, 'nf90_create '//path)
         s%writable = .true.
         call preserf_write_root_housekeeping(s, prefix, singlefile, &
                                              archive, unique_id)
         call preserf_create_skeleton_groups(s)

      case ('r', 'R')
         ncerr = nf90_open(path, NF90_NOWRITE, s%ncid)
         call preserf_check_nf_with_msg(ncerr, 'nf90_open '//path)
         s%writable = .false.
         call preserf_validate_schema_version(s, version)
         call preserf_resolve_skeleton_groups(s)

      case ('a', 'A')
         ! Append mode requires resuming next_sp_index by scanning the
         ! existing /savepoints/sp_NNNNNN groups, which needs an
         ! nf90_inq_grps call shape that the netcdf-fortran 4.5.x
         ! wrapper makes awkward (see src/preserf-fortran/README.md
         ! follow-ups). Until that is implemented, 'a' is rejected
         ! rather than silently corrupting _preserf_savepoint_count
         ! (which would be rewritten to 0 on close).
         write (*, '(a)') &
            'preserf: append mode (a) is not yet supported in v0.1; '// &
            'use w (create) or r (read)'
         error stop 1

      case default
         write (*, '(a,a)') 'preserf: unknown open mode: ', mode
         error stop 1
      end select
      ! Silence "unused" warning for `version` on write-path opens.
      if (.false.) version = version
   end subroutine preserf_open_serializer

   !> Create `directory` with `mkdir -p` semantics before a write-mode
   !> open, so a fresh run does not abort inside `nf90_create` on a missing
   !> parent directory (issue #42). Serialbox's serializer creation made
   !> the directory, so drop-in `!$SER INIT directory='...'` call sites
   !> never do; preserf must match that behaviour.
   !>
   !> Fortran has no intrinsic mkdir, so the portable approach is
   !> `EXECUTE_COMMAND_LINE` with the platform `mkdir`. `mkdir -p` is a
   !> no-op when the directory already exists, so re-initialising over an
   !> existing store is fine. An empty `directory` is skipped here rather
   !> than running `mkdir -p ''`: with the netcdf4 backend the store path
   !> is built as `trim(directory)//'/'//<prefix>.nc`, so an empty
   !> `directory` yields the root-anchored `/<prefix>.nc` (it does NOT mean
   !> "current working directory"); there is no parent directory for
   !> preserf to create in that case, so the skip is correct.
   !>
   !> A failed `mkdir` (`exitstat /= 0`) or a shell that could not be
   !> launched (`cmdstat /= 0`) aborts with a clear message that names the
   !> directory, rather than letting the subsequent `nf90_create` fail with
   !> netCDF's generic "Permission denied".
   subroutine preserf_ensure_directory(directory)
      character(len=*), intent(in) :: directory
      integer :: exitstat, cmdstat
      character(len=256) :: cmdmsg

      if (len_trim(directory) == 0) return

      ! Single-quote the path so spaces and shell metacharacters are taken
      ! literally; embedded single quotes are escaped via the standard
      ! '\'' close-reopen idiom so a quote in the path cannot break out of
      ! the quoting. `--` terminates option parsing so a path beginning with
      ! `-` is treated as an operand rather than a `mkdir` flag.
      call execute_command_line( &
         "mkdir -p -- '"//replace_single_quotes(trim(directory))//"'", &
         wait=.true., exitstat=exitstat, cmdstat=cmdstat, cmdmsg=cmdmsg)

      if (cmdstat /= 0) then
         write (*, '(a,a,a,a)') &
            'preserf: could not run mkdir for output directory ', &
            trim(directory), ': ', trim(cmdmsg)
         error stop 1
      end if
      if (exitstat /= 0) then
         ! Note: the Fortran standard only guarantees `cmdmsg` is defined
         ! when `cmdstat /= 0`. Here the command ran (`cmdstat == 0`) but
         ! `mkdir` returned a non-zero exit status, so `cmdmsg` may be
         ! undefined and must not be read; report only the exit status.
         write (*, '(a,a,a,i0,a)') &
            'preserf: failed to create output directory ', &
            trim(directory), ' (mkdir exit status ', exitstat, ')'
         error stop 1
      end if
   end subroutine preserf_ensure_directory

   !> Return `s` with every single quote replaced by the shell-safe
   !> close-reopen escape `'\''`, so the result can be embedded inside a
   !> single-quoted shell word. Used by preserf_ensure_directory to pass an
   !> arbitrary directory path to `mkdir -p` without shell injection.
   pure function replace_single_quotes(s) result(out)
      character(len=*), intent(in) :: s
      character(len=:), allocatable :: out
      integer :: i
      out = ''
      do i = 1, len(s)
         if (s(i:i) == "'") then
            out = out//"'\''"
         else
            out = out//s(i:i)
         end if
      end do
   end function replace_single_quotes

   subroutine preserf_close_serializer(s)
      type(t_serializer), intent(inout) :: s
      integer :: ncerr
      integer(int32) :: savepoint_count
      logical :: entered_define_mode

      if (s%ncid /= -1) then
         if (s%writable) then
            ! Refresh the savepoint count attribute before closing.
            !
            ! On NETCDF4 (HDF5-backed) datasets nf90_redef is a no-op
            ! and returns NF90_NOERR; on classic datasets it actually
            ! enters define mode. Some files may already be in define
            ! mode from earlier writes, in which case redef returns
            ! NF90_EINDEFINE — we treat that as a no-op too. Any
            ! other return code is unexpected and aborts the close
            ! rather than silently skipping the metadata refresh.
            ncerr = nf90_redef(s%ncid)
            if (ncerr == NF90_NOERR) then
               entered_define_mode = .true.
            else if (ncerr == NF90_EINDEFINE) then
               entered_define_mode = .false.
            else
               call preserf_check_nf_with_msg(ncerr, 'nf90_redef before close')
               entered_define_mode = .false.  ! unreachable
            end if

            savepoint_count = int(s%next_sp_index, int32)
            ncerr = nf90_put_att(s%ncid, NF90_GLOBAL, &
                                 '_preserf_savepoint_count', savepoint_count)
            call preserf_check_nf_with_msg(ncerr, &
                                           'nf90_put_att _preserf_savepoint_count')

            if (entered_define_mode) then
               ncerr = nf90_enddef(s%ncid)
               call preserf_check_nf_with_msg(ncerr, 'nf90_enddef before close')
            end if
         end if
         ncerr = nf90_close(s%ncid)
         call preserf_check_nf_with_msg(ncerr, 'nf90_close')
         s%ncid = -1
         s%fields_grpid = -1
         ! `/_tracers` is created lazily per session (fs_RegisterAllTracers),
         ! so this id MUST be cleared on close — otherwise a later
         ! write-mode ppser_initialize in the same process would see a stale
         ! non-(-1) id, skip the lazy create, and write tracer descriptors
         ! against a group from the previous (closed) file.
         s%tracers_grpid = -1
         s%savepoints_grpid = -1
         s%next_sp_index = 0
         s%writable = .true.
      end if
   end subroutine preserf_close_serializer

   !> Write every `_preserf_*` root attribute for a freshly created store
   !> from one place. The first four are intrinsic housekeeping; the
   !> optional `singlefile` / `archive` / `unique_id` are the metadata-only
   !> `!$SER INIT` keywords pp_ser passes through — recorded purely so a
   !> store round-trips them (they do not affect preserf's runtime
   !> behaviour). Each metadata attr is written with its effective value:
   !> the supplied keyword, or the `PPSER_DEFAULT_*` Serialbox default when
   !> absent, so the reader always finds a complete set. `singlefile`
   !> follows the Boolean storage convention (NF90_BYTE, 0/1) used for
   !> boolean metainfo in m_preserf.
   subroutine preserf_write_root_housekeeping(s, prefix, singlefile, &
                                              archive, unique_id)
      type(t_serializer), intent(inout) :: s
      character(len=*), intent(in) :: prefix
      logical, intent(in), optional :: singlefile
      character(len=*), intent(in), optional :: archive
      integer, intent(in), optional :: unique_id

      integer :: ncerr
      integer(int32) :: zero, schema_version, uid
      integer(int8) :: singlefile_flag
      logical :: singlefile_eff
      character(len=:), allocatable :: archive_eff

      zero = 0_int32
      schema_version = PRESERF_SCHEMA_VERSION

      ncerr = nf90_put_att(s%ncid, NF90_GLOBAL, &
                           '_preserf_schema_version', schema_version)
      call preserf_check_nf_with_msg(ncerr, 'put_att _preserf_schema_version')

      ncerr = nf90_put_att(s%ncid, NF90_GLOBAL, &
                           '_preserf_serialbox_prefix', trim(prefix))
      call preserf_check_nf_with_msg(ncerr, 'put_att _preserf_serialbox_prefix')

      ncerr = nf90_put_att(s%ncid, NF90_GLOBAL, &
                           '_preserf_savepoint_count', zero)
      call preserf_check_nf_with_msg(ncerr, 'put_att _preserf_savepoint_count')

      ncerr = nf90_put_att(s%ncid, NF90_GLOBAL, &
                           '_preserf_writer', preserf_writer_version())
      call preserf_check_nf_with_msg(ncerr, 'put_att _preserf_writer')

      ! Metadata-only INIT keywords (effective value = keyword or default).
      singlefile_eff = PPSER_DEFAULT_SINGLEFILE
      if (present(singlefile)) singlefile_eff = singlefile
      singlefile_flag = preserf_logical_to_byte(singlefile_eff)
      ncerr = nf90_put_att(s%ncid, NF90_GLOBAL, &
                           '_preserf_singlefile', singlefile_flag)
      call preserf_check_nf_with_msg(ncerr, 'put_att _preserf_singlefile')

      archive_eff = PPSER_DEFAULT_ARCHIVE
      if (present(archive)) archive_eff = trim(archive)
      ncerr = nf90_put_att(s%ncid, NF90_GLOBAL, '_preserf_archive', archive_eff)
      call preserf_check_nf_with_msg(ncerr, 'put_att _preserf_archive')

      uid = int(PPSER_DEFAULT_UNIQUE_ID, int32)
      if (present(unique_id)) uid = int(unique_id, int32)
      ncerr = nf90_put_att(s%ncid, NF90_GLOBAL, '_preserf_unique_id', uid)
      call preserf_check_nf_with_msg(ncerr, 'put_att _preserf_unique_id')
   end subroutine preserf_write_root_housekeeping

   subroutine preserf_create_skeleton_groups(s)
      type(t_serializer), intent(inout) :: s
      integer :: ncerr

      ncerr = nf90_def_grp(s%ncid, '_fields', s%fields_grpid)
      call preserf_check_nf_with_msg(ncerr, 'def_grp /_fields')

      ! `/_tracers` is created lazily by fs_RegisterAllTracers the first
      ! time a tracer is registered (ADR 0003 §1, storage_mapping.md §4a),
      ! not here — so a field-only store carries no empty tracer group.
      ! Clear the id for this fresh write session so the lazy create fires
      ! (belt-and-braces with the reset in preserf_close_serializer).
      s%tracers_grpid = -1

      ncerr = nf90_def_grp(s%ncid, 'savepoints', s%savepoints_grpid)
      call preserf_check_nf_with_msg(ncerr, 'def_grp /savepoints')
   end subroutine preserf_create_skeleton_groups

   subroutine preserf_resolve_skeleton_groups(s)
      type(t_serializer), intent(inout) :: s
      integer :: ncerr

      ncerr = nf90_inq_ncid(s%ncid, '_fields', s%fields_grpid)
      call preserf_check_nf_with_msg(ncerr, 'inq_ncid /_fields')

      ! `/_tracers` is resolved leniently: stores written before ADR 0003
      ! have no such group, and a field-only run must still open them. Any
      ! lookup failure (the common one being "group not found") leaves
      ! tracers_grpid = -1, which the tracer read path treats as "no
      ! tracers registered".
      ncerr = nf90_inq_ncid(s%ncid, '_tracers', s%tracers_grpid)
      if (ncerr /= NF90_NOERR) s%tracers_grpid = -1

      ncerr = nf90_inq_ncid(s%ncid, 'savepoints', s%savepoints_grpid)
      call preserf_check_nf_with_msg(ncerr, 'inq_ncid /savepoints')

      ! Append-mode index resumption (scanning existing /savepoints/sp_*
      ! groups to pick up where the previous run left off) is intentionally
      ! deferred — it requires nf90_inq_grps with a pre-sized output array,
      ! and 'a' mode is out of scope for the minimal v0.1 helper.
      s%next_sp_index = 0
   end subroutine preserf_resolve_skeleton_groups

   subroutine preserf_validate_schema_version(s, version)
      type(t_serializer), intent(in) :: s
      integer, intent(out) :: version
      integer :: ncerr

      ncerr = nf90_get_att(s%ncid, NF90_GLOBAL, &
                           '_preserf_schema_version', version)
      call preserf_check_nf_with_msg(ncerr, &
                                     'get_att _preserf_schema_version (not a preserf store?)')

      if (version /= PRESERF_SCHEMA_VERSION) then
         write (*, '(a,i0,a,i0)') &
            'preserf: unsupported schema version ', version, &
            '; this build supports ', PRESERF_SCHEMA_VERSION
         error stop 1
      end if
   end subroutine preserf_validate_schema_version

   ! ASCII lowercase, mirroring `m_preserf`'s `to_lower`. Duplicated here
   ! (rather than reused) because `m_preserf` already `use`s this module,
   ! so depending on it back would be a circular module dependency.
   pure function preserf_to_lower(s) result(r)
      character(len=*), intent(in) :: s
      character(len=len(s)) :: r
      integer :: i, c

      do i = 1, len(s)
         c = iachar(s(i:i))
         if (c >= iachar('A') .and. c <= iachar('Z')) then
            r(i:i) = achar(c + 32)
         else
            r(i:i) = s(i:i)
         end if
      end do
   end function preserf_to_lower

end module utils_preserf
