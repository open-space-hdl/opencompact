# OpenCompact Conventions

OpenCompact follows the coding conventions of Open Logic and the module development process of the architecture
document. This page lists the rules and the few OpenCompact-specific additions.

## VHDL coding

- The Open Logic coding conventions (`open-logic/doc/Conventions.md`) apply in full: port names
  `<Interface>_<Signal>`, generics `_g`, constants `_c`, variables `_v`, types `_t`, FSM types `<Name>Fsm_t` or
  `Fsm_t` with states `_s`, functions in `lowerCamelCase`, four spaces of indentation, no tabs, no trailing
  whitespace.
- Entities are named `ocp_<function>` with full words (for example `ocp_sample_adaptive_coder`). All OpenCompact
  sources are compiled into the VHDL library `opencompact`; Open Logic is compiled into the library `olo`.
- Language: VHDL-2008.
- Entities with non-trivial state use the two-process pattern of Open Logic: all registers in one `TwoProcess_r`
  record, signals `r` and `r_next`, a combinational process starting with `v := r;` and ending with
  `r_next <= v;`, a sequential process with `r <= r_next;` and the reset override at its end.
- Resets are synchronous and high-active. Only state registers are reset. The core has one clock domain `Clk`.
- Every data path between blocks is a valid / ready stream (AXI4-Stream handshake semantics).
- Standard functions (FIFOs, RAMs, crossings, synchronisers) are instantiated from Open Logic, never rewritten.
  Memories use the fault-tolerant `olo_ft_*` entities.
- State machines have a `when others` branch that returns to a defined recovery state; the reset leads to that state
  from any state.
- The arithmetic of the standard uses `numeric_std` types whose widths are derived from the generics; integers are
  used for counters and indexes only, never for values that may exceed 31 bits.
- Comments name the clause or the equation of CCSDS 123.0-B-2 where it helps the reader (for example
  `-- (37)` or `-- CCSDS 4.10.3`).
- File header: copyright line and authors, then a 1 to 2 sentence description that links to the module
  documentation. Never write "all rights reserved".
- Never use em-dashes in code, comments or documentation. Use UTF-8 only.
- VSG 3.27 with the Open Logic configuration in `lint/config` must report no errors and no warnings:
  `python lint/lint.py`. Safe automatic fixes: `python lint/lint.py --fix`.
- The design must be synthesizable in a technology-independent way: `python lint/synth_check.py` synthesizes
  `ocp_core` with every configuration of the regression with GHDL (after `python run.py --compile`) and fails on
  errors and inferred latches.
- Generated files are never edited by hand: `hdl/ocp_pkg/src/ocp_low_entropy_pkg.vhd`
  (`tools/gen_low_entropy_pkg.py`) and `docs/compliance.md` (`tools/compliance.py`).
- Traceability: every requirement of a specification is verified by at least one test case of the verification plan,
  every clause of the traceability matrix (architecture section 10) by the test cases of its requirements, and
  every test case of a plan is run by a testbench. `python tools/compliance.py` writes the
  [compliance matrix](compliance.md); `python tools/compliance.py --check` fails on a gap.

## Module development process

Every module goes through the seven phases of the architecture document (section 9):

| Phase | Output |
| --- | --- |
| A Requirements | `hdl/<module>/docs/specification.md`: requirements with IDs, each tracing to CCSDS clauses |
| B Architecture | `hdl/<module>/docs/architecture.md`: blocks, ports, state machines, data formats |
| C Verification plan | `hdl/<module>/docs/verification_plan.md`: test cases with IDs, requirement coverage |
| D RTL | `hdl/<module>/src/*.vhd` |
| E Testbenches | `hdl/<module>/tb/<entity>_tb.vhd` (VUnit runner) and `vunit_config.py` (configurations) |
| F Verification | Regression green, `hdl/<module>/docs/verification_report.md` |
| G Integration | Tests at the next level that cross every seam the module touches |

A module is one group of blocks of the architecture (section 7). `hdl/<module>/README.md` links the four documents
and explains how to run the tests.

## Diagrams

- Every architecture document has a block diagram; data formats have one where text alone is hard to follow.
- Diagrams are draw.io drawings stored as editable SVG with the drawing embedded (`<name>.drawio.svg`) in the `img/`
  folder next to the document. The SVG is the source: open it in draw.io to change it. It is exported with the light
  theme on an opaque white background, so that it reads in both colour schemes of the documentation site.
- Blocks: light blue for OpenCompact logic (a building block or a pipeline stage), white with a blue outline for an
  OpenCompact entity instantiated as a whole, light grey for an Open Logic entity, drawn inside the block that
  instantiates it or, for a FIFO between two blocks, as a small box on the connection. A dashed outline groups the
  blocks of one entity instance; a dashed block exists for some generics only (the entropy coder selected by
  `EntropyCoder_g`, the divider of near-lossless compression); a stacked block is replicated (the block buffers).
  The title carries the building block ID of the architecture (`PR-1`) or the name of the pipeline stage; the entity
  or the stage numbers follow in grey.
- Connections: thick lines for data, thin lines for single signals. Every line is horizontal or vertical; a dot marks
  a branch or a junction, an arc marks a line that crosses another without a connection. Ports cross the frame of
  the entity, inputs on the left, outputs on the right where the layout allows.
- A diagram is at most about 1000 px wide, so that its text stays readable in the content column, and its alt text
  names the blocks it shows.

## Verification

- VUnit runs every test (`run.py`); UVVM supplies checks, alerts and randomisation.
- The configurations of the regression are defined once in `tools/ocp_configs.py` and used by the golden data
  generator, the reference model, the testbenches (VUnit configurations) and the synthesis checks.
- Reference data: compressed images of the CNES reference software and entropy coder input sequences of the
  reference model `tools/ocp_model.py`, stored in `tb/golden/`. `tools/golden.py` regenerates them where the CNES
  reference software is installed; the regression only reads the stored files.
- A test passes only when UVVM reports no unexpected alerts and every expected alert occurred
  (`ocp_tb_pkg.ocpTestEnd`).
- Tests observe ports only, never internal signals.
- GHDL is the default simulator; QuestaSim (`python run.py --questa`) is used for code coverage. Every test passes in
  both simulators.
- `run.py` gives every GHDL simulation its own copy of the option `ghdl.sim_flags` and stops when a simulation command
  does not carry exactly the generics of its configuration (VUnit 5.0.0.dev7 shares that list between configurations).
- A side effect is never obtained by calling an impure function and discarding its result: QuestaSim may remove such
  a call.

## Git

- `main` holds the integrated state. Every module or change is developed on a branch `feature/<module>` or
  `bugfix/<topic>` and merged with `--no-ff` once its regression is green.
- Commit messages: imperative subject line, body explains what and why.
