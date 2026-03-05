# fabi386 Top-Level Makefile
# Thin wrapper over existing scripts and bench/verilator build system.
#
# Usage:
#   make test                           - Run all Verilator tests
#   make regression-l2-sp               - Run L2 split-phase regression gate
#   make yosys                          - Yosys per-module resource check
#   make yosys-full                     - Yosys full-design flattened check
#   make quartus VM_IP=192.168.64.4     - Quartus synthesis on VM
#   make quartus-full VM_IP=192.168.64.4 - Quartus full compile on VM
#   make clean                          - Remove build artifacts

.PHONY: test regression-l2-sp yosys yosys-full quartus quartus-full clean

test:
	$(MAKE) -C bench/verilator test

regression-l2-sp:
	./scripts/regression_l2_sp.sh

yosys:
	./scripts/yosys_resource_check.sh

yosys-full:
	./scripts/yosys_resource_check.sh --full

quartus:
ifndef VM_IP
	$(error VM_IP is required. Usage: make quartus VM_IP=192.168.64.4)
endif
	./scripts/quartus_synth_check.sh $(VM_IP)

quartus-full:
ifndef VM_IP
	$(error VM_IP is required. Usage: make quartus-full VM_IP=192.168.64.4)
endif
	./scripts/quartus_synth_check.sh $(VM_IP) --full

clean:
	$(MAKE) -C bench/verilator clean
	rm -rf build/*.v build/*.log
