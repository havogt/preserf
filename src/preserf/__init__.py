"""preserf - A preprocessor for Fortran data serialization directives."""

from preserf.errors import DirectiveError
from preserf.preprocessor import Options, Preprocessor

__version__ = "0.1.0"

__all__ = ["DirectiveError", "Options", "Preprocessor", "__version__"]
