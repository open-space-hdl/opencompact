# ocp_pkg: Specification

## 1. Overview

`ocp_pkg` holds the definitions shared by all modules; `ocp_low_entropy_pkg` holds the code and flush tables of the
low-entropy codes of the hybrid entropy coder as ROM constants.

## 2. Requirements

| ID | Requirement | CCSDS |
| --- | --- | --- |
| PK-IF-01 | The package shall define the codeword stream (up to 64 bits with length) and the item kinds of the entropy coder input sequence (mapped quantizer index, absolute and relative error limit value). | 5.4.1 |
| PK-IF-02 | The package shall decode the string generics of the input order, the entropy coder, the fidelity control method, the local sum type and the prediction mode into the codes of the header fields and stop the elaboration on an unknown value. | 5.3.2.2, 5.3.3.2 |
| PK-IF-03 | The package shall give the element of a per-band table for every band, repeating the last element, and the position of the entries of a band in the weight tables. | 5.3.3.3 |
| PK-LE-01 | The package shall hold the input symbol limits and the thresholds of the 16 low-entropy codes. | 5.4.3.3.3.3 |
| PK-LE-02 | The package shall hold, for every low-entropy code, the output codeword of every input codeword and the flush word of every active prefix, as in tables B-1 to B-32. | 5.4.3.3.3.3 |
