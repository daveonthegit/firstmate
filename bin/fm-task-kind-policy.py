#!/usr/bin/env python3
"""Enforce the task metadata kind reader boundary.

Usage: python3 bin/fm-task-kind-policy.py [bin-directory]
Checks shell field accessors (including constant key/getter aliases), metadata
text filters, embedded/generated readers, and Python metadata dictionary reads.
Record writers, generic transport, and unrelated protocol kinds are permitted.
"""
import argparse
import ast
from pathlib import Path
import re
import shlex
import sys


OWNER = "fm-task-kind.sh"
GETTER = r"(?:(?!source_field\b|meta\b|metadata\b)[\w-]*(?:meta|field|value|_get)[\w-]*)"


def shell_violations(text):
    constants = {}
    aliases = set()
    lines = text.splitlines()
    for line in lines:
        match = re.search(r"\b(\w+)=(['\"]?)(kind|" + GETTER + r")\2(?:\s|;|$)", line)
        if match:
            constants[match[1]] = match[3]
        match = re.search(r"\b(\w+)\(\)\s*\{\s*(" + GETTER + r")\s", line)
        if match:
            aliases.add(match[1])
    getter = GETTER + ("|" + "|".join(re.escape(a) for a in aliases) if aliases else "")
    logical = []
    pending = ""
    start = 1
    for number, raw in enumerate(lines, 1):
        if not pending:
            start = number
        pending += raw[:-1] + " " if raw.endswith("\\") else raw
        if raw.endswith("\\"):
            continue
        logical.append((start, pending))
        pending = ""
    if pending:
        logical.append((start, pending))
    for number, raw in logical:
        if raw.lstrip().startswith("#"):
            continue
        line = raw
        for key, value in constants.items():
            line = re.sub(r"\$\{" + re.escape(key) + r"\}|\$" + re.escape(key) + r"\b", value, line)
        try:
            tokens = shlex.split(line, comments=True)
        except ValueError:
            tokens = [line]
        normalized = " ".join(tokens)
        field_read = re.search(r"\b(?:" + getter + r")\s+[^;\n]*?(?:\s|^)kind(?=\s|[);]|$)", normalized)
        filter_read = (re.search(r"\b(?:grep|sed|awk)\b", line)
                       and re.search(r"(?:\^kind(?:=|\b)|\$\w+\s*==\s*['\"]kind['\"]|\[['\"]kind['\"]\])", line))
        transport = re.search(r"\bgrep\s+-v\b", line)
        embedded_read = re.search(
            r"\b(?:meta|metadata|task_meta)(?:\.get\(\s*['\"]kind['\"]|\[['\"]kind['\"]\]|\.kind\b)", line)
        raw_read = re.search(r"\$\{\w+#kind=\}|case\b.*\bkind=\*\)|\$\w+\s*==\s*['\"]kind['\"]", line)
        if field_read or (filter_read and not transport) or embedded_read or raw_read:
            yield number, "task metadata kind must be read through fm_task_kind"


def python_violations(text):
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return
    meta_names = {"meta", "metadata", "task_meta"}
    key_names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and node.value.value == "kind":
            key_names.update(t.id for t in node.targets if isinstance(t, ast.Name))

    def kind_key(node):
        return ((isinstance(node, ast.Constant) and node.value == "kind")
                or (isinstance(node, ast.Name) and node.id in key_names))

    changed = True
    while changed:
        changed = False
        for node in ast.walk(tree):
            if isinstance(node, (ast.Assign, ast.AnnAssign)):
                value = node.value
                if isinstance(value, ast.Name) and value.id in meta_names:
                    targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                    for target in targets:
                        if isinstance(target, ast.Name) and target.id not in meta_names:
                            meta_names.add(target.id)
                            changed = True
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            if (node.func.attr == "get" and isinstance(node.func.value, ast.Name)
                    and node.func.value.id in meta_names and node.args
                    and kind_key(node.args[0])):
                yield node.lineno, "task metadata kind must delegate to fm-task-kind.sh"
        if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name):
            if (node.value.id in meta_names and kind_key(node.slice) and isinstance(node.ctx, ast.Load)):
                yield node.lineno, "task metadata kind must delegate to fm-task-kind.sh"


def violations(root):
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in {".sh", ".py", ".mjs", ".js"}:
            continue
        if path.relative_to(root).as_posix() == OWNER:
            continue
        text = path.read_text(encoding="utf-8")
        readers = list(shell_violations(text)) if path.suffix != ".py" else []
        readers += list(python_violations(text))
        for number, reason in sorted(set(readers)):
            yield f"{path}:{number}: {reason}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error("bin directory does not exist")
    errors = list(violations(args.root))
    for error in errors:
        print(error, file=sys.stderr)
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
