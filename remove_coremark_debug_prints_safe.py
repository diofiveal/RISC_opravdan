#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path.cwd()
PIPE = ROOT / "scr1/src/core/pipeline"

TAGS = ("[DBG-", "[FOCUS-", "[IFU-DBG]")

def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

if not PIPE.is_dir():
    die("run this script from the RISC_opravdan repository root")

def read_text_keep_encoding(path):
    data = path.read_bytes()
    for enc in ("utf-8", "cp1251"):
        try:
            return data.decode(enc), enc
        except UnicodeDecodeError:
            pass
    die(f"cannot decode {path} as UTF-8 or CP1251")

def find_statement_end(text, start):
    """
    Find the semicolon terminating a $display/$write statement.
    Handles multiline format strings and parentheses.
    """
    paren = 0
    in_string = False
    escape = False
    i = start

    while i < len(text):
        ch = text[i]

        if in_string:
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == '(':
                paren += 1
            elif ch == ')':
                if paren > 0:
                    paren -= 1
            elif ch == ';' and paren == 0:
                return i + 1
        i += 1

    return None

def strip_tagged_displays(text, path):
    # Collect edits first, then apply backwards so indices remain valid.
    edits = []
    pos = 0

    call_re = re.compile(r'\$(?:display|write)\b')

    while True:
        m = call_re.search(text, pos)
        if not m:
            break

        end = find_statement_end(text, m.start())
        if end is None:
            die(f"{path}: unterminated {m.group(0)} near character {m.start()}")

        stmt = text[m.start():end]
        if any(tag in stmt for tag in TAGS):
            # Keep line structure reasonably clean. Remove indentation before
            # the call only when nothing else appears on that line.
            line_start = text.rfind('\n', 0, m.start()) + 1
            prefix = text[line_start:m.start()]
            rm_start = line_start if prefix.strip() == "" else m.start()

            # Also consume one following newline if the statement occupied
            # its own line; this avoids leaving blank whitespace-only lines.
            rm_end = end
            if rm_start == line_start:
                j = end
                while j < len(text) and text[j] in " \t\r":
                    j += 1
                if j < len(text) and text[j] == '\n':
                    rm_end = j + 1

            edits.append((rm_start, rm_end, stmt.splitlines()[0].strip()))

        pos = end

    if not edits:
        return text, 0

    for start, end, _ in reversed(edits):
        text = text[:start] + text[end:]

    return text, len(edits)

total = 0
changed_files = []

# Search the whole pipeline so no verbose trace is missed.
for path in sorted(PIPE.glob("*.sv")):
    text, enc = read_text_keep_encoding(path)
    new_text, removed = strip_tagged_displays(text, path)

    if removed:
        path.write_text(new_text, encoding=enc)
        total += removed
        changed_files.append((path, enc, removed))
        print(f"[remove] {path.name}: {removed} display(s), encoding={enc}")

# Verify no tagged print call remains.
leftovers = []
for path in sorted(PIPE.glob("*.sv")):
    text, _ = read_text_keep_encoding(path)
    for m in re.finditer(r'\$(?:display|write)\b', text):
        end = find_statement_end(text, m.start())
        if end is not None:
            stmt = text[m.start():end]
            if any(tag in stmt for tag in TAGS):
                leftovers.append(path.name)

if leftovers:
    die("tagged debug display still present in: " + ", ".join(sorted(set(leftovers))))

print()
if total:
    print(f"Done: removed {total} verbose debug print statement(s).")
else:
    print("No tagged debug print statements found.")

print("Assertions and $error statements were not touched.")
print()
print("Check:")
print("  git diff --check")
print(r"""  grep -R -nE '\[DBG-|\[FOCUS-|\[IFU-DBG\]' scr1/src/core/pipeline || true""")
