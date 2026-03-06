# Repository Guidelines

## Project Structure & Module Organization
`fabi386` is an FPGA softcore CPU project centered on SystemVerilog RTL.

- `rtl/`: synthesizable design modules.
- `rtl/core/`: OoO core pipeline, decode, execute, rename, ROB, branch prediction.
- `rtl/memory/`: cache/TLB/page-walk/MMU blocks.
- `rtl/soc/`: SoC peripherals (PIC/PIT/PS2/VGA/IO bus/telemetry).
- `rtl/top/`: top-level package and integration wrappers (`f386_pkg.sv`, top modules).
- `bench/verilator/`: C++ simulation tests (CMake + Verilator + CTest).
- `bench/formal/`: SymbiYosys proofs (`.sby` + `_props.sv`).
- `scripts/`: synthesis/resource tooling (`quartus_synth_check.sh`, `yosys_resource_check.sh`).
- `docs/`: architecture notes, verification summaries, and resource/timing history.

## Build, Test, and Development Commands
Run commands from repo root unless noted.

- `make -C bench/verilator build`: configure and compile Verilator tests.
- `make -C bench/verilator test`: run all C++/Verilator tests via CTest.
- `make -C bench/verilator alu|branch|core`: run a single simulation target.
- `make -C bench/formal all`: run all formal jobs (BMC + prove).
- `make -C bench/formal bmc|prove|alu|rob|seg`: targeted formal runs.
- `./scripts/yosys_resource_check.sh [module|--full]`: quick native synthesis estimates.
- `make quartus QUARTUS_HOST=<host>`: Quartus synthesis on NAS (default backend).
- `make quartus QUARTUS_BACKEND=vm VM_IP=<ip>`: Quartus synthesis on VM (fallback).
- `./scripts/quartus_synth_check.sh --backend nas --host <host>`: direct invocation.

## Coding Style & Naming Conventions
- SystemVerilog: 4-space indentation, aligned signal declarations, and `f386_*` module naming.
- Keep filenames aligned with module names (example: `rtl/core/f386_decode.sv`).
- Use `snake_case` for signals/variables; use `UPPER_CASE` for macros/constants.
- C++ testbench code uses C++17; keep tests deterministic and emit clear `PASS`/`FAIL`.
- Favor focused comments that explain intent or hardware behavior, not obvious syntax.

## Testing Guidelines
- Add or update tests for every RTL behavior change.
- Verilator tests: add `test_<feature>.cpp` and register it in `bench/verilator/CMakeLists.txt`.
- Formal checks: add `<block>.sby` and `<block>_props.sv`; wire target into `bench/formal/Makefile`.
- Before opening a PR, run at least `make -C bench/verilator test` and relevant formal targets.

## Commit & Pull Request Guidelines
- Use concise, imperative commit subjects (for example: `Fix async reset patterns for Yosys compatibility`).
- Optional phase tags are used for milestone work (example: `Phase P1.8b: ...`).
- Keep commits scoped to one logical change (RTL, tests, docs, or tooling).
- PRs should include:
  - what changed and why,
  - verification performed (commands + key results),
  - impact on resources/timing if synthesis-facing modules changed,
  - linked issue or design doc in `docs/` when applicable.
