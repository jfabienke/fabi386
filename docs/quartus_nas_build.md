# Quartus NAS Build Server

This repo now supports Quartus builds through the QNAP NAS build host using the
generic wrapper:

```bash
./scripts/quartus_synth_check.sh --backend nas --host 192.168.50.100
./scripts/quartus_synth_check.sh --backend nas --host 192.168.50.100 --full
```

`make` wrappers:

```bash
make quartus QUARTUS_HOST=192.168.50.100
make quartus-full QUARTUS_HOST=192.168.50.100
```

VM fallback remains available:

```bash
make quartus QUARTUS_BACKEND=vm VM_IP=192.168.64.4
```

## Server Summary

- Host access: `ssh admin@192.168.50.100`
- Quartus container: `quartus`
- Docker binary:
  `/share/CACHEDEV1_DATA/.qpkg/container-station/bin/system-docker`
- Remote project root:
  `/share/CACHEDEV1_DATA/quartus/projects`
- Job workspace root:
  `/share/CACHEDEV1_DATA/quartus/projects/fabi386_jobs`
- Quartus version in container:
  `Quartus Prime Lite 17.0.2 Build 602`
- Quartus binaries:
  `/opt/intelFPGA/quartus/bin`

## How the Wrapper Uses the NAS

For each run, the wrapper:

1. runs `sv2v` locally
2. stages a self-contained job under `build/quartus_jobs/<jobid>/`
3. copies that directory to the NAS
4. runs Quartus inside the `quartus` Docker container
5. fetches reports and bitstream artifacts back into the local job dir

Fetched outputs include:

- `<project>.map.rpt`
- `<project>.fit.rpt` when `--full`
- `<project>.sta.rpt` when `--full`
- `output_files/*.sof` if generated
- `output_files/*.rbf` if generated
- full backend log as `quartus.log`

## Parallelism

The wrapper uses backend-specific defaults:

- `QUARTUS_PARALLEL=auto` on the VM backend resolves to `1`
- `QUARTUS_PARALLEL=auto` on the NAS backend resolves to the remote CPU count,
  capped at `8`

Override manually if needed:

```bash
QUARTUS_PARALLEL=4 ./scripts/quartus_synth_check.sh --backend nas --host 192.168.50.100
```

## Operational Notes

- The NAS flow does not require `sshpass`.
- The NAS flow uses `admin` SSH plus `docker exec`, not direct `quartus` SSH login.
- Treat JTAG/programming support as separate from build support until explicitly
  verified.
- The old UTM/Rosetta VM setup script remains in-tree as fallback:
  [setup_quartus_vm.sh](/Users/jvindahl/Development/fabi386/scripts/setup_quartus_vm.sh)

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| SSH fails | Wrong NAS IP / key / `AllowUsers` config | Verify `ssh admin@host` works first |
| Backend says container missing | Quartus container not running | Start `quartus` in Container Station |
| Compile starts but reports missing | Remote path mismatch | Check `QUARTUS_NAS_REMOTE_ROOT` and job dir |
| Compile is unexpectedly slow | Over-aggressive parallelism or NAS contention | Retry with `QUARTUS_PARALLEL=4` |
| Need old flow | NAS unavailable | Use `--backend vm` / `VM_IP=...` |

### Manual Cleanup of Old NAS Jobs

Remote job directories are preserved after fetch for debugging. Clean up old
jobs manually:

```bash
# List existing jobs
ssh admin@192.168.50.100 "ls /share/CACHEDEV1_DATA/quartus/projects/fabi386_jobs/"

# Remove a specific old job
ssh admin@192.168.50.100 "rm -rf /share/CACHEDEV1_DATA/quartus/projects/fabi386_jobs/<old_job_id>"
```
