/*
 * fabi386: Unified Global Package (v12.0)
 * ----------------------------------------
 * Defines the structs, enums, and types used across the OoO pipeline
 * and the HARE instrumentation suite.
 */

package f386_pkg;

    // --- Architectural Constants ---
    typedef logic [4:0] phys_reg_t; // 32 Physical Registers
    typedef logic [3:0] rob_id_t;   // 16-entry Reorder Buffer

    // --- Core Operation Categories ---
    typedef enum logic [3:0] {
        OP_ALU_REG   = 4'h0,
        OP_ALU_IMM   = 4'h1,
        OP_LOAD      = 4'h2,
        OP_STORE     = 4'h3,
        OP_BRANCH    = 4'h4,
        OP_FLOAT     = 4'h5,
        OP_MICROCODE = 4'h6,
        OP_SYS_CALL  = 4'h7,
        OP_DATA_READ = 4'h8,
        OP_IO_READ   = 4'h9,
        OP_IO_WRITE  = 4'hA
    } op_type_t;

    // --- Semantic RE Tags ---
    typedef enum logic [3:0] {
        SEM_NONE      = 4'h0,
        SEM_PROLOGUE  = 4'h1,
        SEM_EPILOGUE  = 4'h2,
        SEM_INT_CALL  = 4'h3,
        SEM_MODE_SW   = 4'h4,
        SEM_SMC       = 4'h5, // Self-Modifying Code
        SEM_HOT_PATH  = 4'hA,
        SEM_FAR_RET   = 4'hB,
        SEM_V86_ENTER = 4'hD,
        SEM_V86_EXIT  = 4'hE,
        SEM_SYS_RST   = 4'hF
    } semantic_tag_t;

    // --- PASC Memory Classes ---
    typedef enum logic [2:0] {
        CLASS_INTERNAL = 3'd0, // HyperRAM
        CLASS_EXT_RAM  = 3'd1, // Motherboard SIMMs
        CLASS_ADPT_MEM = 3'd2, // ISA Adapter SRAM/VRAM
        CLASS_MMIO     = 3'd3, // Hardware Registers
        CLASS_HOLE     = 3'd4  // Unmapped/Empty
    } mem_class_t;

    // --- Pipeline Packets ---
    typedef struct packed {
        logic           valid;
        logic [31:0]    pc;
        logic [31:0]    raw_instr;
        logic [7:0]     opcode;
        op_type_t       op_cat;

        // Physical Register Mapping
        phys_reg_t      p_dest;
        phys_reg_t      p_src_a;
        phys_reg_t      p_src_b;

        // Operand Status
        logic           src_a_ready;
        logic           src_b_ready;
        logic [31:0]    val_a;
        logic [31:0]    val_b;

        rob_id_t        rob_tag;
        logic [31:0]    imm_value;
    } ooo_instr_t;

    typedef struct packed {
        ooo_instr_t     instr;
        logic [31:0]    data;
        logic           ready;
        logic           valid;
    } rob_entry_t;

    typedef struct packed {
        logic           is_data;
        ooo_instr_t     instr;
        struct packed {
            logic [31:0] addr;
            logic [31:0] value;
            mem_class_t  m_class;
            logic        taint;
        } data;
        logic           stack_fault;
    } telemetry_pkt_t;

endpackage
