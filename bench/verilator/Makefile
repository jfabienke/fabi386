# fabi386 Verilator Testbench - Convenience Makefile
# Wraps CMake for quick iteration
#
# Usage:
#   make build     - Configure + build all tests
#   make test      - Run all tests via CTest
#   make alu       - Run ALU test only
#   make branch    - Run branch predictor test only
#   make core      - Run OoO core integration test only
#   make clean     - Remove build directory
#   make wave      - Open VCD traces in GTKWave (if available)

BUILD_DIR := build

.PHONY: all build test alu branch core clean wave

all: test

$(BUILD_DIR)/Makefile:
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && cmake ..

build: $(BUILD_DIR)/Makefile
	cmake --build $(BUILD_DIR) -j$$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

test: build
	cd $(BUILD_DIR) && ctest --output-on-failure

alu: build
	$(BUILD_DIR)/test_alu_basic

branch: build
	$(BUILD_DIR)/test_branch

core: build
	$(BUILD_DIR)/tb_ooo_core

clean:
	rm -rf $(BUILD_DIR) *.vcd

wave:
	@which gtkwave >/dev/null 2>&1 && gtkwave *.vcd || echo "GTKWave not found"
