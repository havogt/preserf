!> Minimal end-to-end exercise of the preserf Fortran helper API.
!>
!> Registers three `real(real64)` fields covering the 1-D / 2-D / 3-D
!> `fs_write_field` / `fs_read_field` overloads (`v(5)`, `w(3,4)`,
!> `u(4,3,2)`), with non-zero halos on `u` to exercise the `put_halo_attr`
!> path. Writes a serializer-level metainfo mix that covers every
!> scalar overload (String, Int32, Boolean, Int64, Float32) plus a
!> savepoint with Int32 + Float64 metainfo. Then re-opens the store
!> read-only and reads all three fields back to verify lossless
!> round-trip.
!>
!> The Python test in tests/integration_tests/test_fortran_wire_compat.py runs this binary
!> and additionally validates the on-disk attribute and variable types
!> directly via netCDF4 (so the kind-specific `nf90_put_att` branches
!> are protected against on-disk type regressions).
program test_minimal
   use, intrinsic :: iso_fortran_env, only: int32, int64, real32, real64
   ! Deliberately import the alias module names rather than the real
   ! ones (utils_preserf, m_preserf). pp_ser-generated source uses
   ! `USE m_serialize` / `USE utils_ppser`, so wiring the integration
   ! test through the same names protects the re-export path against
   ! regressions (a removed/renamed public symbol that breaks the
   ! aliases will fail this test instead of silently slipping
   ! through).
   use utils_ppser
   use m_serialize
   implicit none

   character(len=:), allocatable :: out_dir
   character(len=:), allocatable :: arg_buf
   integer :: arg_len, arg_stat
   real(real64), allocatable :: u(:, :, :), u_back(:, :, :)
   real(real64), allocatable :: v(:), v_back(:)
   real(real64), allocatable :: w(:, :), w_back(:, :)
   integer, parameter :: ni = 4, nj = 3, nk = 2
   integer, parameter :: nv = 5
   integer, parameter :: nw_i = 3, nw_j = 4
   integer :: i, j, k
   real(real64) :: maxdiff
   ! No local `sp` declaration: pp_ser-generated code uses the
   ! module-level `ppser_savepoint` from utils_ppser, so exercising
   ! the integration test through that handle protects the
   ! default-arg branch of fs_create_savepoint against regressions.

   if (command_argument_count() < 1) then
      write (*, '(a)') 'usage: test_minimal <output_dir>'
      error stop 1
   end if
   ! Query the argument length first (the LENGTH= form of
   ! get_command_argument returns the full required size), then
   ! allocate a buffer of exactly that length — a fixed-size buffer
   ! could truncate or overflow.
   call get_command_argument(1, length=arg_len, status=arg_stat)
   if (arg_stat /= 0) then
      write (*, '(a,i0)') &
         'preserf-test_minimal: get_command_argument(length) failed, status=', &
         arg_stat
      error stop 1
   end if
   allocate (character(len=arg_len) :: arg_buf)
   call get_command_argument(1, value=arg_buf, status=arg_stat)
   if (arg_stat /= 0) then
      write (*, '(a,i0)') &
         'preserf-test_minimal: get_command_argument(value) failed, status=', &
         arg_stat
      error stop 1
   end if
   out_dir = arg_buf
   ! Note: the caller is responsible for ensuring out_dir exists.
   ! Both invocation paths handle this:
   !   * pytest creates the dir via the tmp_path fixture before exec.
   !   * ctest's COMMAND list runs `cmake -E make_directory` first.

   ! An optional second argument selects an alternate scenario; with
   ! no second argument the full hello-world round-trip below runs.
   !
   ! 'badref-write' exercises the bad-reference-path safety property
   ! of ppser_initialize: when an explicit directory_ref / prefix_ref
   ! pair is supplied, the reference store is opened *before* the
   ! writable main store is created/truncated, so a missing reference
   ! path must abort without destroying the target file. This branch
   ! just triggers the abort; tests/integration_tests/test_fortran_wire_compat.py drives the
   ! scenario and asserts the writable target survived intact.
   if (command_argument_count() >= 2) then
      block
         character(len=:), allocatable :: scenario
         integer :: s_len, s_stat
         call get_command_argument(2, length=s_len, status=s_stat)
         if (s_stat /= 0) error stop &
            'preserf-test_minimal: get_command_argument(2,length) failed'
         allocate (character(len=s_len) :: scenario)
         call get_command_argument(2, value=scenario, status=s_stat)
         if (s_stat /= 0) error stop &
            'preserf-test_minimal: get_command_argument(2,value) failed'
         if (scenario == 'badref-write') then
            ! The reference directory does not exist, so the
            ! reference nf90_open fails and ppser_initialize aborts
            ! before the main nf90_create can truncate the target.
            call ppser_initialize(out_dir, 'fhello', 'w', &
                                  directory_ref=trim(out_dir)//'/__preserf_no_such_ref__', &
                                  prefix_ref='nope')
            ! Unreachable: a missing reference store must abort.
            error stop &
               'preserf-test_minimal: bad directory_ref was accepted'
         else if (scenario == 'init-keywords') then
            ! Exercise the behaviour-changing keywords widened onto
            ! ppser_initialize in Slice D: realtype / rprecision (real
            ! tolerance value, not byte length — see issue #38), rperturb
            ! (read-perturb scale), and mpi_rank (per-rank store suffix).
            ! Metadata-only keywords (singlefile / archive / unique_id)
            ! are Slice D Phase 3.
            block
               use netcdf
               ! Mirrors the (private) TID_FLOAT32 in m_preserf; the
               ! float32 TypeID per storage_mapping.md.
               integer, parameter :: TID_FLOAT32 = 4
               integer :: ncerr, varid
               integer(int32) :: type_id_back
               logical :: exist0, exist1, exist_plain

               ! --- realtype overrides ppser_realtype and auto-derives
               ! ppser_reallength so a real field registers as float32.
               ! rprecision is accepted as a real tolerance (Serialbox
               ! compat, e.g. ICON passes 10.0**(-PRECISION(1.0))) but
               ! does not affect ppser_reallength (see issue #38). ---
               call ppser_initialize(out_dir, 'fkw', 'w', &
                                     realtype='float', &
                                     rprecision=1.0e-6_real64)
               if (trim(ppser_realtype) /= 'float') error stop &
                  'init-keywords: realtype did not update ppser_realtype'
               if (ppser_reallength /= 4) error stop &
                  'init-keywords: realtype=float did not derive ppser_reallength=4'
               call fs_register_field(ppser_serializer, 'f32', &
                                      ppser_realtype, ppser_reallength, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               ncerr = nf90_inq_varid(ppser_serializer%fields_grpid, &
                                      'f32', varid)
               if (ncerr /= nf90_noerr) error stop &
                  'init-keywords: inq_varid f32 failed'
               ncerr = nf90_get_att(ppser_serializer%fields_grpid, varid, &
                                    'type_id', type_id_back)
               if (ncerr /= nf90_noerr) error stop &
                  'init-keywords: get_att type_id failed'
               if (type_id_back /= TID_FLOAT32) error stop &
                  'init-keywords: realtype=float did not register float32'
               call ppser_finalize()

               ! --- realtype matching is case-insensitive: an uppercase
               ! 'FLOAT' must still derive ppser_reallength=4. type_id_from_datatype
               ! lowercases the datatype, so a case-sensitive length
               ! derivation here would leave ppser_reallength at the default
               ! 8 and abort fs_register_field on a byte-length mismatch
               ! (issue #38, PR #40 review). ---
               call ppser_initialize(out_dir, 'fkw', 'w', realtype='FLOAT')
               if (trim(ppser_realtype) /= 'FLOAT') error stop &
                  'init-keywords: uppercase realtype did not update ppser_realtype'
               if (ppser_reallength /= 4) error stop &
                  'init-keywords: realtype=FLOAT did not derive ppser_reallength=4'
               call ppser_finalize()

               ! --- rperturb threads to ppser_zrperturb (Slice A-2) ---
               call ppser_initialize(out_dir, 'fkw', 'w', rperturb=1.5_real64)
               if (ppser_zrperturb /= 1.5_real64) error stop &
                  'init-keywords: rperturb did not update ppser_zrperturb'
               ! realtype was omitted on this init, so the prior init's
               ! overrides must NOT stick: they are module SAVE state and
               ! ppser_initialize resets them to the Serialbox defaults on
               ! every fresh session.
               if (trim(ppser_realtype) /= 'double') error stop &
                  'init-keywords: realtype override stuck across re-init'
               if (ppser_reallength /= 8) error stop &
                  'init-keywords: ppser_reallength override stuck across re-init'
               call ppser_finalize()

               ! rperturb omitted here must likewise fall back to the
               ! default (0), not the 1.5 override from the init above.
               call ppser_initialize(out_dir, 'fkw', 'w')
               if (ppser_zrperturb /= 0.0_real64) error stop &
                  'init-keywords: rperturb override stuck across re-init'
               call ppser_finalize()

               ! --- mpi_rank suffixes the store name: one file per rank,
               ! and never the bare prefix (storage_mapping.md §9) ---
               ! Clear any fmr* stores first. The ctest fixture creates
               ! test-output but never cleans it, so a store left by a
               ! prior run could otherwise satisfy the positive existence
               ! checks (without this run writing it) or trip the
               ! bare-prefix negative check below — both false results.
               call delete_if_exists(trim(out_dir)//'/fmr.nc')
               call delete_if_exists(trim(out_dir)//'/fmr_rank0.nc')
               call delete_if_exists(trim(out_dir)//'/fmr_rank1.nc')
               call ppser_initialize(out_dir, 'fmr', 'w', mpi_rank=0)
               call ppser_finalize()
               call ppser_initialize(out_dir, 'fmr', 'w', mpi_rank=1)
               call ppser_finalize()
               inquire (file=trim(out_dir)//'/fmr_rank0.nc', exist=exist0)
               inquire (file=trim(out_dir)//'/fmr_rank1.nc', exist=exist1)
               inquire (file=trim(out_dir)//'/fmr.nc', exist=exist_plain)
               if (.not. (exist0 .and. exist1)) error stop &
                  'init-keywords: mpi_rank did not produce one store per rank'
               if (exist_plain) error stop &
                  'init-keywords: mpi_rank store must be suffixed, not bare'

               ! --- metadata-only keywords: signature compatibility ---
               ! singlefile / archive / unique_id are recorded as
               ! `_preserf_*` root attributes (Slice D Phase 3); the
               ! cross-language round-trip of their values is asserted in
               ! tests/integration_tests/test_preprocessor_e2e.py. Pass all
               ! three (with the behaviour-changing ones too) so a
               ! type/name mismatch in the widened interface fails to
               ! compile here rather than in downstream generated code.
               call ppser_initialize(out_dir, 'fmeta', 'w', &
                                     singlefile=.true., archive='netcdf', &
                                     unique_id=42, mpi_rank=0, &
                                     rprecision=1.0e-6_real64, rperturb=0.0_real64, &
                                     realtype='double')
               call ppser_finalize()

               write (*, '(a)') 'preserf-fortran: init-keywords OK'
               stop
            end block
         else if (scenario == 'realtype-too-long') then
            ! A realtype string longer than ppser_realtype's fixed
            ! length must abort rather than silently truncate (which
            ! would mis-register every real field). Python's
            ! test_fortran_realtype_too_long_aborts drives this scenario
            ! and asserts the non-zero exit + guard message.
            call ppser_initialize(out_dir, 'frt', 'w', &
                                  realtype='this_type_name_is_far_too_long')
            ! Unreachable: the length guard must abort before returning.
            error stop &
               'preserf-test_minimal: over-long realtype was accepted'
         else if (scenario == 'backend-nczarr') then
            ! Slice E: ppser_initialize(..., backend='nczarr-v2') makes
            ! the helper emit an NCZarr V2 `.zarr` directory store (via a
            ! file://...#mode=nczarr,zarr2 URL) instead of a `.nc` file,
            ! using the same group-per-savepoint schema. Write one real64
            ! field, finalize, then re-open the same store read-only (also
            ! backend='nczarr-v2') and read it back to prove the URL
            ! round-trips end to end through the Fortran helper. The
            ! Python wire-compat test additionally decodes the `.zarr`
            ! store via tests/_support/storage.py.
            block
               real(real64) :: uz(3), uz_back(3)
               integer :: i
               do i = 1, 3
                  uz(i) = 500.0_real64 + real(i, real64)
               end do
               call ppser_initialize(out_dir, 'fzarr', 'w', backend='nczarr-v2')
               call fs_add_serializer_metainfo(ppser_serializer, 'author', &
                                               'fortran-test')
               call fs_register_field(ppser_serializer, 'u', 'double', &
                                      ppser_reallength, 3, 0, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_add_savepoint_metainfo(ppser_savepoint, 'ntstep', 1_int32)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'u', uz)
               call ppser_finalize()
               ! Re-open the NCZarr store read-only and read the field back.
               call ppser_initialize(out_dir, 'fzarr', 'r', backend='nczarr-v2')
               if (ppser_get_mode() /= 1) error stop &
                  'backend-nczarr: read open should set mode 1'
               call fs_register_field(ppser_serializer, 'u', 'double', &
                                      ppser_reallength, 3, 0, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_add_savepoint_metainfo(ppser_savepoint, 'ntstep', 1_int32)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u', uz_back)
               do i = 1, 3
                  if (uz_back(i) /= 500.0_real64 + real(i, real64)) error stop &
                     'backend-nczarr: data round-trip mismatch'
               end do
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: backend-nczarr OK'
               stop
            end block
         else if (scenario == 'backend-bad') then
            ! Slice E: an unrecognised backend must abort at the
            ! ppser_initialize boundary, before any store is opened, with
            ! a clear message rather than a deep netCDF URL error.
            call ppser_initialize(out_dir, 'fbad', 'w', backend='zarr3')
            ! Unreachable: the backend allowlist must abort first.
            error stop &
               'preserf-test_minimal: unknown backend was accepted'
         else if (scenario == 'backend-nczarr-relpath') then
            ! Slice E: NCZarr's file:// URL needs an absolute directory.
            ! A relative directory must abort with a clear message rather
            ! than build a malformed file://<authority>/... URL that would
            ! silently target the wrong store.
            call ppser_initialize('relative_dir_not_absolute', 'frel', 'w', &
                                  backend='nczarr-v2')
            ! Unreachable: the absolute-directory guard must abort first.
            error stop &
               'preserf-test_minimal: relative nczarr directory was accepted'
         else if (scenario == 'backend-nczarr-badchar') then
            ! Slice E: the nczarr-v2 URL is built by raw concatenation, so
            ! a directory (or prefix) carrying a URI-significant character
            ! — here a space — must abort rather than emit a malformed
            ! file:// URL that would target the wrong on-disk store.
            call ppser_initialize('/preserf abs dir', 'fbad', 'w', &
                                  backend='nczarr-v2')
            ! Unreachable: the URI-safe-char guard must abort first.
            error stop &
               'preserf-test_minimal: nczarr directory with unsafe char accepted'
         else if (scenario == 'read-roundtrip') then
            ! Slice A-1 Phase 1 + Phase 3: write a store, finalize, then
            ! re-open read-only and replay the same REGISTER / SAVEPOINT /
            ! METAINFO directives pp_ser emits outside the DATA-mode
            ! SELECT CASE. None of them may attempt an nf90_def_* on the
            ! read-only handle. Two savepoints exercise the read-side
            ! next_sp_index increment (sp_000000 → sp_000001).
            block
               real(real64) :: u_back(3)
               integer :: i
               call write_store(out_dir, 'frtrip', 100.0_real64)
               call ppser_initialize(out_dir, 'frtrip', 'r')
               if (ppser_get_mode() /= 1) error stop &
                  'read-roundtrip: ppser_initialize(..., "r") should set mode 1'
               ! Serializer + field metainfo / registry validation
               ! (all matching the written store).
               call fs_add_serializer_metainfo(ppser_serializer, 'author', &
                                               'fortran-test')
               call fs_register_field(ppser_serializer, 'u', 'double', &
                                      ppser_reallength, 3, 0, 0, 0, &
                                      1, 2, 0, 0, 0, 0, 0, 0)
               ! Savepoint 0 (sp_000000).
               call fs_create_savepoint('step', ppser_savepoint)
               if (ppser_savepoint%idx /= 0) error stop &
                  'read-roundtrip: first savepoint should resolve idx 0'
               call fs_add_savepoint_metainfo(ppser_savepoint, 'ntstep', 1_int32)
               call fs_add_savepoint_metainfo(ppser_savepoint, 't', 0.5_real64)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u', u_back)
               do i = 1, 3
                  if (u_back(i) /= 100.0_real64 + real(i, real64)) error stop &
                     'read-roundtrip: sp_000000 data round-trip mismatch'
               end do
               ! Savepoint 1 (sp_000001) — proves the index advanced.
               call fs_create_savepoint('step2', ppser_savepoint)
               if (ppser_savepoint%idx /= 1) error stop &
                  'read-roundtrip: second savepoint should resolve idx 1'
               call fs_add_savepoint_metainfo(ppser_savepoint, 'ntstep', 2_int32)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u', u_back)
               do i = 1, 3
                  if (u_back(i) /= 100.0_real64 + real(i + 3, real64)) error stop &
                     'read-roundtrip: sp_000001 data round-trip mismatch'
               end do
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: read-roundtrip OK'
               stop
            end block
         else if (scenario == 'init-default-mode') then
            ! Issue #32: `mode` is optional on ppser_initialize for pp_ser /
            ! Serialbox `!$SER INIT` drop-in compatibility — those call sites
            ! never pass it (mode is selected via `!$SER MODE` ->
            ! ppser_set_mode). Cover the three omitted-mode paths:
            !   (a) no prior set_mode  -> default write (creates the store),
            !   (b) ppser_set_mode(1)  -> read-only open, runtime mode stays 1,
            !   (c) ppser_set_mode(2)  -> read-only open, read-perturb (2)
            !       preserved (a blind 'r' -> 1 sync would clobber it).
            block
               real(real64) :: u_w(3), u_back(3)
               integer :: i
               do i = 1, 3
                  u_w(i) = 500.0_real64 + real(i, real64)
               end do

               ! (a) Omitted mode with the default runtime state writes.
               call ppser_initialize(out_dir, 'fdefmode')
               if (ppser_get_mode() /= 0) error stop &
                  'init-default-mode: omitted mode should default to write (0)'
               call fs_register_field(ppser_serializer, 'u', 'double', &
                                      ppser_reallength, 3, 0, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'u', u_w)
               call ppser_finalize()

               ! (b) `!$SER MODE read` before an INIT that omits mode opens
               ! the store read-only and leaves the runtime mode at 1.
               call ppser_set_mode(1)
               call ppser_initialize(out_dir, 'fdefmode')
               if (ppser_get_mode() /= 1) error stop &
                  'init-default-mode: set_mode(1) + omitted mode should read (1)'
               call fs_register_field(ppser_serializer, 'u', 'double', &
                                      ppser_reallength, 3, 0, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u', u_back)
               do i = 1, 3
                  if (u_back(i) /= 500.0_real64 + real(i, real64)) error stop &
                     'init-default-mode: read-back mismatch under derived read mode'
               end do
               call ppser_finalize()

               ! (c) read-perturb (2) must survive an INIT that omits mode:
               ! the open is still read-only, and the runtime mode is left
               ! at 2 rather than synced back to plain read.
               call ppser_set_mode(2)
               call ppser_initialize(out_dir, 'fdefmode')
               if (ppser_get_mode() /= 2) error stop &
                  'init-default-mode: read-perturb (2) clobbered by omitted mode'
               call ppser_finalize()

               write (*, '(a)') 'preserf-fortran: init-default-mode OK'
               stop
            end block
         else if (scenario == 'perturb-roundtrip') then
            ! Slice A-2: the 5-arg fs_read_field applies symmetric
            ! multiplicative noise data*(1 + scale*(2*r-1)) for every
            ! rank (1D / 2D / 3D). A non-zero scale must keep each element
            ! within [orig*(1-scale), orig*(1+scale)] and shift the field
            ! overall; a zero scale must leave the data bit-identical.
            block
               real(real64) :: u1(3), u1b(3)
               real(real64) :: u2(2, 2), u2b(2, 2)
               real(real64) :: u3(2, 2, 2), u3b(2, 2, 2)
               real(real64) :: dev
               integer :: i, j, k
               ! Distinct, strictly-positive fixtures so the relative
               ! bounds are unambiguous for every element.
               do i = 1, 3
                  u1(i) = 100.0_real64 + real(i, real64)
               end do
               do j = 1, 2
                  do i = 1, 2
                     u2(i, j) = 200.0_real64 + real(10*i + j, real64)
                  end do
               end do
               do k = 1, 2
                  do j = 1, 2
                     do i = 1, 2
                        u3(i, j, k) = 300.0_real64 + real(100*i + 10*j + k, real64)
                     end do
                  end do
               end do
               ! Write a store carrying one field of each rank.
               call ppser_initialize(out_dir, 'fpert', 'w')
               call fs_register_field(ppser_serializer, 'u1', 'double', &
                                      ppser_reallength, 3, 0, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'u2', 'double', &
                                      ppser_reallength, 2, 2, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'u3', 'double', &
                                      ppser_reallength, 2, 2, 2, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'u1', u1)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'u2', u2)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'u3', u3)
               call ppser_finalize()
               ! Re-open read-only and perturb-read every rank (scale 0.1).
               call ppser_initialize(out_dir, 'fpert', 'r')
               call fs_register_field(ppser_serializer, 'u1', 'double', &
                                      ppser_reallength, 3, 0, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'u2', 'double', &
                                      ppser_reallength, 2, 2, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'u3', 'double', &
                                      ppser_reallength, 2, 2, 2, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u1', u1b, 0.1_real64)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u2', u2b, 0.1_real64)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u3', u3b, 0.1_real64)
               dev = 0.0_real64
               do i = 1, 3
                  if (u1b(i) < u1(i)*0.9_real64 .or. u1b(i) > u1(i)*1.1_real64) &
                     error stop 'perturb-roundtrip: 1d value out of bounds'
                  dev = dev + abs(u1b(i) - u1(i))
               end do
               do j = 1, 2
                  do i = 1, 2
                     if (u2b(i, j) < u2(i, j)*0.9_real64 .or. &
                         u2b(i, j) > u2(i, j)*1.1_real64) &
                        error stop 'perturb-roundtrip: 2d value out of bounds'
                     dev = dev + abs(u2b(i, j) - u2(i, j))
                  end do
               end do
               do k = 1, 2
                  do j = 1, 2
                     do i = 1, 2
                        if (u3b(i, j, k) < u3(i, j, k)*0.9_real64 .or. &
                            u3b(i, j, k) > u3(i, j, k)*1.1_real64) &
                           error stop 'perturb-roundtrip: 3d value out of bounds'
                        dev = dev + abs(u3b(i, j, k) - u3(i, j, k))
                     end do
                  end do
               end do
               if (dev <= 0.0_real64) error stop &
                  'perturb-roundtrip: scale 0.1 left data unchanged'
               ! Zero scale: identity across ranks (re-read same savepoint).
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u1', u1b, 0.0_real64)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u2', u2b, 0.0_real64)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u3', u3b, 0.0_real64)
               do i = 1, 3
                  if (u1b(i) /= u1(i)) error stop &
                     'perturb-roundtrip: scale 0.0 should be identity (1d)'
               end do
               do j = 1, 2
                  do i = 1, 2
                     if (u2b(i, j) /= u2(i, j)) error stop &
                        'perturb-roundtrip: scale 0.0 should be identity (2d)'
                  end do
               end do
               do k = 1, 2
                  do j = 1, 2
                     do i = 1, 2
                        if (u3b(i, j, k) /= u3(i, j, k)) error stop &
                           'perturb-roundtrip: scale 0.0 should be identity (3d)'
                     end do
                  end do
               end do
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: perturb-roundtrip OK'
               stop
            end block
         else if (scenario == 'read-ref') then
            ! Slice A-1 Phase 2: with an explicit directory_ref / prefix_ref
            ! the savepoint is resolved against the PRIMARY serializer (as
            ! pp_ser's SAVEPOINT directive does) but the read targets the
            ! REFERENCE serializer. The data must come from the reference
            ! file, not the primary — proving fs_read_field re-resolves the
            ! savepoint under its own serializer.
            block
               real(real64) :: u_back(3)
               integer :: i
               call write_store(out_dir, 'fprimary', 100.0_real64)
               call write_store(out_dir, 'fref', 200.0_real64)
               call ppser_initialize(out_dir, 'fprimary', 'r', &
                                     directory_ref=out_dir, prefix_ref='fref')
               if (ppser_serializer_ref%ncid == -1) error stop &
                  'read-ref: explicit ref should open ppser_serializer_ref'
               call fs_register_field(ppser_serializer, 'u', 'double', &
                                      ppser_reallength, 3, 0, 0, 0, &
                                      1, 2, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_read_field(ppser_serializer_ref, ppser_savepoint, 'u', &
                                  u_back)
               do i = 1, 3
                  if (u_back(i) /= 200.0_real64 + real(i, real64)) error stop &
                     'read-ref: read returned primary data, not reference data'
               end do
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: read-ref OK'
               stop
            end block
         else if (scenario == 'read-bad-dtype') then
            call write_store(out_dir, 'fbdtype', 0.0_real64)
            call ppser_initialize(out_dir, 'fbdtype', 'r')
            ! 'float'/4 registers as type_id FLOAT32; the store has FLOAT64.
            call fs_register_field(ppser_serializer, 'u', 'float', 4, &
                                   3, 0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0)
            call abort_unexpected('read-bad-dtype')
         else if (scenario == 'read-bad-dims') then
            call write_store(out_dir, 'fbdims', 0.0_real64)
            call ppser_initialize(out_dir, 'fbdims', 'r')
            ! Size 4 instead of the registered size 3.
            call fs_register_field(ppser_serializer, 'u', 'double', &
                                   ppser_reallength, 4, 0, 0, 0, &
                                   1, 2, 0, 0, 0, 0, 0, 0)
            call abort_unexpected('read-bad-dims')
         else if (scenario == 'read-bad-halo') then
            call write_store(out_dir, 'fbhalo', 0.0_real64)
            call ppser_initialize(out_dir, 'fbhalo', 'r')
            ! iMinusHalo 9 instead of the registered 1.
            call fs_register_field(ppser_serializer, 'u', 'double', &
                                   ppser_reallength, 3, 0, 0, 0, &
                                   9, 2, 0, 0, 0, 0, 0, 0)
            call abort_unexpected('read-bad-halo')
         else if (scenario == 'read-bad-spname') then
            call write_store(out_dir, 'fbspn', 0.0_real64)
            call ppser_initialize(out_dir, 'fbspn', 'r')
            call fs_register_field(ppser_serializer, 'u', 'double', &
                                   ppser_reallength, 3, 0, 0, 0, &
                                   1, 2, 0, 0, 0, 0, 0, 0)
            ! Store's sp_000000 carries name 'step'.
            call fs_create_savepoint('wrongname', ppser_savepoint)
            call abort_unexpected('read-bad-spname')
         else if (scenario == 'read-bad-meta-value') then
            call write_store(out_dir, 'fbmval', 0.0_real64)
            call ppser_initialize(out_dir, 'fbmval', 'r')
            call fs_register_field(ppser_serializer, 'u', 'double', &
                                   ppser_reallength, 3, 0, 0, 0, &
                                   1, 2, 0, 0, 0, 0, 0, 0)
            call fs_create_savepoint('step', ppser_savepoint)
            ! Store has ntstep == 1.
            call fs_add_savepoint_metainfo(ppser_savepoint, 'ntstep', 999_int32)
            call abort_unexpected('read-bad-meta-value')
         else if (scenario == 'read-bad-meta-typeid') then
            call write_store(out_dir, 'fbmtid', 0.0_real64)
            call ppser_initialize(out_dir, 'fbmtid', 'r')
            call fs_register_field(ppser_serializer, 'u', 'double', &
                                   ppser_reallength, 3, 0, 0, 0, &
                                   1, 2, 0, 0, 0, 0, 0, 0)
            call fs_create_savepoint('step', ppser_savepoint)
            ! Store stored ntstep as Int32; replay as Float64 → type-id clash.
            call fs_add_savepoint_metainfo(ppser_savepoint, 'ntstep', 1.0_real64)
            call abort_unexpected('read-bad-meta-typeid')
         else if (scenario == 'read-bad-xtype') then
            ! Hand-build a store whose registry says FLOAT64 but whose
            ! savepoint variable is FLOAT32, so validate_field_shape passes
            ! and require_variable_xtype is the check that must reject it.
            call build_xtype_mismatch_store(trim(out_dir)//'/fbxtype.nc')
            call ppser_initialize(out_dir, 'fbxtype', 'r')
            call fs_register_field(ppser_serializer, 'u', 'double', &
                                   ppser_reallength, 3, 0, 0, 0, &
                                   0, 0, 0, 0, 0, 0, 0, 0)
            call fs_create_savepoint('step', ppser_savepoint)
            block
               real(real64) :: u_back(3)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'u', u_back)
            end block
            call abort_unexpected('read-bad-xtype')
         else if (scenario == 'type-matrix') then
            ! Slice B: smoke-test the new dtype x rank overloads end to
            ! end. One 1-D write+read round-trip per dtype (logical /
            ! int32 / int64 / real32 / real64), a 0-D (scalar) round-trip,
            ! a 4-D round-trip, and a real32 read-perturb. The full
            ! (rank x dtype) on-disk type matrix is asserted by the Python
            ! cross-language test; here we prove the Fortran overloads
            ! resolve, compile, and round-trip their values losslessly.
            block
               logical :: lf(3), lfb(3)
               integer(int32) :: i4f(3), i4fb(3), sc, scb
               integer(int64) :: i8f(3), i8fb(3)
               real(real32) :: r4f(3), r4fb(3), r4p(3)
               real(real64) :: r8f(3), r8fb(3)
               real(real32) :: a4(2, 2, 2, 2), a4b(2, 2, 2, 2)
               ! 0-D (scalar) logical + real32 exercise the rank-0 logical
               ! byte buffer and the rank-0 perturb path end to end.
               logical :: lsc, lscb
               real(real32) :: rsc, rscb
               integer :: i, j, k, l
               lf = [.true., .false., .true.]
               do i = 1, 3
                  i4f(i) = int(10 + i, int32)
                  i8f(i) = int(1000000000000_int64 + i, int64)
                  r4f(i) = real(i, real32) + 0.5_real32
                  r8f(i) = real(i, real64) + 0.25_real64
               end do
               sc = 4242_int32
               lsc = .true.
               rsc = 6.25_real32
               do l = 1, 2
                  do k = 1, 2
                     do j = 1, 2
                        do i = 1, 2
                           a4(i, j, k, l) = real(1000*i + 100*j + 10*k + l, real32)
                        end do
                     end do
                  end do
               end do

               call ppser_initialize(out_dir, 'ftypes', 'w')
               call fs_register_field(ppser_serializer, 'lf', 'bool', 1, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'i4f', 'int', 4, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'i8f', 'int64', 8, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'r4f', 'float', 4, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'r8f', 'double', 8, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               ! 0-D scalar: all-zero size tuple.
               call fs_register_field(ppser_serializer, 'sc', 'int', 4, &
                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               ! 4-D real32.
               call fs_register_field(ppser_serializer, 'a4', 'float', 4, &
                                      2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0)
               ! 0-D logical and 0-D real32 (scalar) fields.
               call fs_register_field(ppser_serializer, 'lsc', 'bool', 1, &
                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'rsc', 'float', 4, &
                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'lf', lf)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i4f', i4f)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i8f', i8f)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r4f', r4f)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r8f', r8f)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'sc', sc)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'a4', a4)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'lsc', lsc)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'rsc', rsc)
               ! 1D-array metainfo overloads (one per scalar type), on both
               ! the root serializer and the savepoint.
               call fs_add_serializer_metainfo(ppser_serializer, 'm_i4', i4f)
               call fs_add_serializer_metainfo(ppser_serializer, 'm_r8', r8f)
               call fs_add_serializer_metainfo(ppser_serializer, 'm_lg', lf)
               call fs_add_savepoint_metainfo(ppser_savepoint, 'm_i8', i8f)
               call fs_add_savepoint_metainfo(ppser_savepoint, 'm_r4', r4f)
               call ppser_finalize()

               call ppser_initialize(out_dir, 'ftypes', 'r')
               call fs_register_field(ppser_serializer, 'lf', 'bool', 1, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'i4f', 'int', 4, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'i8f', 'int64', 8, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'r4f', 'float', 4, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'r8f', 'double', 8, &
                                      3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'sc', 'int', 4, &
                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'a4', 'float', 4, &
                                      2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'lsc', 'bool', 1, &
                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'rsc', 'float', 4, &
                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'lf', lfb)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'i4f', i4fb)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'i8f', i8fb)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'r4f', r4fb)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'r8f', r8fb)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'sc', scb)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'a4', a4b)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'lsc', lscb)
               call fs_read_field(ppser_serializer, ppser_savepoint, 'rsc', rscb)
               if (any(lfb .neqv. lf)) error stop 'type-matrix: logical mismatch'
               if (any(i4fb /= i4f)) error stop 'type-matrix: int32 mismatch'
               if (any(i8fb /= i8f)) error stop 'type-matrix: int64 mismatch'
               if (any(r4fb /= r4f)) error stop 'type-matrix: real32 mismatch'
               if (any(r8fb /= r8f)) error stop 'type-matrix: real64 mismatch'
               if (scb /= sc) error stop 'type-matrix: 0-D scalar mismatch'
               if (any(a4b /= a4)) error stop 'type-matrix: 4-D mismatch'
               if (lscb .neqv. lsc) error stop 'type-matrix: 0-D logical mismatch'
               if (rscb /= rsc) error stop 'type-matrix: 0-D real32 mismatch'
               ! Read-mode validation of the 1D-array metainfo: replaying
               ! the same calls checks each stored vector attribute's
               ! values, length, and array TypeID shadow tag.
               call fs_add_serializer_metainfo(ppser_serializer, 'm_i4', i4f)
               call fs_add_serializer_metainfo(ppser_serializer, 'm_r8', r8f)
               call fs_add_serializer_metainfo(ppser_serializer, 'm_lg', lf)
               call fs_add_savepoint_metainfo(ppser_savepoint, 'm_i8', i8f)
               call fs_add_savepoint_metainfo(ppser_savepoint, 'm_r4', r4f)
               ! real32 read-perturb: scale 0 is the identity, a non-zero
               ! scale keeps each element within +/- scale and shifts it.
               call fs_read_field(ppser_serializer, ppser_savepoint, 'r4f', &
                                  r4p, 0.0_real64)
               if (any(r4p /= r4f)) error stop &
                  'type-matrix: real32 perturb scale 0 should be identity'
               call fs_read_field(ppser_serializer, ppser_savepoint, 'r4f', &
                                  r4p, 0.1_real64)
               do i = 1, 3
                  if (r4p(i) < r4f(i)*0.9_real32 .or. r4p(i) > r4f(i)*1.1_real32) &
                     error stop 'type-matrix: real32 perturb out of bounds'
               end do
               ! 0-D real32 read-perturb exercises the scalar apply_perturb
               ! (PRESERF_RANK == 0) branch: scale 0 is the identity, a
               ! non-zero scale stays within +/- scale.
               call fs_read_field(ppser_serializer, ppser_savepoint, 'rsc', &
                                  rscb, 0.0_real64)
               if (rscb /= rsc) error stop &
                  'type-matrix: 0-D real32 perturb scale 0 should be identity'
               call fs_read_field(ppser_serializer, ppser_savepoint, 'rsc', &
                                  rscb, 0.1_real64)
               if (rscb < rsc*0.9_real32 .or. rscb > rsc*1.1_real32) error stop &
                  'type-matrix: 0-D real32 perturb out of bounds'
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: type-matrix OK'
               stop
            end block
         else if (scenario == 'wire-matrix') then
            ! Slice B Phase 3: write one field of every (dtype, rank)
            ! combination plus a 1D-array metainfo of each scalar type,
            ! so the Python cross-language test can assert the on-disk
            ! netCDF type for the whole matrix against storage_mapping §1.
            !
            ! Extents are DISTINCT per axis (rank-r uses (2,3,4,5)[:r]) so
            ! the Python shape/dims assertions actually constrain axis
            ! order (a C-order/Fortran-order transpose regression would
            ! change the shape). Numeric fields are filled with a
            ! column-major ramp 1..N via reshape; preserf reverses axes on
            ! disk, so the Python side reads the array back in C-order
            ! (arr.ravel(order='C') == arange) to reproduce that ramp,
            ! catching an element-order scramble that a uniform fill could
            ! not. Logical fields stay all-.true. (their encode is covered
            ! by the native type-matrix scenario and the a_lg metainfo).
            block
               logical :: l0, l1(2), l2(2, 3), l3(2, 3, 4), l4(2, 3, 4, 5)
               integer(int32) :: i40, i41(2), i42(2, 3), i43(2, 3, 4), i44(2, 3, 4, 5)
               integer(int64) :: i80, i81(2), i82(2, 3), i83(2, 3, 4), i84(2, 3, 4, 5)
               real(real32) :: r40, r41(2), r42(2, 3), r43(2, 3, 4), r44(2, 3, 4, 5)
               real(real64) :: r80, r81(2), r82(2, 3), r83(2, 3, 4), r84(2, 3, 4, 5)
               integer :: ii
               l0 = .true.; l1 = .true.; l2 = .true.; l3 = .true.; l4 = .true.
               i40 = 1_int32
               i41 = reshape([(int(ii, int32), ii=1, size(i41))], shape(i41))
               i42 = reshape([(int(ii, int32), ii=1, size(i42))], shape(i42))
               i43 = reshape([(int(ii, int32), ii=1, size(i43))], shape(i43))
               i44 = reshape([(int(ii, int32), ii=1, size(i44))], shape(i44))
               i80 = 1_int64
               i81 = reshape([(int(ii, int64), ii=1, size(i81))], shape(i81))
               i82 = reshape([(int(ii, int64), ii=1, size(i82))], shape(i82))
               i83 = reshape([(int(ii, int64), ii=1, size(i83))], shape(i83))
               i84 = reshape([(int(ii, int64), ii=1, size(i84))], shape(i84))
               r40 = 1.0_real32
               r41 = reshape([(real(ii, real32), ii=1, size(r41))], shape(r41))
               r42 = reshape([(real(ii, real32), ii=1, size(r42))], shape(r42))
               r43 = reshape([(real(ii, real32), ii=1, size(r43))], shape(r43))
               r44 = reshape([(real(ii, real32), ii=1, size(r44))], shape(r44))
               r80 = 1.0_real64
               r81 = reshape([(real(ii, real64), ii=1, size(r81))], shape(r81))
               r82 = reshape([(real(ii, real64), ii=1, size(r82))], shape(r82))
               r83 = reshape([(real(ii, real64), ii=1, size(r83))], shape(r83))
               r84 = reshape([(real(ii, real64), ii=1, size(r84))], shape(r84))

               call ppser_initialize(out_dir, 'fmatrix', 'w')
               ! Register + write every (dtype, rank). Names are
               ! "<tag><rank>" so the Python test can build them; sizes use
               ! the distinct (2,3,4,5) prefix per rank.
               call reg_matrix_field('l0', 'bool', 1, 0, 0, 0, 0)
               call reg_matrix_field('l1', 'bool', 1, 2, 0, 0, 0)
               call reg_matrix_field('l2', 'bool', 1, 2, 3, 0, 0)
               call reg_matrix_field('l3', 'bool', 1, 2, 3, 4, 0)
               call reg_matrix_field('l4', 'bool', 1, 2, 3, 4, 5)
               call reg_matrix_field('i40', 'int', 4, 0, 0, 0, 0)
               call reg_matrix_field('i41', 'int', 4, 2, 0, 0, 0)
               call reg_matrix_field('i42', 'int', 4, 2, 3, 0, 0)
               call reg_matrix_field('i43', 'int', 4, 2, 3, 4, 0)
               call reg_matrix_field('i44', 'int', 4, 2, 3, 4, 5)
               call reg_matrix_field('i80', 'int64', 8, 0, 0, 0, 0)
               call reg_matrix_field('i81', 'int64', 8, 2, 0, 0, 0)
               call reg_matrix_field('i82', 'int64', 8, 2, 3, 0, 0)
               call reg_matrix_field('i83', 'int64', 8, 2, 3, 4, 0)
               call reg_matrix_field('i84', 'int64', 8, 2, 3, 4, 5)
               call reg_matrix_field('r40', 'float', 4, 0, 0, 0, 0)
               call reg_matrix_field('r41', 'float', 4, 2, 0, 0, 0)
               call reg_matrix_field('r42', 'float', 4, 2, 3, 0, 0)
               call reg_matrix_field('r43', 'float', 4, 2, 3, 4, 0)
               call reg_matrix_field('r44', 'float', 4, 2, 3, 4, 5)
               call reg_matrix_field('r80', 'double', 8, 0, 0, 0, 0)
               call reg_matrix_field('r81', 'double', 8, 2, 0, 0, 0)
               call reg_matrix_field('r82', 'double', 8, 2, 3, 0, 0)
               call reg_matrix_field('r83', 'double', 8, 2, 3, 4, 0)
               call reg_matrix_field('r84', 'double', 8, 2, 3, 4, 5)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'l0', l0)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'l1', l1)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'l2', l2)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'l3', l3)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'l4', l4)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i40', i40)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i41', i41)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i42', i42)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i43', i43)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i44', i44)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i80', i80)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i81', i81)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i82', i82)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i83', i83)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'i84', i84)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r40', r40)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r41', r41)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r42', r42)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r43', r43)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r44', r44)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r80', r80)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r81', r81)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r82', r82)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r83', r83)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'r84', r84)
               ! 1D-array metainfo of each scalar type on the root group.
               call fs_add_serializer_metainfo(ppser_serializer, 'a_lg', &
                                               [.true., .false.])
               call fs_add_serializer_metainfo(ppser_serializer, 'a_i4', &
                                               [10_int32, 20_int32, 30_int32])
               call fs_add_serializer_metainfo(ppser_serializer, 'a_i8', &
                                               [100_int64, 200_int64])
               call fs_add_serializer_metainfo(ppser_serializer, 'a_r4', &
                                               [1.5_real32, 2.5_real32])
               call fs_add_serializer_metainfo(ppser_serializer, 'a_r8', &
                                               [3.5_real64, 4.5_real64])
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: wire-matrix OK'
               stop
            end block
         else if (scenario == 'tracers') then
            ! Slice C Phase 1: tracers. Register three real64 tracers of
            ! rank 1/2/3 in the built-in registry, write their /_tracers
            ! descriptors via fs_RegisterAllTracers, then exercise all four
            ! TRACER write entry points across distinct savepoints:
            !   sp_000000  by_name('q_v', timelevel=2)  -> {q_v}
            !   sp_000001  by_idx(2)                     -> {q_c}
            !   sp_000002  by_idx(1, 3)                  -> {q_v,q_c,q_r}
            !   sp_000003  all()                         -> {q_v,q_c,q_r}
            !   sp_000004  all(stype='tens')             -> {q_v}
            ! The Python wire-compat test reads back the descriptors,
            ! data, and the optional timelevel attribute.
            block
               ! TARGET: ppser_register_tracer keeps a pointer to these
               ! arrays so a read-mode TRACER can read back into them.
               real(real64), target :: qv(3), qc(2, 3), qr(2, 2, 2)
               integer :: i, j, k
               do i = 1, 3
                  qv(i) = real(10 + i, real64)
               end do
               do j = 1, 3
                  do i = 1, 2
                     qc(i, j) = real(100*i + j, real64)
                  end do
               end do
               do k = 1, 2
                  do j = 1, 2
                     do i = 1, 2
                        qr(i, j, k) = real(100*i + 10*j + k, real64)
                     end do
                  end do
               end do

               call ppser_initialize(out_dir, 'ftracers', 'w')
               ! Registration order fixes tracer_index: q_v=1, q_c=2, q_r=3.
               call ppser_register_tracer('q_v', qv, stype='tens')
               call ppser_register_tracer('q_c', qc, stype='bd')
               call ppser_register_tracer('q_r', qr)
               call fs_RegisterAllTracers()

               call fs_create_savepoint('sp_byname', ppser_savepoint)
               call ppser_write_tracer_by_name('q_v', stype='tens', timelevel=2)

               call fs_create_savepoint('sp_byidx', ppser_savepoint)
               call ppser_write_tracer_by_idx(2, stype='bd')

               call fs_create_savepoint('sp_byrange', ppser_savepoint)
               call ppser_write_tracer_by_idx(1, 3, stype='')

               call fs_create_savepoint('sp_all', ppser_savepoint)
               call ppser_write_tracer_all(stype='')

               call fs_create_savepoint('sp_tens', ppser_savepoint)
               call ppser_write_tracer_all(stype='tens')

               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: tracers OK'
               stop
            end block
         else if (scenario == 'tracers-roundtrip') then
            ! Slice C read-mode round-trip: write a tracer store, finalize,
            ! re-open read-only, re-register the same tracers (bound to
            ! freshly zeroed TARGET arrays), validate the descriptors via
            ! fs_RegisterAllTracers, then read every tracer back with
            ! ppser_write_tracer_all and assert the values match the
            ! originals — proving symmetric Fortran read-back through the
            ! registry pointers (no def_var on the read-only handle).
            block
               real(real64), target :: qv(3), qc(2, 3)
               real(real64) :: qv0(3), qc0(2, 3)
               integer :: i, j
               do i = 1, 3
                  qv(i) = real(10 + i, real64)
               end do
               do j = 1, 3
                  do i = 1, 2
                     qc(i, j) = real(100*i + j, real64)
                  end do
               end do
               qv0 = qv
               qc0 = qc
               call ppser_initialize(out_dir, 'ftrt', 'w')
               call ppser_register_tracer('q_v', qv, stype='tens')
               call ppser_register_tracer('q_c', qc, stype='bd')
               call fs_RegisterAllTracers()
               call fs_create_savepoint('step', ppser_savepoint)
               call ppser_write_tracer_all(stype='')
               call ppser_finalize()
               ! Re-open read-only. ppser_finalize cleared the registry, so
               ! re-register the same tracers bound to zeroed arrays.
               qv = 0.0_real64
               qc = 0.0_real64
               call ppser_initialize(out_dir, 'ftrt', 'r')
               if (ppser_get_mode() /= 1) error stop &
                  'tracers-roundtrip: read open should set mode 1'
               call ppser_register_tracer('q_v', qv, stype='tens')
               call ppser_register_tracer('q_c', qc, stype='bd')
               call fs_RegisterAllTracers()
               call fs_create_savepoint('step', ppser_savepoint)
               call ppser_write_tracer_all(stype='')
               if (any(qv /= qv0)) error stop &
                  'tracers-roundtrip: q_v did not read back to its written value'
               if (any(qc /= qc0)) error stop &
                  'tracers-roundtrip: q_c did not read back to its written value'
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: tracers-roundtrip OK'
               stop
            end block
         else if (scenario == 'kbuff') then
            ! Slice C Phase 2: DATA_KBUFF. Write two fields one vertical
            ! level at a time through fs_write_kbuff — a 3-D field t(i,j,k)
            ! from 2-D (i,j) slices and a 2-D field c(i,k) from 1-D (i)
            ! slices. The helper buffers each slice and flushes the full
            ! field on the last level (k == k_size); the on-disk variable
            ! is byte-identical to a !$SER DATA write. The Python
            ! wire-compat test asserts the assembled fields.
            block
               integer, parameter :: ni = 3, nj = 2, ke = 4
               real(real64) :: tslice(ni, nj), cslice(ni)
               integer :: i, j, kk
               call ppser_initialize(out_dir, 'fkbuff', 'w')
               call fs_register_field(ppser_serializer, 't', 'double', &
                                      ppser_reallength, ni, nj, ke, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_register_field(ppser_serializer, 'c', 'double', &
                                      ppser_reallength, ni, ke, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               ! Emit each level in a k-loop, as pp_ser-generated code does.
               do kk = 1, ke
                  do j = 1, nj
                     do i = 1, ni
                        tslice(i, j) = real(100*i + 10*j + kk, real64)
                     end do
                  end do
                  call fs_write_kbuff(ppser_serializer, ppser_savepoint, 't', &
                                      tslice, k=kk, k_size=ke, &
                                      mode=ppser_get_mode())
                  do i = 1, ni
                     cslice(i) = real(10*i + kk, real64)
                  end do
                  call fs_write_kbuff(ppser_serializer, ppser_savepoint, 'c', &
                                      cslice, k=kk, k_size=ke, &
                                      mode=ppser_get_mode())
               end do
               call ppser_finalize()

               ! Read-back phase: re-open read-only and recover each level
               ! through fs_write_kbuff (mode=read), proving symmetric
               ! k-buffer read-back into the per-level slices.
               call ppser_initialize(out_dir, 'fkbuff', 'r')
               if (ppser_get_mode() /= 1) error stop &
                  'kbuff: read open should set mode 1'
               call fs_create_savepoint('step', ppser_savepoint)
               do kk = 1, ke
                  tslice = 0.0_real64
                  call fs_write_kbuff(ppser_serializer, ppser_savepoint, 't', &
                                      tslice, k=kk, k_size=ke, &
                                      mode=ppser_get_mode())
                  do j = 1, nj
                     do i = 1, ni
                        if (tslice(i, j) /= real(100*i + 10*j + kk, real64)) &
                           error stop 'kbuff: t read-back mismatch'
                     end do
                  end do
                  cslice = 0.0_real64
                  call fs_write_kbuff(ppser_serializer, ppser_savepoint, 'c', &
                                      cslice, k=kk, k_size=ke, &
                                      mode=ppser_get_mode())
                  do i = 1, ni
                     if (cslice(i) /= real(10*i + kk, real64)) &
                        error stop 'kbuff: c read-back mismatch'
                  end do
               end do
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: kbuff OK'
               stop
            end block
         else if (scenario == 'option') then
            ! Slice C Phase 3: OPTION. fs_Option(verbosity=N) sets the
            ! module verbosity knob and records the reserved
            ! _preserf_option_verbosity root attribute on the writable
            ! store. The Python wire-compat test reads the value back.
            block
               real(real64) :: uo(3)
               integer :: i
               do i = 1, 3
                  uo(i) = real(i, real64)
               end do
               call ppser_initialize(out_dir, 'foption', 'w')
               if (ppser_verbosity /= 0) error stop &
                  'option: verbosity should default to 0 on fresh init'
               call fs_Option(verbosity=2)
               if (ppser_verbosity /= 2) error stop &
                  'option: fs_Option(verbosity=2) did not update ppser_verbosity'
               ! A minimal field write so the store is a complete sample.
               call fs_register_field(ppser_serializer, 'u', 'double', &
                                      ppser_reallength, 3, 0, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_write_field(ppser_serializer, ppser_savepoint, 'u', uo)
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: option OK'
               stop
            end block
         else if (scenario == 'tracer-tl-overwrite') then
            ! "Last write wins": write q_v twice at one savepoint, first
            ! with timelevel=2 then without. The final variable must carry
            ! no timelevel attribute. The Python wire-compat test asserts
            ! the attribute is absent.
            block
               real(real64), target :: q(3)
               integer :: i
               do i = 1, 3
                  q(i) = real(i, real64)
               end do
               call ppser_initialize(out_dir, 'ftltl', 'w')
               call ppser_register_tracer('q_v', q, stype='tens')
               call fs_RegisterAllTracers()
               call fs_create_savepoint('step', ppser_savepoint)
               call ppser_write_tracer_by_name('q_v', stype='tens', timelevel=2)
               call ppser_write_tracer_by_name('q_v', stype='tens')
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: tracer-tl-overwrite OK'
               stop
            end block
         else if (scenario == 'tracers-multi-session') then
            ! Regression: tracers_grpid must be cleared on close so a
            ! second write-mode session lazily re-creates /_tracers in the
            ! new file instead of reusing a stale group id from the first
            ! (closed) file. Without the reset the second
            ! fs_RegisterAllTracers writes a descriptor against the stale
            ! grpid and aborts; reaching OK proves the reset works.
            block
               real(real64), target :: q(3)
               integer :: i
               do i = 1, 3
                  q(i) = real(i, real64)
               end do
               call ppser_initialize(out_dir, 'fms_a', 'w')
               call ppser_register_tracer('q_v', q, stype='tens')
               call fs_RegisterAllTracers()
               call fs_create_savepoint('step', ppser_savepoint)
               call ppser_write_tracer_all(stype='')
               call ppser_finalize()
               call ppser_initialize(out_dir, 'fms_b', 'w')
               call ppser_register_tracer('q_v', q, stype='tens')
               call fs_RegisterAllTracers()
               call fs_create_savepoint('step', ppser_savepoint)
               call ppser_write_tracer_all(stype='')
               call ppser_finalize()
               write (*, '(a)') 'preserf-fortran: tracers-multi-session OK'
               stop
            end block
         else if (scenario == 'tracers-bad-dup') then
            ! Registering the same tracer name twice must abort.
            block
               real(real64), target :: q(3)
               q = 1.0_real64
               call ppser_initialize(out_dir, 'ftbd', 'w')
               call ppser_register_tracer('q_v', q, stype='tens')
               call ppser_register_tracer('q_v', q, stype='tens')
               call abort_unexpected('tracers-bad-dup')
            end block
         else if (scenario == 'tracers-bad-namelen') then
            ! A tracer name longer than the fixed-length registry component
            ! must abort rather than silently truncate.
            block
               real(real64), target :: q(3)
               q = 1.0_real64
               call ppser_initialize(out_dir, 'ftbl', 'w')
               call ppser_register_tracer( &
                  'this_tracer_name_is_deliberately_far_longer_than_'// &
                  'sixty_four_characters_for_the_test', q)
               call abort_unexpected('tracers-bad-namelen')
            end block
         else if (scenario == 'tracers-bad-name') then
            ! Writing a tracer that was never registered must abort.
            block
               real(real64), target :: q(3)
               q = 1.0_real64
               call ppser_initialize(out_dir, 'ftbn', 'w')
               call ppser_register_tracer('q_v', q, stype='tens')
               call fs_create_savepoint('step', ppser_savepoint)
               call ppser_write_tracer_by_name('nope')
               call abort_unexpected('tracers-bad-name')
            end block
         else if (scenario == 'tracers-bad-idx') then
            ! An out-of-range tracer index must abort.
            block
               real(real64), target :: q(3)
               q = 1.0_real64
               call ppser_initialize(out_dir, 'ftbi', 'w')
               call ppser_register_tracer('q_v', q, stype='tens')
               call fs_create_savepoint('step', ppser_savepoint)
               call ppser_write_tracer_by_idx(5)
               call abort_unexpected('tracers-bad-idx')
            end block
         else if (scenario == 'tracers-bad-reorder') then
            ! Read-mode registration order must match the write order: a
            ! tracer registered at a different position than its stored
            ! tracer_index must abort (else by_idx resolves the wrong one).
            block
               real(real64), target :: q1(3), q2(3)
               q1 = 1.0_real64
               q2 = 2.0_real64
               call ppser_initialize(out_dir, 'ftbo', 'w')
               call ppser_register_tracer('q_v', q1, stype='tens')
               call ppser_register_tracer('q_c', q2, stype='bd')
               call fs_RegisterAllTracers()
               call fs_create_savepoint('step', ppser_savepoint)
               call ppser_write_tracer_all(stype='')
               call ppser_finalize()
               ! Re-open read-only and register in the REVERSE order.
               call ppser_initialize(out_dir, 'ftbo', 'r')
               call ppser_register_tracer('q_c', q2, stype='bd')
               call ppser_register_tracer('q_v', q1, stype='tens')
               call fs_RegisterAllTracers()
               call abort_unexpected('tracers-bad-reorder')
            end block
         else if (scenario == 'tracers-bad-range') then
            ! A descending tracer index range (idx2 < idx) must abort rather
            ! than silently write nothing.
            block
               real(real64), target :: q1(3), q2(3)
               q1 = 1.0_real64
               q2 = 2.0_real64
               call ppser_initialize(out_dir, 'ftbr', 'w')
               call ppser_register_tracer('q_v', q1, stype='tens')
               call ppser_register_tracer('q_c', q2, stype='bd')
               call fs_create_savepoint('step', ppser_savepoint)
               call ppser_write_tracer_by_idx(2, 1)
               call abort_unexpected('tracers-bad-range')
            end block
         else if (scenario == 'kbuff-bad-namelen') then
            ! A k-buffer field name longer than the fixed-length table
            ! component must abort rather than silently truncate.
            block
               real(real64) :: s(3)
               s = 1.0_real64
               call ppser_initialize(out_dir, 'fkbl', 'w')
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_write_kbuff(ppser_serializer, ppser_savepoint, &
                                   'this_kbuff_field_name_is_deliberately_'// &
                                   'far_longer_than_sixty_four_characters', s, &
                                   k=1, k_size=2, mode=ppser_get_mode())
               call abort_unexpected('kbuff-bad-namelen')
            end block
         else if (scenario == 'kbuff-bad-order') then
            ! Levels must be written once each in order 1..k_size. Skipping
            ! level 2 (writing k=1 then k=3) must abort rather than flush a
            ! buffer with a stale/zeroed slice.
            block
               real(real64) :: s(2)
               s = 1.0_real64
               call ppser_initialize(out_dir, 'fkbo', 'w')
               call fs_register_field(ppser_serializer, 'f', 'double', &
                                      ppser_reallength, 2, 3, 0, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_write_kbuff(ppser_serializer, ppser_savepoint, 'f', s, &
                                   k=1, k_size=3, mode=ppser_get_mode())
               call fs_write_kbuff(ppser_serializer, ppser_savepoint, 'f', s, &
                                   k=3, k_size=3, mode=ppser_get_mode())
               call abort_unexpected('kbuff-bad-order')
            end block
         else if (scenario == 'kbuff-bad-shape') then
            ! Two fs_write_kbuff calls for the same field with different
            ! slice shapes — same total size (8) but transposed dims
            ! [2,4] vs [4,2] — must abort (regression for the per-dim
            ! shape check, which a size-only check would miss).
            block
               real(real64) :: s1(2, 4), s2(4, 2)
               s1 = 1.0_real64
               s2 = 2.0_real64
               call ppser_initialize(out_dir, 'fkbs', 'w')
               call fs_register_field(ppser_serializer, 'f', 'double', &
                                      ppser_reallength, 2, 4, 3, 0, &
                                      0, 0, 0, 0, 0, 0, 0, 0)
               call fs_create_savepoint('step', ppser_savepoint)
               call fs_write_kbuff(ppser_serializer, ppser_savepoint, 'f', s1, &
                                   k=1, k_size=3, mode=ppser_get_mode())
               call fs_write_kbuff(ppser_serializer, ppser_savepoint, 'f', s2, &
                                   k=2, k_size=3, mode=ppser_get_mode())
               call abort_unexpected('kbuff-bad-shape')
            end block
         else
            write (*, '(a,a)') &
               'preserf-test_minimal: unknown scenario argument: ', &
               scenario
            error stop 1
         end if
      end block
   end if

   allocate (u(ni, nj, nk), u_back(ni, nj, nk))
   do k = 1, nk
      do j = 1, nj
         do i = 1, ni
            ! Distinct, easy-to-decode value at each cell so the Python
            ! cross-check can verify the axis-order mapping precisely:
            !   value = 100*i + 10*j + k
            ! e.g. u(2,3,1) = 231, u(4,3,2) = 432.
            u(i, j, k) = real(100*i + 10*j + k, real64)
         end do
      end do
   end do

   ! 1-D field — exercises the fs_write_field_r8_1d /
   ! fs_read_field_r8_1d overload path and the rank-1 dim creation /
   ! reversal logic.
   allocate (v(nv), v_back(nv))
   do i = 1, nv
      v(i) = real(i, real64)
   end do

   ! 2-D field — exercises fs_write_field_r8_2d / fs_read_field_r8_2d.
   ! Same i*10 + j encoding as the 3-D case for axis-order verification.
   allocate (w(nw_i, nw_j), w_back(nw_i, nw_j))
   do j = 1, nw_j
      do i = 1, nw_i
         w(i, j) = real(10*i + j, real64)
      end do
   end do

   ! ---------------- write phase ----------------
   call ppser_initialize(out_dir, 'fhello', 'w')
   ! ppser_initialize sets ppser_mode_state from the open mode
   ! (`'w'` → 0), so pp_ser-generated SELECT CASE (ppser_get_mode())
   ! blocks pick the write branch by default. Verify the contract.
   if (ppser_get_mode() /= 0) error stop &
      'ppser_initialize(..., "w") should default mode to 0'

   call fs_add_serializer_metainfo(ppser_serializer, 'author', 'fortran-test')
   call fs_add_serializer_metainfo(ppser_serializer, 'schema_version', 7_int32)
   ! Exercise the Boolean → NF90_BYTE path so the test confirms the
   ! on-disk attribute type matches storage_mapping.md §1.
   call fs_add_serializer_metainfo(ppser_serializer, 'use_gpu', .true.)
   ! Exercise the Int64 and Float32 metainfo overloads — these kind-
   ! specific nf90_put_att branches are easy to break independently.
   call fs_add_serializer_metainfo(ppser_serializer, &
                                   'wallclock_ns', 1700000000000000000_int64)
   call fs_add_serializer_metainfo(ppser_serializer, &
                                   'tolerance32', 1.0e-3_real32)

   ! Non-zero halos on u exercise the put_halo_attr path; the helper
   ! emits each non-zero halo as a named attribute on the registry
   ! variable. Only the halos for the active rank get written
   ! (storage_mapping.md §4): iminushalo, iplushalo for axis i;
   ! jminushalo, jplushalo for axis j; kminushalo, kplushalo for k.
   call fs_register_field(ppser_serializer, 'u', 'double', ppser_reallength, &
                          ni, nj, nk, 0, &
                          1, 2, 3, 4, 0, 5, 0, 0)
   call fs_register_field(ppser_serializer, 'v', 'double', ppser_reallength, &
                          nv, 0, 0, 0, &
                          0, 0, 0, 0, 0, 0, 0, 0)
   call fs_register_field(ppser_serializer, 'w', 'double', ppser_reallength, &
                          nw_i, nw_j, 0, 0, &
                          0, 0, 0, 0, 0, 0, 0, 0)

   ! Use the two-argument fs_create_savepoint form pp_ser actually
   ! emits — relies on the default-serializer branch updating the
   ! module-level ppser_savepoint via ppser_serializer.
   call fs_create_savepoint('step', ppser_savepoint)
   call fs_add_savepoint_metainfo(ppser_savepoint, 'ntstep', 1_int32)
   call fs_add_savepoint_metainfo(ppser_savepoint, 't', 0.5_real64)
   call fs_write_field(ppser_serializer, ppser_savepoint, 'u', u)
   call fs_write_field(ppser_serializer, ppser_savepoint, 'v', v)
   call fs_write_field(ppser_serializer, ppser_savepoint, 'w', w)

   ! ---------------- ON / OFF gate exercise ----------------
   ! Disable serialization, attempt fs_* operations that would
   ! otherwise mutate the store, then re-enable. The Python pytest
   ! verifies that nothing was written while disabled (no
   ! `disabled_field` in /_fields, no `disabled_meta` attribute on
   ! root).
   if (.not. fs_serialization_status()) error stop &
      'fs_serialization_status() should be .true. by default'
   block
      integer :: grpid_before, idx_before
      grpid_before = ppser_savepoint%grpid
      idx_before = ppser_savepoint%idx
      call fs_disable_serialization()
      if (fs_serialization_status()) error stop &
         'fs_serialization_status() should be .false. after fs_disable_serialization'
      call fs_register_field(ppser_serializer, 'disabled_field', 'double', &
                             ppser_reallength, 1, 0, 0, 0, &
                             0, 0, 0, 0, 0, 0, 0, 0)
      call fs_add_serializer_metainfo(ppser_serializer, 'disabled_meta', 42_int32)
      ! fs_create_savepoint must be a true no-op when disabled: it
      ! MUST NOT clobber the caller's ppser_savepoint to -1.
      call fs_create_savepoint('would_be_step', ppser_savepoint)
      if (ppser_savepoint%grpid /= grpid_before .or. &
          ppser_savepoint%idx /= idx_before) then
         error stop &
            'fs_create_savepoint clobbered savepoint while disabled'
      end if
      ! fs_write_field (the DATA path) must also be a true no-op when
      ! disabled: writing a -999 sentinel into the already-populated
      ! `u` savepoint variable MUST leave the on-disk data untouched.
      ! The Python test asserts the sentinel never reached disk; the
      ! maxdiff round-trip check at the end of this program would also
      ! flag a leak. Without this call, a regression that dropped the
      ! `serialisation_enabled` early return from fs_write_field would
      ! go unnoticed.
      u_back = -999.0_real64
      call fs_write_field(ppser_serializer, ppser_savepoint, 'u', u_back)
      ! fs_read_field (the DATA read path) must likewise be a true
      ! no-op when disabled. Its `data` argument is intent(inout), so
      ! the early return leaves the caller's buffer intact: fill
      ! u_back with a -777 sentinel, attempt a disabled read, and
      ! confirm nothing was overwritten. A regression dropping the
      ! `serialisation_enabled` early return from the read overloads
      ! would clobber the sentinel here.
      u_back = -777.0_real64
      call fs_read_field(ppser_serializer, ppser_savepoint, 'u', u_back)
      if (any(u_back /= -777.0_real64)) error stop &
         'fs_read_field was not a no-op while serialization was disabled'
      call fs_enable_serialization()
      if (.not. fs_serialization_status()) error stop &
         'fs_serialization_status() should be .true. after fs_enable_serialization'
   end block

   call ppser_finalize()

   ! ---------------- read phase ----------------
   ! Disable the gate AFTER ppser_finalize. ppser_finalize itself
   ! resets `serialisation_enabled` to 1, so disabling *before* it
   ! would leave the flag already enabled going into the init below
   ! and prove nothing about ppser_initialize. Disabling here —
   ! between finalize and the fresh init — means the flag is 0 on
   ! entry to ppser_initialize, so the assertion isolates
   ! ppser_initialize's own reset path: without that reset the stale
   ! disabled SAVE state would silently no-op every fs_* call in the
   ! read phase.
   call fs_disable_serialization()
   call ppser_initialize(out_dir, 'fhello', 'r')
   if (.not. fs_serialization_status()) error stop &
      'ppser_initialize should reset serialisation_enabled on a fresh session'
   ! And `'r'` → 1, so pp_ser DATA blocks pick the read branch
   ! without an explicit ppser_set_mode call.
   if (ppser_get_mode() /= 1) error stop &
      'ppser_initialize(..., "r") should default mode to 1'
   ! pp_ser-generated read DATA branches call
   ! `fs_read_field(ppser_serializer_ref, ppser_savepoint, ...)`,
   ! so read through `ppser_serializer_ref` here to exercise the
   ! ref-serializer setup in ppser_initialize(..., 'r'). The
   ! savepoint group must be resolved under the ref serializer's
   ! own ncid (HDF5 returns distinct grpids per open even for the
   ! same on-disk file).
   if (ppser_serializer_ref%ncid == -1) error stop &
      'ppser_initialize(..., "r") should also open ppser_serializer_ref'
   block
      use netcdf
      integer :: ncerr, sps_grpid, sp_grpid
      ncerr = nf90_inq_ncid(ppser_serializer_ref%ncid, &
                            'savepoints', sps_grpid)
      if (ncerr /= 0) error stop 'inq_ncid savepoints (ref) failed'
      ncerr = nf90_inq_ncid(sps_grpid, 'sp_000000', sp_grpid)
      if (ncerr /= 0) error stop 'inq_ncid sp_000000 (ref) failed'
      ppser_savepoint%grpid = sp_grpid
      ppser_savepoint%idx = 0
   end block
   call fs_read_field(ppser_serializer_ref, ppser_savepoint, 'u', u_back)
   call fs_read_field(ppser_serializer_ref, ppser_savepoint, 'v', v_back)
   call fs_read_field(ppser_serializer_ref, ppser_savepoint, 'w', w_back)

   ! Compile-only resolution check for the 5-argument fs_read_field
   ! perturb form (pp_ser-generated CASE(2) branches). Wrapped in
   ! `if (.false.)` so the runtime never reaches
   ! `read_perturb_not_implemented`; the call existing in source is
   ! enough to verify the generic interface continues to resolve the
   ! 5-argument signature.
   if (.false.) then
      call fs_read_field(ppser_serializer_ref, ppser_savepoint, 'u', &
                         u_back, 1.0e-3_real64)
      call fs_read_field(ppser_serializer_ref, ppser_savepoint, 'v', &
                         v_back, 1.0e-3_real64)
      call fs_read_field(ppser_serializer_ref, ppser_savepoint, 'w', &
                         w_back, 1.0e-3_real64)
   end if

   call ppser_finalize()

   ! ---------------- explicit-reference read ----------------
   ! Re-open read-only, this time passing an *explicit* directory_ref
   ! / prefix_ref pair (here pointing back at the same store). This
   ! exercises the branch in ppser_initialize that opens the reference
   ! serializer from explicit arguments rather than implicitly from
   ! the main directory/prefix. pp_ser-generated read DATA branches
   ! call fs_read_field(ppser_serializer_ref, ...), so the explicitly
   ! opened reference serializer must resolve the savepoint and field
   ! exactly like the implicit-reference case above.
   block
      use netcdf
      integer :: ncerr, sps_grpid, sp_grpid
      real(real64), allocatable :: u_ref(:, :, :)
      allocate (u_ref(ni, nj, nk))
      call ppser_initialize(out_dir, 'fhello', 'r', &
                            directory_ref=out_dir, prefix_ref='fhello')
      if (ppser_serializer_ref%ncid == -1) error stop &
         'explicit directory_ref/prefix_ref should open ppser_serializer_ref'
      ncerr = nf90_inq_ncid(ppser_serializer_ref%ncid, &
                            'savepoints', sps_grpid)
      if (ncerr /= 0) error stop 'inq_ncid savepoints (explicit ref) failed'
      ncerr = nf90_inq_ncid(sps_grpid, 'sp_000000', sp_grpid)
      if (ncerr /= 0) error stop 'inq_ncid sp_000000 (explicit ref) failed'
      ppser_savepoint%grpid = sp_grpid
      ppser_savepoint%idx = 0
      call fs_read_field(ppser_serializer_ref, ppser_savepoint, 'u', u_ref)
      if (maxval(abs(u - u_ref)) /= 0.0_real64) error stop &
         'explicit-reference read returned wrong data for u'
      call ppser_finalize()
   end block

   maxdiff = max( &
             maxval(abs(u - u_back)), &
             maxval(abs(v - v_back)), &
             maxval(abs(w - w_back)))
   if (maxdiff /= 0.0_real64) then
      write (*, '(a,es14.6)') 'preserf-fortran: round-trip mismatch, maxdiff=', &
         maxdiff
      error stop 1
   end if

   write (*, '(a)') 'preserf-fortran: hello-world OK'

contains

   !> Delete a file if it exists. The init-keywords scenario uses this
   !> to clear stores left behind by a prior run before asserting on
   !> store names, since the ctest output dir is reused, not cleaned.
   subroutine delete_if_exists(path)
      character(len=*), intent(in) :: path
      logical :: exists
      integer :: unit, ios
      inquire (file=path, exist=exists)
      if (.not. exists) return
      open (newunit=unit, file=path, status='old', iostat=ios)
      if (ios == 0) close (unit, status='delete')
   end subroutine delete_if_exists

   !> Register a field of the given datatype and (i,j,k,l) sizes with all
   !> halos zero, against the module-level ppser_serializer. Keeps the
   !> wire-matrix scenario's 25 registrations terse.
   subroutine reg_matrix_field(name, dtype, bytes, isz, jsz, ksz, lsz)
      character(len=*), intent(in) :: name, dtype
      integer, intent(in) :: bytes, isz, jsz, ksz, lsz
      call fs_register_field(ppser_serializer, name, dtype, bytes, &
                             isz, jsz, ksz, lsz, 0, 0, 0, 0, 0, 0, 0, 0)
   end subroutine reg_matrix_field

   !> Write a small two-savepoint store used by the read-mode scenarios.
   !> Field `u` (1-D, size 3, iMinusHalo=1 / iPlusHalo=2) is written into
   !> savepoint 'step' (values base+1..3) and savepoint 'step2'
   !> (values base+4..6), each with a savepoint metainfo pair. The
   !> distinct `base` lets the read-ref scenario tell the primary and
   !> reference stores apart.
   subroutine write_store(out_dir, prefix, base)
      character(len=*), intent(in) :: out_dir, prefix
      real(real64), intent(in) :: base
      real(real64) :: u1(3), u2(3)
      integer :: i
      do i = 1, 3
         u1(i) = base + real(i, real64)
         u2(i) = base + real(i + 3, real64)
      end do
      call ppser_initialize(out_dir, prefix, 'w')
      call fs_add_serializer_metainfo(ppser_serializer, 'author', 'fortran-test')
      call fs_register_field(ppser_serializer, 'u', 'double', ppser_reallength, &
                             3, 0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0)
      call fs_create_savepoint('step', ppser_savepoint)
      call fs_add_savepoint_metainfo(ppser_savepoint, 'ntstep', 1_int32)
      call fs_add_savepoint_metainfo(ppser_savepoint, 't', 0.5_real64)
      call fs_write_field(ppser_serializer, ppser_savepoint, 'u', u1)
      call fs_create_savepoint('step2', ppser_savepoint)
      call fs_add_savepoint_metainfo(ppser_savepoint, 'ntstep', 2_int32)
      call fs_write_field(ppser_serializer, ppser_savepoint, 'u', u2)
      call ppser_finalize()
   end subroutine write_store

   !> Build, with raw netCDF calls, a schema-valid store whose `/_fields/u`
   !> registry records type_id FLOAT64 and dims [3] but whose
   !> savepoints/sp_000000/u variable is NF90_FLOAT. This is the one
   !> registry/variable inconsistency that validate_field_shape (which
   !> only checks the registry) cannot catch, so it isolates the
   !> read-side require_variable_xtype rejection.
   subroutine build_xtype_mismatch_store(path)
      use netcdf
      character(len=*), intent(in) :: path
      integer :: ncid, fgid, vid, spsid, spid, dimid, uvid
      integer(int32) :: schema, tid_f64, idx0, dimsvec(1)
      real(real32) :: vals(3)

      schema = 1_int32        ! PRESERF_SCHEMA_VERSION
      tid_f64 = 5_int32       ! TID_FLOAT64
      idx0 = 0_int32
      dimsvec = [3_int32]
      vals = [1.0_real32, 2.0_real32, 3.0_real32]

      call nc_must(nf90_create(path, NF90_NETCDF4, ncid), 'nf90_create')
      call nc_must(nf90_put_att(ncid, NF90_GLOBAL, '_preserf_schema_version', &
                                schema), 'put_att _preserf_schema_version')
      ! Registry carrier variable with type_id + dims attributes.
      call nc_must(nf90_def_grp(ncid, '_fields', fgid), 'def_grp _fields')
      call nc_must(nf90_def_var(fgid, 'u', NF90_INT, vid), 'def_var /_fields/u')
      call nc_must(nf90_put_att(fgid, vid, 'type_id', tid_f64), 'put_att type_id')
      call nc_must(nf90_put_att(fgid, vid, 'dims', dimsvec), 'put_att dims')
      ! Savepoint group with a FLOAT32 data variable (the inconsistency).
      call nc_must(nf90_def_grp(ncid, 'savepoints', spsid), 'def_grp savepoints')
      call nc_must(nf90_def_grp(spsid, 'sp_000000', spid), 'def_grp sp_000000')
      call nc_must(nf90_put_att(spid, NF90_GLOBAL, '_preserf_savepoint_index', &
                                idx0), 'put_att _preserf_savepoint_index')
      call nc_must(nf90_put_att(spid, NF90_GLOBAL, 'name', 'step'), 'put_att name')
      call nc_must(nf90_def_dim(spid, 'u_dim0', 3, dimid), 'def_dim u_dim0')
      call nc_must(nf90_def_var(spid, 'u', NF90_FLOAT, [dimid], uvid), &
                   'def_var sp_000000/u (float32)')
      ! NETCDF4/HDF5 lets data and define operations interleave, so the
      ! put_var below would succeed without this — but commit the
      ! definitions explicitly so the test does not depend on that
      ! behaviour (PR #22 review note).
      call nc_must(nf90_enddef(ncid), 'enddef')
      call nc_must(nf90_put_var(spid, uvid, vals), 'put_var sp_000000/u')
      call nc_must(nf90_close(ncid), 'nf90_close')
   end subroutine build_xtype_mismatch_store

   !> Abort the test build if a raw netCDF call in
   !> build_xtype_mismatch_store failed. Unchecked errors there could
   !> leave a malformed store that makes the read-bad-xtype negative
   !> test pass for the wrong reason (PR #22 review note).
   subroutine nc_must(ncerr, what)
      use netcdf, only: nf90_noerr, nf90_strerror
      integer, intent(in) :: ncerr
      character(len=*), intent(in) :: what
      if (ncerr /= nf90_noerr) then
         write (*, '(a,a,a,a)') 'build_xtype_mismatch_store: ', trim(what), &
            ' failed: ', trim(nf90_strerror(ncerr))
         error stop 1
      end if
   end subroutine nc_must

   !> Print a non-matching marker and exit 0 when a read-mode validation
   !> directive was expected to abort but returned instead. The negative
   !> ctest scenarios use PASS_REGULAR_EXPRESSION on the specific abort
   !> message, so a clean exit with this (non-matching) line fails the
   !> test — exactly what we want if validation silently accepts.
   subroutine abort_unexpected(name)
      character(len=*), intent(in) :: name
      write (*, '(a,a,a)') 'preserf-test_minimal: scenario ', trim(name), &
         ' did not abort as expected'
      stop
   end subroutine abort_unexpected

end program test_minimal
