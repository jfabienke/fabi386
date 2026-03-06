# fabi386 Top-Level Makefile
# Thin wrapper over existing scripts and bench/verilator build system.
#
# Usage:
#   make test                           - Run all Verilator tests
#   make regression-l2-sp               - Run L2 split-phase regression gate
#   make yosys                          - Yosys per-module resource check
#   make yosys-full                     - Yosys full-design flattened check
#   make quartus QUARTUS_HOST=192.168.50.100              - Quartus synthesis on NAS
#   make quartus-full QUARTUS_HOST=192.168.50.100         - Quartus full compile on NAS
#   make quartus QUARTUS_BACKEND=vm VM_IP=192.168.64.4    - Quartus synthesis on VM (fallback)
#   make clean                          - Remove build artifacts

.PHONY: test regression-l2-sp yosys yosys-full quartus quartus-full clean

QUARTUS_BACKEND ?= nas

test:
	$(MAKE) -C bench/verilator test

regression-l2-sp:
	./scripts/regression_l2_sp.sh

yosys:
	./scripts/yosys_resource_check.sh

yosys-full:
	./scripts/yosys_resource_check.sh --full

quartus:
ifdef QUARTUS_HOST
	./scripts/quartus_synth_check.sh --backend $(QUARTUS_BACKEND) --host $(QUARTUS_HOST)
else ifdef VM_IP
	./scripts/quartus_synth_check.sh --backend vm --host $(VM_IP)
else
	$(error QUARTUS_HOST is required. Usage: make quartus QUARTUS_HOST=192.168.50.100 [QUARTUS_BACKEND=nas|vm])
endif

quartus-full:
ifdef QUARTUS_HOST
	./scripts/quartus_synth_check.sh --backend $(QUARTUS_BACKEND) --host $(QUARTUS_HOST) --full
else ifdef VM_IP
	./scripts/quartus_synth_check.sh --backend vm --host $(VM_IP) --full
else
	$(error QUARTUS_HOST is required. Usage: make quartus-full QUARTUS_HOST=192.168.50.100 [QUARTUS_BACKEND=nas|vm])
endif

clean:
	$(MAKE) -C bench/verilator clean
	rm -rf build/*.v build/*.log
