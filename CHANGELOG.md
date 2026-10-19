# Changelog

The notable changes of OpenCompact. The versions follow semantic versioning: 0.y.z while the core is at TRL 3, a
major version for an incompatible change of ports, stream formats, generics or register map, a minor version for a
feature and a patch version for a fix.

## [0.1.1] - 2026-10-19

### Fixed

- The AMD Vivado simulator (xsim) stopped at time 0 with "Index 2 out of bound 1 downto 0" in `ocp_predictor`. The
  array fields of the predictor items now use fully constrained array types; xsim gave the element of an
  index-constrained field the constraint of another field when the record was accessed through an alias. The
  behaviour is unchanged in every simulator.

### Changed

- QuestaSim runs with a time resolution of 1 fs, as GHDL (`run.py`).

### Added

- `lint/xsim_smoke.py`: elaborates and simulates every top level of the synthesis check in xsim.

## [0.1.0] - 2026-10-18

First release. The CCSDS 123.0-B-2 compressor `ocp_core` with all options of the standard, the image framing with
deterministic aborted images, and the compression channel `ocp_channel` with the input adapter for an
AXI4-Stream of samples and the status registers on AXI4-Lite. Verified by simulation (TRL 3) in GHDL and QuestaSim.

Known issue: the AMD Vivado simulator (xsim) stops at time 0 in `ocp_predictor` (fixed in 0.1.1).
