# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Fit of the LUT and flip-flop model of tools/ocp_estimate.py to synthesis results.

Usage: python tools/ocp_estimate_fit.py --collect --tool TOOL [--device DEVICE]
       python tools/ocp_estimate_fit.py [--check]
--collect writes the calibration file tools/tests/calibration_<device>.json from the results of tools/synth_libero.py
in libero_out/<device>/ (tools/libero_summary.py) with the tool (for example "Libero SoC 2025.2"), the synthesis build
and the date of the runs; only configurations of ocp_estimate.SWEEP are taken. Without options the script fits the
LUT and flip-flop counts of the calibration file by least squares over ocp_estimate.logic_features() and prints the
coefficients, the leave-one-out error and the residual of every configuration. --check fails when the coefficients
of ocp_estimate.LOGIC_MODEL are not those of the fit.
"""

import argparse
import datetime
import json
import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import libero_summary  # noqa: E402
import ocp_estimate  # noqa: E402
import ocp_generics  # noqa: E402

TARGETS = {"polarfire": "PolarFire MPF100T (FCG484, STD speed grade, industrial range)"}


def calibration_file(device):
    return ROOT / "tools" / "tests" / f"calibration_{device}.json"


def collect(device, tool):
    rows = [r for r in libero_summary.results(device) if r["name"] in ocp_estimate.SWEEP]
    if not rows:
        sys.exit(f"no results of the sweep configurations in libero_out/{device}/")
    builds = sorted({r["tool"] for r in rows})
    dates = sorted(datetime.datetime.strptime(" ".join(r["date"].split()), "%a %b %d %H:%M:%S %Y").date()
                   for r in rows)
    cal = {
        "target": TARGETS[device],
        "tool": tool,
        "synthesis": builds,
        "dates": [dates[0].isoformat(), dates[-1].isoformat()],
        "rows": [{"name": r["name"], "lut": r["lut"], "ff": r["ff"], "lsram": r["lsram"], "usram": r["usram"],
                  "math": r["math"], "fmaxMHz": r["fmax_pr"]} for r in rows],
    }
    calibration_file(device).write_text(json.dumps(cal, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"{calibration_file(device).relative_to(ROOT).as_posix()}: {len(rows)} configurations")


def features(name):
    cfg, extra = ocp_estimate.SWEEP[name]
    return ocp_estimate.logic_features(dict(ocp_generics.generics(cfg), **extra))


def least_squares(x, y):
    """Exact least squares solution of x c = y (integer rows): the normal equations solved in rational arithmetic, so
    that the coefficients do not depend on the platform. A coefficient the data does not determine is 0."""
    n = len(x[0])
    a = [[Fraction(sum(r[i] * r[j] for r in x)) for j in range(n)] + [Fraction(sum(r[i] * v for r, v in zip(x, y)))]
         for i in range(n)]
    pivots = []
    row = 0
    for col in range(n):
        piv = next((k for k in range(row, n) if a[k][col] != 0), None)
        if piv is None:
            continue
        a[row], a[piv] = a[piv], a[row]
        a[row] = [v / a[row][col] for v in a[row]]
        for k in range(n):
            if k != row and a[k][col] != 0:
                f = a[k][col]
                a[k] = [vk - f * vr for vk, vr in zip(a[k], a[row])]
        pivots.append(col)
        row += 1
    coef = [Fraction(0)] * n
    for r, col in enumerate(pivots):
        coef[col] = a[r][n]
    return coef


def fit(rows, key, names):
    """Least squares coefficients of the features `names` for the column `key` of the rows, and the leave-one-out
    relative error of every row."""
    x = [[features(r["name"])[n] for n in names] for r in rows]
    y = [r[key] for r in rows]
    coef = least_squares(x, y)
    loo = []
    for i in range(len(rows)):
        c = least_squares(x[:i] + x[i + 1:], y[:i] + y[i + 1:])
        loo.append(float(sum(ci * xi for ci, xi in zip(c, x[i])) - y[i]) / y[i])
    return [float(c) for c in coef], loo


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--device", default="polarfire", choices=sorted(TARGETS))
    p.add_argument("--collect", action="store_true")
    p.add_argument("--tool", help="tool name and version for --collect, for example \"Libero SoC 2025.2\"")
    p.add_argument("--check", action="store_true")
    a = p.parse_args()
    if a.collect:
        if not a.tool:
            p.error("--collect needs --tool")
        collect(a.device, a.tool)
        return 0
    cal = json.loads(calibration_file(a.device).read_text(encoding="utf-8"))
    rows = cal["rows"]
    names = list(features(rows[0]["name"]))
    ok = True
    for key in ("lut", "ff"):
        coef, loo = fit(rows, key, names)
        model = {n: round(float(c), 1) for n, c in zip(names, coef)}
        err = [abs(e) for e in loo]
        print(f"{key}: leave-one-out error mean {sum(err) / len(err):.1%}, max {max(err):.1%} "
              f"({len(rows)} configurations)")
        print("    " + ", ".join(f"{n} {c}" for n, c in model.items()))
        for r, e in zip(rows, loo):
            print(f"    {r['name']:28s} {r[key]:7d} {e:+7.1%}")
        if a.check and ocp_estimate.LOGIC_MODEL.get(a.device, {}).get(key) != model:
            print(f"{key}: ocp_estimate.LOGIC_MODEL differs from the fit of {calibration_file(a.device).name}")
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
