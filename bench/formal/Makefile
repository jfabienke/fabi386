# fabi386 Formal Verification Makefile
# Runs all SymbiYosys proofs
#
# Usage:
#   make all     - Run all proofs (BMC + prove)
#   make bmc     - Run bounded model checking only
#   make prove   - Run unbounded proofs only
#   make alu     - Run ALU proofs only
#   make rob     - Run ROB proofs only
#   make seg     - Run segment cache proofs only
#   make clean   - Remove proof outputs

PROOFS := f386_alu f386_rob f386_seg_cache

.PHONY: all bmc prove clean $(PROOFS)

all: $(PROOFS)

bmc: $(addsuffix _bmc, $(PROOFS))

prove: $(addsuffix _prove, $(PROOFS))

# Individual proof targets
f386_alu: f386_alu_bmc f386_alu_prove
f386_rob: f386_rob_bmc f386_rob_prove
f386_seg_cache: f386_seg_cache_bmc f386_seg_cache_prove

# Aliases
alu: f386_alu
rob: f386_rob
seg: f386_seg_cache

# Pattern rules
%_bmc: %.sby %_props.sv
	sby -f $< bmc

%_prove: %.sby %_props.sv
	sby -f $< prove

clean:
	rm -rf $(addsuffix _bmc, $(PROOFS)) $(addsuffix _prove, $(PROOFS))
