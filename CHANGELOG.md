# Changelog

The notable changes of OpenCompact. The versions follow semantic versioning: 0.y.z while the core is at TRL 3, a
major version for an incompatible change of ports, stream formats, generics or register map, a minor version for a
feature and a patch version for a fix.

## [Unreleased]

### Added

- Runtime parameters (`RuntimeParams_g`, default false, only with `RuntimeConfig_g`): every image takes its own
  user-defined data, sub-frame interleaving depth M (BI order), weight update parameters (log2 t_inc, vmin, vmax) and
  entropy coder parameters (Umax, gamma0, gamma\* and K of the sample-adaptive coder, Umax, gamma0 and gamma\* of the
  hybrid coder, r of the block-adaptive coder) from new ports of `ocp_core` (`Cfg_UserData` to `Cfg_RefInterval`,
  `Act_UserData` to `Act_RefInterval`) or, in `ocp_channel`, from new AXI4-Lite registers of `ocp_mib` (NEXT_SAMPLES,
  NEXT_ORDER, NEXT_WEIGHTS, NEXT_ADAPTIVE, NEXT_BLOCK) committed with the dimensions. Values outside their ranges are
  taken as the nearest valid values, the dependent ranges after the values they depend on (gamma\* after gamma0, vmax
  after vmin, M after NZ); with the hybrid coder gamma0 starts at the smallest value for which every initial
  accumulator is below 2^(D + gamma0). The header of every image carries its parameters. The core holds them for up
  to 16 images in the encoding of their header fields (31 to 51 bits per image). With the generic false the
  compressed images, the throughput and the registers of the GHDL netlist are those of version 0.2.0.
- Register map version 3 (ID 0x4F435003): NEXT_SAMPLES to NEXT_BLOCK, GENERICS.RUNTIME_PARAMS; with the runtime
  parameters the parameter fields of SAMPLES, ORDER, WEIGHTS, ADAPTIVE and BLOCK show the values of the last image.
- `lint/xsim_smoke.py` also elaborates and simulates the runtime parameter configurations (167 top levels).
- Decoder of the reference model (`ocp_model.decompress`, `tools/ocp_decompress.py`, user guide section 11): decodes
  a compressed image of any configuration of CCSDS 123.0-B-2 in Python, without other software, to the clipped
  quantizer bin centers, as the CNES reference decoder does, with the maximum error of every sample; the command
  compares the decoded image with the original. Tests in `tools/tests` (pytest, in the CI) against the golden data
  and against images decoded by the CNES decoder (`tools/golden.py --decoded`);
  `tools/check_model_testvectors.py --decode` decodes the CCSDS test data set.
- Tests from the code coverage review of the runtime parameters: the queue full behind the tail pointer of the hybrid
  coder (rp04, TC-CO-61), the end of a segment of 64 blocks within the reference sample interval (rp05, blocks of 8
  samples, TC-CO-59), band-varying accumulator initialisation values (rp06, TC-CO-59), and the unused addresses of the
  register map with the runtime parameters (TC-MB-08).

## [0.2.0] - 2026-10-25

### Added

- Runtime configuration (`RuntimeConfig_g`, default false): the image dimensions NX, NY, NZ (up to the maxima of the
  generics) and the band-independent error limit values of every image from new configuration ports of `ocp_core`
  (`Cfg_*`, `Cfg_Taken`, `Act_*`) or, in `ocp_channel`, from new AXI4-Lite registers of `ocp_mib` (CONTROL, STATUS,
  NEXT_X, NEXT_Y, NEXT_Z, NEXT_LIMITS). Values outside their ranges are taken as the nearest valid values. With the
  generic false the compressed images and the throughput are unchanged, and the logic added for the runtime
  configuration has no loads.
- LIMITS register: the band-independent error limit values (of the generics, or of the last image with the runtime
  configuration); GENERICS.RUNTIME_CONFIG.
- `lint/xsim_smoke.py` also elaborates and simulates the runtime configurations (161 top levels).

### Fixed

- Throughput model (`tools/ocp_throughput.py`, user guide section 8.1): with the hybrid coder the tail of every image
  (19 + NZ clock cycles without an item) holds back the next image once the output FIFO of the predictor is full; the
  model took the samples of consecutive images in the cycles of the predictor alone, too early for sequences of small
  images or of images at one sample per cycle. The compressed images are not affected; the core is unchanged.

### Changed

- Verification: the test end compares the alert counters of every level itself and ends the simulation with a
  failure, whatever the stop limits of the test.
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
