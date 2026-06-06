"""Cross-language wire-compat: Fortran writes, Python reads.

This test runs the ``preserf_fortran_test_minimal`` binary built from
``tests-fortran/unit/m_preserf/test_minimal.f90`` and validates the
resulting store via ``tests/_support/storage.py``. If the Fortran library
hasn't been built the test is skipped by default — the Fortran build is
intentionally not part of ``pixi run test-py`` so the default Python
test loop stays fast (sub-second) and doesn't reconfigure / rebuild
``build/preserf-fortran/`` on every run.

To build the binary locally::

    pixi run build-fortran

Then ``pixi run test-py`` (or ``pixi run test-py-integration``) will pick
it up. For a single command that serializes build → pytest and treats a
missing binary as a hard failure rather than a skip, use
``pixi run test-py-with-fortran`` (which sets ``PRESERF_REQUIRE_FORTRAN=1``
and depends on ``test-fortran``). ``pixi run verify`` and
``pixi run test-all`` both go through that strict path, so the verify
gate fails (instead of skipping) when the Fortran binary is missing
or broken.

In CI (and any environment that should treat a missing binary as a
regression rather than a skip), set ``PRESERF_REQUIRE_FORTRAN=1`` — the
``fortran_binary`` fixture (defined in ``tests/conftest.py``) then fails
the test instead of skipping it.
"""

from __future__ import annotations

import subprocess
from typing import TYPE_CHECKING

import numpy as np
import pytest

from tests._support.serialbox import TypeID, numpy_dtype_for
from tests._support.storage import open_url_for, read_dump
from tests.conftest import _require_binary

if TYPE_CHECKING:
    from pathlib import Path


def test_fortran_writes_python_reads(tmp_path: Path, fortran_binary: Path) -> None:
    """The Fortran helper writes a store the Python reader can decode."""
    out_dir = tmp_path / "fortran_out"
    out_dir.mkdir()

    # The Fortran test is expected to complete in well under a second;
    # the 60-second cap is generous but stops a deadlock from hanging
    # CI / local runs indefinitely.
    result = subprocess.run(
        [str(fortran_binary), str(out_dir)],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"Fortran binary exited {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "preserf-fortran: hello-world OK" in result.stdout

    nc_path = out_dir / "fhello.nc"

    # Direct attribute checks on the raw netCDF root. read_dump() skips
    # housekeeping attributes (those starting with `_preserf_`), so a
    # bug in the Fortran writer for `_preserf_writer` or the close-time
    # `_preserf_savepoint_count` refresh wouldn't surface through the
    # SerialboxDump-shaped assertions below.
    import netCDF4  # local import; netCDF4 is a dev-only dependency

    raw = netCDF4.Dataset(str(nc_path), "r")
    try:
        # Root housekeeping attributes + their on-disk netCDF types.
        # `_preserf_schema_version` and `_preserf_savepoint_count` must
        # be 32-bit ints (NC_INT) regardless of the Fortran default
        # integer kind; the writer casts to integer(int32) explicitly.
        # netCDF4-python doesn't expose attribute nc_type directly,
        # but `getncattr` returns numpy scalars whose dtype reflects
        # the on-disk type for non-string attrs (np.int32 ↔ NC_INT,
        # np.int64 ↔ NC_INT64, np.int8 ↔ NC_BYTE, etc.).
        v = raw.getncattr("_preserf_schema_version")
        assert v == 1 and v.dtype == np.dtype("int32"), (
            f"_preserf_schema_version on disk is {v.dtype}, expected int32"
        )
        assert raw.getncattr("_preserf_serialbox_prefix") == "fhello"
        # _preserf_savepoint_count is refreshed in preserf_close_serializer;
        # the test writes exactly one savepoint and expects that to be
        # reflected. Must also be NC_INT (int32) so cross-language
        # readers don't see a different type from a Python-written store.
        cnt = raw.getncattr("_preserf_savepoint_count")
        assert cnt == 1 and cnt.dtype == np.dtype("int32")
        writer = raw.getncattr("_preserf_writer")
        assert isinstance(writer, str) and writer.startswith("preserf ")

        # Wire-level on-disk type assertions for the metainfo overloads.
        # `read_dump()` decodes via the __preserf_type_id shadow tag and
        # casts to the registry dtype, so a wrong on-disk type would
        # still survive that path. The direct dtype check below catches
        # regressions in the kind-specific nf90_put_att branches.
        assert raw.getncattr("use_gpu").dtype == np.dtype("int8"), (
            "use_gpu must be NF90_BYTE (int8)"
        )
        assert raw.getncattr("schema_version").dtype == np.dtype("int32"), (
            "schema_version must be NF90_INT (int32)"
        )
        assert raw.getncattr("wallclock_ns").dtype == np.dtype("int64"), (
            "wallclock_ns must be NF90_INT64 (int64)"
        )
        assert raw.getncattr("tolerance32").dtype == np.dtype("float32"), (
            "tolerance32 must be NF90_FLOAT (float32)"
        )

        # /_fields registry variables: type_id + dims attributes on the
        # dummy scalar carrier. Also verify the registry variable
        # itself is NC_INT (the schema's "dummy scalar" sentinel).
        fields_grp = raw.groups["_fields"]
        for fname in ("u", "v", "w"):
            assert fields_grp.variables[fname].dtype == np.dtype("int32"), (
                f"/_fields/{fname} carrier must be NF90_INT"
            )
            assert fields_grp.variables[fname].getncattr("type_id") == 5
        # `/_tracers` is created lazily (ADR 0003 §1): this hello-world store
        # registers no tracer, so the group must be absent — not present-and-
        # empty.
        assert "_tracers" not in raw.groups, (
            "field-only store must not carry an empty /_tracers group"
        )
        # ON / OFF gate must have produced no side effects: the
        # fs_register_field call inside the disabled window targeted
        # `disabled_field` and the fs_add_serializer_metainfo call
        # targeted `disabled_meta`. Neither should appear on disk.
        assert "disabled_field" not in fields_grp.variables, (
            "fs_register_field was not a no-op while serialization was "
            "disabled (`disabled_field` leaked into /_fields)"
        )
        assert "disabled_meta" not in raw.ncattrs(), (
            "fs_add_serializer_metainfo was not a no-op while "
            "serialization was disabled (`disabled_meta` leaked onto root)"
        )
        # Halo round-trip for `u` (jSize halos = 3 and 4 etc.); confirms
        # put_halo_attr actually wrote them.
        u_reg = fields_grp.variables["u"]
        assert int(u_reg.getncattr("iminushalo")) == 1
        assert int(u_reg.getncattr("iplushalo")) == 2
        assert int(u_reg.getncattr("jminushalo")) == 3
        assert int(u_reg.getncattr("jplushalo")) == 4
        # kminushalo is 0 → should NOT be present (storage_mapping.md §4
        # specifies halos are optional and only emitted when non-zero).
        assert "kminushalo" not in u_reg.ncattrs()
        assert int(u_reg.getncattr("kplushalo")) == 5

        # /savepoints/sp_000000 housekeeping: _preserf_savepoint_index
        # is read by read_dump() but discarded, so test it here directly.
        sp_grp = raw.groups["savepoints"].groups["sp_000000"]
        assert int(sp_grp.getncattr("_preserf_savepoint_index")) == 0

        # ON / OFF gate must also cover the DATA path: test_minimal.f90
        # attempts an fs_write_field of a -999.0 sentinel into the
        # already-written `u` variable while serialization is disabled.
        # None of u's cells may carry that sentinel — if any do, the
        # `serialisation_enabled` early return regressed out of
        # fs_write_field.
        u_disk = np.asarray(sp_grp.variables["u"][...])
        assert not np.any(u_disk == -999.0), (
            "fs_write_field was not a no-op while serialization was "
            "disabled (`u` was overwritten with the -999.0 sentinel)"
        )

        # Per-savepoint field variable types: each `u`/`v`/`w` data
        # variable must be on-disk NF90_DOUBLE.
        for fname in ("u", "v", "w"):
            assert sp_grp.variables[fname].dtype == np.dtype("float64"), (
                f"savepoint/{fname} variable must be NF90_DOUBLE"
            )
    finally:
        raw.close()

    dump = read_dump(str(nc_path))

    # Prefix and writer attribute
    assert dump.prefix == "fhello"

    # Global metainfo written via fs_add_serializer_metainfo
    assert "author" in dump.global_meta_info
    assert dump.global_meta_info["author"].type_id == TypeID.String
    assert dump.global_meta_info["author"].value == "fortran-test"
    assert dump.global_meta_info["schema_version"].type_id == TypeID.Int32
    assert dump.global_meta_info["schema_version"].value == 7
    # use_gpu exercises the Boolean → NF90_BYTE path. The shadow tag
    # carries TypeID.Boolean (=1), and the underlying value round-trips.
    assert dump.global_meta_info["use_gpu"].type_id == TypeID.Boolean
    assert dump.global_meta_info["use_gpu"].value is True
    # Int64 and Float32 metainfo branches.
    assert dump.global_meta_info["wallclock_ns"].type_id == TypeID.Int64
    assert dump.global_meta_info["wallclock_ns"].value == 1_700_000_000_000_000_000
    assert dump.global_meta_info["tolerance32"].type_id == TypeID.Float32
    assert dump.global_meta_info["tolerance32"].value == pytest.approx(1e-3, rel=1e-6)

    # Field registry: three fields covering all three real64 overloads.
    # The helper reverses Fortran-order sizes to C-order, so:
    #   u (Fortran iSize=4, jSize=3, kSize=2) → dims == [2, 3, 4]
    #   v (1-D, iSize=5)                       → dims == [5]
    #   w (2-D, iSize=3, jSize=4)              → dims == [4, 3]
    assert set(dump.field_map.keys()) == {"u", "v", "w"}
    assert dump.field_map["u"].type_id == TypeID.Float64
    assert dump.field_map["u"].dims == [2, 3, 4]
    assert dump.field_map["v"].type_id == TypeID.Float64
    assert dump.field_map["v"].dims == [5]
    assert dump.field_map["w"].type_id == TypeID.Float64
    assert dump.field_map["w"].dims == [4, 3]

    # One savepoint named "step" with two metainfo entries and three fields.
    assert len(dump.savepoints) == 1
    sp = dump.savepoints[0]
    assert sp.name == "step"
    assert sp.meta_info["ntstep"].type_id == TypeID.Int32
    assert sp.meta_info["ntstep"].value == 1
    assert sp.meta_info["t"].type_id == TypeID.Float64
    assert sp.meta_info["t"].value == 0.5
    assert set(sp.fields.keys()) == {"u", "v", "w"}

    # 3-D field round-trip. Fortran u(i,j,k) = 100*i + 10*j + k.
    # After axis reversal the Python view has shape (nk, nj, ni) =
    # (2, 3, 4), and Fortran's u(i,j,k) lands at numpy u_py[k-1, j-1, i-1].
    u_py = dump.field_data["u"][0]
    assert u_py.shape == (2, 3, 4)
    assert u_py.dtype == np.float64
    assert u_py[0, 0, 0] == 111  # Fortran u(1,1,1)
    assert u_py[0, 0, 3] == 411  # Fortran u(4,1,1)
    assert u_py[0, 2, 0] == 131  # Fortran u(1,3,1)
    assert u_py[1, 0, 0] == 112  # Fortran u(1,1,2)
    assert u_py[1, 2, 3] == 432  # Fortran u(4,3,2)

    # 1-D field round-trip. v is rank-1 so the C-order/Fortran-order
    # reversal is a no-op.
    v_py = dump.field_data["v"][0]
    assert v_py.shape == (5,)
    assert v_py.dtype == np.float64
    np.testing.assert_array_equal(v_py, np.arange(1, 6, dtype=np.float64))

    # 2-D field round-trip. Fortran w(i,j) = 10*i + j, registered as
    # iSize=3, jSize=4. C-order shape is (4, 3) and Fortran w(i,j)
    # lands at numpy w_py[j-1, i-1].
    w_py = dump.field_data["w"][0]
    assert w_py.shape == (4, 3)
    assert w_py.dtype == np.float64
    assert w_py[0, 0] == 11  # Fortran w(1,1)
    assert w_py[0, 2] == 31  # Fortran w(3,1)
    assert w_py[3, 0] == 14  # Fortran w(1,4)
    assert w_py[3, 2] == 34  # Fortran w(3,4)


def test_fortran_writes_nczarr_v2_python_reads(
    tmp_path: Path, fortran_binary: Path
) -> None:
    """The Fortran helper can emit an NCZarr V2 store the Python reader decodes.

    Slice E: with ``backend='nczarr-v2'`` the helper writes a ``.zarr``
    directory store (via a ``file://...#mode=nczarr,zarr2`` URL onto
    netcdf-c's NCZarr backend) using the same group-per-savepoint schema
    as NetCDF4. This proves a Fortran-written NCZarr V2 store decodes
    through the same Python reference reader, using the identical URL form
    (:func:`open_url_for`) so writer and reader stay in lockstep. The
    ``backend-nczarr`` scenario in ``test_minimal.f90`` writes the store.
    """
    out_dir = tmp_path / "fortran_out"
    out_dir.mkdir()

    result = subprocess.run(
        [str(fortran_binary), str(out_dir), "backend-nczarr"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"Fortran binary exited {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "preserf-fortran: backend-nczarr OK" in result.stdout

    # NCZarr V2 produces a `.zarr` directory store, not a `.nc` file.
    store_dir = out_dir / "fzarr.zarr"
    assert store_dir.is_dir(), (
        "backend='nczarr-v2' should produce a .zarr directory store, but "
        f"{store_dir} is not a directory"
    )

    # Decode through the Python reference reader using the same URL form
    # the Fortran writer used; open_url_for keeps the two in lockstep.
    url, _fmt = open_url_for(out_dir, "fzarr", "nczarr-v2")
    dump = read_dump(url)

    assert dump.prefix == "fzarr"
    assert dump.global_meta_info["author"].type_id == TypeID.String
    assert dump.global_meta_info["author"].value == "fortran-test"

    assert set(dump.field_map.keys()) == {"u"}
    assert dump.field_map["u"].type_id == TypeID.Float64
    assert dump.field_map["u"].dims == [3]

    assert len(dump.savepoints) == 1
    sp = dump.savepoints[0]
    assert sp.name == "step"
    assert sp.meta_info["ntstep"].type_id == TypeID.Int32
    assert sp.meta_info["ntstep"].value == 1

    u_py = dump.field_data["u"][0]
    assert u_py.dtype == np.float64
    np.testing.assert_array_equal(
        u_py, np.array([501.0, 502.0, 503.0], dtype=np.float64)
    )


def test_fortran_autoregistered_fields_python_reads(
    tmp_path: Path, fortran_binary: Path
) -> None:
    """Issue #43: a write with no prior REGISTER auto-registers the field.

    Serialbox's ``fs_write_field`` registers a field (type + dims, inferred
    from the array) on its first write, so pp_ser ``!$SER DATA`` /
    ``!$SER ACCDATA`` call sites that never emit ``!$SER REGISTER`` write
    without an explicit registration. The ``autoregister`` scenario in
    ``test_minimal.f90`` writes representative dtypes / ranks with no
    ``fs_register_field`` call. This decodes the resulting store through the
    Python reference reader and asserts the auto-registered ``type_id`` /
    ``dims`` and the field values — proving the inferred registry entry is
    well-formed for the cross-language reader, not just for Fortran reads.
    """
    out_dir = tmp_path / "fortran_out"
    out_dir.mkdir()

    result = subprocess.run(
        [str(fortran_binary), str(out_dir), "autoregister"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"Fortran binary exited {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "preserf-fortran: autoregister OK" in result.stdout

    dump = read_dump(out_dir / "fauto.nc")

    # Every field was auto-registered on first write — no REGISTER call
    # appears in the scenario, yet the registry must carry the inferred
    # type_id and C-order dims for each.
    assert dump.field_map["r8f"].type_id == TypeID.Float64
    assert dump.field_map["r8f"].dims == [3]
    assert dump.field_map["i4f"].type_id == TypeID.Int32
    # 2-D Fortran (2,3) -> C-order dims [3, 2].
    assert dump.field_map["i4f"].dims == [3, 2]
    assert dump.field_map["lf"].type_id == TypeID.Boolean
    assert dump.field_map["lf"].dims == [4]
    assert dump.field_map["sc"].type_id == TypeID.Int32
    assert dump.field_map["sc"].dims == []
    assert dump.field_map["a4"].type_id == TypeID.Float32
    assert dump.field_map["a4"].dims == [2, 2, 2, 2]

    # Values round-trip through the Python reader at the single savepoint.
    # field_data is keyed by per-field id; resolve each via the savepoint's
    # field map rather than assuming a particular id assignment order.
    sp = dump.savepoints[0]
    np.testing.assert_array_equal(
        dump.field_data["r8f"][sp.fields["r8f"]],
        np.array([1.25, 2.25, 3.25], dtype=np.float64),
    )
    np.testing.assert_array_equal(
        dump.field_data["lf"][sp.fields["lf"]],
        np.array([True, False, False, True]),
    )
    assert int(dump.field_data["sc"][sp.fields["sc"]]) == 4242


def test_fortran_writes_tracers_python_reads(
    tmp_path: Path, fortran_binary: Path
) -> None:
    """Slice C Phase 1: Fortran tracer writes round-trip through Python.

    The ``tracers`` scenario registers three real64 tracers (rank 1/2/3),
    writes their ``/_tracers`` descriptors via ``fs_RegisterAllTracers``,
    and exercises every TRACER write entry point across five savepoints
    (see ``test_minimal.f90``). This asserts the descriptors, the
    per-savepoint data placement for each entry point, the optional
    ``timelevel`` attribute, and axis-order — all decoded through the
    Python reference reader (ADR 0003 / storage_mapping.md §4a).
    """
    out_dir = tmp_path / "fortran_out"
    out_dir.mkdir()

    result = subprocess.run(
        [str(fortran_binary), str(out_dir), "tracers"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"Fortran binary exited {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "preserf-fortran: tracers OK" in result.stdout

    nc_path = out_dir / "ftracers.nc"

    # Direct netCDF checks: read_dump() folds the descriptor attributes
    # into its model, so assert the raw on-disk shape here — the /_tracers
    # group is a sibling of /_fields, and the timelevel lands as an
    # attribute on the savepoint data variable.
    import netCDF4  # local import; netCDF4 is a dev-only dependency

    raw = netCDF4.Dataset(str(nc_path), "r")
    try:
        assert "_tracers" in raw.groups, "store is missing the /_tracers group"
        tracers_grp = raw.groups["_tracers"]
        assert set(tracers_grp.variables) == {"q_v", "q_c", "q_r"}
        # Carrier is the NF90_INT dummy scalar, like /_fields entries.
        assert tracers_grp.variables["q_v"].dtype == np.dtype("int32")
        assert int(tracers_grp.variables["q_v"].getncattr("tracer_index")) == 1
        assert int(tracers_grp.variables["q_c"].getncattr("tracer_index")) == 2
        assert int(tracers_grp.variables["q_r"].getncattr("tracer_index")) == 3
        # timelevel attribute is present only where a @timelevel was given
        # (sp_byname's q_v, value 2) and must be NF90_INT (int32).
        sp0 = raw.groups["savepoints"].groups["sp_000000"]
        tl = sp0.variables["q_v"].getncattr("timelevel")
        assert tl == 2 and tl.dtype == np.dtype("int32")
        # by_idx(2) at sp_000001 wrote only q_c, with no timelevel.
        sp1 = raw.groups["savepoints"].groups["sp_000001"]
        assert set(sp1.variables) == {"q_c"}
        assert "timelevel" not in sp1.variables["q_c"].ncattrs()
        # Tracer data variables are NF90_DOUBLE, like DATA fields.
        assert sp0.variables["q_v"].dtype == np.dtype("float64")
    finally:
        raw.close()

    dump = read_dump(str(nc_path))

    # Descriptors: type_id, C-order dims, stype, tracer_index.
    assert set(dump.tracer_map) == {"q_v", "q_c", "q_r"}
    assert dump.tracer_map["q_v"].type_id == TypeID.Float64
    assert dump.tracer_map["q_v"].dims == [3]
    assert dump.tracer_map["q_c"].dims == [3, 2]  # Fortran (2,3) -> C-order
    assert dump.tracer_map["q_r"].dims == [2, 2, 2]
    assert dump.tracer_stype == {"q_v": "tens", "q_c": "bd", "q_r": ""}
    assert dump.tracer_index == {"q_v": 1, "q_c": 2, "q_r": 3}

    # Five savepoints in write order.
    assert [sp.name for sp in dump.savepoints] == [
        "sp_byname",
        "sp_byidx",
        "sp_byrange",
        "sp_all",
        "sp_tens",
    ]
    # Tracer data is NOT mixed into the field channel.
    assert dump.field_data == {}

    # Entry-point placement, keyed by savepoint index:
    #   0 by_name('q_v')      -> only q_v
    #   1 by_idx(2)           -> only q_c
    #   2 by_idx(1, 3)        -> all three
    #   3 all()               -> all three
    #   4 all(stype='tens')   -> only q_v (the only 'tens' tracer)
    assert sorted(dump.tracer_data["q_v"]) == [0, 2, 3, 4]
    assert sorted(dump.tracer_data["q_c"]) == [1, 2, 3]
    assert sorted(dump.tracer_data["q_r"]) == [2, 3]

    # timelevel: only the by_name write at sp 0 carried one (=2).
    assert dump.tracer_timelevel["q_v"][0] == 2
    assert dump.tracer_timelevel["q_v"][2] is None
    assert dump.tracer_timelevel["q_c"][1] is None

    # Value + axis-order round-trip. q_v is rank-1 (no reversal); q_c and
    # q_r reverse Fortran (i,j[,k]) -> numpy [.. ,j-1,i-1].
    np.testing.assert_array_equal(
        dump.tracer_data["q_v"][0], np.array([11.0, 12.0, 13.0])
    )
    qc = dump.tracer_data["q_c"][1]  # Fortran qc(i,j) = 100*i + j
    assert qc.shape == (3, 2)
    assert qc[0, 0] == 101  # qc(1,1)
    assert qc[0, 1] == 201  # qc(2,1)
    assert qc[2, 1] == 203  # qc(2,3)
    qr = dump.tracer_data["q_r"][2]  # Fortran qr(i,j,k) = 100*i + 10*j + k
    assert qr.shape == (2, 2, 2)
    assert qr[0, 0, 0] == 111  # qr(1,1,1)
    assert qr[1, 1, 1] == 222  # qr(2,2,2)


def test_fortran_tracer_timelevel_last_write_wins(
    tmp_path: Path, fortran_binary: Path
) -> None:
    """A later tracer write that omits @timelevel clears an earlier one.

    The ``tracer-tl-overwrite`` scenario writes q_v twice at one savepoint —
    first ``timelevel=2`` then with no timelevel. Per ADR 0003 §2 (last write
    wins), the on-disk variable must carry no ``timelevel`` attribute.
    """
    out_dir = tmp_path / "fortran_out"
    out_dir.mkdir()

    result = subprocess.run(
        [str(fortran_binary), str(out_dir), "tracer-tl-overwrite"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"Fortran binary exited {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "preserf-fortran: tracer-tl-overwrite OK" in result.stdout

    import netCDF4  # local import; netCDF4 is a dev-only dependency

    raw = netCDF4.Dataset(str(out_dir / "ftltl.nc"), "r")
    try:
        q_v = raw.groups["savepoints"].groups["sp_000000"].variables["q_v"]
        assert "timelevel" not in q_v.ncattrs(), (
            "a final tracer write without @timelevel must clear the attribute "
            "left by an earlier write (last-write-wins)"
        )
        np.testing.assert_array_equal(np.asarray(q_v[...]), np.array([1.0, 2.0, 3.0]))
    finally:
        raw.close()


def test_fortran_writes_kbuff_python_reads(
    tmp_path: Path, fortran_binary: Path
) -> None:
    """Slice C Phase 2: DATA_KBUFF assembled fields round-trip through Python.

    The ``kbuff`` scenario writes two fields one vertical level at a time
    via ``fs_write_kbuff`` — a 3-D ``t(i,j,k)`` from 2-D slices and a 2-D
    ``c(i,k)`` from 1-D slices. The helper buffers each slice and flushes
    the full field on the last level, producing an on-disk variable
    identical to a ``!$SER DATA`` write (ADR 0003 §5, storage_mapping §6).
    This asserts the assembled fields match the per-level accumulation.
    """
    out_dir = tmp_path / "fortran_out"
    out_dir.mkdir()

    result = subprocess.run(
        [str(fortran_binary), str(out_dir), "kbuff"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"Fortran binary exited {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "preserf-fortran: kbuff OK" in result.stdout

    nc_path = out_dir / "fkbuff.nc"
    dump = read_dump(str(nc_path))

    # The k-buffered fields register and land exactly like DATA fields:
    #   t: Fortran (ni=3, nj=2, ke=4) -> C-order dims [4, 2, 3]
    #   c: Fortran (ni=3, ke=4)       -> C-order dims [4, 3]
    assert set(dump.field_map) == {"t", "c"}
    assert dump.field_map["t"].type_id == TypeID.Float64
    assert dump.field_map["t"].dims == [4, 2, 3]
    assert dump.field_map["c"].dims == [4, 3]
    assert len(dump.savepoints) == 1

    # Assembled values: the scenario fills t(i,j,k) = 100i + 10j + k from
    # 2-D slices and c(i,k) = 10i + k from 1-D slices, one level per call.
    # preserf reverses axes on disk, so numpy sees t[k-1, j-1, i-1].
    t = dump.field_data["t"][0]
    c = dump.field_data["c"][0]
    assert t.shape == (4, 2, 3)
    assert c.shape == (4, 3)
    expected_t = np.array(
        [
            [[100 * i + 10 * j + k for i in range(1, 4)] for j in range(1, 3)]
            for k in range(1, 5)
        ],
        dtype=np.float64,
    )
    expected_c = np.array(
        [[10 * i + k for i in range(1, 4)] for k in range(1, 5)], dtype=np.float64
    )
    np.testing.assert_array_equal(t, expected_t)
    np.testing.assert_array_equal(c, expected_c)


def test_fortran_writes_option_python_reads(
    tmp_path: Path, fortran_binary: Path
) -> None:
    """Slice C Phase 3: an OPTION value round-trips through Python.

    The ``option`` scenario calls ``fs_Option(verbosity=2)`` on a writable
    store; the helper records it as the reserved root attribute
    ``_preserf_option_verbosity`` (ADR 0003 §4, storage_mapping §4b). This
    asserts the value is decoded by the Python reference reader.
    """
    out_dir = tmp_path / "fortran_out"
    out_dir.mkdir()

    result = subprocess.run(
        [str(fortran_binary), str(out_dir), "option"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"Fortran binary exited {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "preserf-fortran: option OK" in result.stdout

    nc_path = out_dir / "foption.nc"

    # The option lands in the reserved `_preserf_*` namespace as NF90_INT.
    import netCDF4  # local import; netCDF4 is a dev-only dependency

    raw = netCDF4.Dataset(str(nc_path), "r")
    try:
        v = raw.getncattr("_preserf_option_verbosity")
        assert v == 2 and v.dtype == np.dtype("int32"), (
            f"_preserf_option_verbosity on disk is {v.dtype}, expected int32"
        )
    finally:
        raw.close()

    dump = read_dump(str(nc_path))
    assert dump.option_verbosity == 2


def test_fortran_bad_reference_path_keeps_target(
    tmp_path: Path, fortran_binary: Path
) -> None:
    """A bad ``directory_ref`` aborts without truncating the target.

    ``ppser_initialize`` opens an explicit ``directory_ref`` reference
    store *before* creating the writable main store, so a missing
    reference path must fail cleanly without truncating (or
    overwriting) the writable target file. The Fortran ``badref-write``
    scenario in ``test_minimal.f90`` triggers exactly this case.
    """
    out_dir = tmp_path / "fortran_out"
    out_dir.mkdir()

    # Pre-place a sentinel where the writable store would be created.
    # If ppser_initialize wrongly created/truncated the target before
    # validating the (bad) reference path, this content is destroyed.
    target = out_dir / "fhello.nc"
    sentinel = b"preserf-sentinel-must-survive-bad-directory_ref"
    target.write_bytes(sentinel)

    result = subprocess.run(
        [str(fortran_binary), str(out_dir), "badref-write"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    # A missing reference store must abort the program.
    assert result.returncode != 0, (
        "binary should have aborted on a bad directory_ref\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    # The reference store opens first, so the main nf90_create never
    # ran: the writable target must still hold the untouched sentinel.
    assert target.read_bytes() == sentinel, (
        "a bad directory_ref truncated or overwrote the writable target"
    )


def test_fortran_realtype_too_long_aborts(tmp_path: Path, fortran_binary: Path) -> None:
    """An over-long ``realtype`` aborts instead of silently truncating.

    ``ppser_realtype`` is fixed-length; ``ppser_initialize`` rejects a
    ``realtype`` keyword that would not fit rather than truncating it
    (which would mis-register every real field). The Fortran
    ``realtype-too-long`` scenario in ``test_minimal.f90`` triggers the
    guard.
    """
    out_dir = tmp_path / "fortran_out"
    out_dir.mkdir()

    result = subprocess.run(
        [str(fortran_binary), str(out_dir), "realtype-too-long"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert result.returncode != 0, (
        "binary should have aborted on an over-long realtype\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "realtype string exceeds" in (result.stdout + result.stderr), (
        "abort should name the realtype length guard\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Slice B: full (rank x dtype) type-coverage matrix.
#
# The `wire-matrix` scenario writes one field of every dtype x rank
# combination (named "<tag><rank>") plus a 1D-array metainfo of each
# scalar type. Extents are distinct per axis (rank-r uses the (2,3,4,5)
# prefix) so the on-disk C-order shape/dims constrain axis order; numeric
# fields are filled with a column-major ramp 1..N, so the on-disk array
# read back as numpy ravel(order="F") must equal arange(1, N+1) — this
# catches both an axis-order transpose (wrong shape) and an element-order
# scramble (wrong ramp). The test asserts, for each (rank, dtype), the raw
# on-disk netCDF type and registry type_id against the TypeID -> netCDF
# table in docs/references/storage_mapping.md §1, plus shape and values.
# ---------------------------------------------------------------------------

# (tag, primitive TypeID)
_MATRIX_DTYPES = [
    ("l", TypeID.Boolean),
    ("i4", TypeID.Int32),
    ("i8", TypeID.Int64),
    ("r4", TypeID.Float32),
    ("r8", TypeID.Float64),
]

# Fortran column-major extents per rank: rank-r uses (2,3,4,5)[:r].
_MATRIX_FORTRAN_EXTENTS = {0: (), 1: (2,), 2: (2, 3), 3: (2, 3, 4), 4: (2, 3, 4, 5)}
# Every (tag, rank) field name the wire-matrix scenario must emit.
_MATRIX_FIELD_NAMES = {
    f"{tag}{rank}" for (tag, _tid) in _MATRIX_DTYPES for rank in range(5)
}


@pytest.fixture(scope="module")
def matrix_store(tmp_path_factory: pytest.TempPathFactory) -> dict[str, object]:
    """Run the `wire-matrix` scenario once and read back the matrix store.

    Module-scoped so the Fortran binary runs a single time for the whole
    parametrised matrix. ``_require_binary`` applies the same skip / hard-fail
    semantics (``PRESERF_REQUIRE_FORTRAN``) as the ``fortran_binary`` fixture.
    """
    binary = _require_binary("unit/m_preserf", "preserf_fortran_test_minimal")
    out_dir = tmp_path_factory.mktemp("wire_matrix")
    result = subprocess.run(
        [str(binary), str(out_dir), "wire-matrix"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"Fortran binary exited {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "preserf-fortran: wire-matrix OK" in result.stdout

    nc_path = out_dir / "fmatrix.nc"

    import netCDF4  # local import; netCDF4 is a dev-only dependency

    registry_type_id: dict[str, int] = {}
    savepoint_dtype: dict[str, np.dtype] = {}
    raw = netCDF4.Dataset(str(nc_path), "r")
    try:
        fields_grp = raw.groups["_fields"]
        sp_grp = raw.groups["savepoints"].groups["sp_000000"]
        for vname in fields_grp.variables:
            registry_type_id[vname] = int(
                fields_grp.variables[vname].getncattr("type_id")
            )
        for vname in sp_grp.variables:
            savepoint_dtype[vname] = sp_grp.variables[vname].dtype
    finally:
        raw.close()

    # Completeness guard: the writer must emit exactly the 25 matrix
    # fields — no more, no less. Without this a dropped field surfaces as
    # a bare KeyError on one parametrised case, and a spurious extra
    # variable goes unnoticed entirely.
    assert set(registry_type_id) == _MATRIX_FIELD_NAMES, (
        "registry fields differ from the expected 25-field matrix: "
        f"missing={_MATRIX_FIELD_NAMES - set(registry_type_id)}, "
        f"unexpected={set(registry_type_id) - _MATRIX_FIELD_NAMES}"
    )
    assert set(savepoint_dtype) == _MATRIX_FIELD_NAMES, (
        "savepoint variables differ from the expected 25-field matrix: "
        f"missing={_MATRIX_FIELD_NAMES - set(savepoint_dtype)}, "
        f"unexpected={set(savepoint_dtype) - _MATRIX_FIELD_NAMES}"
    )

    return {
        "registry_type_id": registry_type_id,
        "savepoint_dtype": savepoint_dtype,
        "dump": read_dump(str(nc_path)),
    }


@pytest.mark.parametrize("rank", [0, 1, 2, 3, 4])
@pytest.mark.parametrize(("tag", "tid"), _MATRIX_DTYPES)
def test_fortran_type_coverage_matrix(
    matrix_store: dict[str, object],
    rank: int,
    tag: str,
    tid: TypeID,
) -> None:
    """Each (rank, dtype) field has the expected on-disk type, shape, and values."""
    name = f"{tag}{rank}"
    expected_dtype = numpy_dtype_for(tid)
    # On disk the dims/shape are C-order = reverse of the Fortran extents.
    c_shape = tuple(reversed(_MATRIX_FORTRAN_EXTENTS[rank]))

    registry_type_id = matrix_store["registry_type_id"]
    savepoint_dtype = matrix_store["savepoint_dtype"]
    dump = matrix_store["dump"]

    # Registry type_id (storage_mapping §1 TypeID) and the raw on-disk
    # savepoint variable netCDF type both match the table.
    assert registry_type_id[name] == int(tid), (  # type: ignore[index]
        f"/_fields/{name} type_id should be {int(tid)} ({tid.name})"
    )
    assert savepoint_dtype[name] == expected_dtype, (  # type: ignore[index]
        f"savepoint variable {name} on-disk dtype should be {expected_dtype}"
    )

    info = dump.field_map[name]  # type: ignore[attr-defined]
    assert info.type_id == tid
    # Distinct extents make this assertion sensitive to an axis-order
    # (C-order vs Fortran-order) transpose regression.
    assert info.dims == list(c_shape)

    arr = dump.field_data[name][0]  # type: ignore[attr-defined]
    assert arr.shape == c_shape
    assert arr.dtype == expected_dtype
    if tag == "l":
        # Logical fields are filled all-.true. -> on-disk byte 1.
        assert np.all(arr == 1)
    else:
        # Numeric fields carry a Fortran column-major ramp 1..N. preserf
        # reverses axes on disk (Fortran (i,j,k) -> numpy [k,j,i]), so the
        # on-disk array traversed C-order (row-major) reproduces that
        # column-major fill; any element-order scramble breaks the ramp.
        expected = np.arange(1, arr.size + 1, dtype=expected_dtype)
        np.testing.assert_array_equal(arr.ravel(order="C"), expected)


def test_fortran_array_metainfo_matrix(matrix_store: dict[str, object]) -> None:
    """1D-array metainfo of each scalar type round-trips with its array TypeID."""
    gm = matrix_store["dump"].global_meta_info  # type: ignore[attr-defined]

    assert gm["a_lg"].type_id == TypeID.ArrayOfBoolean
    assert gm["a_lg"].value == [True, False]
    assert gm["a_i4"].type_id == TypeID.ArrayOfInt32
    assert gm["a_i4"].value == [10, 20, 30]
    assert gm["a_i8"].type_id == TypeID.ArrayOfInt64
    assert gm["a_i8"].value == [100, 200]
    assert gm["a_r4"].type_id == TypeID.ArrayOfFloat32
    assert gm["a_r4"].value == pytest.approx([1.5, 2.5])
    assert gm["a_r8"].type_id == TypeID.ArrayOfFloat64
    assert gm["a_r8"].value == [3.5, 4.5]
