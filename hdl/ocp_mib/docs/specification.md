# ocp_mib: Specification

## 1. Overview

`ocp_mib` is the status and configuration interface of an OpenCompact channel (`ocp_channel`): an AXI4-Lite slave with
an identification register, read-only registers with the generics that define the compressed images, and 32-bit counters
of the images, of the faulty and discarded SDUs and of the memory errors. With `RuntimeConfig_g` it also holds the
configuration of the next images (image dimensions and band-independent error limit values), checks it and passes it to
the core; otherwise the only effect of a write is the clearing of a counter. The register map is described once in
`hdl/ocp_mib/regs/ocp_regs.yml`; `tools/regmap.py` generates the VHDL package `ocp_regs_pkg`, the [register
map](register_map.md) and the C header `sw/ocp_regs.h` from it.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | CCSDS |
| --- | --- | --- |
| MB-IF-01 | The MIB shall provide an AXI4-Lite slave with 8-bit byte addresses and 32-bit data; every access shall complete with the response OKAY, reads of unused addresses and bits shall return zero, and writes to read-only registers shall have no effect. | none |
| MB-IF-02 | The MIB shall take one-cycle event pulses: image done, image aborted, faulty SDU, discarded SDU, corrected and detected memory error. | none |

### 2.2 Registers

| ID | Requirement | CCSDS |
| --- | --- | --- |
| MB-ID-01 | The register ID shall read 0x4F435002: the letters OCP and the version 2 of the register map. | none |
| MB-GN-01 | The registers GENERICS to BLOCK shall read the values of the generics of the channel as listed in the register map: sizes in their natural units, enumerations with the codes of the header fields, the fields of an entropy coder that is not selected as zero. | 5.3.2.2, 5.3.3.2, 5.3.4 |
| MB-CN-01 | Every event pulse shall increment its 32-bit counter by one; a counter shall saturate at 2^32 - 1. | none |
| MB-CN-02 | A write to a counter register shall clear that counter; an event in the clock cycle of the write shall be counted after the clearing (the counter reads 1). | none |
| MB-RS-01 | A reset shall clear all counters. | none |

### 2.3 Runtime configuration

| ID | Requirement | CCSDS |
| --- | --- | --- |
| MB-RC-01 | With `RuntimeConfig_g` true the registers NEXT_X, NEXT_Y, NEXT_Z and NEXT_LIMITS shall hold the configuration for the next images, written and read back by software; after a reset they hold `XSize_g`, `YSize_g`, `ZSize_g` and the first values of `AbsErrorLimits_g` and `RelErrorLimits_g` (zero for an error limit method not in use). | 5.3.2.2, 5.3.3.4 |
| MB-RC-02 | A write of '1' to CONTROL.COMMIT shall check the values of NEXT_X to NEXT_LIMITS: NX, NY, NZ from 1 to their maxima (NX = 1 only with reduced prediction and column-oriented local sums), the error limit values of the methods in use below 2^DA and 2^DR. Valid values shall reach all five configuration outputs of the core in the same clock cycle, so that an image start takes either the complete previous or the complete new configuration, and shall set STATUS.CFG_PENDING; invalid values shall set STATUS.CFG_ERROR and leave the configuration outputs unchanged. | 3.2, 4.3.1, 4.4.1, 4.8.2.2, 4.8.2.3 |
| MB-RC-03 | STATUS.CFG_PENDING shall be '1' from a valid COMMIT until the core takes the configuration (`Cfg_Taken`); after a valid COMMIT in the clock cycle of `Cfg_Taken` it shall stay '1' until the next `Cfg_Taken` (the image that starts in that cycle takes the previous values); STATUS.CFG_ERROR shall stay '1' until software writes '1' to it. | none |
| MB-RC-04 | IMAGE_X, IMAGE_Y, IMAGE_Z, ORDER.SUB_FRAME_DEPTH and LIMITS shall read the values that the core took for the last image, from its `Act_` outputs (after a reset the values of MB-RC-01; values out of range taken as in CO-RC-07); GENERICS.RUNTIME_CONFIG shall read `RuntimeConfig_g`. | 5.3.2.2, 5.3.3.4 |
| MB-RC-05 | With `RuntimeConfig_g` false NEXT_X to NEXT_LIMITS, CONTROL and STATUS shall read zero, writes to them shall have no effect, and LIMITS shall read the band-independent error limit values of the generics (zero for a method not in use or with band-dependent limits). | none |

### 2.4 Register map generation

| ID | Requirement | CCSDS |
| --- | --- | --- |
| MB-RG-01 | The VHDL package, the register map documentation and the C header shall be generated from `ocp_regs.yml`; `python tools/regmap.py --check` shall fail when one of them differs from the description. | none |

## 3. Error conditions

| Condition | Response |
| --- | --- |
| Read of an unused address | Zero, response OKAY |
| Write to a read-only register or an unused address | No effect, response OKAY |
| Counter at 2^32 - 1 | Stays at 2^32 - 1 until it is cleared |
| COMMIT with a value out of range | STATUS.CFG_ERROR set, the configuration of the core unchanged, response OKAY |
| COMMIT while CFG_PENDING is set | The new values replace the pending ones; the core takes the values valid at its next image start |
| Valid COMMIT in the clock cycle of `Cfg_Taken` | The image that starts takes the previous values; the new values reach the outputs one clock cycle later, CFG_PENDING stays '1' until the next `Cfg_Taken` |

## 4. Configuration parameters

The generics of the channel that the registers GENERICS to BLOCK report (names and ranges of `ocp_core` and
`ocp_channel`): `InStreamWidth_g`, `OutStreamWidth_g`, `OutWidth_g`, `Speculation_g`, `XSize_g`, `YSize_g`, `ZSize_g`,
`DynamicRange_g`, `SignedSamples_g`, `UserData_g`, `EncodingOrder_g`, `SubFrameDepth_g`, `OutputWordSize_g`,
`EntropyCoder_g`, `Fidelity_g`, `SupTableCount_g`, `PredictionBands_g`, `PredictionMode_g`, `LocalSum_g`,
`RegisterSize_g`, `SampleRepResolution_g`, `PeriodicUpdate_g`, `UpdatePeriodExp_g`, `WeightResolution_g`,
`WeightUpdateInterval_g`, `WeightUpdateVmin_g`, `WeightUpdateVmax_g`, `WeightExpOffsetsUsed_g`, `CustomWeights_g`,
`WeightInitResolution_g`, `UnaryLimit_g`, `RescaleCounterSize_g`, `InitialCountExp_g`, `AccuInitBandVarying_g`,
`AccuInit_g`, `BlockSize_g`, `RestrictedCodes_g`, `RefInterval_g`, `AbsErrorLimits_g`, `RelErrorLimits_g`,
`AbsBitDepth_g`, `RelBitDepth_g`, `AbsBandDependent_g`, `RelBandDependent_g` and `RuntimeConfig_g`.
