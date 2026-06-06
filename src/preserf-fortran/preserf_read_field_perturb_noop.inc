! Template body for a 5-argument fs_read_field overload for non-floating
! dtypes (integer and logical). The read-perturb CASE(2) form in pp_ser
! emits the same 5-arg call shape for every type including integer and
! logical (see issue #39 and mo_ser_common.f90 examples). Perturbation is
! meaningless for these types, so the overload reads the field via its
! 4-arg sibling PRESERF_BASE and silently ignores `perturb`.
!
! The `perturb` argument must still be declared real(real64) to match the
! call shape pp_ser emits (ppser_zrperturb is real64 regardless of the
! field kind). Instantiated for integer (int32/int64) and logical x ranks
! 0-4 from m_preserf.F90.
subroutine PRESERF_SUB(s, sp, fieldname, data, perturb)
   type(t_serializer), intent(in) :: s
   type(t_savepoint), intent(in) :: sp
   character(len=*), intent(in) :: fieldname
   PRESERF_DTYPE, intent(inout) PRESERF_DIMS :: data
   real(real64), intent(in) :: perturb
   real(real64) :: unused_perturb
   if (serialisation_enabled == 0) return
   call PRESERF_BASE(s, sp, fieldname, data)
   ! `perturb` is accepted to match pp_ser's 5-arg call shape but is
   ! meaningless for non-float types and is intentionally ignored here.
   ! The unreachable read into a discard local is a zero-cost reference
   ! that silences the compiler's unused-dummy-argument check (same
   ! `if (.false.) ...` idiom as `version` in preserf_open_serializer in
   ! utils_preserf.f90; perturb is intent(in) so it is only read here).
   if (.false.) unused_perturb = perturb
end subroutine PRESERF_SUB
