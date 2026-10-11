# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""CCSDS 123.0-B-2 compliance matrix of OpenCompact.

Usage: python tools/compliance.py [--check]
Reads the requirement traceability matrix of docs/architecture.md (section 10), the requirements of every
hdl/<module>/docs/specification.md (ID and CCSDS clauses) and the test cases of every verification_plan.md (test and
requirement IDs), and writes docs/compliance.md: for every CCSDS clause of the matrix the requirements that trace to it
and the test cases that verify them. With --check the file is not written; the exit code is 1 when a clause in the
scope of the core has no test case.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "compliance.md"
CLAUSE_RE = re.compile(r"\d+(?:\.\d+)+")
# Clause with optional sub-item letters and an optional range end: '5.5.2.3 to 5.5.2.13', '5.7.10a1'
RANGE_RE = re.compile(r"(\d+(?:\.\d+)+)(?:[a-z]+\d*)?(?:\s+to\s+(\d+(?:\.\d+)+))?")


def table_rows(text):
    """Rows of markdown tables as lists of cells (header and separator rows included)."""
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("|") and line.endswith("|"):
            yield [c.strip() for c in line.strip("|").split("|")]


def clauses(cell):
    """Base clause numbers of a clause cell, ranges expanded: '5.6.9.3, 5.6.8c4' -> ['5.6.9.3', '5.6.8'],
    '5.7.4.1 to 5.7.4.3' -> ['5.7.4.1', '5.7.4.2', '5.7.4.3']."""
    result = []
    for m in RANGE_RE.finditer(cell):
        first, last = m.group(1), m.group(2)
        if last:
            fp, lp = first.split("."), last.split(".")
            if len(fp) == len(lp) and fp[:-1] == lp[:-1] and int(fp[-1]) <= int(lp[-1]):
                result += [".".join(fp[:-1] + [str(n)]) for n in range(int(fp[-1]), int(lp[-1]) + 1)]
            else:
                result += [first, last]
        else:
            result.append(first)
    return result


def expand_ids(cell):
    """Requirement IDs of a test row: 'ML-IF-01, ML-DS-01 to 04, DL-QS-01, 02' -> full list."""
    ids = []
    prefix = None
    last = None
    for part in [p.strip() for p in cell.split(",")]:
        m = re.match(r"^([A-Z]+(?:-[A-Z0-9]+)*-)(\d+)(?:\s+to\s+(?:[A-Z]+(?:-[A-Z0-9]+)*-)?(\d+))?", part)
        if m:
            prefix, first = m.group(1), int(m.group(2))
            last_n = int(m.group(3)) if m.group(3) else first
            width = len(m.group(2))
            ids += [f"{prefix}{n:0{width}d}" for n in range(first, last_n + 1)]
            last = (prefix, width)
            continue
        m = re.match(r"^(\d+)(?:\s+to\s+(\d+))?$", part)
        if m and last:
            prefix, width = last
            first = int(m.group(1))
            last_n = int(m.group(2)) if m.group(2) else first
            ids += [f"{prefix}{n:0{width}d}" for n in range(first, last_n + 1)]
    return ids


def load_requirements():
    """Requirements of the module specifications: ID -> (module, CCSDS clauses). Block rows (NI-1) are skipped."""
    reqs = {}
    for spec in sorted(ROOT.glob("hdl/*/docs/specification.md")):
        module = spec.parent.parent.name
        for row in table_rows(spec.read_text(encoding="utf-8")):
            if len(row) >= 3 and re.match(r"^[A-Z]+(-[A-Z0-9]+)*-\d{2}$", row[0]):
                reqs[row[0]] = (module, clauses(row[-1]))
    return reqs


def load_tests():
    """Test cases of the verification plans: test ID -> requirement IDs. Also returns the test names of the plans
    that no testbench of the repository runs."""
    tests = {}
    names = set()
    for plan in sorted(ROOT.glob("hdl/*/docs/verification_plan.md")):
        for row in table_rows(plan.read_text(encoding="utf-8")):
            if len(row) >= 3 and row[0].startswith("`test_"):
                m = re.search(r"\((TC-[A-Z]+-\d+)\)", row[0])
                tid = m.group(1) if m else row[0]
                tests.setdefault(tid, set()).update(expand_ids(row[-1]))
                names.add(row[0].split("`")[1])
            elif len(row) >= 3 and re.match(r"^TC-[A-Z]+-\d+", row[0]):
                # Rows that reference test IDs directly (for example "TC-CORE-02 (two configurations)")
                for tid in re.findall(r"TC-[A-Z]+-\d+", row[0]):
                    tests.setdefault(tid, set()).update(expand_ids(row[-1]))
    run_names = set()
    for tb in ROOT.glob("hdl/*/tb/*.vhd"):
        run_names.update(re.findall(r'run\("(test_\w+)"\)', tb.read_text(encoding="utf-8")))
    return tests, sorted(names - run_names)


def load_matrix():
    text = (ROOT / "docs" / "architecture.md").read_text(encoding="utf-8")
    section = text[text.index("## 10 Requirement traceability matrix"):text.index("## 11 ")]
    rows = []
    for row in table_rows(section):
        if len(row) >= 5 and CLAUSE_RE.match(row[0]):
            rows.append(row[:5])
    return rows


def matches(req_clauses, row_clauses):
    for rc in req_clauses:
        for c in row_clauses:
            if rc == c or rc.startswith(c + "."):
                return True
    return False


def test_key(tid):
    parts = tid.split("-")
    return (parts[1], int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0)


def main():
    reqs = load_requirements()
    tests, not_run = load_tests()
    matrix = load_matrix()
    lines = [
        "# OpenCompact: CCSDS 123.0-B-2 Compliance Matrix",
        "",
        "Generated by `python tools/compliance.py` from the requirement traceability matrix of the",
        "[architecture](architecture.md) (section 10), the requirements of the module specifications and the test cases",
        "of the module verification plans. `python tools/compliance.py --check` fails when a clause or a requirement",
        "has no test case, or when a test case of a plan is not run by a testbench.",
        "",
        "## 1. CCSDS 123.0-B-2 clauses",
        "",
        "A clause is listed with every requirement whose CCSDS reference lies in the clause, and with the test cases that",
        "verify these requirements. The interpretations of the standard are listed in the sections \"Interpretation of",
        "the standard\" of the module specifications.",
        "",
        "| CCSDS clause | Title | Owner | Requirements | Test cases | Status |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    missing = []
    for clause, title, owner, _, level in matrix:
        cl = clauses(clause)
        req_ids = sorted(r for r, (_, rc) in reqs.items() if matches(rc, cl))
        test_ids = sorted({t for t, ids in tests.items() if ids & set(req_ids)}, key=test_key)
        if owner.startswith("Out of scope"):
            status = "Out of scope"
        elif owner.startswith("Not implemented"):
            status = "Not implemented (permission)"
        elif test_ids and level == "Target":
            status = "Interface verified; target hardware"
        elif test_ids:
            status = "Verified"
        else:
            status = "Not traced"
            missing.append(clause)
        lines.append(f"| {clause} | {title} | {owner} | {', '.join(req_ids) or '-'} | {', '.join(test_ids) or '-'} | "
                     f"{status} |")
    lines += [
        "",
        f"Clauses: {len(matrix)}; verified: {sum(1 for line in lines if line.endswith('| Verified |'))}; "
        f"not traced: {len(missing)}.",
        "",
        "## 2. Requirements",
        "",
        "Requirements of the module specifications and the test cases that verify them (requirements without a CCSDS",
        "reference included).",
        "",
        "| Module | Requirements | Verified by a test case | Without a test case |",
        "| --- | --- | --- | --- |",
    ]
    covered = set().union(*tests.values())
    untested = sorted(r for r in reqs if r not in covered)
    for module in sorted({m for m, _ in reqs.values()}):
        ids = [r for r, (m, _) in reqs.items() if m == module]
        gaps = [r for r in ids if r not in covered]
        lines.append(f"| `{module}` | {len(ids)} | {len(ids) - len(gaps)} | {', '.join(gaps) or '-'} |")
    lines += [
        "",
        f"Requirements: {len(reqs)}; without a test case: {len(untested)}; test cases of the plans not run by a "
        f"testbench: {len(not_run)}.",
        "",
    ]
    if "--check" not in sys.argv:
        OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
        print(f"written {OUT.relative_to(ROOT)}")
    for c in missing:
        print(f"clause not traced: {c}")
    for r in untested:
        print(f"requirement without a test case: {r}")
    for n in not_run:
        print(f"test case of a plan not run by a testbench: {n}")
    failed = missing or untested or not_run
    sys.exit(1 if failed and "--check" in sys.argv else 0)


if __name__ == "__main__":
    main()
