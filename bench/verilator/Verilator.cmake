# Verilator.cmake — verilate() helper function
# Adapted from reference/80x86/Verilator.cmake
#
# Usage:
#   verilate(<target_name>
#       SOURCES <sv_files...>
#       TOP_MODULE <module_name>
#       CPP_SOURCES <cpp_files...>
#       FLAGS <verilator_flags...>
#       INCLUDE_DIRS <dirs...>
#   )

function(verilate TARGET_NAME)
    cmake_parse_arguments(V
        ""
        "TOP_MODULE"
        "SOURCES;CPP_SOURCES;FLAGS;INCLUDE_DIRS"
        ${ARGN}
    )

    if(NOT V_TOP_MODULE)
        message(FATAL_ERROR "verilate: TOP_MODULE is required")
    endif()

    if(NOT V_SOURCES)
        message(FATAL_ERROR "verilate: SOURCES is required")
    endif()

    # Build include directory flags
    set(INCLUDE_FLAGS "")
    foreach(dir ${V_INCLUDE_DIRS})
        list(APPEND INCLUDE_FLAGS "-I${dir}")
    endforeach()

    # Verilator output directory (unique per target to avoid conflicts)
    set(VDIR ${CMAKE_CURRENT_BINARY_DIR}/${TARGET_NAME}_vdir)

    # Run Verilator to generate C++ from SystemVerilog
    set(VERILATOR_STAMP ${VDIR}/V${V_TOP_MODULE}.h)

    add_custom_command(
        OUTPUT ${VERILATOR_STAMP}
        COMMAND ${VERILATOR_BIN}
            --cc
            --Mdir ${VDIR}
            --top-module ${V_TOP_MODULE}
            --prefix V${V_TOP_MODULE}
            ${V_FLAGS}
            ${INCLUDE_FLAGS}
            ${V_SOURCES}
        DEPENDS ${V_SOURCES}
        COMMENT "Verilating ${V_TOP_MODULE}..."
        VERBATIM
    )

    # Build the Verilated model library
    add_custom_command(
        OUTPUT ${VDIR}/V${V_TOP_MODULE}__ALL.a
        COMMAND make -C ${VDIR} -f V${V_TOP_MODULE}.mk VERILATOR_ROOT=${VERILATOR_ROOT}
        DEPENDS ${VERILATOR_STAMP}
        COMMENT "Building Verilated model for ${V_TOP_MODULE}..."
        VERBATIM
    )

    add_custom_target(${TARGET_NAME}_verilate
        DEPENDS ${VDIR}/V${V_TOP_MODULE}__ALL.a
    )

    # Build the test executable
    add_executable(${TARGET_NAME} ${V_CPP_SOURCES})
    add_dependencies(${TARGET_NAME} ${TARGET_NAME}_verilate)

    target_include_directories(${TARGET_NAME} PRIVATE
        ${VDIR}
        ${VERILATOR_ROOT}/include
        ${CMAKE_CURRENT_SOURCE_DIR}
    )

    find_package(Threads REQUIRED)

    target_link_libraries(${TARGET_NAME} PRIVATE
        ${VDIR}/V${V_TOP_MODULE}__ALL.a
        ${VERILATOR_ROOT}/include/verilated.cpp
        ${VERILATOR_ROOT}/include/verilated_threads.cpp
        ${VERILATOR_ROOT}/include/verilated_vcd_c.cpp
        Threads::Threads
    )
endfunction()
