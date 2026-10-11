# ocp_pkg: Verification Plan

## 1. Overview

The transcription of the low-entropy code tables is checked by its structure: for every code the flush table must
contain exactly the proper prefixes of the input codewords, the input codewords must be prefix-free, and every active
prefix extended by every symbol must be an active prefix or an input codeword. The generated package is compared with
the transcription by `tools/gen_low_entropy_pkg.py --check`. The functions of `ocp_pkg` and the tables are used by every
core test; a wrong table entry or function changes the compressed image of the hybrid coder or the header.

## 2. Test cases

| Test cases | Description | Requirements |
| --- | --- | --- |
| TC-CO-01 to TC-CO-24 | Core tests: headers of all generic values, items of all kinds | PK-IF-01, PK-IF-02, PK-IF-03 |
| TC-CO-04, TC-CO-05, TC-CO-10, TC-CO-13, TC-CO-16 | Hybrid coder: all 16 low-entropy codes with escape symbols, complete input codewords and flush words (TC-CO-16) | PK-LE-01, PK-LE-02 |

## 3. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| PK-IF-01 to PK-IF-03 | TC-CO-01 to TC-CO-24 |
| PK-LE-01, PK-LE-02 | TC-CO-04, TC-CO-05, TC-CO-10, TC-CO-13, TC-CO-16; structure checks of the transcription |
