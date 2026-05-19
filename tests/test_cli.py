"""Tests for the preserf CLI."""

from pathlib import Path

from typer.testing import CliRunner

import preserf
from preserf.cli import _collect, app

runner = CliRunner()

_SOURCE = "module m\n!$SER ON\nend module m\n"


def test_version_string() -> None:
    assert preserf.__version__ == "0.1.0"


def test_version_flag() -> None:
    result = runner.invoke(app, ["--version"])
    assert result.exit_code == 0
    assert "0.1.0" in result.stdout


def test_no_inputs_is_error() -> None:
    result = runner.invoke(app, [])
    assert result.exit_code != 0


def test_processes_file_to_stdout(tmp_path: Path) -> None:
    src = tmp_path / "in.f90"
    src.write_text(_SOURCE)
    result = runner.invoke(app, [str(src)])
    assert result.exit_code == 0
    assert "call fs_enable_serialization()" in result.stdout
    assert "#ifdef SERIALIZE" in result.stdout


def test_writes_output_file(tmp_path: Path) -> None:
    src = tmp_path / "in.f90"
    src.write_text(_SOURCE)
    dst = tmp_path / "out.f90"
    result = runner.invoke(app, [str(src), "-o", str(dst)])
    assert result.exit_code == 0
    assert "call fs_enable_serialization()" in dst.read_text()


def test_output_dir(tmp_path: Path) -> None:
    src = tmp_path / "in.f90"
    src.write_text(_SOURCE)
    out_dir = tmp_path / "generated"
    result = runner.invoke(app, [str(src), "-d", str(out_dir)])
    assert result.exit_code == 0
    assert (out_dir / "in.f90").is_file()


def test_directive_error_returns_1(tmp_path: Path) -> None:
    src = tmp_path / "bad.f90"
    src.write_text("!$SER BOGUS\n")
    result = runner.invoke(app, [str(src)])
    assert result.exit_code == 1
    assert "Unknown directive" in result.stderr


def test_missing_file_returns_1(tmp_path: Path) -> None:
    result = runner.invoke(app, [str(tmp_path / "missing.f90")])
    assert result.exit_code == 1


def test_output_with_multiple_inputs_rejected(tmp_path: Path) -> None:
    a = tmp_path / "a.f90"
    b = tmp_path / "b.f90"
    a.write_text(_SOURCE)
    b.write_text(_SOURCE)
    result = runner.invoke(app, [str(a), str(b), "-o", str(tmp_path / "o.f90")])
    assert result.exit_code == 1
    assert "single input" in result.stderr


def test_output_with_recursive_dir_rejected(tmp_path: Path) -> None:
    src = tmp_path / "src"
    src.mkdir()
    (src / "a.f90").write_text(_SOURCE)
    (src / "b.f90").write_text(_SOURCE)
    out_dir = tmp_path / "out"
    result = runner.invoke(
        app, [str(src), "-r", "-d", str(out_dir), "-o", str(tmp_path / "o.f90")]
    )
    assert result.exit_code == 1
    assert "single input" in result.stderr


def test_recursive_requires_output_dir(tmp_path: Path) -> None:
    result = runner.invoke(app, [str(tmp_path), "-r"])
    assert result.exit_code == 1
    assert "requires --output-dir" in result.stderr


def test_recursive_mirrors_tree(tmp_path: Path) -> None:
    nested = tmp_path / "src" / "sub"
    nested.mkdir(parents=True)
    (nested / "deep.f90").write_text(_SOURCE)
    (tmp_path / "src" / "top.f90").write_text(_SOURCE)
    out_dir = tmp_path / "out"
    result = runner.invoke(app, [str(tmp_path / "src"), "-r", "-d", str(out_dir)])
    assert result.exit_code == 0
    assert (out_dir / "top.f90").is_file()
    assert (out_dir / "sub" / "deep.f90").is_file()


def test_ignore_identical_skips_rewrite(tmp_path: Path) -> None:
    src = tmp_path / "in.f90"
    src.write_text(_SOURCE)
    dst = tmp_path / "out.f90"
    assert runner.invoke(app, [str(src), "-o", str(dst)]).exit_code == 0
    first_mtime = dst.stat().st_mtime_ns
    assert runner.invoke(app, [str(src), "-o", str(dst), "-i"]).exit_code == 0
    assert dst.stat().st_mtime_ns == first_mtime


def test_modules_arg_is_trimmed(tmp_path: Path) -> None:
    # Untrimmed entries would yield invalid "USE  b_mod" with a double space.
    src = tmp_path / "m.f90"
    src.write_text(_SOURCE)
    result = runner.invoke(app, [str(src), "--modules", "a_mod, b_mod ,c_mod"])
    assert result.exit_code == 0
    assert "USE a_mod\n" in result.stdout
    assert "USE b_mod\n" in result.stdout
    assert "USE c_mod\n" in result.stdout


def test_collect_deduplicates_overlapping_dirs(tmp_path: Path) -> None:
    sub = tmp_path / "src" / "sub"
    sub.mkdir(parents=True)
    (sub / "a.f90").write_text(_SOURCE)
    files = _collect([tmp_path / "src", sub], recursive=True)
    assert len(files) == 1


def test_collect_deduplicates_via_resolved_identity(tmp_path: Path) -> None:
    src = tmp_path / "src"
    src.mkdir()
    (src / "a.f90").write_text(_SOURCE)
    aliased = tmp_path / "src" / ".." / "src"
    files = _collect([src, aliased], recursive=True)
    assert len(files) == 1
