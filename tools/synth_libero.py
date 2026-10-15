# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Synthesis (and optionally place and route with timing) of ocp_core with Microchip Libero SoC.

Usage: python tools/synth_libero.py --config <configuration> [--family F --die D --package P] [--clk-mhz F] [--impl]
       [--in-last]
Writes libero_out/<configuration>/ (synthesis top level of the configuration, Tcl script, project and reports) and
runs Libero in batch mode (`libero` must be on the PATH, for example Libero_SoC/Designer/bin). With --in-last the core
has the image framing (UseInLast_g) and the results go to libero_out/<configuration>_last/.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import ocp_configs  # noqa: E402
import ocp_wrapper  # noqa: E402

OLO_AREAS = ("base", "ft")


def sources():
    """Open Logic sources (compile order of Open Logic) and OpenCompact sources (packages first)."""
    olo = []
    for line in (ROOT / "open-logic" / "compile_order.txt").read_text().splitlines():
        rel = line.strip()
        if rel and rel.split("/")[1] in OLO_AREAS:
            olo.append(ROOT / "open-logic" / rel)
    ocp = []
    for line in (ROOT / "component_list.txt").read_text().splitlines():
        name = line.strip()
        if name and not name.startswith("#"):
            ocp += sorted((ROOT / name / "src").glob("*.vhd"))
    ocp.sort(key=lambda f: 0 if f.stem == "ocp_pkg" else 1 if f.stem.endswith("_pkg") else 2)
    return olo, ocp

DEVICES = {
    "polarfire": ("PolarFire", "MPF100T", "FCG484", "1.0", "IND"),
    "rtg4": ("RTG4", "RT4G150", "1657 CG", "1.2", "MIL"),
}


def tcl(out, device, clk_mhz, impl):
    family, die, package, voltage, prange = DEVICES[device]
    olo, ocp = sources()
    sdc = out / "constraint.sdc"
    sdc.write_text("create_clock -name {{Clk}} -period {:.3f} [get_ports {{Clk}}]\n".format(1000.0 / clk_mhz))
    lines = [
        f"new_project -location {{{(out / 'prj').as_posix()}}} -name {{ocp}} -hdl {{VHDL}} -family {{{family}}} "
        f"-die {{{die}}} -package {{{package}}} -speed {{STD}} -die_voltage {{{voltage}}} -part_range {{{prange}}}",
        'project_settings -vhdl_mode "VHDL_2008"',
        "add_library -library olo",
        "add_library -library opencompact",
    ]
    lines += [f"create_links -convert_EDN_to_HDL 0 -library olo -hdl_source {{{f.as_posix()}}}" for f in olo]
    lines += [f"create_links -convert_EDN_to_HDL 0 -library opencompact -hdl_source {{{f.as_posix()}}}" for f in ocp]
    lines += [
        f"create_links -convert_EDN_to_HDL 0 -library work -hdl_source {{{(out / 'ocp_synth_top.vhd').as_posix()}}}",
        "build_design_hierarchy",
        'set_root -module "ocp_synth_top::work"',
        f"create_links -convert_EDN_to_HDL 0 -sdc {{{sdc.as_posix()}}}",
        f"organize_tool_files -tool {{SYNTHESIZE}} -file {{{sdc.as_posix()}}} -module {{ocp_synth_top::work}} "
        "-input_type {constraint}",
        "run_tool -name {SYNTHESIZE}",
    ]
    if impl:
        st = out / "smarttime.tcl"
        # The 20 worst paths, the first 3 of them expanded
        st.write_text("report -type timing -analysis max -format text -max_paths 20 -max_expanded_paths 3 {}\n".format(
            (out / "max_timing.rpt").as_posix()))
        lines += [
            f"organize_tool_files -tool {{PLACEROUTE}} -file {{{sdc.as_posix()}}} -module {{ocp_synth_top::work}} "
            "-input_type {constraint}",
            f"organize_tool_files -tool {{VERIFYTIMING}} -file {{{sdc.as_posix()}}} -module {{ocp_synth_top::work}} "
            "-input_type {constraint}",
            "run_tool -name {PLACEROUTE}",
            f"run_tool -name {{VERIFYTIMING}} -script {{{st.as_posix()}}}",
        ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", required=True)
    parser.add_argument("--device", default="polarfire", choices=sorted(DEVICES))
    parser.add_argument("--clk-mhz", type=float, default=100.0)
    parser.add_argument("--impl", action="store_true")
    parser.add_argument("--in-last", action="store_true", help="image framing (UseInLast_g)")
    parser.add_argument("--libero", default=shutil.which("libero") or
                        r"D:\Microchip\Libero_SoC_2025.2\Libero_SoC\Designer\bin\libero.exe")
    args = parser.parse_args()
    out = ROOT / "libero_out" / args.device / (args.config + ("_last" if args.in_last else ""))
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    top = ocp_wrapper.wrapper(ocp_configs.CONFIGS[args.config], use_in_last=args.in_last)
    (out / "ocp_synth_top.vhd").write_text(top, encoding="utf-8")
    script = out / "synth.tcl"
    script.write_text(tcl(out, args.device, args.clk_mhz, args.impl), encoding="utf-8")
    with open(out / "libero.log", "w") as log:
        res = subprocess.run([args.libero, "script:" + script.as_posix()], cwd=out, stdout=log,
                             stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=os.environ)
    sys.exit(res.returncode)


if __name__ == "__main__":
    main()
