# DE10-Nano MEM_FABRIC Smoke Test

> **WARNING:** Never modify `rtl/top/f386_pkg.sv` directly. Always use a temp
> copy with patched feature gates. The sed commands below write to a temp file
> and clean up on exit via `trap`.

**Status:** Runbook created. Not yet executed.

---

## Prerequisites

- Quartus NAS build server configured. See [quartus_nas_build.md](/Users/jvindahl/Development/fabi386/docs/quartus_nas_build.md).
- sv2v installed locally (ARM, via Homebrew).
- DE10-Nano board with USB-Blaster connected.
- NAS reachable via `ssh admin@<host>`.
- VM backend is still available as fallback, but NAS is now the preferred path.

---

## Step 1: Patch Feature Gates (temp file)

```bash
tmp_pkg=$(mktemp "${TMPDIR:-/tmp}/f386_pkg_fabric.XXXXXX.sv")
trap "rm -f '$tmp_pkg'" EXIT

sed -E \
    -e "s/(CONF_ENABLE_LSQ_MEMIF)[[:space:]]*=[[:space:]]*1'b0/\1 = 1'b1/" \
    -e "s/(CONF_ENABLE_L2_CACHE)[[:space:]]*=[[:space:]]*1'b0/\1 = 1'b1/" \
    -e "s/(CONF_ENABLE_MEM_FABRIC)[[:space:]]*=[[:space:]]*1'b0/\1 = 1'b1/" \
    rtl/top/f386_pkg.sv > "$tmp_pkg"

# Verify substitution
grep -q "CONF_ENABLE_MEM_FABRIC.*1'b1" "$tmp_pkg" || echo "ERROR: sed failed"
grep -q "CONF_ENABLE_LSQ_MEMIF.*1'b1"  "$tmp_pkg" || echo "ERROR: sed failed"
grep -q "CONF_ENABLE_L2_CACHE.*1'b1"   "$tmp_pkg" || echo "ERROR: sed failed"
```

## Step 2: Build with temp pkg override

```bash
QUARTUS_HOST=192.168.50.100  # adjust for your NAS

# Preferred: use the wrapper with the temp patched pkg. This keeps the working
# tree unchanged while still building the gate-on configuration.
./scripts/quartus_synth_check.sh \
    --backend nas \
    --host "${QUARTUS_HOST}" \
    --pkg "$tmp_pkg" \
    --job-name mem_fabric_smoke
```

## Step 3: Full Compile (optional)

```bash
./scripts/quartus_synth_check.sh \
    --backend nas \
    --host "${QUARTUS_HOST}" \
    --pkg "$tmp_pkg" \
    --full \
    --job-name mem_fabric_smoke_full
```

Check timing report for violations after completion.

## Step 4: Flash DE10

Option A — USB-Blaster (direct):
```bash
quartus_pgm -c USB-Blaster -m JTAG -o "p;output_files/f386_sv2v.sof"
```

Option B — MiSTer `.rbf` copy:
Copy the generated `.rbf` to the MiSTer SD card and load via OSD.

## Step 5: Smoke Tests

Run each test from the DOS prompt. All 5 must complete without hang:

| # | Test | Exercises |
|---|------|-----------|
| 1 | Boot to DOS prompt | Full fetch→decode→execute→memory path through L2_SP |
| 2 | `FDISK /STATUS` | Sequential disk metadata reads |
| 3 | `DIR` | Load/store/ifetch interleaving |
| 4 | `EDIT` (open, type, exit) | Mixed read/write/ifetch under interactive load |
| 5 | `MEM` | Memory map reporting (MMIO reads) |

---

## Pass/Fail Criteria

All 5 tests complete without hang. Record:

| Field | Value |
|-------|-------|
| Date | |
| Commit | |
| ALMs | |
| Timing clean | Yes / No |
| Boot | Pass / Fail |
| FDISK | Pass / Fail |
| DIR | Pass / Fail |
| EDIT | Pass / Fail |
| MEM | Pass / Fail |

---

## Known Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| SSH connection refused | NAS IP / key / `AllowUsers` mismatch | Verify `ssh admin@<host>` first |
| Quartus backend says container missing | NAS container not running | Start `quartus` in Container Station |
| Compile unexpectedly slow | NAS load or overly high parallelism | Retry with `QUARTUS_PARALLEL=4` |
| Boot hangs (no DOS prompt) | Microcode deadlock (OP_MICROCODE in ROB) | Known P3 gap — avoid complex instructions |
| Hang during EDIT/DIR | MSHR exhaustion or response deadlock | Check debug signals below |

---

## Debug Signals

If a hang occurs, inspect these via MiSTer debug bridge or SignalTap:

| Signal | Location | What to check |
|--------|----------|---------------|
| `lk_state` | L2_SP main FSM | Stuck in non-IDLE state? |
| `mh_state[0:3]` | MSHR per-entry FSM | Any MSHR stuck in COMPLETE/WB/FILL? |
| `dd_owner` | DDRAM ownership | Deadlock between clients? |
| `rsp_buf_valid` | Response buffer | Backpressure stall? |
| `sq_empty` | LSQ store queue | Stores not draining? |
