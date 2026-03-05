# DE10-Nano MEM_FABRIC Smoke Test

> **WARNING:** Never modify `rtl/top/f386_pkg.sv` directly. Always use a temp
> copy with patched feature gates. The sed commands below write to a temp file
> and clean up on exit via `trap`.

**Status:** Runbook created. Not yet executed.

---

## Prerequisites

- Quartus 21.1 Lite in UTM VM (Ubuntu ARM64 + Rosetta). **Not 25.1** (AVX crash).
- sv2v installed locally (ARM, via Homebrew).
- `sshpass` installed: `brew install hudochenkov/sshpass/sshpass`
- DE10-Nano board with USB-Blaster connected.
- VM IP known (changes on reboot): `ssh quartus@<IP>` and verify with `ip addr show enp0s1`.

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

## Step 2: sv2v Conversion

```bash
top_files=$(ls rtl/top/*.sv | grep -v f386_pkg.sv)

sv2v -I rtl/core \
    "$tmp_pkg" rtl/primitives/*.sv rtl/core/*.sv \
    rtl/memory/*.sv rtl/soc/*.sv $top_files \
    > build/f386_sv2v_fabric.v
```

## Step 3: Quartus Synthesis on VM

```bash
VM_IP=192.168.64.4  # check actual IP

# Copy to VM tmpfs ramdisk (VirtIO shared mount is too slow)
sshpass -p 'quartus' scp -o PubkeyAuthentication=no \
    build/f386_sv2v_fabric.v rtl/core/f386_alu.v rtl/core/f386_fpu_spatial.v \
    quartus@${VM_IP}:/tmp/ramdisk/

# Run synthesis (--parallel=1 required — Rosetta deadlocks on IPC pipes)
sshpass -p 'quartus' ssh -o PubkeyAuthentication=no quartus@${VM_IP} \
    "cd /tmp/ramdisk && quartus_map f386_sv2v --parallel=1"
```

## Step 4: Full Compile (optional)

```bash
sshpass -p 'quartus' ssh -o PubkeyAuthentication=no quartus@${VM_IP} \
    "cd /tmp/ramdisk && quartus_sh --flow compile f386_sv2v --parallel=1"
```

Check timing report for violations after completion.

## Step 5: Flash DE10

Option A — USB-Blaster (direct):
```bash
quartus_pgm -c USB-Blaster -m JTAG -o "p;output_files/f386_sv2v.sof"
```

Option B — MiSTer `.rbf` copy:
Copy the generated `.rbf` to the MiSTer SD card and load via OSD.

## Step 6: Smoke Tests

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
| Quartus hangs during compile | Rosetta deadlock on IPC pipes | Use `--parallel=1` |
| Compile extremely slow (~30 min) | Using VirtIO shared mount | Run from `/tmp/ramdisk` |
| SSH connection refused | VM IP changed on reboot | Re-check with `ip addr show enp0s1` |
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
