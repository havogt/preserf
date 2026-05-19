"""Command-line interface for the preserf preprocessor."""

import sys
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.markup import escape
from rich.panel import Panel

from preserf import __version__
from preserf.errors import DirectiveError
from preserf.preprocessor import Options, Preprocessor

# Extensions treated as Fortran source when expanding a directory.
_FORTRAN_SUFFIXES = frozenset({".f90", ".f", ".f03", ".inc", ".incf"})

# Diagnostics and progress go to stderr so they never corrupt the
# preprocessed source written to stdout.
_err = Console(stderr=True)

app = typer.Typer(
    add_completion=False,
    help="Expand !$SER serialization directives in Fortran source.",
)


def _fail(message: str) -> typer.Exit:
    """Print a one-line error to stderr; the returned Exit is raised."""
    _err.print(f"[bold red]preserf:[/] {escape(message)}")
    return typer.Exit(1)


def _version_callback(value: bool) -> None:
    if value:
        Console().print(f"preserf {__version__}")
        raise typer.Exit()


def _is_fortran(path: Path) -> bool:
    return path.suffix.lower() in _FORTRAN_SUFFIXES


def _collect(sources: list[Path], recursive: bool) -> list[Path]:
    """Resolve CLI inputs to a flat list of Fortran source files.

    Raises :class:`ValueError` if a directory is given without ``--recursive``.
    """
    files: list[Path] = []
    for path in sources:
        if path.is_dir():
            if not recursive:
                raise ValueError(f"{path} is a directory (use --recursive)")
            files.extend(
                sorted(p for p in path.rglob("*") if p.is_file() and _is_fortran(p))
            )
        else:
            files.append(path)
    # Overlapping inputs (a directory and a subdirectory of it, symlinks,
    # ".." segments) can name the same file; de-duplicate by resolved
    # identity while keeping each file's first-seen path spelling.
    seen: dict[Path, Path] = {}
    for file in files:
        seen.setdefault(file.resolve(), file)
    return list(seen.values())


def _output_path(
    source: Path,
    output: Path | None,
    output_dir: Path | None,
    recursive: bool,
    roots: list[Path],
) -> Path | None:
    """Destination for ``source``, or ``None`` to write to stdout."""
    if output is not None:
        return output
    if output_dir is None:
        return None
    if recursive:
        for root in roots:
            if root.is_dir() and root in source.parents:
                return output_dir / source.relative_to(root)
    return output_dir / source.name


def _process_file(
    source: Path, destination: Path | None, options: Options, ignore_identical: bool
) -> bool:
    """Preprocess ``source``; return True if a file was (re)written."""
    result = Preprocessor(str(source), source.read_text(), options).process()
    if destination is None:
        sys.stdout.write(result)
        return False
    if ignore_identical and destination.is_file() and destination.read_text() == result:
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(result)
    return True


@app.command()
def main(
    sources: Annotated[
        list[Path],
        typer.Argument(
            metavar="SOURCE...",
            show_default=False,
            help="Fortran source files, or directories with --recursive.",
        ),
    ],
    output: Annotated[
        Path | None,
        typer.Option(
            "-o",
            "--output",
            help="Write a single input's result here (default: stdout).",
        ),
    ] = None,
    output_dir: Annotated[
        Path | None,
        typer.Option(
            "-d",
            "--output-dir",
            help="Directory to write preprocessed files into.",
        ),
    ] = None,
    recursive: Annotated[
        bool,
        typer.Option(
            "-r",
            "--recursive",
            help="Recurse into input directories, mirroring the tree.",
        ),
    ] = False,
    ignore_identical: Annotated[
        bool,
        typer.Option(
            "-i",
            "--ignore-identical",
            help="Skip writing output identical to the existing file.",
        ),
    ] = False,
    no_prefix: Annotated[
        bool,
        typer.Option(
            "-p",
            "--no-prefix",
            help="Do not emit the '#define ACC_PREFIX !$acc' line.",
        ),
    ] = False,
    acc_if: Annotated[
        str,
        typer.Option(
            "-a",
            "--acc-if",
            help="IF clause appended to generated OpenACC update directives.",
        ),
    ] = "",
    sp_as_var: Annotated[
        bool,
        typer.Option(
            "-s",
            "--sp-as-var",
            help="Pass savepoint names as variables, not string literals.",
        ),
    ] = False,
    modules: Annotated[
        str,
        typer.Option(
            "-m",
            "--modules",
            help="Comma-separated extra modules to add to USE statements.",
        ),
    ] = "",
    ifdef: Annotated[
        str,
        typer.Option(
            "--ifdef",
            help="C-preprocessor guard symbol (empty disables guards).",
        ),
    ] = "SERIALIZE",
    real: Annotated[
        str,
        typer.Option(
            "--real",
            help="Fortran real kind parameter used by the ZERO directive.",
        ),
    ] = "ireals",
    module: Annotated[
        str,
        typer.Option(
            "--module",
            help="Module imported for fs_* serialization calls.",
        ),
    ] = "m_serialize",
    version: Annotated[
        bool,
        typer.Option(
            "--version",
            callback=_version_callback,
            is_eager=True,
            help="Show the version and exit.",
        ),
    ] = False,
) -> None:
    """Expand !$SER serialization directives in Fortran source."""
    options = Options(
        ifdef=ifdef,
        real=real,
        module=module,
        acc_prefix=not no_prefix,
        acc_if=acc_if,
        sp_as_var=sp_as_var,
        modules=tuple(m.strip() for m in modules.split(",") if m.strip()),
    )

    if recursive and output_dir is None:
        raise _fail("--recursive requires --output-dir")

    try:
        files = _collect(sources, recursive)
    except ValueError as exc:
        raise _fail(str(exc)) from exc

    if output is not None and len(files) > 1:
        raise _fail("--output requires a single input file")

    written: list[Path] = []
    for source in files:
        destination = _output_path(source, output, output_dir, recursive, sources)
        try:
            wrote = _process_file(source, destination, options, ignore_identical)
        except DirectiveError as exc:
            _err.print(
                Panel(
                    escape(str(exc)),
                    title="!$SER directive error",
                    border_style="red",
                    expand=False,
                )
            )
            raise typer.Exit(1) from exc
        except OSError as exc:
            raise _fail(str(exc)) from exc
        if wrote and destination is not None:
            written.append(destination)

    for dest in written:
        _err.print(f"[green]wrote[/] {escape(str(dest))}")


if __name__ == "__main__":
    app()
