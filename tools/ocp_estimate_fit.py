# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Fit of the LUT, flip-flop and clock frequency models of tools/ocp_estimate.py to synthesis results.

Usage: python tools/ocp_estimate_fit.py --collect --tool TOOL [--device DEVICE]
       python tools/ocp_estimate_fit.py [--write | --check] [--device DEVICE]
--collect writes the calibration file tools/tests/calibration_<device>.json from the results of tools/synth_libero.py
in libero_out/<device>/ (tools/libero_summary.py) with the tool (for example "Libero SoC 2025.2"), the synthesis build
and the date of the runs; only configurations of ocp_estimate.SWEEP are taken, and a run whose place and route step
did not start because the top level has more I/O than the device is marked (its synthesis result is complete).

Without options the script fits the models to the calibration file and prints them with their errors; --write also
writes them to tools/estimate/ocp_models.mjs, from which ocp_resources.mjs and tools/ocp_estimate.py read them. The configurations of CHECK_SET are kept out of the fit and only checked. LUT and flip-flops: least
squares of the relative error over ocp_estimate.logic_features(), with the coefficients of features other than the
base kept at or above 0 (a feature with a negative coefficient is dropped and the fit repeated). Clock frequency:
least squares of the clock period in picoseconds over ocp_estimate.clock_features() for the place and route runs.
The errors are those of ocp_estimate.estimate_resources() with the rounded coefficients. --check fails when
tools/estimate/ocp_models.mjs is not the fit of the calibration files.
"""

import argparse
import datetime
import json
import math
import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import libero_summary  # noqa: E402
import ocp_estimate  # noqa: E402
import ocp_generics  # noqa: E402
import ocp_wrapper  # noqa: E402

TARGETS = {"polarfire": "PolarFire MPF100T (STD)"}

# Configurations kept out of the fit: user guide configurations that combine several options
CHECK_SET = ("c04_near_abs_hybrid", "c06_near_both_block", "c20_hybrid_d28", "c26_tp_bil_near_abs",
             "c30_tp_bip_both_stride")

# The configurations of user guide section 8.2
USER_GUIDE = ("c01_lossless_bip", "c03_lossless_bsq_narrow", "c04_near_abs_hybrid", "c06_near_both_block",
              "c11_wide_d32", "c20_hybrid_d28", "c25_tp_bsq_lossless", "c26_tp_bil_near_abs", "c27_tp_bip_full",
              "c29_tp_bip_near_stride", "c30_tp_bip_both_stride")

IO_NOTE = "synthesis only, I/O exceeds the device"


def calibration_file(device):
    return ROOT / "tools" / "tests" / f"calibration_{device}.json"


def collect(device, tool):
    rows = [r for r in libero_summary.results(device) if r["name"] in ocp_estimate.SWEEP]
    if not rows:
        sys.exit(f"no results of the sweep configurations in libero_out/{device}/")
    builds = sorted({r["tool"] for r in rows})
    dates = sorted(datetime.datetime.strptime(" ".join(r["date"].split()), "%a %b %d %H:%M:%S %Y").date()
                   for r in rows)
    out = []
    for r in rows:
        row = {"name": r["name"], "lut": r["lut"], "ff": r["ff"], "lsram": r["lsram"], "usram": r["usram"],
               "math": r["math"], "fmaxMHz": r["fmax_pr"]}
        log = ROOT / "libero_out" / device / r["name"] / "libero.log"
        if log.exists() and "Number of I/O modules" in log.read_text(errors="replace"):
            row["note"] = IO_NOTE
        out.append(row)
    cal = {
        "target": TARGETS[device],
        "tool": tool,
        "synthesis": builds,
        "dates": [dates[0].isoformat(), dates[-1].isoformat()],
        "outWidth": ocp_wrapper.OUT_WIDTH,
        "rows": out,
    }
    calibration_file(device).write_text(json.dumps(cal, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"{calibration_file(device).relative_to(ROOT).as_posix()}: {len(out)} configurations")


def generics(name):
    """The generics of a sweep point, with the output width of its synthesis top level (tools/synth_libero.py)."""
    cfg, extra = ocp_estimate.SWEEP[name]
    g = dict(ocp_generics.generics(cfg), OutWidth_g=ocp_wrapper.OUT_WIDTH)
    g.update(extra)
    return g


def features(name):
    return ocp_estimate.logic_features(generics(name))


def least_squares(x, y):
    """Exact least squares solution of x c = y (rational rows): the normal equations solved in rational arithmetic, so
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


def fit_logic(rows, key):
    """Coefficients (one decimal) of the relative least squares fit of the column key, all but the base >= 0."""
    names = list(features(rows[0]["name"]))
    active = list(names)
    while True:
        x = [[Fraction(features(r["name"])[n], r[key]) for n in active] for r in rows]
        coef = dict(zip(active, least_squares(x, [1] * len(rows))))
        negative = [n for n, c in coef.items() if c < 0 and n != "base"]
        if not negative:
            break
        active = [n for n in active if n not in negative]
    return {n: round(float(coef.get(n, 0)), 1) + 0.0 for n in names}


def fit_clock(rows):
    """Coefficients (picoseconds) of the least squares fit of the clock period of the place and route runs."""
    names = list(ocp_estimate.clock_features(generics(rows[0]["name"])))
    x = [[ocp_estimate.clock_features(generics(r["name"]))[n] for n in names] for r in rows]
    y = [Fraction(10 ** 6) / Fraction(str(r["fmaxMHz"])) for r in rows]
    return {n: round(float(c)) for n, c in zip(names, least_squares(x, y))}


def errors(rows, key, estimate):
    """Relative error of the estimate of every row: name -> error."""
    return {r["name"]: estimate(generics(r["name"])) / r[key] - 1 for r in rows if r.get(key)}


def stats(err, names=None):
    e = [v for n, v in err.items() if names is None or n in names]
    return math.sqrt(sum(v * v for v in e) / len(e)), max(abs(v) for v in e), len(e)


def fit(cal):
    """The model of the calibration data, with the errors of every resource for the notes and the report."""
    rows = cal["rows"]
    fit_rows = [r for r in rows if r["name"] not in CHECK_SET]
    model = {"lut": fit_logic(fit_rows, "lut"), "ff": fit_logic(fit_rows, "ff"),
             "period_ps": fit_clock([r for r in fit_rows if r["fmaxMHz"]])}
    est = {
        "lut": lambda g: ocp_estimate.linear_estimate(model["lut"], ocp_estimate.logic_features(g)),
        "ff": lambda g: ocp_estimate.linear_estimate(model["ff"], ocp_estimate.logic_features(g)),
        "fmaxMHz": lambda g: ocp_estimate.clock_estimate(model["period_ps"], ocp_estimate.clock_features(g)),
    }
    err = {key: errors(rows, key, est[key]) for key in est}
    pr = [r for r in rows if r["fmaxMHz"]]
    n_check = len(CHECK_SET)

    def figures(key):
        rms, mx, _ = stats(err[key])
        crms, cmx, _ = stats(err[key], CHECK_SET)
        return f"RMS {rms:.1%}, max {mx:.1%} ({crms:.1%} and {cmx:.1%} for the {n_check} runs kept out of the fit)"

    source = (f"{cal['target']}, {cal['tool']} ({', '.join(cal['synthesis'])}), {cal['outWidth']}-bit output, runs "
              f"of {cal['dates'][-1]}")
    ug_rms, ug_max, n_ug = stats(err["lut"], USER_GUIDE)
    rest = [n for n in USER_GUIDE if n != "c11_wide_d32"]
    rest_rms, rest_max, _ = stats(err["lut"], rest)
    model["notes"] = [
        f"LUT and flip-flops: {source}; a linear model over the structure of the configuration, fitted to "
        f"{len(fit_rows)} of {len(rows)} synthesis runs. Error against all runs: LUT {figures('lut')}; flip-flops "
        f"{figures('ff')}.",
        f"LUT of the {n_ug} configurations of user guide section 8.2: RMS {ug_rms:.1%}, max {ug_max:.1%} "
        f"(c11_wide_d32); without c11_wide_d32 RMS {rest_rms:.1%}, max {rest_max:.1%}.",
        f"Clock frequency: place and route for a 100 MHz constraint, a linear model of the clock period fitted to "
        f"{len([r for r in fit_rows if r['fmaxMHz']])} of {len(pr)} runs. Error against all runs: {figures('fmaxMHz')}.",
    ]
    return model, err


def models_text(models):
    """The generated module tools/estimate/ocp_models.mjs with the models of every target."""
    return ("// SPDX-License-Identifier: MIT\n"
            "// Copyright (c) 2026 by Julian Schneider\n"
            "//\n"
            "// The resource models of ocp_core for every target: generated by tools/ocp_estimate_fit.py from the\n"
            "// calibration files tools/tests/calibration_<target>.json, do not edit. ocp_resources.mjs and\n"
            "// tools/ocp_estimate.py read them.\n"
            "// @ts-check\n"
            "/** @type {Record<string, { lut: Record<string, number>, ff: Record<string, number>,\n"
            " *   period_ps: Record<string, number>, notes: string[] }>} */\n"
            f"export const MODELS = {json.dumps(models, indent=2)};\n")


def report(model, err):
    for key in ("lut", "ff", "fmaxMHz"):
        for label, names in (("all", None), ("check set", CHECK_SET), ("user guide", USER_GUIDE),
                             ("user guide without c11", [n for n in USER_GUIDE if n != "c11_wide_d32"])):
            rms, mx, n = stats(err[key], names)
            print(f"{key:8s} {label:24s} {n:3d} runs: RMS {rms:6.1%}, max {mx:6.1%}")
    print("\n" + json.dumps(model, indent=1))
    print("\nErrors of every run (* check set):")
    for name in err["lut"]:
        cells = [f"{k} {err[k][name]:+6.1%}" for k in ("lut", "ff", "fmaxMHz") if name in err[k]]
        print(f"    {name:28s}{'*' if name in CHECK_SET else ' '} " + ", ".join(cells))


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--device", default="polarfire", choices=sorted(TARGETS))
    p.add_argument("--collect", action="store_true")
    p.add_argument("--tool", help="tool name and version for --collect, for example \"Libero SoC 2025.2\"")
    p.add_argument("--check", action="store_true")
    p.add_argument("--write", action="store_true", help="write the models to tools/estimate/ocp_models.mjs")
    a = p.parse_args()
    if a.collect:
        if not a.tool:
            p.error("--collect needs --tool")
        collect(a.device, a.tool)
        return 0
    cal = json.loads(calibration_file(a.device).read_text(encoding="utf-8"))
    model, err = fit(cal)
    text = models_text(dict(ocp_estimate.MODELS, **{a.device: model}))
    out = ocp_estimate.MODELS_FILE
    if a.check:
        if out.read_text(encoding="utf-8") != text:
            print(f"{out.relative_to(ROOT).as_posix()} is not the fit of {calibration_file(a.device).name}: run "
                  "python tools/ocp_estimate_fit.py --write")
            return 1
        print(f"{out.relative_to(ROOT).as_posix()} is up to date")
        return 0
    report(model, err)
    if a.write:
        out.write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {out.relative_to(ROOT).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
