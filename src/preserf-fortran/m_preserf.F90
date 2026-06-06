!> preserf Fortran helper: serialisation operations.
!>
!> This module exposes the `fs_*` API that `pp_ser`-expanded directives
!> emit. The on-disk layout is the group-per-savepoint schema documented
!> in `docs/references/storage_mapping.md`.
!>
!> v0.1 covers the directives needed for a hello-world flow:
!>   * `fs_register_field` — REGISTER directive
!>   * `fs_create_savepoint` — SAVEPOINT directive (without metainfo args)
!>   * `fs_add_savepoint_metainfo` — SAVEPOINT key=value pairs (scalars)
!>   * `fs_add_serializer_metainfo` — METAINFO directive (scalars)
!>   * `fs_write_field` / `fs_read_field` — DATA directive
!>                                          (real(real64), 1D / 2D / 3D)
!>   * `fs_enable_serialization` / `fs_disable_serialization` — ON / OFF
!>
!> Other directives (DATA_KBUFF, OPTION, TRACER, ACCDATA, REGISTERTRACERS)
!> are out of scope for this PR and will land in follow-ups.
module m_preserf
   use, intrinsic :: iso_fortran_env, only: int8, int32, int64, real32, real64
   use netcdf
   use utils_preserf, only: t_serializer, t_savepoint, &
                            ppser_serializer, ppser_savepoint, &
                            ppser_get_mode, &
                            preserf_check_nf_with_msg, &
                            preserf_logical_to_byte, &
                            PRESERF_SAVEPOINT_INDEX_LIMIT, &
                            serialisation_enabled, &
                            t_tracer_entry, ppser_tracers, &
                            ppser_tracer_count, PPSER_MAX_TRACERS, &
                            PPSER_TRACER_TID_FLOAT64, &
                            PPSER_TRACER_NAME_LEN, PPSER_TRACER_STYPE_LEN, &
                            t_kbuff_entry, ppser_kbuffers, &
                            ppser_kbuff_count, PPSER_MAX_KBUFF, &
                            ppser_verbosity
   implicit none
   private

   ! Serialbox TypeID values (storage_mapping.md §1).
   integer(int32), parameter :: TID_BOOLEAN = 1
   integer(int32), parameter :: TID_INT32 = 2
   integer(int32), parameter :: TID_INT64 = 3
   integer(int32), parameter :: TID_FLOAT32 = 4
   integer(int32), parameter :: TID_FLOAT64 = 5
   integer(int32), parameter :: TID_STRING = 6
   ! Array bit (Serialbox MetainfoValue::Array): the array TypeID of a
   ! scalar TypeID `t` is `TID_ARRAY .or. t` (e.g. ArrayOfInt32 = 18).
   ! Matches `tests/_support/serialbox.py::TypeID.Array` (0x10).
   integer(int32), parameter :: TID_ARRAY = 16

   ! `serialisation_enabled` is owned by utils_preserf (so that
   ! ppser_initialize can reset it on a fresh session); imported via
   ! the `use utils_preserf, only: ...` at the module top.

   public :: fs_create_savepoint
   public :: fs_register_field
   public :: fs_enable_serialization
   public :: fs_disable_serialization
   public :: fs_serialization_status

   ! Tracers (Slice C / ADR 0003). `ppser_register_tracer` is the
   ! host-side registration entry point (not pp_ser-generated); the
   ! `fs_RegisterAllTracers` and `ppser_write_tracer_*` names are what
   ! pp_ser emits for REGISTERTRACERS / TRACER.
   !
   ! IMPORTANT: the `data` array passed to `ppser_register_tracer` MUST
   ! have the TARGET attribute and outlive the run. The registry stores a
   ! pointer to it (not a copy) so a read-mode `!$SER TRACER` can read the
   ! stored field back into the same array (F2008 12.5.2.4). Passing a
   ! non-TARGET array — or letting it go out of scope / be reallocated —
   ! leaves a dangling pointer.
   interface ppser_register_tracer
      module procedure ppser_register_tracer_1d
      module procedure ppser_register_tracer_2d
      module procedure ppser_register_tracer_3d
      module procedure ppser_register_tracer_4d
   end interface
   public :: ppser_register_tracer
   public :: fs_RegisterAllTracers
   public :: ppser_write_tracer_by_name
   public :: ppser_write_tracer_by_idx
   public :: ppser_write_tracer_all

   ! DATA_KBUFF (Slice C / ADR 0003 §5). pp_ser emits one fs_write_kbuff
   ! call per vertical level; the overloads differ by the slice's rank.
   interface fs_write_kbuff
      module procedure fs_write_kbuff_r8_1d
      module procedure fs_write_kbuff_r8_2d
      module procedure fs_write_kbuff_r8_3d
   end interface
   public :: fs_write_kbuff

   ! OPTION (Slice C / ADR 0003 §4). The helper exposes a single fixed
   ! keyword, `verbosity`; the preprocessor rejects any other OPTION key.
   public :: fs_Option

   interface fs_add_savepoint_metainfo
      module procedure fs_add_savepoint_metainfo_l
      module procedure fs_add_savepoint_metainfo_i4
      module procedure fs_add_savepoint_metainfo_i8
      module procedure fs_add_savepoint_metainfo_r4
      module procedure fs_add_savepoint_metainfo_r8
      module procedure fs_add_savepoint_metainfo_s
      ! 1D-array overloads (Serialbox MetainfoValue::Array).
      module procedure fs_add_savepoint_metainfo_l_1d
      module procedure fs_add_savepoint_metainfo_i4_1d
      module procedure fs_add_savepoint_metainfo_i8_1d
      module procedure fs_add_savepoint_metainfo_r4_1d
      module procedure fs_add_savepoint_metainfo_r8_1d
   end interface
   public :: fs_add_savepoint_metainfo

   interface fs_add_serializer_metainfo
      module procedure fs_add_serializer_metainfo_l
      module procedure fs_add_serializer_metainfo_i4
      module procedure fs_add_serializer_metainfo_i8
      module procedure fs_add_serializer_metainfo_r4
      module procedure fs_add_serializer_metainfo_r8
      module procedure fs_add_serializer_metainfo_s
      ! 1D-array overloads (Serialbox MetainfoValue::Array).
      module procedure fs_add_serializer_metainfo_l_1d
      module procedure fs_add_serializer_metainfo_i4_1d
      module procedure fs_add_serializer_metainfo_i8_1d
      module procedure fs_add_serializer_metainfo_r4_1d
      module procedure fs_add_serializer_metainfo_r8_1d
   end interface
   public :: fs_add_serializer_metainfo

   ! Field write/read overload matrix: {logical, int32, int64, real32,
   ! real64} x {0D, 1D, 2D, 3D, 4D}. The bodies are generated from
   ! `#include` templates in the contains section
   ! (docs/adr/0004-fortran-cpp-templates.md); these lists keep every
   ! generated name greppable and resolve the generic interface.
   interface fs_write_field
      module procedure fs_write_field_l_0d, fs_write_field_l_1d, &
         fs_write_field_l_2d, fs_write_field_l_3d, fs_write_field_l_4d
      module procedure fs_write_field_i4_0d, fs_write_field_i4_1d, &
         fs_write_field_i4_2d, fs_write_field_i4_3d, fs_write_field_i4_4d
      module procedure fs_write_field_i8_0d, fs_write_field_i8_1d, &
         fs_write_field_i8_2d, fs_write_field_i8_3d, fs_write_field_i8_4d
      module procedure fs_write_field_r4_0d, fs_write_field_r4_1d, &
         fs_write_field_r4_2d, fs_write_field_r4_3d, fs_write_field_r4_4d
      module procedure fs_write_field_r8_0d, fs_write_field_r8_1d, &
         fs_write_field_r8_2d, fs_write_field_r8_3d, fs_write_field_r8_4d
   end interface
   public :: fs_write_field

   interface fs_read_field
      module procedure fs_read_field_l_0d, fs_read_field_l_1d, &
         fs_read_field_l_2d, fs_read_field_l_3d, fs_read_field_l_4d
      module procedure fs_read_field_i4_0d, fs_read_field_i4_1d, &
         fs_read_field_i4_2d, fs_read_field_i4_3d, fs_read_field_i4_4d
      module procedure fs_read_field_i8_0d, fs_read_field_i8_1d, &
         fs_read_field_i8_2d, fs_read_field_i8_3d, fs_read_field_i8_4d
      module procedure fs_read_field_r4_0d, fs_read_field_r4_1d, &
         fs_read_field_r4_2d, fs_read_field_r4_3d, fs_read_field_r4_4d
      module procedure fs_read_field_r8_0d, fs_read_field_r8_1d, &
         fs_read_field_r8_2d, fs_read_field_r8_3d, fs_read_field_r8_4d
      ! Read-perturb (5-arg) overloads: floating dtypes only, ranks 0-4.
      module procedure fs_read_field_r4_0d_perturb, &
         fs_read_field_r4_1d_perturb, fs_read_field_r4_2d_perturb, &
         fs_read_field_r4_3d_perturb, fs_read_field_r4_4d_perturb
      module procedure fs_read_field_r8_0d_perturb, &
         fs_read_field_r8_1d_perturb, fs_read_field_r8_2d_perturb, &
         fs_read_field_r8_3d_perturb, fs_read_field_r8_4d_perturb
      ! Read-perturb (5-arg) no-op overloads: integer and logical dtypes,
      ! ranks 0-4. Perturbation is ignored for non-float types; these
      ! overloads exist so that pp_ser / Serialbox callers that emit the
      ! same 5-arg call shape for every type (e.g. mo_ser_common.f90
      ! CASE(2) blocks) compile and run correctly for integer/logical
      ! fields. See issue #39.
      module procedure fs_read_field_l_0d_perturb, &
         fs_read_field_l_1d_perturb, fs_read_field_l_2d_perturb, &
         fs_read_field_l_3d_perturb, fs_read_field_l_4d_perturb
      module procedure fs_read_field_i4_0d_perturb, &
         fs_read_field_i4_1d_perturb, fs_read_field_i4_2d_perturb, &
         fs_read_field_i4_3d_perturb, fs_read_field_i4_4d_perturb
      module procedure fs_read_field_i8_0d_perturb, &
         fs_read_field_i8_1d_perturb, fs_read_field_i8_2d_perturb, &
         fs_read_field_i8_3d_perturb, fs_read_field_i8_4d_perturb
   end interface
   public :: fs_read_field

contains

   ! ========================================================================
   ! ON / OFF
   !
   ! When `serialisation_enabled == 0`, every fs_* entry point below
   ! returns early before performing any I/O. This matches the contract
   ! pp_ser-expanded `!$SER ON` / `!$SER OFF` directives need: an OFF
   ! must make subsequent SAVEPOINT / DATA / METAINFO directives behave
   ! as no-ops at runtime.
   ! ========================================================================
   subroutine fs_enable_serialization()
      serialisation_enabled = 1
   end subroutine fs_enable_serialization

   subroutine fs_disable_serialization()
      serialisation_enabled = 0
   end subroutine fs_disable_serialization

   !> True iff fs_* I/O is currently enabled. Exposed so callers / tests
   !> can introspect the runtime state.
   function fs_serialization_status() result(enabled)
      logical :: enabled
      enabled = (serialisation_enabled /= 0)
   end function fs_serialization_status

   ! ========================================================================
   ! REGISTER
   ! ========================================================================
   !> Register a field's static metadata under `/_fields/<fieldname>`.
   !> Matches the call shape that pp_ser emits for the REGISTER directive
   !> (see directives_specification.md §3.10).
   subroutine fs_register_field(s, fieldname, datatype, bytes_per_element, &
                                iSize, jSize, kSize, lSize, &
                                iMinusHalo, iPlusHalo, &
                                jMinusHalo, jPlusHalo, &
                                kMinusHalo, kPlusHalo, &
                                lMinusHalo, lPlusHalo)
      type(t_serializer), intent(inout) :: s
      character(len=*), intent(in) :: fieldname
      character(len=*), intent(in) :: datatype
      integer, intent(in) :: bytes_per_element
      integer, intent(in) :: iSize, jSize, kSize, lSize
      integer, intent(in) :: iMinusHalo, iPlusHalo
      integer, intent(in) :: jMinusHalo, jPlusHalo
      integer, intent(in) :: kMinusHalo, kPlusHalo
      integer, intent(in) :: lMinusHalo, lPlusHalo

      integer :: ncerr, varid
      integer(int32) :: type_id, zero
      integer(int32), allocatable :: dims(:)

      if (serialisation_enabled == 0) return
      if (s%fields_grpid == -1) then
         write (*, '(a)') 'preserf: fs_register_field called before ppser_initialize'
         error stop 1
      end if

      type_id = type_id_from_datatype(datatype, bytes_per_element)
      ! `dims` records the netCDF C-order shape (slowest-varying axis
      ! first). Fortran callers declare sizes in column-major order
      ! (iSize, jSize, kSize, lSize); the helper reverses them so a
      ! Python / netCDF-C reader sees `dims[0]` as the leading numpy
      ! axis. See storage_mapping.md §1 + §4.
      dims = active_dims_c_order(iSize, jSize, kSize, lSize)
      zero = 0_int32

      ! pp_ser emits REGISTER outside the SELECT CASE (ppser_get_mode())
      ! that gates DATA blocks, so this directive runs in read mode too.
      ! In read mode the store already exists and is opened read-only:
      ! resolve the registry entry and validate it instead of creating
      ! (a create would abort on the read-only handle). Modes 1 (read)
      ! and 2 (read-perturb) both take the resolve-and-validate path.
      if (ppser_get_mode() /= 0) then
         call validate_registered_field(s, fieldname, type_id, dims, &
                                        iMinusHalo, iPlusHalo, &
                                        jMinusHalo, jPlusHalo, &
                                        kMinusHalo, kPlusHalo, &
                                        lMinusHalo, lPlusHalo)
         return
      end if

      ! Create the dummy attribute-carrier scalar variable.
      ncerr = nf90_def_var(s%fields_grpid, trim(fieldname), NF90_INT, varid)
      call preserf_check_nf_with_msg(ncerr, &
                                     'def_var /_fields/'//trim(fieldname))
      ncerr = nf90_put_att(s%fields_grpid, varid, 'type_id', type_id)
      call preserf_check_nf_with_msg(ncerr, 'put_att type_id')
      ncerr = nf90_put_att(s%fields_grpid, varid, 'dims', dims)
      call preserf_check_nf_with_msg(ncerr, 'put_att dims')

      ! Emit only non-zero halos (put_halo_attr skips zeros).
      ! Halos are named by physical direction (i/j/k/l) rather than
      ! storage axis, so a low-rank shortcut like `IK1` (rank-2
      ! storage tuple (ie, ke1, 0, 0) plus kPlusHalo=1) still wants
      ! its physical k-halo emitted. Do NOT gate halo emission by the
      ! storage rank — emit every non-zero halo unconditionally and
      ! let the writer convention (§4) handle the rest.
      call put_halo_attr(s%fields_grpid, varid, 'iminushalo', iMinusHalo)
      call put_halo_attr(s%fields_grpid, varid, 'iplushalo', iPlusHalo)
      call put_halo_attr(s%fields_grpid, varid, 'jminushalo', jMinusHalo)
      call put_halo_attr(s%fields_grpid, varid, 'jplushalo', jPlusHalo)
      call put_halo_attr(s%fields_grpid, varid, 'kminushalo', kMinusHalo)
      call put_halo_attr(s%fields_grpid, varid, 'kplushalo', kPlusHalo)
      call put_halo_attr(s%fields_grpid, varid, 'lminushalo', lMinusHalo)
      call put_halo_attr(s%fields_grpid, varid, 'lplushalo', lPlusHalo)

      ! Write the scalar value (0) so the variable has a representable payload.
      ncerr = nf90_put_var(s%fields_grpid, varid, zero)
      call preserf_check_nf_with_msg(ncerr, 'put_var (registry placeholder)')
   end subroutine fs_register_field

   ! ========================================================================
   ! SAVEPOINT
   ! ========================================================================
   !> Create a new savepoint group under `/savepoints/`. The group is
   !> named `sp_NNNNNN` (zero-padded six-digit index, per
   !> storage_mapping.md §5).
   subroutine fs_create_savepoint(name, savepoint, s)
      character(len=*), intent(in) :: name
      ! `intent(inout)` (rather than `intent(out)`) so a disabled-mode
      ! early return is a true no-op: the caller's existing savepoint
      ! handle survives intact. With `intent(out)` the actual argument
      ! would be undefined on entry, so a `!$SER OFF` block containing
      ! a SAVEPOINT would discard the previous `ppser_savepoint` and
      ! the first DATA call after `!$SER ON` would abort with
      ! "uninitialised savepoint" instead of resuming the prior one.
      type(t_savepoint), intent(inout) :: savepoint
      type(t_serializer), intent(inout), optional :: s

      if (serialisation_enabled == 0) return

      ! When we DO proceed, overwrite any stale handle the caller may
      ! have passed in — the savepoint we're about to create owns the
      ! field and `create_savepoint_on` populates it.
      savepoint%grpid = -1
      savepoint%idx = -1
      savepoint%owner_ncid = -1

      if (present(s)) then
         call create_savepoint_on(s, name, savepoint)
      else
         call create_savepoint_on(ppser_serializer, name, savepoint)
      end if
   end subroutine fs_create_savepoint

   !> Body of fs_create_savepoint, parameterised on the target serializer.
   !> Pulled out of fs_create_savepoint to avoid taking a pointer to a
   !> non-TARGET optional dummy (which would be undefined per Fortran
   !> 2008 association lifetime rules).
   subroutine create_savepoint_on(ser, name, savepoint)
      type(t_serializer), intent(inout) :: ser
      character(len=*), intent(in) :: name
      type(t_savepoint), intent(inout) :: savepoint
      character(len=9) :: group_name
      integer :: ncerr
      integer(int32) :: idx_attr

      if (ser%savepoints_grpid == -1) then
         write (*, '(a)') 'preserf: fs_create_savepoint called before ppser_initialize'
         error stop 1
      end if

      ! pp_ser emits SAVEPOINT outside the DATA-mode SELECT CASE, so this
      ! runs in read mode too. In read mode resolve the existing
      ! sp_NNNNNN group at the current index rather than creating one
      ! (a def_grp would abort on the read-only handle).
      if (ppser_get_mode() /= 0) then
         call resolve_savepoint_on(ser, name, savepoint)
         return
      end if

      if (ser%next_sp_index >= PRESERF_SAVEPOINT_INDEX_LIMIT) then
         write (*, '(a,i0)') 'preserf: savepoint index exceeds cap of ', &
            PRESERF_SAVEPOINT_INDEX_LIMIT
         error stop 1
      end if

      write (group_name, '("sp_",i6.6)') ser%next_sp_index
      ncerr = nf90_def_grp(ser%savepoints_grpid, group_name, savepoint%grpid)
      call preserf_check_nf_with_msg(ncerr, 'def_grp '//group_name)
      savepoint%idx = ser%next_sp_index
      ! Record the creating serializer so fs_write_field can reject a
      ! savepoint paired with a different serializer (see t_savepoint).
      savepoint%owner_ncid = ser%ncid

      idx_attr = int(ser%next_sp_index, int32)
      ncerr = nf90_put_att(savepoint%grpid, NF90_GLOBAL, &
                           '_preserf_savepoint_index', idx_attr)
      call preserf_check_nf_with_msg(ncerr, 'put_att _preserf_savepoint_index')
      ! Don't trim() the caller's name — preserve trailing blanks the
      ! same way string metainfo values do (storage_mapping.md §1 +
      ! §5: NC_CHAR string round-trip is lossless).
      ncerr = nf90_put_att(savepoint%grpid, NF90_GLOBAL, 'name', name)
      call preserf_check_nf_with_msg(ncerr, 'put_att name')

      ser%next_sp_index = ser%next_sp_index + 1
   end subroutine create_savepoint_on

   !> Read-mode counterpart to create_savepoint_on: resolve the existing
   !> sp_NNNNNN group at the serializer's current index and validate its
   !> `name` attribute (storage_mapping.md §5) against the runtime
   !> SAVEPOINT argument. Advances next_sp_index exactly like the create
   !> path, so successive SAVEPOINT directives resolve sp_000000,
   !> sp_000001, … in the order they were written.
   subroutine resolve_savepoint_on(ser, name, savepoint)
      type(t_serializer), intent(inout) :: ser
      character(len=*), intent(in) :: name
      type(t_savepoint), intent(inout) :: savepoint
      character(len=9) :: group_name
      integer :: ncerr, grpid, name_len
      character(len=:), allocatable :: stored_name

      if (ser%next_sp_index >= PRESERF_SAVEPOINT_INDEX_LIMIT) then
         write (*, '(a,i0)') 'preserf: savepoint index exceeds cap of ', &
            PRESERF_SAVEPOINT_INDEX_LIMIT
         error stop 1
      end if

      write (group_name, '("sp_",i6.6)') ser%next_sp_index
      ncerr = nf90_inq_ncid(ser%savepoints_grpid, group_name, grpid)
      if (ncerr /= NF90_NOERR) then
         write (*, '(a,a,a,a,a)') &
            'preserf: read-mode savepoint "', trim(name), &
            '" could not be resolved: group ', group_name, &
            ' is not present in the store'
         error stop 1
      end if

      ncerr = nf90_inquire_attribute(grpid, NF90_GLOBAL, 'name', len=name_len)
      call preserf_check_nf_with_msg(ncerr, 'inquire_attribute savepoint name')
      allocate (character(len=name_len) :: stored_name)
      ncerr = nf90_get_att(grpid, NF90_GLOBAL, 'name', stored_name)
      call preserf_check_nf_with_msg(ncerr, 'get_att savepoint name')
      if (stored_name /= name) then
         write (*, '(a,a,a,a,a,a,a)') &
            'preserf: read-mode savepoint name mismatch at ', group_name, &
            ': store has "', trim(stored_name), '", run expects "', &
            trim(name), '"'
         error stop 1
      end if

      savepoint%grpid = grpid
      savepoint%idx = ser%next_sp_index
      savepoint%owner_ncid = ser%ncid
      ser%next_sp_index = ser%next_sp_index + 1
   end subroutine resolve_savepoint_on

   ! ========================================================================
   ! TRACERS (REGISTERTRACERS + TRACER, ADR 0003 / storage_mapping.md §4a)
   !
   ! pp_ser's tracer directives carry only a name/index + stype + an
   ! integer timelevel, never the data. Host code / tests bind the data
   ! up front via `ppser_register_tracer` (the built-in registry in
   ! utils_preserf), which keeps a pointer to the host's TARGET array;
   ! `fs_RegisterAllTracers` writes one `/_tracers/<name>` descriptor per
   ! entry, and the `ppser_write_tracer_*` entry points serialize the
   ! pointed-to array at the current savepoint as a variable named by the
   ! tracer (byte-identical to a !$SER DATA field), with the integer
   ! timelevel as an optional attribute.
   !
   ! Write mode writes the array; read / read-perturb mode reads the stored
   ! variable back into the same host array (so a !$SER TRACER round-trips).
   ! v1.0 binds real(real64) arrays of rank 1-4; fs_RegisterAllTracers also
   ! resolves-and-validates the descriptors in read mode.
   ! ========================================================================

   ! Host-side registration overloads (real64, ranks 1-4). Each binds the
   ! caller's TARGET array into the matching rank-specific pointer.
#define PRESERF_SUB ppser_register_tracer_1d
#define PRESERF_DIMS , dimension(:)
#define PRESERF_RANK 1
#define PRESERF_PTR d1
#include "preserf_register_tracer.inc"
#undef PRESERF_PTR
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB ppser_register_tracer_2d
#define PRESERF_DIMS , dimension(:, :)
#define PRESERF_RANK 2
#define PRESERF_PTR d2
#include "preserf_register_tracer.inc"
#undef PRESERF_PTR
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB ppser_register_tracer_3d
#define PRESERF_DIMS , dimension(:, :, :)
#define PRESERF_RANK 3
#define PRESERF_PTR d3
#include "preserf_register_tracer.inc"
#undef PRESERF_PTR
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB ppser_register_tracer_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#define PRESERF_RANK 4
#define PRESERF_PTR d4
#include "preserf_register_tracer.inc"
#undef PRESERF_PTR
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB

   ! Per-rank tracer write/read at the current savepoint (real64, ranks 1-4).
#define PRESERF_SUB tracer_io_1d
#define PRESERF_PTR d1
#include "preserf_tracer_io.inc"
#undef PRESERF_PTR
#undef PRESERF_SUB
#define PRESERF_SUB tracer_io_2d
#define PRESERF_PTR d2
#include "preserf_tracer_io.inc"
#undef PRESERF_PTR
#undef PRESERF_SUB
#define PRESERF_SUB tracer_io_3d
#define PRESERF_PTR d3
#include "preserf_tracer_io.inc"
#undef PRESERF_PTR
#undef PRESERF_SUB
#define PRESERF_SUB tracer_io_4d
#define PRESERF_PTR d4
#include "preserf_tracer_io.inc"
#undef PRESERF_PTR
#undef PRESERF_SUB

   !> Claim and initialise a registry slot for a newly registered tracer,
   !> returning its 1-based index. Rejects an unsupported rank, a duplicate
   !> name (which would collide when fs_RegisterAllTracers defines the
   !> `/_tracers/<name>` carrier) and a full registry. The caller binds the
   !> rank-specific data pointer after this returns.
   function register_tracer_slot(name, rank, fshape, stype) result(n)
      character(len=*), intent(in) :: name
      integer, intent(in) :: rank
      integer, intent(in) :: fshape(:)
      character(len=*), intent(in), optional :: stype
      integer :: n

      if (rank < 1 .or. rank > 4) then
         write (*, '(a)') &
            'preserf: ppser_register_tracer supports rank 1..4 only'
         error stop 1
      end if
      ! Reject names / stypes that would silently truncate into the
      ! fixed-length registry components (which would then mismatch the
      ! on-disk variable name / stype attribute).
      if (len_trim(name) > PPSER_TRACER_NAME_LEN) then
         write (*, '(a,a,a,i0,a)') &
            'preserf: tracer name "', trim(name), '" exceeds ', &
            PPSER_TRACER_NAME_LEN, ' characters'
         error stop 1
      end if
      if (present(stype)) then
         if (len_trim(stype) > PPSER_TRACER_STYPE_LEN) then
            write (*, '(a,a,a,i0,a)') &
               'preserf: tracer stype "', trim(stype), '" exceeds ', &
               PPSER_TRACER_STYPE_LEN, ' characters'
            error stop 1
         end if
      end if
      if (find_tracer(name) /= 0) then
         write (*, '(a,a,a)') &
            'preserf: tracer "', trim(name), '" is already registered'
         error stop 1
      end if
      if (ppser_tracer_count >= PPSER_MAX_TRACERS) then
         write (*, '(a,i0)') &
            'preserf: tracer registry full; cap is ', PPSER_MAX_TRACERS
         error stop 1
      end if

      ppser_tracer_count = ppser_tracer_count + 1
      n = ppser_tracer_count
      ppser_tracers(n)%name = name
      ppser_tracers(n)%stype = ''
      if (present(stype)) ppser_tracers(n)%stype = stype
      ppser_tracers(n)%type_id = PPSER_TRACER_TID_FLOAT64
      ppser_tracers(n)%rank = rank
      ppser_tracers(n)%fshape = 0
      ppser_tracers(n)%fshape(1:rank) = fshape
   end function register_tracer_slot

   !> 1-based index of the registry entry named `name`, or 0 if absent.
   function find_tracer(name) result(idx)
      character(len=*), intent(in) :: name
      integer :: idx, i
      idx = 0
      do i = 1, ppser_tracer_count
         if (trim(ppser_tracers(i)%name) == trim(name)) then
            idx = i
            return
         end if
      end do
   end function find_tracer

   !> The tracer's C-order dims (slowest-varying first), reversed from the
   !> stored Fortran shape — the same convention `/_fields` uses (§1.1).
   function tracer_c_order_dims(entry) result(cd)
      type(t_tracer_entry), intent(in) :: entry
      integer(int32), allocatable :: cd(:)
      integer :: i, r
      r = entry%rank
      allocate (cd(r))
      do i = 1, r
         cd(i) = int(entry%fshape(r - i + 1), int32)
      end do
   end function tracer_c_order_dims

   !> Register all tracers currently in the built-in registry (the
   !> REGISTERTRACERS directive). In write mode this writes a
   !> `/_tracers/<name>` descriptor per entry; in read mode it resolves
   !> and validates that each registered tracer's descriptor is present
   !> in the store and agrees on type_id / dims / stype.
   subroutine fs_RegisterAllTracers()
      integer :: i, ncerr

      if (serialisation_enabled == 0) return
      if (ppser_serializer%ncid == -1) then
         write (*, '(a)') &
            'preserf: fs_RegisterAllTracers called before ppser_initialize'
         error stop 1
      end if

      if (ppser_get_mode() /= 0) then
         if (ppser_tracer_count > 0 .and. ppser_serializer%tracers_grpid == -1) then
            write (*, '(a)') &
               'preserf: read-mode store has no /_tracers group but tracers '// &
               'are registered'
            error stop 1
         end if
         do i = 1, ppser_tracer_count
            call validate_registered_tracer(ppser_serializer, ppser_tracers(i), i)
         end do
         return
      end if

      ! No registered tracers → no `/_tracers` group (lazy creation, ADR
      ! 0003 §1): a field-only store carries no empty tracer group.
      if (ppser_tracer_count == 0) return

      ! Create `/_tracers` on first use. It is NOT part of the init-time
      ! skeleton (unlike `/_fields` / `/savepoints`); netCDF-4 allows
      ! defining a group at any time, as fs_create_savepoint already does.
      if (ppser_serializer%tracers_grpid == -1) then
         ncerr = nf90_def_grp(ppser_serializer%ncid, '_tracers', &
                              ppser_serializer%tracers_grpid)
         call preserf_check_nf_with_msg(ncerr, 'def_grp /_tracers')
      end if

      do i = 1, ppser_tracer_count
         call write_tracer_descriptor(ppser_serializer%tracers_grpid, &
                                      ppser_tracers(i), i)
      end do
   end subroutine fs_RegisterAllTracers

   !> Write one `/_tracers/<name>` descriptor: a scalar NF90_INT carrier
   !> (value 0) holding type_id, C-order dims, stype, and the 1-based
   !> tracer_index — mirroring fs_register_field's `/_fields` carrier.
   subroutine write_tracer_descriptor(grpid, entry, tracer_index)
      integer, intent(in) :: grpid
      type(t_tracer_entry), intent(in) :: entry
      integer, intent(in) :: tracer_index
      integer :: ncerr, varid
      integer(int32) :: zero, tid, idx_attr
      integer(int32), allocatable :: cdims(:)

      zero = 0_int32
      tid = entry%type_id
      cdims = tracer_c_order_dims(entry)

      ncerr = nf90_def_var(grpid, trim(entry%name), NF90_INT, varid)
      call preserf_check_nf_with_msg(ncerr, &
                                     'def_var /_tracers/'//trim(entry%name))
      ncerr = nf90_put_att(grpid, varid, 'type_id', tid)
      call preserf_check_nf_with_msg(ncerr, 'put_att tracer type_id')
      ncerr = nf90_put_att(grpid, varid, 'dims', cdims)
      call preserf_check_nf_with_msg(ncerr, 'put_att tracer dims')
      ncerr = nf90_put_att(grpid, varid, 'stype', trim(entry%stype))
      call preserf_check_nf_with_msg(ncerr, 'put_att tracer stype')
      idx_attr = int(tracer_index, int32)
      ncerr = nf90_put_att(grpid, varid, 'tracer_index', idx_attr)
      call preserf_check_nf_with_msg(ncerr, 'put_att tracer_index')
      ncerr = nf90_put_var(grpid, varid, zero)
      call preserf_check_nf_with_msg(ncerr, &
                                     'put_var (tracer descriptor placeholder)')
   end subroutine write_tracer_descriptor

   !> Read-mode counterpart to write_tracer_descriptor: confirm the
   !> registered tracer's `/_tracers/<name>` carrier exists and agrees on
   !> type_id, dims (C-order), stype, and its 1-based `tracer_index`.
   !> Mirrors validate_registered_field. `expected_index` is the tracer's
   !> position in the current run's registration order; checking it against
   !> the stored value catches a read run that registers tracers in a
   !> different order, which would otherwise make `ppser_write_tracer_by_idx`
   !> resolve a different tracer than was written at that index.
   subroutine validate_registered_tracer(s, entry, expected_index)
      type(t_serializer), intent(in) :: s
      type(t_tracer_entry), intent(in) :: entry
      integer, intent(in) :: expected_index
      integer :: ncerr, varid, attr_len, axis
      integer(int32) :: stored_tid, stored_idx
      integer(int32), allocatable :: stored_dims(:), cdims(:)
      character(len=:), allocatable :: stored_stype

      ncerr = nf90_inq_varid(s%tracers_grpid, trim(entry%name), varid)
      if (ncerr == NF90_ENOTVAR) then
         write (*, '(a,a,a)') &
            'preserf: read-mode tracer "', trim(entry%name), &
            '" is not present in the store /_tracers registry'
         error stop 1
      end if
      call preserf_check_nf_with_msg(ncerr, &
                                     'inq_varid /_tracers/'//trim(entry%name))

      ncerr = nf90_get_att(s%tracers_grpid, varid, 'type_id', stored_tid)
      call preserf_check_nf_with_msg(ncerr, 'get_att tracer type_id')
      if (stored_tid /= entry%type_id) then
         write (*, '(a,a,a,i0,a,i0)') &
            'preserf: read-mode tracer "', trim(entry%name), &
            '" type_id mismatch: store has ', stored_tid, &
            ', run expects ', entry%type_id
         error stop 1
      end if

      cdims = tracer_c_order_dims(entry)
      ncerr = nf90_inquire_attribute(s%tracers_grpid, varid, 'dims', len=attr_len)
      call preserf_check_nf_with_msg(ncerr, 'inquire_attribute tracer dims')
      allocate (stored_dims(attr_len))
      ncerr = nf90_get_att(s%tracers_grpid, varid, 'dims', stored_dims)
      call preserf_check_nf_with_msg(ncerr, 'get_att tracer dims')
      if (attr_len /= size(cdims)) then
         write (*, '(a,a,a,i0,a,i0)') &
            'preserf: read-mode tracer "', trim(entry%name), &
            '" rank mismatch: store ', attr_len, ', run ', size(cdims)
         error stop 1
      end if
      do axis = 1, attr_len
         if (stored_dims(axis) /= cdims(axis)) then
            write (*, '(a,a,a)') &
               'preserf: read-mode tracer "', trim(entry%name), &
               '" dims mismatch with registered shape'
            error stop 1
         end if
      end do

      ncerr = nf90_inquire_attribute(s%tracers_grpid, varid, 'stype', len=attr_len)
      call preserf_check_nf_with_msg(ncerr, 'inquire_attribute tracer stype')
      allocate (character(len=attr_len) :: stored_stype)
      ncerr = nf90_get_att(s%tracers_grpid, varid, 'stype', stored_stype)
      call preserf_check_nf_with_msg(ncerr, 'get_att tracer stype')
      if (trim(stored_stype) /= trim(entry%stype)) then
         write (*, '(a,a,a,a,a,a)') &
            'preserf: read-mode tracer "', trim(entry%name), &
            '" stype mismatch: store "', trim(stored_stype), &
            '", run "', trim(entry%stype)
         error stop 1
      end if

      ncerr = nf90_get_att(s%tracers_grpid, varid, 'tracer_index', stored_idx)
      call preserf_check_nf_with_msg(ncerr, 'get_att tracer_index')
      if (int(stored_idx) /= expected_index) then
         write (*, '(a,a,a,i0,a,i0)') &
            'preserf: read-mode tracer "', trim(entry%name), &
            '" tracer_index mismatch: store has ', int(stored_idx), &
            ', run registered it at position ', expected_index
         error stop 1
      end if
   end subroutine validate_registered_tracer

   !> Write (mode 0) or read (mode 1/2) the registry entry `idx` at the
   !> current savepoint, dispatching on its stored rank to the matching
   !> tracer_io_* overload, which moves data through the entry's
   !> rank-specific pointer (so a read lands back in the host's array).
   subroutine tracer_io_at_current_sp(idx, timelevel)
      integer, intent(in) :: idx
      integer, intent(in), optional :: timelevel
      integer :: tl, grpid, mode
      logical :: has_tl

      call require_open(ppser_serializer, 'ppser_write_tracer')
      call require_savepoint(ppser_savepoint, 'ppser_write_tracer')
      call require_savepoint_owner(ppser_serializer, ppser_savepoint, &
                                   'ppser_write_tracer')

      has_tl = present(timelevel)
      tl = 0
      if (has_tl) tl = timelevel
      grpid = ppser_savepoint%grpid
      mode = ppser_get_mode()

      select case (ppser_tracers(idx)%rank)
      case (1)
         call tracer_io_1d(grpid, ppser_tracers(idx), mode, tl, has_tl)
      case (2)
         call tracer_io_2d(grpid, ppser_tracers(idx), mode, tl, has_tl)
      case (3)
         call tracer_io_3d(grpid, ppser_tracers(idx), mode, tl, has_tl)
      case (4)
         call tracer_io_4d(grpid, ppser_tracers(idx), mode, tl, has_tl)
      case default
         write (*, '(a,i0)') &
            'preserf: tracer has unsupported rank ', ppser_tracers(idx)%rank
         error stop 1
      end select
   end subroutine tracer_io_at_current_sp

   !> `!$SER TRACER <name>` — serialize the named tracer at the current
   !> savepoint: write in write mode, read it back into the registered host
   !> array in read mode. `stype` is accepted to match pp_ser's call shape
   !> but is not needed here (it is fixed at registration time and recorded
   !> on the `/_tracers` descriptor).
   subroutine ppser_write_tracer_by_name(name, stype, timelevel)
      character(len=*), intent(in) :: name
      character(len=*), intent(in), optional :: stype
      integer, intent(in), optional :: timelevel
      integer :: idx

      if (serialisation_enabled == 0) return
      if (present(stype)) continue  ! accepted for call-shape compatibility
      idx = find_tracer(name)
      if (idx == 0) then
         write (*, '(a,a,a)') &
            'preserf: ppser_write_tracer_by_name: tracer "', trim(name), &
            '" is not registered'
         error stop 1
      end if
      call tracer_io_at_current_sp(idx, timelevel)
   end subroutine ppser_write_tracer_by_name

   !> `!$SER TRACER $idx` / `$idx-idx2` — serialize the tracer(s) at the
   !> given 1-based registry index (or inclusive index range) at the current
   !> savepoint (write or read per the runtime mode).
   subroutine ppser_write_tracer_by_idx(idx, idx2, stype, timelevel)
      integer, intent(in) :: idx
      integer, intent(in), optional :: idx2
      character(len=*), intent(in), optional :: stype
      integer, intent(in), optional :: timelevel
      integer :: lo, hi, i

      if (serialisation_enabled == 0) return
      if (present(stype)) continue  ! accepted for call-shape compatibility
      lo = idx
      hi = idx
      if (present(idx2)) hi = idx2
      ! The preprocessor passes `$idx-idx2` ranges verbatim without
      ! normalising order, so a descending range (idx2 < idx) would
      ! silently skip the do-loop and write/read nothing. Fail loudly.
      if (hi < lo) then
         write (*, '(a,i0,a,i0,a)') &
            'preserf: ppser_write_tracer_by_idx: descending index range (', &
            lo, '..', hi, '); the upper bound must be >= the lower bound'
         error stop 1
      end if
      do i = lo, hi
         if (i < 1 .or. i > ppser_tracer_count) then
            write (*, '(a,i0,a,i0,a)') &
               'preserf: ppser_write_tracer_by_idx: index ', i, &
               ' is out of range (1..', ppser_tracer_count, ')'
            error stop 1
         end if
         call tracer_io_at_current_sp(i, timelevel)
      end do
   end subroutine ppser_write_tracer_by_idx

   !> `!$SER TRACER %all` — serialize every registered tracer at the current
   !> savepoint, optionally filtered to a single stype (empty = no filter);
   !> write or read per the runtime mode.
   subroutine ppser_write_tracer_all(stype, timelevel)
      character(len=*), intent(in), optional :: stype
      integer, intent(in), optional :: timelevel
      integer :: i
      logical :: filter

      if (serialisation_enabled == 0) return
      filter = .false.
      if (present(stype)) then
         if (len_trim(stype) > 0) filter = .true.
      end if
      do i = 1, ppser_tracer_count
         if (filter) then
            if (trim(ppser_tracers(i)%stype) /= trim(stype)) cycle
         end if
         call tracer_io_at_current_sp(i, timelevel)
      end do
   end subroutine ppser_write_tracer_all

   ! ========================================================================
   ! DATA_KBUFF (ADR 0003 §5, storage_mapping.md §6)
   !
   ! Write mode buffers the per-level slices of a field and flushes the
   ! assembled (slice_shape..., k_size) field on the last level via the
   ! field write path, so the on-disk variable is identical to a !$SER DATA
   ! write. Read mode loads the stored field once and copies each level
   ! back into the caller's slice. One active buffer per (savepoint, field);
   ! see utils_preserf for the table state.
   ! ========================================================================

   ! Per-slice-rank fs_write_kbuff overloads (real64 slices of rank 1-3).
#define PRESERF_SUB fs_write_kbuff_r8_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_write_kbuff.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_kbuff_r8_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_write_kbuff.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_kbuff_r8_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_write_kbuff.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB

   !> Abort if (k, k_size) is out of range for a fs_write_kbuff call.
   subroutine kbuff_check_k(k, k_size)
      integer, intent(in) :: k, k_size
      if (k_size < 1) then
         write (*, '(a,i0)') &
            'preserf: fs_write_kbuff k_size must be >= 1; got ', k_size
         error stop 1
      end if
      if (k < 1 .or. k > k_size) then
         write (*, '(a,i0,a,i0)') &
            'preserf: fs_write_kbuff k=', k, ' is out of range 1..', k_size
         error stop 1
      end if
   end subroutine kbuff_check_k

   !> Buffer the level-`k` slice of `fieldname` (write mode) and, on the
   !> last level, assemble and write the full field. `flat_slice` is the
   !> slice flattened column-major; placing level k at offset
   !> (k-1)*slice_size reproduces the full field's column-major layout.
   subroutine kbuff_accumulate(s, sp, fieldname, flat_slice, slice_shape, &
                               k, k_size)
      type(t_serializer), intent(inout) :: s
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: fieldname
      real(real64), intent(in) :: flat_slice(:)
      integer, intent(in) :: slice_shape(:)
      integer, intent(in) :: k, k_size
      integer :: idx, slice_size, off
      logical :: is_new

      call kbuff_check_k(k, k_size)
      slice_size = size(flat_slice)
      call kbuff_claim(sp%grpid, fieldname, slice_shape, slice_size, k_size, &
                       idx, is_new)
      if (is_new) ppser_kbuffers(idx)%buffer = 0.0_real64

      ! Levels must be written exactly once each, in ascending order
      ! (k = 1, 2, ..., k_size) — the contract pp_ser emits via `do k=1,ke`.
      ! `filled` counts the levels written so far, so the next call must
      ! supply level filled+1. Rejecting anything else catches a repeated or
      ! skipped level (which a count-only check at k_size would miss, e.g.
      ! 1,1,3 makes three calls yet never writes level 2) before the buffer
      ! flushes stale/zeroed slices.
      if (k /= ppser_kbuffers(idx)%filled + 1) then
         write (*, '(a,a,a,i0,a,i0,a)') &
            'preserf: fs_write_kbuff for "', trim(fieldname), &
            '" expected level ', ppser_kbuffers(idx)%filled + 1, &
            ' but got ', k, ' (levels must be written once each, in order)'
         error stop 1
      end if

      off = (k - 1)*slice_size
      ppser_kbuffers(idx)%buffer(off + 1:off + slice_size) = flat_slice
      ppser_kbuffers(idx)%filled = ppser_kbuffers(idx)%filled + 1

      if (k == k_size) call kbuff_flush(s, sp, idx)
   end subroutine kbuff_accumulate

   !> Read-mode counterpart: ensure the full stored field is loaded into the
   !> buffer (once, on the first level seen) and return the slot index so the
   !> caller can copy out level `k`.
   function kbuff_load(grpid, fieldname, slice_shape, slice_size, k, k_size) &
      result(idx)
      integer, intent(in) :: grpid
      character(len=*), intent(in) :: fieldname
      integer, intent(in) :: slice_shape(:)
      integer, intent(in) :: slice_size, k, k_size
      integer :: idx
      logical :: is_new

      call kbuff_check_k(k, k_size)
      call kbuff_claim(grpid, fieldname, slice_shape, slice_size, k_size, &
                       idx, is_new)
      if (is_new) call kbuff_load_full(grpid, fieldname, ppser_kbuffers(idx))
   end function kbuff_load

   !> Locate the active k-buffer for (grpid, fieldname), validating that a
   !> resumed buffer agrees on slice shape and k_size; otherwise claim a free
   !> slot (reusing one freed by a prior flush) and allocate its buffer.
   !> `is_new` is true when a fresh slot was claimed (buffer contents are
   !> then undefined — the caller initialises them).
   subroutine kbuff_claim(grpid, fieldname, slice_shape, slice_size, k_size, &
                          idx, is_new)
      integer, intent(in) :: grpid
      character(len=*), intent(in) :: fieldname
      integer, intent(in) :: slice_shape(:)
      integer, intent(in) :: slice_size, k_size
      integer, intent(out) :: idx
      logical, intent(out) :: is_new
      integer :: i, sr, free_slot

      sr = size(slice_shape)
      ! Reject a field name that would silently truncate into the fixed-length
      ! buffer-table component (which would then mismatch the on-disk variable
      ! name and make the per-(savepoint,field) lookup inconsistent).
      if (len_trim(fieldname) > PPSER_TRACER_NAME_LEN) then
         write (*, '(a,a,a,i0,a)') &
            'preserf: fs_write_kbuff field name "', trim(fieldname), &
            '" exceeds ', PPSER_TRACER_NAME_LEN, ' characters'
         error stop 1
      end if
      free_slot = 0
      do i = 1, ppser_kbuff_count
         if (ppser_kbuffers(i)%grpid == grpid .and. &
             trim(ppser_kbuffers(i)%name) == trim(fieldname)) then
            ! The rank check gates the fshape comparison: when full_rank
            ! matches, the stored slice dims are fshape(1:sr) and can be
            ! compared element-wise against this call's slice_shape (two
            ! shapes with the same total size but different dims — e.g.
            ! [10,20] vs [8,25] — must be rejected, not silently merged).
            if (ppser_kbuffers(i)%k_size /= k_size .or. &
                ppser_kbuffers(i)%full_rank /= sr + 1) then
               write (*, '(a,a,a)') &
                  'preserf: fs_write_kbuff for "', trim(fieldname), &
                  '" has an inconsistent slice shape / k_size across levels'
               error stop 1
            end if
            if (any(ppser_kbuffers(i)%fshape(1:sr) /= slice_shape)) then
               write (*, '(a,a,a)') &
                  'preserf: fs_write_kbuff for "', trim(fieldname), &
                  '" has an inconsistent slice shape / k_size across levels'
               error stop 1
            end if
            idx = i
            is_new = .false.
            return
         end if
         if (free_slot == 0 .and. ppser_kbuffers(i)%grpid == -1) free_slot = i
      end do

      if (free_slot /= 0) then
         idx = free_slot
      else
         if (ppser_kbuff_count >= PPSER_MAX_KBUFF) then
            write (*, '(a,i0)') &
               'preserf: too many concurrent k-buffers; cap is ', PPSER_MAX_KBUFF
            error stop 1
         end if
         ppser_kbuff_count = ppser_kbuff_count + 1
         idx = ppser_kbuff_count
      end if

      if (sr < 1 .or. sr > 3) then
         write (*, '(a)') &
            'preserf: fs_write_kbuff supports slice rank 1..3 only'
         error stop 1
      end if
      ppser_kbuffers(idx)%grpid = grpid
      ppser_kbuffers(idx)%name = fieldname
      ppser_kbuffers(idx)%full_rank = sr + 1
      ppser_kbuffers(idx)%fshape = 0
      ppser_kbuffers(idx)%fshape(1:sr) = slice_shape
      ppser_kbuffers(idx)%fshape(sr + 1) = k_size
      ppser_kbuffers(idx)%slice_size = slice_size
      ppser_kbuffers(idx)%k_size = k_size
      ppser_kbuffers(idx)%filled = 0
      if (allocated(ppser_kbuffers(idx)%buffer)) &
         deallocate (ppser_kbuffers(idx)%buffer)
      allocate (ppser_kbuffers(idx)%buffer(slice_size*k_size))
      is_new = .true.
   end subroutine kbuff_claim

   !> Read the full stored field for `entry` into its (column-major) buffer,
   !> dispatching on the full field rank. Aborts if the variable is absent.
   subroutine kbuff_load_full(grpid, fieldname, entry)
      integer, intent(in) :: grpid
      character(len=*), intent(in) :: fieldname
      type(t_kbuff_entry), intent(inout) :: entry
      integer :: ncerr, varid
      real(real64), allocatable :: t2(:, :), t3(:, :, :), t4(:, :, :, :)

      ncerr = nf90_inq_varid(grpid, trim(fieldname), varid)
      if (ncerr == NF90_ENOTVAR) then
         write (*, '(a,a,a)') &
            'preserf: read-mode k-buffer field "', trim(fieldname), &
            '" is not present at this savepoint'
         error stop 1
      end if
      call preserf_check_nf_with_msg(ncerr, 'inq_varid kbuff '//trim(fieldname))

      select case (entry%full_rank)
      case (2)
         allocate (t2(entry%fshape(1), entry%fshape(2)))
         ncerr = nf90_get_var(grpid, varid, t2)
         call preserf_check_nf_with_msg(ncerr, 'get_var kbuff '//trim(fieldname))
         entry%buffer = reshape(t2, [size(t2)])
      case (3)
         allocate (t3(entry%fshape(1), entry%fshape(2), entry%fshape(3)))
         ncerr = nf90_get_var(grpid, varid, t3)
         call preserf_check_nf_with_msg(ncerr, 'get_var kbuff '//trim(fieldname))
         entry%buffer = reshape(t3, [size(t3)])
      case (4)
         allocate (t4(entry%fshape(1), entry%fshape(2), entry%fshape(3), &
                      entry%fshape(4)))
         ncerr = nf90_get_var(grpid, varid, t4)
         call preserf_check_nf_with_msg(ncerr, 'get_var kbuff '//trim(fieldname))
         entry%buffer = reshape(t4, [size(t4)])
      case default
         write (*, '(a,i0)') &
            'preserf: k-buffer has unsupported full rank ', entry%full_rank
         error stop 1
      end select
   end subroutine kbuff_load_full

   !> Release a k-buffer slot (free its buffer and mark it inactive).
   subroutine kbuff_free(idx)
      integer, intent(in) :: idx
      if (allocated(ppser_kbuffers(idx)%buffer)) &
         deallocate (ppser_kbuffers(idx)%buffer)
      ppser_kbuffers(idx)%grpid = -1
      ppser_kbuffers(idx)%name = ''
      ppser_kbuffers(idx)%full_rank = 0
      ppser_kbuffers(idx)%fshape = 0
      ppser_kbuffers(idx)%slice_size = 0
      ppser_kbuffers(idx)%k_size = 0
      ppser_kbuffers(idx)%filled = 0
   end subroutine kbuff_free

   !> Reshape the completed buffer to the full field shape and write it via
   !> fs_write_field (which validates the /_fields registration), then free
   !> the slot. The reshape dispatches on the full field rank.
   subroutine kbuff_flush(s, sp, idx)
      type(t_serializer), intent(inout) :: s
      type(t_savepoint), intent(in) :: sp
      integer, intent(in) :: idx

      select case (ppser_kbuffers(idx)%full_rank)
      case (2)
         call fs_write_field(s, sp, trim(ppser_kbuffers(idx)%name), &
                             reshape(ppser_kbuffers(idx)%buffer, &
                                     ppser_kbuffers(idx)%fshape(1:2)))
      case (3)
         call fs_write_field(s, sp, trim(ppser_kbuffers(idx)%name), &
                             reshape(ppser_kbuffers(idx)%buffer, &
                                     ppser_kbuffers(idx)%fshape(1:3)))
      case (4)
         call fs_write_field(s, sp, trim(ppser_kbuffers(idx)%name), &
                             reshape(ppser_kbuffers(idx)%buffer, &
                                     ppser_kbuffers(idx)%fshape(1:4)))
      case default
         write (*, '(a,i0)') &
            'preserf: k-buffer has unsupported full rank ', &
            ppser_kbuffers(idx)%full_rank
         error stop 1
      end select

      call kbuff_free(idx)
   end subroutine kbuff_flush

   ! ========================================================================
   ! OPTION (ADR 0003 §4, storage_mapping.md §4b)
   !
   ! fs_Option exposes a single fixed keyword, `verbosity` (the only key
   ! the preprocessor lets through). It sets the module-level verbosity
   ! state and, on a writable store, records the value as the reserved
   ! `_preserf_option_verbosity` root attribute so it round-trips.
   ! ========================================================================
   subroutine fs_Option(verbosity)
      integer, intent(in), optional :: verbosity
      integer :: ncerr
      integer(int32) :: v

      if (serialisation_enabled == 0) return
      if (.not. present(verbosity)) return

      ppser_verbosity = verbosity

      ! pp_ser emits OPTION outside the DATA-mode SELECT CASE, so it runs
      ! in read mode too; only persist the attribute on a writable store
      ! (a read-mode open is read-only). The runtime verbosity knob is
      ! still updated above regardless of mode.
      if (ppser_serializer%ncid /= -1 .and. ppser_serializer%writable) then
         v = int(verbosity, int32)
         ncerr = nf90_put_att(ppser_serializer%ncid, NF90_GLOBAL, &
                              '_preserf_option_verbosity', v)
         call preserf_check_nf_with_msg(ncerr, &
                                        'put_att _preserf_option_verbosity')
      end if
   end subroutine fs_Option

   ! ========================================================================
   ! METAINFO — scalar overloads (savepoint)
   ! ========================================================================
   subroutine fs_add_savepoint_metainfo_l(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      logical, intent(in) :: value
      integer(int8) :: stored
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      stored = preserf_logical_to_byte(value)
      call put_typed_scalar_attr(sp%grpid, key, NF90_BYTE, &
                                 i8_val=stored, tid=TID_BOOLEAN, &
                                 extra_reserved='name')
   end subroutine

   subroutine fs_add_savepoint_metainfo_i4(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      integer(int32), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      call put_typed_scalar_attr(sp%grpid, key, NF90_INT, &
                                 i32_val=value, tid=TID_INT32, &
                                 extra_reserved='name')
   end subroutine

   subroutine fs_add_savepoint_metainfo_i8(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      integer(int64), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      call put_typed_scalar_attr(sp%grpid, key, NF90_INT64, &
                                 i64_val=value, tid=TID_INT64, &
                                 extra_reserved='name')
   end subroutine

   subroutine fs_add_savepoint_metainfo_r4(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      real(real32), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      call put_typed_scalar_attr(sp%grpid, key, NF90_FLOAT, &
                                 r32_val=value, tid=TID_FLOAT32, &
                                 extra_reserved='name')
   end subroutine

   subroutine fs_add_savepoint_metainfo_r8(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      real(real64), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      call put_typed_scalar_attr(sp%grpid, key, NF90_DOUBLE, &
                                 r64_val=value, tid=TID_FLOAT64, &
                                 extra_reserved='name')
   end subroutine

   subroutine fs_add_savepoint_metainfo_s(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      character(len=*), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      call put_typed_scalar_attr(sp%grpid, key, NF90_STRING, &
                                 s_val=value, tid=TID_STRING, &
                                 extra_reserved='name')
   end subroutine

   ! ========================================================================
   ! METAINFO — scalar overloads (serializer / root group)
   ! ========================================================================
   subroutine fs_add_serializer_metainfo_l(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      logical, intent(in) :: value
      integer(int8) :: stored
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      stored = preserf_logical_to_byte(value)
      call put_typed_scalar_attr(s%ncid, key, NF90_BYTE, &
                                 i8_val=stored, tid=TID_BOOLEAN)
   end subroutine

   subroutine fs_add_serializer_metainfo_i4(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      integer(int32), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      call put_typed_scalar_attr(s%ncid, key, NF90_INT, &
                                 i32_val=value, tid=TID_INT32)
   end subroutine

   subroutine fs_add_serializer_metainfo_i8(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      integer(int64), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      call put_typed_scalar_attr(s%ncid, key, NF90_INT64, &
                                 i64_val=value, tid=TID_INT64)
   end subroutine

   subroutine fs_add_serializer_metainfo_r4(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      real(real32), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      call put_typed_scalar_attr(s%ncid, key, NF90_FLOAT, &
                                 r32_val=value, tid=TID_FLOAT32)
   end subroutine

   subroutine fs_add_serializer_metainfo_r8(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      real(real64), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      call put_typed_scalar_attr(s%ncid, key, NF90_DOUBLE, &
                                 r64_val=value, tid=TID_FLOAT64)
   end subroutine

   subroutine fs_add_serializer_metainfo_s(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      character(len=*), intent(in) :: value
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      call put_typed_scalar_attr(s%ncid, key, NF90_STRING, &
                                 s_val=value, tid=TID_STRING)
   end subroutine

   ! ========================================================================
   ! METAINFO — 1D-array overloads (savepoint)
   !
   ! netCDF attributes are natively vector-valued, so an array metainfo
   ! value lands as a vector attribute of the same on-disk type as its
   ! scalar sibling; the `<key>__preserf_type_id` shadow records the
   ! array TypeID (TID_ARRAY .or. base) so readers decode it as an array
   ! (storage_mapping.md §1, §3.3). Array STRING metainfo (NC_STRING) is
   ! deferred to Slice B' alongside string data fields — the F90
   ! nf90_put_att API has no clean vector-of-strings path.
   ! ========================================================================
   subroutine fs_add_savepoint_metainfo_l_1d(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      logical, intent(in) :: value(:)
      integer(int8), allocatable :: stored(:)
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      stored = merge(1_int8, 0_int8, value)
      call put_typed_array_attr(sp%grpid, key, NF90_BYTE, &
                                i8_val=stored, base_tid=TID_BOOLEAN, &
                                extra_reserved='name')
   end subroutine

   subroutine fs_add_savepoint_metainfo_i4_1d(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      integer(int32), intent(in) :: value(:)
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      call put_typed_array_attr(sp%grpid, key, NF90_INT, &
                                i32_val=value, base_tid=TID_INT32, &
                                extra_reserved='name')
   end subroutine

   subroutine fs_add_savepoint_metainfo_i8_1d(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      integer(int64), intent(in) :: value(:)
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      call put_typed_array_attr(sp%grpid, key, NF90_INT64, &
                                i64_val=value, base_tid=TID_INT64, &
                                extra_reserved='name')
   end subroutine

   subroutine fs_add_savepoint_metainfo_r4_1d(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      real(real32), intent(in) :: value(:)
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      call put_typed_array_attr(sp%grpid, key, NF90_FLOAT, &
                                r32_val=value, base_tid=TID_FLOAT32, &
                                extra_reserved='name')
   end subroutine

   subroutine fs_add_savepoint_metainfo_r8_1d(sp, key, value)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: key
      real(real64), intent(in) :: value(:)
      if (serialisation_enabled == 0) return
      call require_savepoint(sp, 'fs_add_savepoint_metainfo')
      call put_typed_array_attr(sp%grpid, key, NF90_DOUBLE, &
                                r64_val=value, base_tid=TID_FLOAT64, &
                                extra_reserved='name')
   end subroutine

   ! ========================================================================
   ! METAINFO — 1D-array overloads (serializer / root group)
   ! ========================================================================
   subroutine fs_add_serializer_metainfo_l_1d(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      logical, intent(in) :: value(:)
      integer(int8), allocatable :: stored(:)
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      stored = merge(1_int8, 0_int8, value)
      call put_typed_array_attr(s%ncid, key, NF90_BYTE, &
                                i8_val=stored, base_tid=TID_BOOLEAN)
   end subroutine

   subroutine fs_add_serializer_metainfo_i4_1d(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      integer(int32), intent(in) :: value(:)
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      call put_typed_array_attr(s%ncid, key, NF90_INT, &
                                i32_val=value, base_tid=TID_INT32)
   end subroutine

   subroutine fs_add_serializer_metainfo_i8_1d(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      integer(int64), intent(in) :: value(:)
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      call put_typed_array_attr(s%ncid, key, NF90_INT64, &
                                i64_val=value, base_tid=TID_INT64)
   end subroutine

   subroutine fs_add_serializer_metainfo_r4_1d(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      real(real32), intent(in) :: value(:)
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      call put_typed_array_attr(s%ncid, key, NF90_FLOAT, &
                                r32_val=value, base_tid=TID_FLOAT32)
   end subroutine

   subroutine fs_add_serializer_metainfo_r8_1d(s, key, value)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: key
      real(real64), intent(in) :: value(:)
      if (serialisation_enabled == 0) return
      call require_open(s, 'fs_add_serializer_metainfo')
      call put_typed_array_attr(s%ncid, key, NF90_DOUBLE, &
                                r64_val=value, base_tid=TID_FLOAT64)
   end subroutine

   ! ========================================================================
   ! DATA — write
   !
   ! The `s` argument is accepted to keep the call shape pp_ser emits
   ! (`fs_write_field(ppser_serializer, ppser_savepoint, ...)`); the
   ! actual netCDF state we need lives on the savepoint's group. We
   ! validate that `s` has been initialised so callers get a clear
   ! error if they forgot `ppser_initialize`.
   ! ========================================================================
   ! Logical field writes (NF90_BYTE 0/1 encoding).
#define PRESERF_SUB fs_write_field_l_0d
#define PRESERF_DIMS
#include "preserf_write_field_logical.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_l_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_write_field_logical.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_l_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_write_field_logical.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_l_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_write_field_logical.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_l_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#include "preserf_write_field_logical.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB

   ! int32 field writes.
#define PRESERF_DTYPE integer(int32)
#define PRESERF_NCTYPE NF90_INT
#define PRESERF_TID TID_INT32
#define PRESERF_SUB fs_write_field_i4_0d
#define PRESERF_DIMS
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_i4_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_i4_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_i4_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_i4_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_TID
#undef PRESERF_NCTYPE
#undef PRESERF_DTYPE

   ! int64 field writes.
#define PRESERF_DTYPE integer(int64)
#define PRESERF_NCTYPE NF90_INT64
#define PRESERF_TID TID_INT64
#define PRESERF_SUB fs_write_field_i8_0d
#define PRESERF_DIMS
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_i8_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_i8_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_i8_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_i8_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_TID
#undef PRESERF_NCTYPE
#undef PRESERF_DTYPE

   ! real32 field writes.
#define PRESERF_DTYPE real(real32)
#define PRESERF_NCTYPE NF90_FLOAT
#define PRESERF_TID TID_FLOAT32
#define PRESERF_SUB fs_write_field_r4_0d
#define PRESERF_DIMS
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_r4_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_r4_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_r4_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_r4_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_TID
#undef PRESERF_NCTYPE
#undef PRESERF_DTYPE

   ! real64 field writes.
#define PRESERF_DTYPE real(real64)
#define PRESERF_NCTYPE NF90_DOUBLE
#define PRESERF_TID TID_FLOAT64
#define PRESERF_SUB fs_write_field_r8_0d
#define PRESERF_DIMS
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_r8_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_r8_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_r8_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_write_field_r8_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#include "preserf_write_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_TID
#undef PRESERF_NCTYPE
#undef PRESERF_DTYPE

   ! ========================================================================
   ! DATA — read
   ! ========================================================================
   ! Logical field reads (NF90_BYTE 0/1 -> .true./.false.).
#define PRESERF_SUB fs_read_field_l_0d
#define PRESERF_DIMS
#define PRESERF_BUFALLOC allocate (buf)
#include "preserf_read_field_logical.inc"
#undef PRESERF_BUFALLOC
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_l_1d
#define PRESERF_DIMS , dimension(:)
#define PRESERF_BUFALLOC allocate (buf(size(data, 1)))
#include "preserf_read_field_logical.inc"
#undef PRESERF_BUFALLOC
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_l_2d
#define PRESERF_DIMS , dimension(:, :)
#define PRESERF_BUFALLOC allocate (buf(size(data, 1), size(data, 2)))
#include "preserf_read_field_logical.inc"
#undef PRESERF_BUFALLOC
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_l_3d
#define PRESERF_DIMS , dimension(:, :, :)
#define PRESERF_BUFALLOC allocate (buf(size(data, 1), size(data, 2), size(data, 3)))
#include "preserf_read_field_logical.inc"
#undef PRESERF_BUFALLOC
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_l_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#define PRESERF_BUFALLOC allocate (buf(size(data, 1), size(data, 2), size(data, 3), size(data, 4)))
#include "preserf_read_field_logical.inc"
#undef PRESERF_BUFALLOC
#undef PRESERF_DIMS
#undef PRESERF_SUB

   ! int32 field reads.
#define PRESERF_DTYPE integer(int32)
#define PRESERF_NCTYPE NF90_INT
#define PRESERF_TID TID_INT32
#define PRESERF_SUB fs_read_field_i4_0d
#define PRESERF_DIMS
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i4_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i4_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i4_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i4_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_TID
#undef PRESERF_NCTYPE
#undef PRESERF_DTYPE

   ! int64 field reads.
#define PRESERF_DTYPE integer(int64)
#define PRESERF_NCTYPE NF90_INT64
#define PRESERF_TID TID_INT64
#define PRESERF_SUB fs_read_field_i8_0d
#define PRESERF_DIMS
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i8_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i8_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i8_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i8_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_TID
#undef PRESERF_NCTYPE
#undef PRESERF_DTYPE

   ! real32 field reads.
#define PRESERF_DTYPE real(real32)
#define PRESERF_NCTYPE NF90_FLOAT
#define PRESERF_TID TID_FLOAT32
#define PRESERF_SUB fs_read_field_r4_0d
#define PRESERF_DIMS
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r4_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r4_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r4_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r4_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_TID
#undef PRESERF_NCTYPE
#undef PRESERF_DTYPE

   ! real64 field reads.
#define PRESERF_DTYPE real(real64)
#define PRESERF_NCTYPE NF90_DOUBLE
#define PRESERF_TID TID_FLOAT64
#define PRESERF_SUB fs_read_field_r8_0d
#define PRESERF_DIMS
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r8_1d
#define PRESERF_DIMS , dimension(:)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r8_2d
#define PRESERF_DIMS , dimension(:, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r8_3d
#define PRESERF_DIMS , dimension(:, :, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r8_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#include "preserf_read_field.inc"
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_TID
#undef PRESERF_NCTYPE
#undef PRESERF_DTYPE

   ! ------------------------------------------------------------------------
   ! DATA — read with perturbation magnitude (CASE(2) form)
   !
   ! pp_ser's read-perturb branch (mode=2) emits
   !   call fs_read_field(ppser_serializer_ref, ppser_savepoint,
   !                      '<field>', <expr>, ppser_zrperturb)
   ! so the 5th `perturb` arg carries the scale `ppser_zrperturb`. Each
   ! overload reads the unperturbed field via its 4-arg sibling, then
   ! applies symmetric multiplicative noise
   !   data = data * (1 + perturb*(2*r - 1)),  r ~ U[0,1)
   ! (the original COSMO `serialize` semantics; upstream serialbox2
   ! leaves the perturb arg unused). Perturbation is only meaningful for
   ! floating fields, so only real32 / real64 get the 5-arg overload; the
   ! apply_perturb_* helpers and the overloads themselves are generated
   ! from templates (docs/adr/0004-fortran-cpp-templates.md).
   ! ------------------------------------------------------------------------

   ! real32 perturbation helpers.
#define PRESERF_DTYPE real(real32)
#define PRESERF_SUB apply_perturb_r4_0d
#define PRESERF_DIMS
#define PRESERF_RANK 0
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB apply_perturb_r4_1d
#define PRESERF_DIMS , dimension(:)
#define PRESERF_RANK 1
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB apply_perturb_r4_2d
#define PRESERF_DIMS , dimension(:, :)
#define PRESERF_RANK 2
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB apply_perturb_r4_3d
#define PRESERF_DIMS , dimension(:, :, :)
#define PRESERF_RANK 3
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB apply_perturb_r4_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#define PRESERF_RANK 4
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_DTYPE

   ! real64 perturbation helpers.
#define PRESERF_DTYPE real(real64)
#define PRESERF_SUB apply_perturb_r8_0d
#define PRESERF_DIMS
#define PRESERF_RANK 0
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB apply_perturb_r8_1d
#define PRESERF_DIMS , dimension(:)
#define PRESERF_RANK 1
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB apply_perturb_r8_2d
#define PRESERF_DIMS , dimension(:, :)
#define PRESERF_RANK 2
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB apply_perturb_r8_3d
#define PRESERF_DIMS , dimension(:, :, :)
#define PRESERF_RANK 3
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB apply_perturb_r8_4d
#define PRESERF_DIMS , dimension(:, :, :, :)
#define PRESERF_RANK 4
#include "preserf_apply_perturb.inc"
#undef PRESERF_RANK
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_DTYPE

   ! real32 read-perturb (5-arg) overloads.
#define PRESERF_DTYPE real(real32)
#define PRESERF_SUB fs_read_field_r4_0d_perturb
#define PRESERF_DIMS
#define PRESERF_BASE fs_read_field_r4_0d
#define PRESERF_APPLY apply_perturb_r4_0d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r4_1d_perturb
#define PRESERF_DIMS , dimension(:)
#define PRESERF_BASE fs_read_field_r4_1d
#define PRESERF_APPLY apply_perturb_r4_1d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r4_2d_perturb
#define PRESERF_DIMS , dimension(:, :)
#define PRESERF_BASE fs_read_field_r4_2d
#define PRESERF_APPLY apply_perturb_r4_2d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r4_3d_perturb
#define PRESERF_DIMS , dimension(:, :, :)
#define PRESERF_BASE fs_read_field_r4_3d
#define PRESERF_APPLY apply_perturb_r4_3d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r4_4d_perturb
#define PRESERF_DIMS , dimension(:, :, :, :)
#define PRESERF_BASE fs_read_field_r4_4d
#define PRESERF_APPLY apply_perturb_r4_4d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_DTYPE

   ! real64 read-perturb (5-arg) overloads.
#define PRESERF_DTYPE real(real64)
#define PRESERF_SUB fs_read_field_r8_0d_perturb
#define PRESERF_DIMS
#define PRESERF_BASE fs_read_field_r8_0d
#define PRESERF_APPLY apply_perturb_r8_0d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r8_1d_perturb
#define PRESERF_DIMS , dimension(:)
#define PRESERF_BASE fs_read_field_r8_1d
#define PRESERF_APPLY apply_perturb_r8_1d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r8_2d_perturb
#define PRESERF_DIMS , dimension(:, :)
#define PRESERF_BASE fs_read_field_r8_2d
#define PRESERF_APPLY apply_perturb_r8_2d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r8_3d_perturb
#define PRESERF_DIMS , dimension(:, :, :)
#define PRESERF_BASE fs_read_field_r8_3d
#define PRESERF_APPLY apply_perturb_r8_3d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_r8_4d_perturb
#define PRESERF_DIMS , dimension(:, :, :, :)
#define PRESERF_BASE fs_read_field_r8_4d
#define PRESERF_APPLY apply_perturb_r8_4d
#include "preserf_read_field_perturb.inc"
#undef PRESERF_APPLY
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_DTYPE

   ! ------------------------------------------------------------------------
   ! DATA — read with perturbation magnitude (CASE(2) form) — no-op overloads
   !
   ! Integer (int32 / int64) and logical fields accept the 5-arg call shape
   ! that pp_ser emits uniformly for every type in its read-perturb CASE(2)
   ! branch (see issue #39). The perturbation argument is received and
   ! discarded; the field is simply read via its 4-arg sibling.
   ! ------------------------------------------------------------------------

   ! logical read-perturb no-op overloads (ranks 0-4).
#define PRESERF_DTYPE logical
#define PRESERF_SUB fs_read_field_l_0d_perturb
#define PRESERF_DIMS
#define PRESERF_BASE fs_read_field_l_0d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_l_1d_perturb
#define PRESERF_DIMS , dimension(:)
#define PRESERF_BASE fs_read_field_l_1d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_l_2d_perturb
#define PRESERF_DIMS , dimension(:, :)
#define PRESERF_BASE fs_read_field_l_2d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_l_3d_perturb
#define PRESERF_DIMS , dimension(:, :, :)
#define PRESERF_BASE fs_read_field_l_3d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_l_4d_perturb
#define PRESERF_DIMS , dimension(:, :, :, :)
#define PRESERF_BASE fs_read_field_l_4d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_DTYPE

   ! int32 read-perturb no-op overloads (ranks 0-4).
#define PRESERF_DTYPE integer(int32)
#define PRESERF_SUB fs_read_field_i4_0d_perturb
#define PRESERF_DIMS
#define PRESERF_BASE fs_read_field_i4_0d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i4_1d_perturb
#define PRESERF_DIMS , dimension(:)
#define PRESERF_BASE fs_read_field_i4_1d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i4_2d_perturb
#define PRESERF_DIMS , dimension(:, :)
#define PRESERF_BASE fs_read_field_i4_2d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i4_3d_perturb
#define PRESERF_DIMS , dimension(:, :, :)
#define PRESERF_BASE fs_read_field_i4_3d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i4_4d_perturb
#define PRESERF_DIMS , dimension(:, :, :, :)
#define PRESERF_BASE fs_read_field_i4_4d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_DTYPE

   ! int64 read-perturb no-op overloads (ranks 0-4).
#define PRESERF_DTYPE integer(int64)
#define PRESERF_SUB fs_read_field_i8_0d_perturb
#define PRESERF_DIMS
#define PRESERF_BASE fs_read_field_i8_0d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i8_1d_perturb
#define PRESERF_DIMS , dimension(:)
#define PRESERF_BASE fs_read_field_i8_1d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i8_2d_perturb
#define PRESERF_DIMS , dimension(:, :)
#define PRESERF_BASE fs_read_field_i8_2d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i8_3d_perturb
#define PRESERF_DIMS , dimension(:, :, :)
#define PRESERF_BASE fs_read_field_i8_3d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#define PRESERF_SUB fs_read_field_i8_4d_perturb
#define PRESERF_DIMS , dimension(:, :, :, :)
#define PRESERF_BASE fs_read_field_i8_4d
#include "preserf_read_field_perturb_noop.inc"
#undef PRESERF_BASE
#undef PRESERF_DIMS
#undef PRESERF_SUB
#undef PRESERF_DTYPE

   ! ========================================================================
   ! Internal helpers
   ! ========================================================================

   !> Map a Serialbox-style type string + element-byte-length to a TypeID.
   function type_id_from_datatype(datatype, bytes_per_element) result(tid)
      character(len=*), intent(in) :: datatype
      integer, intent(in) :: bytes_per_element
      integer(int32) :: tid
      character(len=:), allocatable :: lc

      lc = to_lower(trim(datatype))
      select case (lc)
      case ('bool', 'boolean', 'logical')
         tid = TID_BOOLEAN
      case ('int', 'integer')
         select case (bytes_per_element)
         case (4)
            tid = TID_INT32
         case (8)
            tid = TID_INT64
         case default
            call reject_byte_length(trim(datatype), bytes_per_element, &
                                    '4 or 8')
            tid = TID_INT32  ! unreachable; satisfies compiler
         end select
      case ('int64', 'long')
         call require_byte_length(trim(datatype), bytes_per_element, 8)
         tid = TID_INT64
      case ('float', 'single')
         call require_byte_length(trim(datatype), bytes_per_element, 4)
         tid = TID_FLOAT32
      case ('double')
         call require_byte_length(trim(datatype), bytes_per_element, 8)
         tid = TID_FLOAT64
      case ('real')
         select case (bytes_per_element)
         case (4)
            tid = TID_FLOAT32
         case (8)
            tid = TID_FLOAT64
         case default
            call reject_byte_length(trim(datatype), bytes_per_element, &
                                    '4 or 8')
            tid = TID_FLOAT64  ! unreachable; satisfies compiler
         end select
      case ('string', 'character')
         tid = TID_STRING
      case default
         write (*, '(a,a)') 'preserf: unknown datatype string: ', trim(datatype)
         error stop 1
      end select
   end function type_id_from_datatype

   subroutine reject_byte_length(datatype, got, expected)
      character(len=*), intent(in) :: datatype
      integer, intent(in) :: got
      character(len=*), intent(in) :: expected
      write (*, '(a,a,a,i0,a,a)') &
         'preserf: unsupported byte length for datatype "', &
         datatype, '": got ', got, &
         ' bytes/element, expected ', expected
      error stop 1
   end subroutine reject_byte_length

   !> Require a fixed-width datatype string (e.g. 'double', 'int64') to
   !> be paired with the matching byte length. Catches callers that
   !> pass a fixed-width type name but a mismatched bytes_per_element
   !> (e.g. `datatype='double', bytes_per_element=4`), which would
   !> otherwise silently produce registry metadata that disagrees with
   !> the caller's element size.
   subroutine require_byte_length(datatype, got, expected)
      character(len=*), intent(in) :: datatype
      integer, intent(in) :: got, expected
      character(len=16) :: expected_str
      if (got == expected) return
      write (expected_str, '(i0)') expected
      call reject_byte_length(datatype, got, trim(expected_str))
   end subroutine require_byte_length

   !> Build the active dims vector in netCDF C-order (slowest-varying
   !> axis first) from the Fortran-natural (iSize, jSize, kSize, lSize)
   !> tuple. The Fortran tuple convention (per directives_specification.md
   !> §3.10) is that non-zero sizes form a contiguous leading prefix:
   !> e.g. shortcut "K1" expands to `(ke1, 0, 0, 0)` and shortcut "IJ"
   !> expands to `(ie, je, 0, 0)`. A zero followed by a non-zero is an
   !> inconsistent shape and aborts the program rather than silently
   !> producing an invalid dims vector with embedded zeros.
   function active_dims_c_order(iSize, jSize, kSize, lSize) result(d)
      integer, intent(in) :: iSize, jSize, kSize, lSize
      integer(int32), allocatable :: d(:)
      integer :: rank

      ! Reject any negative size up front — both "active" and trailing
      ! positions must be >= 0. Without this check, a negative trailing
      ! size like (iSize=4, jSize=-3, kSize=0, lSize=0) is silently
      ! treated as a 1-D field (because the `> 0` rank check skips
      ! jSize=-3), hiding a clearly bad REGISTER tuple.
      if (iSize < 0 .or. jSize < 0 .or. kSize < 0 .or. lSize < 0) then
         write (*, '(a,4(i0,a))') &
            'preserf: invalid dim tuple (', &
            iSize, ',', jSize, ',', kSize, ',', lSize, &
            '); negative sizes are not allowed'
         error stop 1
      end if

      ! A fully-zero tuple is a rank-0 (scalar) field: the `dims`
      ! attribute is a zero-length vector and the per-savepoint variable
      ! is a netCDF scalar. This is the 0-D corner of the type-coverage
      ! matrix (Slice B); ranks 1-4 fall through to the checks below.
      if (iSize == 0 .and. jSize == 0 .and. kSize == 0 .and. lSize == 0) then
         allocate (d(0))
         return
      end if

      ! Reject non-contiguous prefixes up front.
      if (jSize > 0 .and. iSize <= 0) call active_dims_inconsistent( &
         iSize, jSize, kSize, lSize)
      if (kSize > 0 .and. jSize <= 0) call active_dims_inconsistent( &
         iSize, jSize, kSize, lSize)
      if (lSize > 0 .and. kSize <= 0) call active_dims_inconsistent( &
         iSize, jSize, kSize, lSize)

      ! At least iSize must be strictly positive for a rank >= 1 field —
      ! a tuple with a zero iSize but non-zero trailing sizes is a
      ! non-contiguous prefix (already rejected above); a partially-zero
      ! tuple that reaches here with iSize == 0 is malformed.
      if (iSize <= 0) then
         write (*, '(a,4(i0,a))') &
            'preserf: invalid dim tuple (', &
            iSize, ',', jSize, ',', kSize, ',', lSize, &
            '); iSize must be > 0'
         error stop 1
      end if

      ! Bounds-check active dims before the int32 cast: under a
      ! -fdefault-integer-8 build the dummy args are int64-wide and a
      ! bare int(iSize, int32) would silently truncate values past
      ! huge(0_int32) (fortran-helper-roadmap.md §4).
      call require_fits_int32(iSize, 'iSize')
      if (jSize > 0) call require_fits_int32(jSize, 'jSize')
      if (kSize > 0) call require_fits_int32(kSize, 'kSize')
      if (lSize > 0) call require_fits_int32(lSize, 'lSize')

      rank = 0
      if (iSize > 0) rank = 1
      if (jSize > 0) rank = 2
      if (kSize > 0) rank = 3
      if (lSize > 0) rank = 4
      allocate (d(rank))
      ! Reverse from Fortran column-major declaration order into
      ! C-order: leading dim = slowest-varying = last Fortran index.
      if (rank == 1) d(1) = int(iSize, int32)
      if (rank == 2) then
         d(1) = int(jSize, int32); d(2) = int(iSize, int32)
      end if
      if (rank == 3) then
         d(1) = int(kSize, int32); d(2) = int(jSize, int32); d(3) = int(iSize, int32)
      end if
      if (rank == 4) then
         d(1) = int(lSize, int32); d(2) = int(kSize, int32)
         d(3) = int(jSize, int32); d(4) = int(iSize, int32)
      end if
   end function active_dims_c_order

   subroutine active_dims_inconsistent(iSize, jSize, kSize, lSize)
      integer, intent(in) :: iSize, jSize, kSize, lSize
      write (*, '(a,4(i0,a))') &
         'preserf: inconsistent dim tuple (', &
         iSize, ',', jSize, ',', kSize, ',', lSize, &
         '); non-zero sizes must form a contiguous leading prefix'
      error stop 1
   end subroutine active_dims_inconsistent

   !> Abort if `value` (a default-kind integer) exceeds the int32
   !> upper bound. storage_mapping.md §1 pins the on-disk `dims` and
   !> halo attributes to NC_INT (int32 on the wire), so widening the
   !> on-disk type is not an option. Under a -fdefault-integer-8 build
   !> the dummy arg can hold values past huge(0_int32) and a bare
   !> int(value, int32) would silently truncate; this guard turns that
   !> into a clean error_stop. Only the upper bound is checked: every
   !> current caller (active_dims_c_order, put_halo_attr) rejects
   !> negative inputs with its own context-specific error message
   !> before reaching here, so a redundant lower-bound check would
   !> only ever fire as dead code. Carry-over from PR #4 review
   !> (fortran-helper-roadmap.md §4).
   subroutine require_fits_int32(value, label)
      integer, intent(in) :: value
      character(len=*), intent(in) :: label
      if (int(value, int64) > int(huge(0_int32), int64)) then
         write (*, '(a,a,a,i0,a,i0)') &
            'preserf: ', trim(label), &
            ' exceeds int32 capacity; got ', value, &
            ', max is ', huge(0_int32)
         error stop 1
      end if
   end subroutine require_fits_int32

   subroutine put_halo_attr(grpid, varid, name, value)
      integer, intent(in) :: grpid, varid
      character(len=*), intent(in) :: name
      integer, intent(in) :: value
      integer :: ncerr
      integer(int32) :: v
      ! Halos describe a physical extent (number of ghost cells on
      ! one side of an axis). Reject negative values rather than
      ! writing nonsensical metadata that readers would round-trip
      ! without complaint.
      if (value < 0) then
         write (*, '(a,a,a,i0)') &
            'preserf: negative halo extent for "', name, '": ', value
         error stop 1
      end if
      if (value == 0) return
      call require_fits_int32(value, 'halo "'//trim(name)//'"')
      v = int(value, int32)
      ncerr = nf90_put_att(grpid, varid, name, v)
      call preserf_check_nf_with_msg(ncerr, 'put_att '//name)
   end subroutine put_halo_attr

   !> Write a typed metainfo attribute as `<key>` plus its shadow
   !> `<key>__preserf_type_id` (storage_mapping.md §3.3). The attribute
   !> is attached as a group-level attribute on `grpid` — NF90_GLOBAL
   !> is the netCDF varid that means "attach to the group itself".
   !>
   !> Exactly one of i8_val / i32_val / i64_val / r32_val / r64_val /
   !> s_val must be supplied, matching `nc_type`. The kind of the
   !> Fortran argument passed to `nf90_put_att` controls the on-disk
   !> netCDF attribute type, which is why each Serialbox TypeID gets
   !> its own kind-correct path here:
   !>
   !>   * Boolean → int8           → NC_BYTE
   !>   * Int32   → int32          → NC_INT
   !>   * Int64   → int64          → NC_INT64
   !>   * Float32 → real32         → NC_FLOAT
   !>   * Float64 → real64         → NC_DOUBLE
   !>   * String  → character(*)   → NC_CHAR
   !>
   !> Both reference writers (Python `netCDF4.Dataset.setncattr` and
   !> the netcdf-fortran F90 `nf90_put_att` with a `character(*)`
   !> argument) produce NC_CHAR for scalar string attributes — see
   !> storage_mapping.md §1. The `__preserf_type_id` shadow attribute
   !> is still the schema's source of truth for the typed-value
   !> contract; readers MUST decode through it rather than the on-disk
   !> netCDF type.
   subroutine put_typed_scalar_attr(grpid, key, nc_type, &
                                    tid, i8_val, i32_val, i64_val, &
                                    r32_val, r64_val, s_val, &
                                    extra_reserved)
      integer, intent(in) :: grpid
      character(len=*), intent(in) :: key
      integer, intent(in) :: nc_type
      integer(int32), intent(in) :: tid
      integer(int8), intent(in), optional :: i8_val
      integer(int32), intent(in), optional :: i32_val
      integer(int64), intent(in), optional :: i64_val
      real(real32), intent(in), optional :: r32_val
      real(real64), intent(in), optional :: r64_val
      character(len=*), intent(in), optional :: s_val
      ! Context-specific reserved attribute name to additionally
      ! reject. Savepoint metainfo callers pass `'name'`; root
      ! callers leave it unset.
      character(len=*), intent(in), optional :: extra_reserved

      integer :: ncerr
      character(len=:), allocatable :: shadow

      if (serialisation_enabled == 0) return

      ! Reject keys colliding with the reserved housekeeping namespace
      ! (`_preserf_*`) or the shadow-tag suffix (`__preserf_type_id`),
      ! per storage_mapping.md §3.2. Matches the Python writer's
      ! _write_metainfo_attrs guard. The optional `extra_reserved`
      ! covers per-context schema attributes (`name` on savepoint
      ! groups; field-registry uses a different code path).
      call reject_reserved_metainfo_key(key, extra_reserved)

      ! pp_ser emits METAINFO / SAVEPOINT key=value pairs outside the
      ! DATA-mode SELECT CASE, so they run in read mode too. In read
      ! mode validate the stored attribute (value + __preserf_type_id)
      ! instead of writing it (a put_att would abort on the read-only
      ! handle).
      if (ppser_get_mode() /= 0) then
         call check_typed_scalar_attr(grpid, key, nc_type, tid, &
                                      i8_val, i32_val, i64_val, &
                                      r32_val, r64_val, s_val)
         return
      end if

      select case (nc_type)
      case (NF90_BYTE)
         if (.not. present(i8_val)) call missing_value_arg(key, 'i8_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, i8_val)
      case (NF90_INT)
         if (.not. present(i32_val)) call missing_value_arg(key, 'i32_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, i32_val)
      case (NF90_INT64)
         if (.not. present(i64_val)) call missing_value_arg(key, 'i64_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, i64_val)
      case (NF90_FLOAT)
         if (.not. present(r32_val)) call missing_value_arg(key, 'r32_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, r32_val)
      case (NF90_DOUBLE)
         if (.not. present(r64_val)) call missing_value_arg(key, 'r64_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, r64_val)
      case (NF90_STRING)
         ! See block comment above — this lands as NC_CHAR on disk
         ! (the F90 wrapper calls nc_put_att_text under the hood).
         ! The Python reference writer also produces NC_CHAR for
         ! scalar string attributes; documented in
         ! storage_mapping.md §1.
         !
         ! NOTE: pass s_val through *without* trim() so trailing
         ! blanks the caller deliberately included are preserved.
         ! storage_mapping.md §1's lossless-string contract requires
         ! this; key sanitization happens above via trim(key), but
         ! the user value is opaque.
         if (.not. present(s_val)) call missing_value_arg(key, 's_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, s_val)
      case default
         write (*, '(a,i0)') 'preserf: unsupported nc_type ', nc_type
         error stop 1
      end select
      call preserf_check_nf_with_msg(ncerr, 'put_att '//key)

      ! Use trim(key) so a fixed-length caller-side key like
      ! `character(len=32) :: key = 'author'` produces the same shadow
      ! tag (`author__preserf_type_id`) the Python reader expects.
      shadow = trim(key)//'__preserf_type_id'
      ncerr = nf90_put_att(grpid, NF90_GLOBAL, shadow, tid)
      call preserf_check_nf_with_msg(ncerr, 'put_att '//shadow)
   end subroutine put_typed_scalar_attr

   subroutine missing_value_arg(key, expected)
      character(len=*), intent(in) :: key, expected
      write (*, '(a,a,a,a,a)') &
         'preserf: put_typed_scalar_attr("', trim(key), &
         '") requires the ', trim(expected), &
         ' optional argument for the requested nc_type'
      error stop 1
   end subroutine missing_value_arg

   subroutine reject_reserved_metainfo_key(key, extra_reserved)
      character(len=*), intent(in) :: key
      character(len=*), intent(in), optional :: extra_reserved
      character(len=*), parameter :: prefix = '_preserf_'
      character(len=*), parameter :: suffix = '__preserf_type_id'
      character(len=:), allocatable :: tkey
      integer :: tlen

      ! Base validation on trim(key) so a fixed-length caller-side
      ! buffer like `character(len=32) :: k = 'foo__preserf_type_id'`
      ! still trips the suffix check despite trailing blanks.
      tkey = trim(key)
      tlen = len(tkey)

      if (tlen >= len(prefix)) then
         if (tkey(1:len(prefix)) == prefix) then
            write (*, '(a,a,a)') 'preserf: metainfo key "', tkey, &
               '" collides with reserved prefix "_preserf_"'
            error stop 1
         end if
      end if
      if (tlen >= len(suffix)) then
         if (tkey(tlen - len(suffix) + 1:tlen) == suffix) then
            write (*, '(a,a,a)') 'preserf: metainfo key "', tkey, &
               '" collides with reserved suffix "__preserf_type_id"'
            error stop 1
         end if
      end if
      if (present(extra_reserved)) then
         if (tkey == trim(extra_reserved)) then
            write (*, '(a,a,a,a,a)') 'preserf: metainfo key "', &
               tkey, '" collides with the schema attribute "', &
               trim(extra_reserved), '" on this target group'
            error stop 1
         end if
      end if
   end subroutine reject_reserved_metainfo_key

   !> Read-mode counterpart to the write logic in put_typed_scalar_attr:
   !> verify that the stored attribute's value AND its
   !> `<key>__preserf_type_id` shadow tag match the runtime metainfo
   !> arguments, aborting on any mismatch (or if the attribute is absent
   !> in the store). The value comparison is bit-exact: the writer stored
   !> the same literal the generated read run re-supplies, so a round-trip
   !> of an unmodified store always matches.
   subroutine check_typed_scalar_attr(grpid, key, nc_type, tid, &
                                      i8_val, i32_val, i64_val, &
                                      r32_val, r64_val, s_val)
      integer, intent(in) :: grpid
      character(len=*), intent(in) :: key
      integer, intent(in) :: nc_type
      integer(int32), intent(in) :: tid
      integer(int8), intent(in), optional :: i8_val
      integer(int32), intent(in), optional :: i32_val
      integer(int64), intent(in), optional :: i64_val
      real(real32), intent(in), optional :: r32_val
      real(real64), intent(in), optional :: r64_val
      character(len=*), intent(in), optional :: s_val

      integer :: ncerr, slen
      integer(int32) :: stored_tid
      character(len=:), allocatable :: shadow, stored_s
      integer(int8) :: s_i8
      integer(int32) :: s_i32
      integer(int64) :: s_i64
      real(real32) :: s_r32
      real(real64) :: s_r64

      shadow = trim(key)//'__preserf_type_id'
      ncerr = nf90_get_att(grpid, NF90_GLOBAL, shadow, stored_tid)
      if (ncerr == NF90_ENOTATT) call metainfo_absent(key)
      call preserf_check_nf_with_msg(ncerr, 'get_att '//shadow)
      if (stored_tid /= tid) then
         write (*, '(a,a,a,i0,a,i0)') &
            'preserf: read-mode metainfo "', trim(key), &
            '" type-id mismatch: store has ', stored_tid, &
            ', run expects ', tid
         error stop 1
      end if

      select case (nc_type)
      case (NF90_BYTE)
         if (.not. present(i8_val)) call missing_value_arg(key, 'i8_val')
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, s_i8)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (s_i8 /= i8_val) call metainfo_value_mismatch(key)
      case (NF90_INT)
         if (.not. present(i32_val)) call missing_value_arg(key, 'i32_val')
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, s_i32)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (s_i32 /= i32_val) call metainfo_value_mismatch(key)
      case (NF90_INT64)
         if (.not. present(i64_val)) call missing_value_arg(key, 'i64_val')
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, s_i64)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (s_i64 /= i64_val) call metainfo_value_mismatch(key)
      case (NF90_FLOAT)
         if (.not. present(r32_val)) call missing_value_arg(key, 'r32_val')
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, s_r32)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (s_r32 /= r32_val) call metainfo_value_mismatch(key)
      case (NF90_DOUBLE)
         if (.not. present(r64_val)) call missing_value_arg(key, 'r64_val')
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, s_r64)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (s_r64 /= r64_val) call metainfo_value_mismatch(key)
      case (NF90_STRING)
         if (.not. present(s_val)) call missing_value_arg(key, 's_val')
         ncerr = nf90_inquire_attribute(grpid, NF90_GLOBAL, key, len=slen)
         call preserf_check_nf_with_msg(ncerr, 'inquire_attribute '//key)
         allocate (character(len=slen) :: stored_s)
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, stored_s)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (stored_s /= s_val) call metainfo_value_mismatch(key)
      case default
         write (*, '(a,i0)') 'preserf: unsupported nc_type ', nc_type
         error stop 1
      end select
   end subroutine check_typed_scalar_attr

   !> Array counterpart of put_typed_scalar_attr: write a 1D-array metainfo
   !> value as the vector attribute `<key>` plus its `<key>__preserf_type_id`
   !> shadow tag carrying the *array* TypeID (TID_ARRAY .or. base_tid). In
   !> read mode it validates the stored attribute instead of writing it.
   !> Exactly one of i8_val / i32_val / i64_val / r32_val / r64_val must be
   !> supplied, matching nc_type (the boolean path pre-converts to int8).
   subroutine put_typed_array_attr(grpid, key, nc_type, base_tid, &
                                   i8_val, i32_val, i64_val, &
                                   r32_val, r64_val, extra_reserved)
      integer, intent(in) :: grpid
      character(len=*), intent(in) :: key
      integer, intent(in) :: nc_type
      integer(int32), intent(in) :: base_tid
      integer(int8), intent(in), optional :: i8_val(:)
      integer(int32), intent(in), optional :: i32_val(:)
      integer(int64), intent(in), optional :: i64_val(:)
      real(real32), intent(in), optional :: r32_val(:)
      real(real64), intent(in), optional :: r64_val(:)
      character(len=*), intent(in), optional :: extra_reserved

      integer :: ncerr
      integer(int32) :: array_tid
      character(len=:), allocatable :: shadow

      if (serialisation_enabled == 0) return
      call reject_reserved_metainfo_key(key, extra_reserved)
      ! The array bit distinguishes a length-1 array from a scalar, so a
      ! reader keys off this shadow tag (not the on-disk shape).
      array_tid = ior(TID_ARRAY, base_tid)

      if (ppser_get_mode() /= 0) then
         call check_typed_array_attr(grpid, key, nc_type, array_tid, &
                                     i8_val, i32_val, i64_val, r32_val, r64_val)
         return
      end if

      select case (nc_type)
      case (NF90_BYTE)
         if (.not. present(i8_val)) call missing_value_arg(key, 'i8_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, i8_val)
      case (NF90_INT)
         if (.not. present(i32_val)) call missing_value_arg(key, 'i32_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, i32_val)
      case (NF90_INT64)
         if (.not. present(i64_val)) call missing_value_arg(key, 'i64_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, i64_val)
      case (NF90_FLOAT)
         if (.not. present(r32_val)) call missing_value_arg(key, 'r32_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, r32_val)
      case (NF90_DOUBLE)
         if (.not. present(r64_val)) call missing_value_arg(key, 'r64_val')
         ncerr = nf90_put_att(grpid, NF90_GLOBAL, key, r64_val)
      case default
         write (*, '(a,i0)') 'preserf: unsupported array nc_type ', nc_type
         error stop 1
      end select
      call preserf_check_nf_with_msg(ncerr, 'put_att '//key)

      shadow = trim(key)//'__preserf_type_id'
      ncerr = nf90_put_att(grpid, NF90_GLOBAL, shadow, array_tid)
      call preserf_check_nf_with_msg(ncerr, 'put_att '//shadow)
   end subroutine put_typed_array_attr

   !> Read-mode counterpart of put_typed_array_attr: verify the stored
   !> array attribute's element count, values, and `__preserf_type_id`
   !> shadow tag all match the runtime metainfo argument; abort otherwise.
   subroutine check_typed_array_attr(grpid, key, nc_type, array_tid, &
                                     i8_val, i32_val, i64_val, r32_val, r64_val)
      integer, intent(in) :: grpid
      character(len=*), intent(in) :: key
      integer, intent(in) :: nc_type
      integer(int32), intent(in) :: array_tid
      integer(int8), intent(in), optional :: i8_val(:)
      integer(int32), intent(in), optional :: i32_val(:)
      integer(int64), intent(in), optional :: i64_val(:)
      real(real32), intent(in), optional :: r32_val(:)
      real(real64), intent(in), optional :: r64_val(:)

      integer :: ncerr, alen
      integer(int32) :: stored_tid
      character(len=:), allocatable :: shadow
      integer(int8), allocatable :: b_i8(:)
      integer(int32), allocatable :: b_i32(:)
      integer(int64), allocatable :: b_i64(:)
      real(real32), allocatable :: b_r32(:)
      real(real64), allocatable :: b_r64(:)

      shadow = trim(key)//'__preserf_type_id'
      ncerr = nf90_get_att(grpid, NF90_GLOBAL, shadow, stored_tid)
      if (ncerr == NF90_ENOTATT) call metainfo_absent(key)
      call preserf_check_nf_with_msg(ncerr, 'get_att '//shadow)
      if (stored_tid /= array_tid) then
         write (*, '(a,a,a,i0,a,i0)') &
            'preserf: read-mode metainfo "', trim(key), &
            '" type-id mismatch: store has ', stored_tid, &
            ', run expects ', array_tid
         error stop 1
      end if

      ncerr = nf90_inquire_attribute(grpid, NF90_GLOBAL, key, len=alen)
      if (ncerr == NF90_ENOTATT) call metainfo_absent(key)
      call preserf_check_nf_with_msg(ncerr, 'inquire_attribute '//key)

      select case (nc_type)
      case (NF90_BYTE)
         if (.not. present(i8_val)) call missing_value_arg(key, 'i8_val')
         if (alen /= size(i8_val)) call metainfo_value_mismatch(key)
         allocate (b_i8(alen))
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, b_i8)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (any(b_i8 /= i8_val)) call metainfo_value_mismatch(key)
      case (NF90_INT)
         if (.not. present(i32_val)) call missing_value_arg(key, 'i32_val')
         if (alen /= size(i32_val)) call metainfo_value_mismatch(key)
         allocate (b_i32(alen))
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, b_i32)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (any(b_i32 /= i32_val)) call metainfo_value_mismatch(key)
      case (NF90_INT64)
         if (.not. present(i64_val)) call missing_value_arg(key, 'i64_val')
         if (alen /= size(i64_val)) call metainfo_value_mismatch(key)
         allocate (b_i64(alen))
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, b_i64)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (any(b_i64 /= i64_val)) call metainfo_value_mismatch(key)
      case (NF90_FLOAT)
         if (.not. present(r32_val)) call missing_value_arg(key, 'r32_val')
         if (alen /= size(r32_val)) call metainfo_value_mismatch(key)
         allocate (b_r32(alen))
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, b_r32)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (any(b_r32 /= r32_val)) call metainfo_value_mismatch(key)
      case (NF90_DOUBLE)
         if (.not. present(r64_val)) call missing_value_arg(key, 'r64_val')
         if (alen /= size(r64_val)) call metainfo_value_mismatch(key)
         allocate (b_r64(alen))
         ncerr = nf90_get_att(grpid, NF90_GLOBAL, key, b_r64)
         call preserf_check_nf_with_msg(ncerr, 'get_att '//key)
         if (any(b_r64 /= r64_val)) call metainfo_value_mismatch(key)
      case default
         write (*, '(a,i0)') 'preserf: unsupported array nc_type ', nc_type
         error stop 1
      end select
   end subroutine check_typed_array_attr

   subroutine metainfo_absent(key)
      character(len=*), intent(in) :: key
      write (*, '(a,a,a)') &
         'preserf: read-mode metainfo "', trim(key), &
         '" is not present in the store'
      error stop 1
   end subroutine metainfo_absent

   subroutine metainfo_value_mismatch(key)
      character(len=*), intent(in) :: key
      write (*, '(a,a,a)') &
         'preserf: read-mode metainfo "', trim(key), &
         '" value mismatch between run and store'
      error stop 1
   end subroutine metainfo_value_mismatch

   !> Read-mode counterpart to the create path in fs_register_field:
   !> resolve the existing /_fields/<fieldname> registry entry and abort
   !> if any registered property (type_id, C-order dims, or a
   !> per-direction halo) disagrees with the runtime REGISTER arguments.
   subroutine validate_registered_field(s, fieldname, type_id, dims, &
                                        iMinusHalo, iPlusHalo, &
                                        jMinusHalo, jPlusHalo, &
                                        kMinusHalo, kPlusHalo, &
                                        lMinusHalo, lPlusHalo)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: fieldname
      integer(int32), intent(in) :: type_id
      integer(int32), intent(in) :: dims(:)
      integer, intent(in) :: iMinusHalo, iPlusHalo
      integer, intent(in) :: jMinusHalo, jPlusHalo
      integer, intent(in) :: kMinusHalo, kPlusHalo
      integer, intent(in) :: lMinusHalo, lPlusHalo
      integer :: ncerr, varid, attr_len, axis
      integer(int32) :: stored_tid
      integer(int32), allocatable :: stored_dims(:)

      ncerr = nf90_inq_varid(s%fields_grpid, trim(fieldname), varid)
      if (ncerr == NF90_ENOTVAR) then
         write (*, '(a,a,a)') &
            'preserf: read-mode field "', trim(fieldname), &
            '" is not present in the store registry'
         error stop 1
      end if
      call preserf_check_nf_with_msg(ncerr, &
                                     'inq_varid /_fields/'//trim(fieldname))

      ncerr = nf90_get_att(s%fields_grpid, varid, 'type_id', stored_tid)
      call preserf_check_nf_with_msg(ncerr, 'get_att type_id')
      if (stored_tid /= type_id) then
         write (*, '(a,a,a,i0,a,i0)') &
            'preserf: read-mode field "', trim(fieldname), &
            '" type_id mismatch: store has ', stored_tid, &
            ', run expects ', type_id
         error stop 1
      end if

      ncerr = nf90_inquire_attribute(s%fields_grpid, varid, 'dims', len=attr_len)
      call preserf_check_nf_with_msg(ncerr, 'inquire_attribute dims')
      allocate (stored_dims(attr_len))
      ncerr = nf90_get_att(s%fields_grpid, varid, 'dims', stored_dims)
      call preserf_check_nf_with_msg(ncerr, 'get_att dims')
      if (attr_len /= size(dims)) then
         write (*, '(a,a,a,i0,a,i0)') &
            'preserf: read-mode field "', trim(fieldname), &
            '" dims mismatch: store rank ', attr_len, &
            ', run rank ', size(dims)
         error stop 1
      end if
      do axis = 1, attr_len
         if (stored_dims(axis) /= dims(axis)) then
            write (*, '(a,a,a)') &
               'preserf: read-mode field "', trim(fieldname), &
               '" dims mismatch with registered shape.'
            write (*, '(a,*(i0,1x))') '  store (C-order): ', stored_dims
            write (*, '(a,*(i0,1x))') '  run   (C-order): ', dims
            error stop 1
         end if
      end do

      ! Halos: the writer emits only non-zero halos (put_halo_attr skips
      ! zeros), so an absent attribute means a 0 extent.
      call validate_halo_attr(s%fields_grpid, varid, fieldname, &
                              'iminushalo', iMinusHalo)
      call validate_halo_attr(s%fields_grpid, varid, fieldname, &
                              'iplushalo', iPlusHalo)
      call validate_halo_attr(s%fields_grpid, varid, fieldname, &
                              'jminushalo', jMinusHalo)
      call validate_halo_attr(s%fields_grpid, varid, fieldname, &
                              'jplushalo', jPlusHalo)
      call validate_halo_attr(s%fields_grpid, varid, fieldname, &
                              'kminushalo', kMinusHalo)
      call validate_halo_attr(s%fields_grpid, varid, fieldname, &
                              'kplushalo', kPlusHalo)
      call validate_halo_attr(s%fields_grpid, varid, fieldname, &
                              'lminushalo', lMinusHalo)
      call validate_halo_attr(s%fields_grpid, varid, fieldname, &
                              'lplushalo', lPlusHalo)
   end subroutine validate_registered_field

   subroutine validate_halo_attr(grpid, varid, fieldname, name, expected)
      integer, intent(in) :: grpid, varid
      character(len=*), intent(in) :: fieldname, name
      integer, intent(in) :: expected
      integer :: ncerr
      integer(int32) :: stored

      ncerr = nf90_get_att(grpid, varid, name, stored)
      if (ncerr == NF90_ENOTATT) then
         stored = 0_int32
      else
         call preserf_check_nf_with_msg(ncerr, 'get_att '//name)
      end if
      if (int(stored) /= expected) then
         write (*, '(a,a,a,a,a,i0,a,i0)') &
            'preserf: read-mode field "', trim(fieldname), '" halo "', &
            trim(name), '" mismatch: store has ', int(stored), &
            ', run expects ', expected
         error stop 1
      end if
   end subroutine validate_halo_attr

   !> Validate that the runtime Fortran shape of a read or write matches
   !> the field's registered dims under `/_fields/<fieldname>` (which are
   !> stored in C-order, so we compare against `reverse(fortran_shape)`).
   !> Aborts with a clear error on type-id mismatch, shape mismatch, or
   !> on a *read* of a field that was never registered. `op` is "write"
   !> or "read" and is interpolated into error messages.
   !> On the *write* path an unknown field is auto-registered on the fly
   !> (type_id + C-order dims inferred from the runtime shape, no halos),
   !> matching Serialbox's `fs_write_field`, which registers a field on
   !> its first write — so pp_ser `!$SER DATA` call sites that never emit
   !> `!$SER REGISTER` write without an explicit registration (issue #43).
   !> When `registered_dims_out` is present it returns the registry's
   !> C-order `dims` vector this routine already fetched, so a read-path
   !> caller can hand it to `require_variable_xtype` instead of having it
   !> re-read the same attribute from the registry.
   subroutine validate_field_shape(s, fieldname, fortran_shape, &
                                   expected_tid, op, registered_dims_out)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: fieldname
      integer, intent(in) :: fortran_shape(:)
      integer(int32), intent(in) :: expected_tid
      character(len=*), intent(in) :: op
      integer(int32), allocatable, intent(out), optional :: registered_dims_out(:)
      integer :: ncerr, varid, attr_len, axis
      integer(int32), allocatable :: registered_dims(:)
      integer(int32) :: registered_tid

      ncerr = nf90_inq_varid(s%fields_grpid, trim(fieldname), varid)
      if (ncerr == NF90_ENOTVAR) then
         ! A write to a field that was never registered: auto-register it
         ! from the runtime shape + type_id (Serialbox parity, issue #43)
         ! rather than abort. A read cannot auto-register — there is no
         ! field to read — so it still aborts.
         if (trim(op) == 'write') then
            call autoregister_field(s, fieldname, fortran_shape, expected_tid)
            ! The entry we just wrote matches the runtime shape and type
            ! by construction, so hand the C-order dims back (a read never
            ! takes this branch, but keep the contract consistent) and
            ! return without re-validating.
            if (present(registered_dims_out)) &
               registered_dims_out = fortran_shape_to_c_order(fortran_shape)
            return
         end if
         write (*, '(a,a,a,a,a)') &
            'preserf: ', trim(op), ' on unregistered field "', &
            trim(fieldname), '"; call fs_register_field first'
         error stop 1
      end if
      call preserf_check_nf_with_msg(ncerr, &
                                     'inq_varid /_fields/'//trim(fieldname))

      ! Confirm the registered TypeID matches the Fortran overload's
      ! dtype. Without this check the data variable's nc_type and the
      ! registry's type_id can disagree, and Python readers (which
      ! decode through the registry) would silently cast and corrupt
      ! values. On the read side, netCDF's automatic type conversion
      ! could likewise quietly accept a wrong-typed registry.
      ncerr = nf90_get_att(s%fields_grpid, varid, 'type_id', registered_tid)
      call preserf_check_nf_with_msg(ncerr, 'get_att type_id')
      if (registered_tid /= expected_tid) then
         write (*, '(a,a,a,a,a,i0,a,i0,a)') &
            'preserf: ', trim(op), ' on field "', trim(fieldname), &
            '" via type-id=', expected_tid, &
            ' overload but the field was registered with type_id=', &
            registered_tid, '.'
         error stop 1
      end if

      ncerr = nf90_inquire_attribute(s%fields_grpid, varid, 'dims', len=attr_len)
      call preserf_check_nf_with_msg(ncerr, 'inquire_attribute dims')
      allocate (registered_dims(attr_len))
      ncerr = nf90_get_att(s%fields_grpid, varid, 'dims', registered_dims)
      call preserf_check_nf_with_msg(ncerr, 'get_att dims')

      if (size(fortran_shape) /= attr_len) then
         write (*, '(a,a,a,a,a,i0,a,i0,a)') &
            'preserf: ', trim(op), ' on field "', trim(fieldname), &
            '" has Fortran rank ', size(fortran_shape), &
            ' but was registered with C-order rank ', attr_len, '.'
         error stop 1
      end if

      ! registered_dims(i) is C-order axis (i-1); compare against
      ! reverse(fortran_shape): C-axis 0 ↔ last Fortran axis.
      do axis = 1, attr_len
         if (int(registered_dims(axis)) /= &
             fortran_shape(attr_len - axis + 1)) then
            write (*, '(a,a,a,a,a)') &
               'preserf: ', trim(op), ' on field "', &
               trim(fieldname), &
               '" runtime shape disagrees with registered dims.'
            write (*, '(a,*(i0,1x))') &
               '  registered (C-order): ', registered_dims
            write (*, '(a,*(i0,1x))') &
               '  runtime (Fortran):    ', fortran_shape
            error stop 1
         end if
      end do

      ! Hand the validated C-order dims back so the read path's
      ! require_variable_xtype need not re-read them from the registry.
      if (present(registered_dims_out)) registered_dims_out = registered_dims
   end subroutine validate_field_shape

   !> Reverse a runtime Fortran shape (fastest-varying axis first) into the
   !> netCDF C-order `dims` vector (slowest-varying axis first) that the
   !> `/_fields/<fieldname>` registry records. A rank-0 (scalar) field maps
   !> to a zero-length vector. Mirrors the column-major → C-order reversal
   !> that active_dims_c_order performs for the explicit REGISTER path.
   function fortran_shape_to_c_order(fortran_shape) result(dims)
      integer, intent(in) :: fortran_shape(:)
      integer(int32), allocatable :: dims(:)
      integer :: r, axis

      r = size(fortran_shape)
      allocate (dims(r))
      do axis = 1, r
         ! C-axis (axis-1) is the slowest-varying = last Fortran axis.
         call require_fits_int32(fortran_shape(r - axis + 1), 'field extent')
         dims(axis) = int(fortran_shape(r - axis + 1), int32)
      end do
   end function fortran_shape_to_c_order

   !> Auto-register a field under `/_fields/<fieldname>` on its first write,
   !> inferring `type_id` and the C-order `dims` from the runtime array.
   !> Serialbox's `fs_write_field` registers a field on first write, so
   !> pp_ser `!$SER DATA` / `!$SER ACCDATA` call sites (which never emit a
   !> `!$SER REGISTER`) can write without an explicit registration. This
   !> mirrors the create branch of fs_register_field, minus the halo
   !> attributes: a write site carries no halo metadata, so the inferred
   !> entry records zero halos (an absent halo attribute reads back as 0).
   !> See issue #43.
   subroutine autoregister_field(s, fieldname, fortran_shape, type_id)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: fieldname
      integer, intent(in) :: fortran_shape(:)
      integer(int32), intent(in) :: type_id
      integer :: ncerr, varid
      integer(int32) :: zero
      integer(int32), allocatable :: dims(:)

      dims = fortran_shape_to_c_order(fortran_shape)
      zero = 0_int32

      ! Create the dummy attribute-carrier scalar variable, matching the
      ! explicit-REGISTER layout (storage_mapping.md §1) so Python readers
      ! decode an auto-registered field identically to a registered one.
      ncerr = nf90_def_var(s%fields_grpid, trim(fieldname), NF90_INT, varid)
      call preserf_check_nf_with_msg(ncerr, &
                                     'def_var /_fields/'//trim(fieldname))
      ncerr = nf90_put_att(s%fields_grpid, varid, 'type_id', type_id)
      call preserf_check_nf_with_msg(ncerr, 'put_att type_id')
      ncerr = nf90_put_att(s%fields_grpid, varid, 'dims', dims)
      call preserf_check_nf_with_msg(ncerr, 'put_att dims')
      ncerr = nf90_put_var(s%fields_grpid, varid, zero)
      call preserf_check_nf_with_msg(ncerr, 'put_var (registry placeholder)')
   end subroutine autoregister_field

   !> Ensure per-field dimensions exist on `grpid` and return their dim ids.
   !> Dimensions are named `<fieldname>_dim0`, `<fieldname>_dim1`, … in
   !> netCDF C-order (slowest-varying axis first, matching how `dims` is
   !> recorded on `/_fields/<fieldname>`). The returned `dimids` are
   !> ordered in Fortran convention (fastest-varying first), so that
   !> netcdf-fortran's automatic dim reversal yields a variable layout
   !> on disk whose dimension order matches the C-order dim names.
   !> See storage_mapping.md §1.1 + §6.
   subroutine ensure_dims(grpid, fieldname, shp_fortran, dimids)
      integer, intent(in) :: grpid
      character(len=*), intent(in) :: fieldname
      integer, intent(in) :: shp_fortran(:)
      integer, allocatable, intent(out) :: dimids(:)
      integer :: r, c_axis, ncerr
      integer, allocatable :: dim_id_by_c_axis(:)
      character(len=:), allocatable :: dname
      character(len=8) :: axis_str

      r = size(shp_fortran)
      allocate (dim_id_by_c_axis(r))
      ! Create / look up dimensions named by C-order axis. C-axis 0 maps
      ! to the slowest-varying = last Fortran axis (= shp_fortran(r)).
      do c_axis = 1, r
         write (axis_str, '(i0)') c_axis - 1
         dname = trim(fieldname)//'_dim'//trim(axis_str)
         ncerr = nf90_inq_dimid(grpid, dname, dim_id_by_c_axis(c_axis))
         if (ncerr == NF90_EBADDIM) then
            ncerr = nf90_def_dim(grpid, dname, &
                                 shp_fortran(r - c_axis + 1), &
                                 dim_id_by_c_axis(c_axis))
            call preserf_check_nf_with_msg(ncerr, 'def_dim '//dname)
         else
            call preserf_check_nf_with_msg(ncerr, 'inq_dimid '//dname)
         end if
      end do

      ! Return dimids in Fortran order (fastest-varying first): netcdf-
      ! fortran reverses this when calling C, so the on-disk variable
      ! reports its dims in C-order, matching the `dims` attribute.
      allocate (dimids(r))
      do c_axis = 1, r
         dimids(r - c_axis + 1) = dim_id_by_c_axis(c_axis)
      end do
   end subroutine ensure_dims

   subroutine ensure_variable(grpid, fieldname, nc_type, dimids, varid)
      integer, intent(in) :: grpid
      character(len=*), intent(in) :: fieldname
      integer, intent(in) :: nc_type
      integer, intent(in) :: dimids(:)
      integer, intent(out) :: varid
      integer :: ncerr

      ncerr = nf90_inq_varid(grpid, trim(fieldname), varid)
      if (ncerr == NF90_ENOTVAR) then
         ncerr = nf90_def_var(grpid, trim(fieldname), nc_type, dimids, varid)
         call preserf_check_nf_with_msg(ncerr, 'def_var '//trim(fieldname))
      else
         call preserf_check_nf_with_msg(ncerr, 'inq_varid '//trim(fieldname))
      end if
   end subroutine ensure_variable

   !> Abort with a clear message if the serializer hasn't been opened.
   subroutine require_open(s, where)
      type(t_serializer), intent(in) :: s
      character(len=*), intent(in) :: where
      if (s%ncid == -1) then
         write (*, '(a,a,a)') 'preserf: ', trim(where), &
            ' called before ppser_initialize'
         error stop 1
      end if
   end subroutine require_open

   !> Abort with a clear message if the savepoint hasn't been created
   !> (or has been cleared by a no-op SAVEPOINT branch). Without this
   !> guard, passing an uninitialised `sp%grpid = -1` into netCDF calls
   !> surfaces as a low-level "NetCDF: Not a valid ID" error rather
   !> than a preserf-level lifecycle diagnostic.
   subroutine require_savepoint(sp, where)
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: where
      if (sp%grpid == -1) then
         write (*, '(a,a,a)') 'preserf: ', trim(where), &
            ' called with an uninitialised savepoint '// &
            '(call fs_create_savepoint first)'
         error stop 1
      end if
   end subroutine require_savepoint

   !> Abort if `sp` was created by a serializer other than `s`.
   !> fs_write_field validates the field registry through
   !> `s%fields_grpid` but creates / writes the data variable under
   !> `sp%grpid`. If the savepoint belongs to a different store the
   !> registry and the data variable would land in different files,
   !> silently producing an internally inconsistent output. The
   !> writable serializer is unique per session, so a mismatch always
   !> signals a caller bug rather than a supported cross-store flow.
   subroutine require_savepoint_owner(s, sp, where)
      type(t_serializer), intent(in) :: s
      type(t_savepoint), intent(in) :: sp
      character(len=*), intent(in) :: where
      if (sp%owner_ncid /= s%ncid) then
         write (*, '(a,a,a)') 'preserf: ', trim(where), &
            ' was passed a savepoint created by a different '// &
            'serializer; the field registry and the data variable '// &
            'would belong to different stores'
         error stop 1
      end if
   end subroutine require_savepoint_owner

   !> Resolve the netCDF group id to read a savepoint's field from under
   !> serializer `s`. pp_ser emits read DATA blocks as
   !> `fs_read_field(ppser_serializer_ref, ppser_savepoint, ...)` while
   !> SAVEPOINT resolves `ppser_savepoint` against `ppser_serializer`.
   !> With an explicit reference store the savepoint's grpid belongs to
   !> the primary open, so re-resolve sp_NNNNNN under `s` from the
   !> savepoint index — otherwise the read would validate against the
   !> reference's registry but pull data from the primary file. When the
   !> savepoint already belongs to `s`, use its grpid directly.
   function resolve_savepoint_grpid(s, sp) result(grpid)
      type(t_serializer), intent(in) :: s
      type(t_savepoint), intent(in) :: sp
      integer :: grpid, ncerr
      character(len=9) :: group_name

      if (sp%owner_ncid == s%ncid) then
         grpid = sp%grpid
         return
      end if
      write (group_name, '("sp_",i6.6)') sp%idx
      ncerr = nf90_inq_ncid(s%savepoints_grpid, group_name, grpid)
      call preserf_check_nf_with_msg(ncerr, &
                                     'inq_ncid '//group_name//' (reference store)')
   end function resolve_savepoint_grpid

   !> Confirm the on-disk netCDF variable matches what the Fortran
   !> read overload + the `/_fields/<name>` registry entry expect:
   !> both the variable's `xtype` AND its actual dimension lengths.
   !>
   !> `validate_field_shape` already checks the registry's `type_id`
   !> and `dims` against the caller's runtime shape; this helper
   !> additionally cross-checks the *savepoint variable* on disk
   !> against the same registry, so a store whose registry and
   !> variable disagree (e.g. mutated by a third-party tool) is
   !> rejected up-front instead of being silently coerced by
   !> nf90_get_var or hitting a low-level netCDF error mid-read.
   !> `known_dims_c`, when present, is the registry's C-order `dims`
   !> vector already fetched by `validate_field_shape` on this same read;
   !> passing it avoids re-reading the identical attribute from the
   !> registry. When absent the dims are fetched here (e.g. for callers
   !> that did not run validate_field_shape first).
   subroutine require_variable_xtype(s, sp_grpid, varid, fieldname, &
                                     expected_xtype, known_dims_c)
      type(t_serializer), intent(in) :: s
      integer, intent(in) :: sp_grpid, varid
      character(len=*), intent(in) :: fieldname
      integer, intent(in) :: expected_xtype
      integer(int32), intent(in), optional :: known_dims_c(:)
      integer :: ncerr, actual_xtype, actual_ndims, axis, registry_varid, &
                 attr_len
      integer(int32), allocatable :: expected_dims_c(:)
      integer, allocatable :: dimids(:)
      integer :: actual_len

      ! Reuse the registry `dims` validate_field_shape already fetched on
      ! this read; only fall back to re-reading them when not supplied.
      if (present(known_dims_c)) then
         expected_dims_c = known_dims_c
      else
         ncerr = nf90_inq_varid(s%fields_grpid, trim(fieldname), registry_varid)
         call preserf_check_nf_with_msg(ncerr, &
                                        'inq_varid /_fields/'//trim(fieldname))
         ncerr = nf90_inquire_attribute(s%fields_grpid, registry_varid, 'dims', &
                                        len=attr_len)
         call preserf_check_nf_with_msg(ncerr, &
                                        'inquire_attribute dims (for variable check)')
         allocate (expected_dims_c(attr_len))
         ncerr = nf90_get_att(s%fields_grpid, registry_varid, 'dims', &
                              expected_dims_c)
         call preserf_check_nf_with_msg(ncerr, 'get_att dims (for variable check)')
      end if

      ncerr = nf90_inquire_variable(sp_grpid, varid, xtype=actual_xtype, &
                                    ndims=actual_ndims)
      call preserf_check_nf_with_msg(ncerr, &
                                     'inquire_variable '//trim(fieldname))
      if (actual_xtype /= expected_xtype) then
         write (*, '(a,a,a,i0,a,i0,a)') &
            'preserf: read of field "', trim(fieldname), &
            '" expects on-disk nc_type ', expected_xtype, &
            ' but the variable has nc_type ', actual_xtype, &
            '. Registry / variable mismatch in the store.'
         error stop 1
      end if
      if (actual_ndims /= size(expected_dims_c)) then
         write (*, '(a,a,a,i0,a,i0,a)') &
            'preserf: read of field "', trim(fieldname), &
            '" expects rank ', size(expected_dims_c), &
            ' but the on-disk variable has rank ', actual_ndims, '.'
         error stop 1
      end if
      if (actual_ndims > 0) then
         allocate (dimids(actual_ndims))
         ncerr = nf90_inquire_variable(sp_grpid, varid, dimids=dimids)
         call preserf_check_nf_with_msg(ncerr, &
                                        'inquire_variable dimids '//trim(fieldname))
         ! netcdf-fortran returns dimids in Fortran order
         ! (fastest-varying first). The expected_dims_c vector is
         ! C-order (slowest-first), so we compare dimids(k) against
         ! expected_dims_c(rank - k + 1).
         do axis = 1, actual_ndims
            ncerr = nf90_inquire_dimension(sp_grpid, dimids(axis), &
                                           len=actual_len)
            call preserf_check_nf_with_msg(ncerr, &
                                           'inquire_dimension '//trim(fieldname))
            if (actual_len /= &
                int(expected_dims_c(actual_ndims - axis + 1))) then
               write (*, '(a,a,a)') &
                  'preserf: read of field "', trim(fieldname), &
                  '" on-disk variable dimension lengths disagree '// &
                  'with registry dims.'
               write (*, '(a,*(i0,1x))') &
                  '  registered (C-order):    ', expected_dims_c
               write (*, '(a,*(i0,1x))') &
                  '  variable axis (Fortran): ', axis, actual_len
               error stop 1
            end if
         end do
         deallocate (dimids)
      end if
   end subroutine require_variable_xtype

   pure function to_lower(s) result(r)
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
   end function to_lower

end module m_preserf
