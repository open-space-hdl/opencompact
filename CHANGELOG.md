# Changelog

The notable changes of OpenCompact. The versions follow semantic versioning: 0.y.z while the core is at TRL 3, a
major version for an incompatible change of ports, stream formats, generics or register map, a minor version for a
feature and a patch version for a fix.

## [Unreleased]

### Added

- Runtime configuration (`RuntimeConfig_g`, default false): the image dimensions NX, NY, NZ (up to the maxima of the
  generics) and the band-independent error limit values of every image from new configuration ports of `ocp_core`
  (`Cfg_*`, `Cfg_Taken`, `Act_*`) or, in `ocp_channel`, from new AXI4-Lite registers of `ocp_mib` (CONTROL, STATUS,
  NEXT_X, NEXT_Y, NEXT_Z, NEXT_LIMITS). Values outside their ranges are taken as the nearest valid values. With the
  generic false the core is unchanged.
- LIMITS register: the band-independent error limit values (of the generics, or of the last image with the runtime
  configuration); GENERICS.RUNTIME_CONFIG.

### Fixed

- Throughput model (`tools/ocp_throughput.py`, user guide section 8.1): with the hybrid coder the tail of every image
  (19 + NZ clock cycles without an item) holds back the next image once the output FIFO of the predictor is full; the
  model took the samples of consecutive images in the cycles of the predictor alone, too early for sequences of small
  images or of images at one sample per cycle. The compressed images are not affected; the core is unchanged.

### Changed

- Open Logic 4.7.0-ft.9 (from 4.7.0-ft.6); no port or generic of OpenCompact changes.
- Register map version 2 (ID 0x4F435002): the registers above are added, the existing ones keep their offsets and
  fields.

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
