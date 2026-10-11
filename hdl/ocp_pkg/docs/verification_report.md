# ocp_pkg: Verification Report

## 1. Test results

Run on 2026-10-11: the structure checks of the transcription of tables B-1 to B-32 pass for all 16 codes (8 to 256
active prefixes per code, 2740 transitions in 3004 table entries); `python tools/gen_low_entropy_pkg.py --check` passes;
the core tests that use the package pass (see the [verification report of
ocp_core](../../ocp_core/docs/verification_report.md)).

## 2. Summary

The low-entropy code tables reproduce the compressed images of the CNES reference software for all hybrid-coder
configurations; configuration c16 selects all 16 low-entropy codes, with escape symbols and flush words.
