"""Error types raised by the preserf preprocessor."""

from __future__ import annotations


class DirectiveError(Exception):
    """A malformed or unsupported ``!$SER`` directive.

    Carries the originating file and line so the CLI can render a
    ``pp_ser``-style diagnostic without the preprocessor calling
    ``sys.exit`` itself.
    """

    def __init__(
        self,
        message: str,
        *,
        filename: str,
        lineno: int,
        directive: str = "",
        line: str = "",
    ) -> None:
        self.message = message
        self.filename = filename
        self.lineno = lineno
        self.directive = directive
        self.line = line
        super().__init__(message)

    def __str__(self) -> str:
        parts = [f'File: "{self.filename}", line {self.lineno}']
        if self.directive:
            parts.append(f"SyntaxError: Invalid !$SER {self.directive} directive")
        parts.append(f"Message: {self.message}")
        if self.line:
            parts.append(f"Line {self.lineno}: {self.line.rstrip()}")
        return "\n".join(parts)
