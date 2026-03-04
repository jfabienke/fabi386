cmake_minimum_required(VERSION 3.16)
project(fabi386_tb LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find Verilator
find_package(verilator HINTS $ENV{VERILATOR_ROOT})
if(NOT verilator_FOUND)
    message(FATAL_ERROR "Verilator not found. Set VERILATOR_ROOT or install verilator.")
endif()

# Include our Verilator helper
include(${CMAKE_CURRENT_SOURCE_DIR}/Verilator.cmake)

# RTL source directories
set(RTL_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../rtl)
set(RTL_INCLUDE_DIRS
    ${RTL_ROOT}/top
    ${RTL_ROOT}/core
    ${RTL_ROOT}/memory
    ${RTL_ROOT}/soc
    ${RTL_ROOT}/primitives
)

# Common Verilator flags
set(VERILATOR_COMMON_FLAGS
    --trace                  # VCD trace support
    --timing                 # Timing support
    -Wall                    # All warnings
    -Wno-fatal               # Do not treat warnings as fatal in bench builds
    -Wno-DECLFILENAME        # Don't warn about filename vs module name
    -Wno-UNUSED              # Don't warn about unused signals during dev
    --x-assign fast          # Avoid random-X oscillation in known comb-loop blocks
    --x-initial fast
)

# ============================================================
# Test: ALU Basic
# ============================================================
verilate(test_alu_basic
    SOURCES
        ${RTL_ROOT}/top/f386_pkg.sv
        ${RTL_ROOT}/core/f386_alu.v
    TOP_MODULE f386_alu
    CPP_SOURCES test_alu_basic.cpp
    FLAGS ${VERILATOR_COMMON_FLAGS}
    INCLUDE_DIRS ${RTL_INCLUDE_DIRS}
)

# ============================================================
# Test: Branch Prediction
# ============================================================
verilate(test_branch
    SOURCES
        ${RTL_ROOT}/top/f386_pkg.sv
        ${RTL_ROOT}/core/f386_branch_predict_gshare.sv
    TOP_MODULE f386_branch_predict_gshare
    CPP_SOURCES test_branch.cpp
    FLAGS ${VERILATOR_COMMON_FLAGS}
    INCLUDE_DIRS ${RTL_INCLUDE_DIRS}
)

# ============================================================
# Test: Full OoO Core (integration)
# ============================================================
verilate(tb_ooo_core
    SOURCES
        ${RTL_ROOT}/top/f386_pkg.sv
        ${RTL_ROOT}/primitives/f386_distributed_ram.sv
        ${RTL_ROOT}/primitives/f386_block_ram.sv
        ${RTL_ROOT}/primitives/f386_picker.sv
        ${RTL_ROOT}/primitives/f386_freelist_multiwidth.sv
        ${RTL_ROOT}/core/f386_alu.v
        ${RTL_ROOT}/core/f386_alu_simd.sv
        ${RTL_ROOT}/core/f386_branch_predict_gshare.sv
        ${RTL_ROOT}/core/f386_branch_predict_hybrid.sv
        ${RTL_ROOT}/core/f386_branch_predict.sv
        ${RTL_ROOT}/core/f386_decode.sv
        ${RTL_ROOT}/core/f386_decode_cache.sv
        ${RTL_ROOT}/core/f386_dispatch.sv
        ${RTL_ROOT}/core/f386_execute_stage.sv
        ${RTL_ROOT}/core/f386_issue_queue.sv
        ${RTL_ROOT}/core/f386_microcode_rom.sv
        ${RTL_ROOT}/core/f386_register_rename.sv
        ${RTL_ROOT}/core/f386_rob.sv
        ${RTL_ROOT}/core/f386_seg_cache.sv
        ${RTL_ROOT}/core/f386_ooo_core_top.sv
    TOP_MODULE f386_ooo_core_top
    CPP_SOURCES tb_ooo_core.cpp memory_model.h
    FLAGS ${VERILATOR_COMMON_FLAGS}
    INCLUDE_DIRS ${RTL_INCLUDE_DIRS}
)

# ============================================================
# Test: Shim Flush/Grant/Ack Race
# ============================================================
verilate(test_shim_flush_race
    SOURCES
        ${RTL_ROOT}/top/f386_pkg.sv
        ${RTL_ROOT}/memory/f386_lsq_to_memctrl_shim.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/shim_flush_race_tb.sv
    TOP_MODULE shim_flush_race_tb
    CPP_SOURCES test_shim_flush_race.cpp
    FLAGS ${VERILATOR_COMMON_FLAGS}
    INCLUDE_DIRS ${RTL_INCLUDE_DIRS}
)

# ============================================================
# Test: L2 Split-Phase Cache with MSHRs
# ============================================================
verilate(test_l2_sp
    SOURCES
        ${RTL_ROOT}/top/f386_pkg.sv
        ${RTL_ROOT}/memory/f386_l2_cache_sp.sv
        ${CMAKE_CURRENT_SOURCE_DIR}/l2_sp_tb.sv
    TOP_MODULE l2_sp_tb
    CPP_SOURCES test_l2_sp.cpp
    FLAGS ${VERILATOR_COMMON_FLAGS}
    INCLUDE_DIRS ${RTL_INCLUDE_DIRS}
)

# ============================================================
# CTest integration
# ============================================================
enable_testing()
add_test(NAME alu_basic COMMAND test_alu_basic)
add_test(NAME branch    COMMAND test_branch)
add_test(NAME ooo_core  COMMAND tb_ooo_core)
add_test(NAME shim_flush_race COMMAND test_shim_flush_race)
add_test(NAME l2_sp     COMMAND test_l2_sp)
