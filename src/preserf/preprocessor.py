"""Expansion of ``!$SER`` serialization directives into Fortran code.

This is a typed reimplementation of Serialbox's ``pp_ser.py``. The
directive grammar and generated code follow
``development/references/directives_specification.md``.

The preprocessor runs two passes over the input: an analysis pass that
collects every serialization API call so the correct ``USE`` import can
be generated, and a generation pass that expands the directives.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from preserf.errors import DirectiveError

# --- directive vocabulary --------------------------------------------------

# Fortran API entry points the directives expand into.
_METHODS = {
    "mode": "ppser_set_mode",
    "getmode": "ppser_get_mode",
    "init": "ppser_initialize",
    "cleanup": "ppser_finalize",
    "datawrite": "fs_write_field",
    "dataread": "fs_read_field",
    "datakbuff": "fs_write_kbuff",
    "option": "fs_Option",
    "serinfo": "fs_add_serializer_metainfo",
    "register": "fs_register_field",
    "registertracers": "fs_RegisterAllTracers",
    "savepoint": "fs_create_savepoint",
    "spinfo": "fs_add_savepoint_metainfo",
    "on": "fs_enable_serialization",
    "off": "fs_disable_serialization",
}

# Directive keyword -> accepted spellings (case-insensitive).
_LANGUAGE = {
    "cleanup": ("CLEANUP", "CLE"),
    "data": ("DATA", "DAT"),
    "data_kbuff": ("DATA_KBUFF", "KBU"),
    "accdata": ("ACCDATA", "ACC"),
    "mode": ("MODE", "MOD"),
    "init": ("INIT", "INI"),
    "option": ("OPTION", "OPT"),
    "metainfo": ("METAINFO",),
    "verbatim": ("VERBATIM", "VER"),
    "register": ("REGISTER", "REG"),
    "registertracers": ("REGISTERTRACERS",),
    "zero": ("ZERO", "ZER"),
    "savepoint": ("SAVEPOINT", "SAV"),
    "tracer": ("TRACER", "TRA"),
    "on": ("ON",),
    "off": ("OFF",),
}

# Symbolic serialization modes accepted by the MODE directive.
_MODES = {
    "write": 0,
    "read": 1,
    "read-perturb": 2,
    "CPU": 0,
    "GPU": 1,
}

# Field-registration dimension shortcuts. Each expands to the 12 values
# iSize jSize kSize lSize iMinusHalo iPlusHalo jMinusHalo jPlusHalo
# kMinusHalo kPlusHalo lMinusHalo lPlusHalo.
_REG_SHORTCUTS = {
    "": "1 0 0 0 0 0 0 0 0 0 0 0",
    "I": "ie 0 0 0 nboundlines nboundlines 0 0 0 0 0 0",
    "J": "je 0 0 0 nboundlines nboundlines 0 0 0 0 0 0",
    "J2": "je 2 0 0 nboundlines nboundlines 0 0 0 0 0 0",
    "K": "ke 0 0 0 0 0 0 0 0 0 0 0",
    "K1": "ke1 0 0 0 0 1 0 0 0 0 0 0",
    "IJ": "ie je 0 0 nboundlines nboundlines nboundlines nboundlines 0 0 0 0",
    "IJ3": "ie je 3 0 nboundlines nboundlines nboundlines nboundlines 0 0 0 0",
    "IK": "ie ke 0 0 nboundlines nboundlines 0 0 0 0 0 0",
    "IK1": "ie ke1 0 0 nboundlines nboundlines 0 0 0 1 0 0",
    "JK": "je ke 0 0 nboundlines nboundlines 0 0 0 0 0 0",
    "JK1": "je ke1 0 0 nboundlines nboundlines 0 1 0 0 0 0",
    "IJK": "ie je ke 0 nboundlines nboundlines nboundlines nboundlines 0 0 0 0",
    "IJK1": "ie je ke1 0 nboundlines nboundlines nboundlines nboundlines 0 1 0 0",
}

# A DATA value is "computed" (written but never read back) when it is an
# expression rather than a plain field reference: it contains an arithmetic
# operator or a ``merge`` intrinsic.
_COMPUTED_OPS = ("*", "+", "-", "/")
_RE_MERGE = re.compile(r"\bmerge\b", re.IGNORECASE)

# Utility-module symbols always imported alongside any serialization call.
_ALWAYS_PPSER = (
    "ppser_savepoint",
    "ppser_serializer",
    "ppser_serializer_ref",
    "ppser_intlength",
    "ppser_reallength",
    "ppser_realtype",
    "ppser_zrperturb",
    "ppser_get_mode",
)

_RE_SER = re.compile(r"^ *!\$ser *(.*)$", re.IGNORECASE)
_RE_SER_CONT_OUT = re.compile(r"^ *!\$ser *(.*) & *$", re.IGNORECASE)
_RE_SER_CONT_IN = re.compile(r"^ *!\$ser& *", re.IGNORECASE)
_RE_TOKENS = re.compile(r"""((?:[^ "']|"[^"]*"|'[^']*')+)""")
_RE_MODULE = re.compile(
    r"^ *(?P<statement>module|program) +(?P<identifier>[a-z][a-z0-9_]*)",
    re.IGNORECASE,
)
_RE_ENDMODULE = re.compile(
    r"^ *end *(module|program) *([a-z][a-z0-9_]*|)", re.IGNORECASE
)
_RE_SUBPROG = re.compile(r"^ *(subroutine|function).*", re.IGNORECASE)
_RE_SUBPROG_CONT = re.compile(r"^ *(subroutine|function)([^!]*)&", re.IGNORECASE)
_RE_CONTINUED = re.compile(r"^([^!]*)&")
_RE_INTENT_IN = re.compile(r".*intent *\(in\)[^:]*::\s*([^!]*)\s*.*", re.IGNORECASE)
_RE_INTENT_IN_CONT = re.compile(
    r".*intent *\(in\)[^:]*::\s*([^!]*)\s*.*&", re.IGNORECASE
)
_RE_INTENT_IN_SUB = re.compile(r", *intent *\(in\)", re.IGNORECASE)
_RE_TRACER = re.compile(
    r"^([a-zA-Z_0-9]+|\$[a-zA-Z_0-9()]+(?:-[a-zA-Z_0-9()]+)?|%all)"
    r"(?:#(tens|bd|surf|sedimvel))?"
    r"(?:@([a-zA-Z_0-9]+))?"
)


def _is_computed(value: str) -> bool:
    """Whether a DATA value is a computed expression, so write-only."""
    if any(op in value for op in _COMPUTED_OPS):
        return True
    return _RE_MERGE.search(value) is not None


@dataclass
class Options:
    """Configuration for a :class:`Preprocessor` run.

    Mirrors the command-line surface of the reference ``pp_ser``.
    """

    ifdef: str = "SERIALIZE"
    """C-preprocessor symbol for ``#ifdef``/``#endif`` guards; empty disables."""

    real: str = "ireals"
    """Fortran real kind parameter used by the ZERO directive."""

    module: str = "m_serialize"
    """Module name imported for ``fs_*`` serialization calls."""

    acc_prefix: bool = True
    """Emit ``#define ACC_PREFIX !$acc`` at the top of the output."""

    acc_if: str = ""
    """Optional IF clause appended to generated OpenACC update directives."""

    sp_as_var: bool = False
    """Pass savepoint names as bare variables rather than string literals."""

    modules: tuple[str, ...] = ()
    """Extra modules added verbatim to the generated ``USE`` block."""


class Preprocessor:
    """Expand ``!$SER`` directives in a single Fortran source file."""

    def __init__(
        self, filename: str, source: str, options: Options | None = None
    ) -> None:
        self.filename = filename
        self._lines = source.splitlines(keepends=True)
        self.options = options or Options()

        # State reset at the start of every pass by :meth:`_reset`.
        self._in_ser = False
        self._line = ""
        self._lineno = 0
        self._module = ""
        self._calls: set[str] = set()
        self._output: list[str] = []
        self._use_stmt_in_module = False
        self._skip_lines = 0

        # Fields named by DATA/ACCDATA/DATA_KBUFF whose INTENT(IN) must be
        # stripped so read-mode can assign into them. Populated during the
        # analysis pass and consumed during generation.
        self.intentin_to_remove: list[str] = []

    # -- public API ---------------------------------------------------------

    def process(self) -> str:
        """Return the preprocessed source (analysis pass, then generation)."""
        # Analysis-pass results must survive into the generation pass, but
        # not leak across separate process() calls; clear them up front.
        self._calls = set()
        self.intentin_to_remove = []
        self._reset()
        self._parse(generate=False)
        self._reset()
        self._parse(generate=True)
        return "".join(self._output)

    # -- pass driver --------------------------------------------------------

    def _reset(self) -> None:
        self._in_ser = False
        self._line = ""
        self._lineno = 0
        self._module = ""
        self._output = []
        self._skip_lines = 0
        self._use_stmt_in_module = False

    def _parse(self, *, generate: bool) -> None:
        if self.options.acc_prefix:
            self._output.append("#define ACC_PREFIX !$acc\n")

        pending = ""  # accumulated continued !$SER directive
        for raw in self._lines:
            if self._skip_lines > 0:
                self._skip_lines -= 1
                self._lineno += 1
                continue
            self._lineno += 1

            line = raw
            if pending:
                if _RE_SER_CONT_IN.match(line):
                    line = _RE_SER_CONT_IN.sub(" ", line)
                else:
                    raise self._error(msg="Incorrect line continuation encountered")
            self._line = pending + line

            cont = _RE_SER_CONT_OUT.match(self._line)
            if cont:
                # Chop the trailing ``&`` and keep accumulating.
                pending = re.sub(r" +& *$", "", self._line).rstrip()
                continue
            pending = ""

            self._lex()
            if generate:
                self._output.append(self._line)
            self._line = ""

        # A continued !$SER directive (trailing `&`) that runs off the end
        # of the file has no continuation line; surface it as a continuation
        # error regardless of guard settings.
        if pending:
            self._line = pending
            raise self._error(msg="Incorrect line continuation encountered")

        # Flush leftover state: a trailing directive block still needs its
        # closing #endif (the reference pp_ser dropped it when the file
        # ended on a directive).
        self._line = ""
        self._lex(final=True)
        if generate and self._line:
            self._output.append(self._line)

    def _lex(self, *, final: bool = False) -> None:
        self._scan_module()
        self._scan_subprogram()
        self._scan_endmodule()
        self._scan_intent_in()

        if self._scan_ser():
            if self.options.ifdef and not self._in_ser:
                self._line = f"#ifdef {self.options.ifdef}\n" + self._line
                self._in_ser = True
        elif self.options.ifdef and self._in_ser:
            self._line = "#endif\n" + self._line
            self._in_ser = False

        if final:
            if self._in_ser:
                raise self._error(
                    msg=f"Unterminated #ifdef {self.options.ifdef} encountered"
                )
            if self._module:
                raise self._error(msg="Unterminated module or program unit encountered")

    # -- scope tracking -----------------------------------------------------

    def _scan_module(self) -> None:
        m = _RE_MODULE.search(self._line)
        if not m:
            return
        if m.group("identifier").upper() == "PROCEDURE":
            return
        if self._module:
            raise self._error(msg=f"Unexpected {m.group('statement')} statement")
        self._emit_use_stmt()
        # Per the spec, contained subprograms host-associate the injected
        # USE from both MODULE and PROGRAM units, so suppress re-injection.
        self._use_stmt_in_module = True
        self._module = m.group("identifier")

    def _scan_subprogram(self) -> None:
        if self._use_stmt_in_module:
            return
        m = _RE_SUBPROG.search(self._line)
        if not m:
            return
        if not _RE_SUBPROG_CONT.search(self._line):
            self._emit_use_stmt()
            return
        # Continued header: pull in continuation lines so the USE block
        # lands after the full signature.
        lookahead = self._lineno  # 0-based index of the line after current
        while lookahead < len(self._lines) and _RE_CONTINUED.search(
            self._lines[lookahead]
        ):
            self._line += self._lines[lookahead]
            lookahead += 1
        if lookahead < len(self._lines):
            self._line += self._lines[lookahead]
            lookahead += 1
        self._skip_lines = lookahead - self._lineno
        self._emit_use_stmt()

    def _scan_endmodule(self) -> None:
        m = _RE_ENDMODULE.search(self._line)
        if not m:
            return
        if not self._module:
            raise self._error(msg=f'Unexpected "end {m.group(1)}" statement')
        if m.group(2) and self._module.lower() != m.group(2).lower():
            raise self._error(msg=f'Was expecting "end {m.group(1)} {self._module}"')
        self._module = ""
        self._use_stmt_in_module = False

    def _scan_intent_in(self) -> None:
        """Strip ``INTENT(IN)`` from declarations of fields read back by DATA.

        Read mode assigns into the field variables, so their ``INTENT(IN)``
        qualifier must be removed when serialization is active. The
        declaration's first line is wrapped in an ``#ifdef``/``#else`` pair
        carrying the qualifier-free and original forms; when guards are
        disabled the qualifier is dropped unconditionally instead.
        """
        if not self.intentin_to_remove or "::" not in self._line:
            return
        if not _RE_INTENT_IN.search(self._line):
            return

        rhs = re.sub(r"!.*", "", self._line.split("::", 1)[1])
        declared = self._declared_names(rhs)
        if _RE_INTENT_IN_CONT.search(self._line):
            # Continued declaration: gather names off the continuation lines.
            idx = self._lineno
            while idx < len(self._lines):
                physical = self._lines[idx]
                declared |= self._declared_names(re.sub(r"!.*", "", physical))
                if "&" not in physical:
                    break
                idx += 1

        matched = [x for x in self.intentin_to_remove if x in declared]
        if not matched:
            return
        stripped = _RE_INTENT_IN_SUB.sub("", self._line)
        if not self.options.ifdef:
            # Guards disabled: serialization is always active, so drop the
            # INTENT(IN) qualifier unconditionally rather than emitting an
            # empty, invalid ``#ifdef`` line.
            self._line = stripped
            return
        self._line = (
            f"#ifdef {self.options.ifdef}\n"
            + stripped
            + "#else\n"
            + self._line
            + "#endif\n"
        )

    @staticmethod
    def _declared_names(text: str) -> set[str]:
        """Variable names from a comma-separated Fortran declaration fragment."""
        var_with_dim = (
            x.strip().replace(" ", "") for x in re.split(r",(?![^(]*\))", text)
        )
        return {re.sub(r"\(.*?\)", "", x) for x in var_with_dim}

    # -- USE statement ------------------------------------------------------

    def _emit_use_stmt(self) -> None:
        if self._use_stmt_in_module:
            return
        # Sorted for reproducible output: the reference pp_ser iterated a
        # set here, so its USE block ordering was non-deterministic.
        calls_pp = sorted(c for c in self._calls if c.startswith("ppser"))
        calls_fs = sorted(c for c in self._calls if not c.startswith("ppser"))
        if not calls_pp and not calls_fs:
            return

        calls_pp = calls_pp + [s for s in _ALWAYS_PPSER if s not in calls_pp]

        out = ["\n"]
        if self.options.ifdef:
            out.append(f"#ifdef {self.options.ifdef}\n")
        if calls_fs:
            out.append(f"USE {self.options.module}, ONLY: &\n")
            out += [f"  {s}, &\n" for s in calls_fs[:-1]]
            out.append(f"  {calls_fs[-1]}\n")
        if calls_pp:
            out.append("USE utils_ppser, ONLY:  &\n")
            out += [f"  {s}, &\n" for s in calls_pp[:-1]]
            out.append(f"  {calls_pp[-1]}\n")
        out += [f"USE {mod}\n" for mod in self.options.modules]
        if self.options.ifdef:
            out.append("#endif\n")
        out.append("\n")
        self._line += "".join(out)

    # -- !$SER dispatch -----------------------------------------------------

    def _scan_ser(self) -> bool:
        m = _RE_SER.search(self._line)
        if not m:
            return False
        body = m.group(1)
        if not body:
            return True  # bare ``!$SER`` line: directive for grouping only
        args = _RE_TOKENS.split(body)[1::2]
        keyword = args[0].upper()
        for name, spellings in _LANGUAGE.items():
            if keyword in spellings:
                getattr(self, f"_ser_{name}")(args)
                return True
        raise self._error(directive=args[0], msg="Unknown directive encountered")

    # -- argument parsing helpers ------------------------------------------

    def _parse_args(
        self, args: list[str]
    ) -> tuple[list[str], list[str], list[str], str]:
        """Split directive tokens into positionals, key/value pairs, IF clause."""
        positionals: list[str] = []
        keys: list[str] = []
        values: list[str] = []
        if_seen = False
        if_statement = ""
        for arg in args[1:]:
            if arg.upper() == "IF":
                if_seen = True
                continue
            if if_seen:
                if if_statement:
                    raise self._error(
                        directive=args[0],
                        msg="IF statement must be last argument",
                    )
                if_statement = arg
                continue
            # Split on the first '=' only, so a value may itself contain
            # '=' (e.g. inside a quoted string literal).
            parts = arg.split("=", 1)
            if len(parts) == 1:
                positionals.append(parts[0])
            else:
                keys.append(parts[0])
                values.append(parts[1])
        if if_seen and not if_statement:
            raise self._error(
                directive=args[0],
                msg="IF must be followed by a condition",
            )
        return positionals, keys, values, if_statement

    def _parse_tracers(
        self, args: list[str]
    ) -> tuple[list[tuple[str | None, ...]], str]:
        specs: list[tuple[str | None, ...]] = []
        if_seen = False
        if_statement = ""
        for arg in args[1:]:
            if arg.upper() == "IF":
                if_seen = True
                continue
            if if_seen:
                if if_statement:
                    raise self._error(
                        directive=args[0],
                        msg="IF statement must be last argument",
                    )
                if_statement = arg
                continue
            m = _RE_TRACER.fullmatch(arg)
            if m is None:
                raise self._error(
                    directive=args[0],
                    msg=f"Tracer specification {arg} is invalid",
                )
            specs.append(m.groups())
        if if_seen and not if_statement:
            raise self._error(
                directive=args[0],
                msg="IF must be followed by a condition",
            )
        return specs, if_statement

    def _annotation(self) -> str:
        return f"! file: {self.filename} lineno: #{self._lineno}\n"

    # -- directive expansions ----------------------------------------------

    def _ser_init(self, args: list[str]) -> None:
        _, _, _, if_statement = self._parse_args(args)
        tab = ""
        out = self._annotation()
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
            tab = "  "
        out += tab + "PRINT *, '>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<'\n"
        out += tab + "PRINT *, '>>> WARNING: SERIALIZATION IS ON <<<'\n"
        out += tab + "PRINT *, '>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<'\n"
        out += tab + "\n"
        out += tab + "! setup serialization environment\n"

        lower = [a.lower() for a in args]
        if_pos = lower.index("if") if "if" in lower else len(args)

        self._calls.add(_METHODS["init"])
        pad = " " * 11
        joined = (", &\n" + pad).join(args[1:if_pos])
        out += tab + f"call {_METHODS['init']}( &\n{pad}{joined})\n"
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_cleanup(self, args: list[str]) -> None:
        out = self._annotation()
        out += "! cleanup serialization environment\n"
        self._calls.add(_METHODS["cleanup"])
        out += f"call {_METHODS['cleanup']}({','.join(args[1:])})\n"
        self._line = out

    def _ser_option(self, args: list[str]) -> None:
        positionals, keys, values, if_statement = self._parse_args(args)
        if positionals:
            raise self._error(
                directive=args[0],
                msg="Must specify only key=value pairs",
            )
        out = self._annotation()
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
        self._calls.add(_METHODS["option"])
        pairs = []
        for key, value in zip(keys, values, strict=True):
            if key.lower() == "verbosity":
                if value.lower() == "off":
                    value = "0"
                elif value.lower() == "on":
                    value = "1"
            pairs.append(f"{key}={value}")
        out += f"call {_METHODS['option']}({', '.join(pairs)})\n"
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_metainfo(self, args: list[str]) -> None:
        positionals, keys, values, if_statement = self._parse_args(args)
        out = self._annotation()
        tab = ""
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
            tab = "  "
        self._calls.add(_METHODS["serinfo"])
        for key, value in zip(keys, values, strict=True):
            out += tab + (
                f'call {_METHODS["serinfo"]}(ppser_serializer, "{key}", {value})\n'
            )
        for name in positionals:
            out += tab + (
                f'call {_METHODS["serinfo"]}(ppser_serializer, "{name}", {name})\n'
            )
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_verbatim(self, args: list[str]) -> None:
        self._line = " ".join(args[1:]) + "\n"

    def _ser_register(self, args: list[str]) -> None:
        positionals, keys, _, if_statement = self._parse_args(args)
        if len(positionals) < 2:
            raise self._error(
                directive=args[0],
                msg="Must specify a name, a type and the field sizes",
            )
        if len(positionals) == 2:
            positionals.append("")
        positionals[0] = "'" + positionals[0] + "'"

        datatypes = {
            "integer": ["'int'", "ppser_intlength"],
            "real": ["ppser_realtype", "ppser_reallength"],
        }
        if positionals[1] not in datatypes:
            valid = ", ".join(f'"{d}"' for d in datatypes)
            raise self._error(
                directive=args[0],
                msg=(
                    f'Data type "{positionals[1]}" not understood. '
                    f"Valid types are: {valid}"
                ),
            )
        positionals[1:2] = datatypes[positionals[1]]

        # With name + (type,length) + one dimension token, that token is a
        # shortcut candidate.
        if len(positionals) == 4:
            expanded = _REG_SHORTCUTS.get(positionals[3].upper())
            if expanded is not None:
                positionals[3:4] = expanded.split()

        out = self._annotation()
        tab = ""
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
            tab = "  "
        self._calls.add(_METHODS["register"])
        out += tab + (
            f"call {_METHODS['register']}(ppser_serializer, {', '.join(positionals)})\n"
        )
        if keys:
            raise self._error(
                directive=args[0],
                msg="Metainformation for fields are not yet implemented",
            )
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_registertracers(self, args: list[str]) -> None:
        self._require_no_args(args)
        self._calls.add(_METHODS["registertracers"])
        self._line = self._annotation() + "call fs_RegisterAllTracers()\n"

    def _ser_zero(self, args: list[str]) -> None:
        positionals, keys, _, if_statement = self._parse_args(args)
        if keys or not positionals:
            raise self._error(directive=args[0], msg="Must specify a list of fields")
        out = self._annotation()
        tab = ""
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
            tab = "  "
        for name in positionals:
            out += tab + f"{name} = 0.0_{self.options.real}\n"
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_savepoint(self, args: list[str]) -> None:
        positionals, keys, values, if_statement = self._parse_args(args)
        if len(positionals) != 1:
            raise self._error(
                directive=args[0],
                msg="Must specify a name and a list of key=value pairs",
            )
        name = positionals[0]
        out = self._annotation()
        tab = ""
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
            tab = "  "
        self._calls.add(_METHODS["savepoint"])
        self._calls.add(_METHODS["spinfo"])
        if self.options.sp_as_var:
            out += tab + f"call {_METHODS['savepoint']}({name}, ppser_savepoint)\n"
        else:
            out += tab + (f"call {_METHODS['savepoint']}('{name}', ppser_savepoint)\n")
        for key, value in zip(keys, values, strict=True):
            out += tab + (
                f"call {_METHODS['spinfo']}(ppser_savepoint, '{key}', {value})\n"
            )
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_mode(self, args: list[str]) -> None:
        positionals, keys, _, if_statement = self._parse_args(args)
        if len(positionals) != 1 or keys:
            raise self._error(
                directive=args[0],
                msg="Must specify exactly one serialization mode",
            )
        out = self._annotation()
        tab = ""
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
            tab = "  "
        self._calls.add(_METHODS["mode"])
        value = positionals[0]
        rendered = str(_MODES[value]) if value in _MODES else value
        out += tab + f"call {_METHODS['mode']}({rendered})\n"
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_data(self, args: list[str], *, isacc: bool = False) -> None:
        positionals, keys, values, if_statement = self._parse_args(args)
        if positionals:
            raise self._error(
                directive=args[0],
                msg="Must specify only field=value pairs",
            )
        self._calls.add(_METHODS["datawrite"])
        self._calls.add(_METHODS["dataread"])
        self._calls.add(_METHODS["getmode"])

        out = self._annotation()
        tab = ""
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
            tab = "  "

        self._track_intentin(values)

        out += tab + f"SELECT CASE ( {_METHODS['getmode']}() )\n"
        out += tab + f"  CASE({_MODES['write']})\n"
        for key, value in zip(keys, values, strict=True):
            if isacc:
                out += self._acc_update("HOST", value, tab)
            out += (
                tab
                + "    "
                + (
                    f"call {_METHODS['datawrite']}"
                    f"(ppser_serializer, ppser_savepoint, '{key}', {value})\n"
                )
            )
        out += tab + f"  CASE({_MODES['read']})\n"
        for key, value in zip(keys, values, strict=True):
            if _is_computed(value):
                continue
            out += (
                tab
                + "    "
                + (
                    f"call {_METHODS['dataread']}"
                    f"(ppser_serializer_ref, ppser_savepoint, '{key}', {value})\n"
                )
            )
            if isacc:
                out += self._acc_update("DEVICE", value, tab)
        out += tab + f"  CASE({_MODES['read-perturb']})\n"
        for key, value in zip(keys, values, strict=True):
            if _is_computed(value):
                continue
            out += (
                tab
                + "    "
                + (
                    f"call {_METHODS['dataread']}"
                    f"(ppser_serializer_ref, ppser_savepoint, '{key}', {value}, "
                    "ppser_zrperturb)\n"
                )
            )
            if isacc:
                out += self._acc_update("DEVICE", value, tab)
        out += tab + "END SELECT\n"
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_accdata(self, args: list[str]) -> None:
        self._ser_data(args, isacc=True)

    def _ser_data_kbuff(self, args: list[str]) -> None:
        positionals, keys, values, if_statement = self._parse_args(args)
        if positionals:
            raise self._error(
                directive=args[0],
                msg="Must specify only field=value pairs",
            )
        out = self._annotation()
        tab = ""
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
            tab = "  "

        pairs = dict(zip(keys, values, strict=True))
        if "k" not in pairs or "k_size" not in pairs:
            raise self._error(
                directive=args[0],
                msg="Must specify k and k_size key=value pairs",
            )
        # Only the serialized field values may be assigned in read mode; the
        # k / k_size index expressions are never written, so their INTENT(IN)
        # must be preserved.
        self._track_intentin(
            [v for k, v in zip(keys, values, strict=True) if k not in ("k", "k_size")]
        )
        k_value = pairs["k"]
        k_size = pairs["k_size"]
        self._calls.add(_METHODS["getmode"])
        self._calls.add(_METHODS["datakbuff"])
        for key, value in zip(keys, values, strict=True):
            if key in ("k", "k_size"):
                continue
            out += (
                tab
                + "    "
                + (
                    f"call {_METHODS['datakbuff']}"
                    f"(ppser_serializer, ppser_savepoint, '{key}', {value}, "
                    f"k={k_value}, k_size={k_size}, mode={_METHODS['getmode']}())\n"
                )
            )
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_tracer(self, args: list[str]) -> None:
        specs, if_statement = self._parse_tracers(args)
        out = self._annotation()
        tab = ""
        if if_statement:
            out += f"IF ({if_statement}) THEN\n"
            tab = "  "
        for ident, stype, timelevel in specs:
            assert ident is not None
            function = "ppser_write_tracer_"
            fargs: list[str] = []
            if ident == "%all":
                function += "all"
            elif ident[0] == "$":
                function += "by_idx"
                idxs = ident[1:]
                fargs += idxs.split("-") if "-" in idxs else [idxs]
            else:
                function += "by_name"
                fargs.append(f"'{ident}'")
            self._calls.add(function)
            fargs.append(f"stype='{stype or ''}'")
            if timelevel:
                fargs.append(f"timelevel={timelevel}")
            out += tab + f"call {function}({', '.join(fargs)})\n"
        if if_statement:
            out += "ENDIF\n"
        self._line = out

    def _ser_on(self, args: list[str]) -> None:
        self._require_no_args(args)
        self._calls.add(_METHODS["on"])
        self._line = self._annotation() + f"call {_METHODS['on']}()\n"

    def _ser_off(self, args: list[str]) -> None:
        self._require_no_args(args)
        self._calls.add(_METHODS["off"])
        self._line = self._annotation() + f"call {_METHODS['off']}()\n"

    # -- shared helpers -----------------------------------------------------

    def _require_no_args(self, args: list[str]) -> None:
        """Reject any token after the keyword for a no-argument directive."""
        if len(args) != 1:
            raise self._error(directive=args[0], msg="Takes no arguments")

    def _acc_update(self, direction: str, value: str, tab: str) -> str:
        """An OpenACC ``UPDATE`` directive line for an ACCDATA field."""
        line = f"{tab}    ACC_PREFIX UPDATE {direction} ( {value} )"
        if self.options.acc_if:
            line += f", IF ({self.options.acc_if}) "
        return line + "\n"

    def _track_intentin(self, values: list[str]) -> None:
        """Record DATA value variables whose INTENT(IN) must later be stripped."""
        for value in values:
            base = re.sub(r"\(.+\)", "", value)
            if base not in self.intentin_to_remove:
                self.intentin_to_remove.append(base)

    def _error(self, *, msg: str, directive: str = "") -> DirectiveError:
        return DirectiveError(
            msg,
            filename=self.filename,
            lineno=self._lineno,
            directive=directive,
            line=self._line,
        )
