# ocp_mib: Specification

## 1. Overview

`ocp_mib` is the status interface of an OpenCompact channel (`ocp_channel`): an AXI4-Lite slave with an
identification register, read-only registers with the generics that define the compressed images, and 32-bit
counters of the images, of the faulty and discarded SDUs and of the memory errors. It has no configuration register;
the only effect of a write is the clearing of a counter. The register map is described once in
`hdl/ocp_mib/regs/ocp_regs.yml`; `tools/regmap.py` generates the VHDL package `ocp_regs_pkg`, the
[register map](register_map.md) and the C header `sw/ocp_regs.h` from it.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | CCSDS |
| --- | --- | --- |
| MB-IF-01 | The MIB shall provide an AXI4-Lite slave with 8-bit byte addresses and 32-bit data; every access shall complete with the response OKAY, reads of unused addresses and bits shall return zero, and writes to read-only registers shall have no effect. | none |
| MB-IF-02 | The MIB shall take one-cycle event pulses: image done, image aborted, faulty SDU, discarded SDU, corrected and detected memory error. | none |

### 2.2 Registers

| ID | Requirement | CCSDS |
| --- | --- | --- |
| MB-ID-01 | The register ID shall read 0x4F435001: the letters OCP and the version 1 of the register map. | none |
| MB-GN-01 | The registers GENERICS to BLOCK shall read the values of the generics of the channel as listed in the register map: sizes in their natural units, enumerations with the codes of the header fields, the fields of an entropy coder that is not selected as zero. | 5.3.2.2, 5.3.3.2, 5.3.4 |
| MB-CN-01 | Every event pulse shall increment its 32-bit counter by one; a counter shall saturate at 2^32 - 1. | none |
| MB-CN-02 | A write to a counter register shall clear that counter; an event in the clock cycle of the write shall be counted after the clearing (the counter reads 1). | none |
| MB-RS-01 | A reset shall clear all counters. | none |

### 2.3 Register map generation

| ID | Requirement | CCSDS |
| --- | --- | --- |
| MB-RG-01 | The VHDL package, the register map documentation and the C header shall be generated from `ocp_regs.yml`; `python tools/regmap.py --check` shall fail when one of them differs from the description. | none |

## 3. Error conditions

| Condition | Response |
| --- | --- |
| Read of an unused address | Zero, response OKAY |
| Write to a read-only register or an unused address | No effect, response OKAY |
| Counter at 2^32 - 1 | Stays at 2^32 - 1 until it is cleared |

## 4. Configuration parameters

The generics of the channel that the registers GENERICS to BLOCK report (names and ranges of `ocp_core` and
`ocp_channel`): `InStreamWidth_g`, `OutStreamWidth_g`, `OutWidth_g`, `Speculation_g`, `XSize_g`, `YSize_g`, `ZSize_g`,
`DynamicRange_g`, `SignedSamples_g`, `UserData_g`, `EncodingOrder_g`, `SubFrameDepth_g`, `OutputWordSize_g`,
`EntropyCoder_g`, `Fidelity_g`, `SupTableCount_g`, `PredictionBands_g`, `PredictionMode_g`, `LocalSum_g`,
`RegisterSize_g`, `SampleRepResolution_g`, `PeriodicUpdate_g`, `UpdatePeriodExp_g`, `WeightResolution_g`,
`WeightUpdateInterval_g`, `WeightUpdateVmin_g`, `WeightUpdateVmax_g`, `WeightExpOffsetsUsed_g`, `CustomWeights_g`,
`WeightInitResolution_g`, `UnaryLimit_g`, `RescaleCounterSize_g`, `InitialCountExp_g`, `AccuInitBandVarying_g`,
`AccuInit_g`, `BlockSize_g`, `RestrictedCodes_g`, `RefInterval_g`.
