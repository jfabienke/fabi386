/*
 * fabi386: Unified Global Package (v13.0)
 * ----------------------------------------
 * Defines the structs, enums, and types used across the OoO pipeline
 * and the HARE instrumentation suite.
 *
 * v13.0: Added centralized MicroArchConf parameters and feature gating.
 *        All pipeline depths, queue sizes, and OoO features are now
 *        parameterized via CONF_* localparams. Derived typedefs use
 *        $clog2 for automatic width scaling.
 */

package f386_pkg;

    // =========================================================================
    // Microarchitectural Configuration (inspired by rsd MicroArchConf.sv)
    // =========================================================================
    // All pipeline structure sizes in one place. Modules reference these
    // instead of hard-coding depths. Feature gates disable advanced OoO
    // subsystems until the core is functionally stable.

    // --- Structure Sizes ---
    localparam int CONF_PHYS_REG_NUM    = 32;   // Physical register file depth
    localparam int CONF_ARCH_REG_NUM    = 8;    // x86 GPRs (EAX-EDI)
    localparam int CONF_ROB_ENTRIES     = 16;   // Reorder buffer depth
    localparam int CONF_IQ_ENTRIES      = 8;    // Issue queue (reservation station) depth
    localparam int CONF_DISPATCH_WIDTH  = 2;    // Superscalar dispatch width (U+V)
    localparam int CONF_COMMIT_WIDTH    = 2;    // Retirement width
    localparam int CONF_MAX_BR_COUNT    = 4;    // Max in-flight branches (snapshot slots)
    localparam int CONF_LSQ_LQ_ENTRIES  = 8;    // Load queue entries (upgraded from 4 in P1.4)
    localparam int CONF_LSQ_SQ_ENTRIES  = 8;    // Store queue entries (upgraded from 4 in P1.4)
    localparam int CONF_TLB_ENTRIES     = 32;   // Unified I/D TLB entries
    localparam int CONF_PHT_ENTRIES     = 256;  // Gshare PHT entries
    localparam int CONF_GHR_WIDTH       = 8;    // Gshare global history register width
    localparam int CONF_RAS_DEPTH       = 16;   // Return address stack depth
    localparam int CONF_FTQ_ENTRIES     = 8;    // Fetch target queue (8 now, 16 post-boot)
    localparam int CONF_L1D_BYTES       = 8192; // L1 data cache size (8KB)
    localparam int CONF_L1D_LINE_BYTES  = 32;   // L1 data cache line size
    localparam int CONF_UCODE_ROM_DEPTH = 256;  // Microcode ROM entries
    localparam int CONF_UCODE_STEP_MAX  = 64;   // Max micro-op steps per instruction
    localparam int CONF_NUM_SEGMENTS    = 6;    // x86 segment registers

    // --- Feature Gating ---
    // Disable advanced OoO features until core is functionally stable.
    // Each maps to a generate-if or mux in the relevant module.
    localparam bit CONF_ENABLE_SPECBITS      = 1'b0;  // Phase P1: per-branch spec bits
    localparam bit CONF_ENABLE_PRODUCER_MTX  = 1'b0;  // Phase P1: wakeup matrix
    localparam bit CONF_ENABLE_RENAME_SNAP   = 1'b0;  // Phase P1: rename snapshots
    localparam bit CONF_ENABLE_DCACHE        = 1'b0;  // Phase P1: L1 data cache
    localparam bit CONF_ENABLE_TAGE          = 1'b0;  // Phase P2: TAGE predictor
    localparam bit CONF_ENABLE_V86           = 1'b1;  // V86 mode support (boot-critical)
    localparam bit CONF_ENABLE_PSE           = 1'b0;  // 4MB pages (deferred)
    localparam bit CONF_ENABLE_PENTIUM_EXT  = 1'b0;  // P5/P6: CMOVcc, basic MMX, RDPMC
    localparam bit CONF_ENABLE_P3_EXT       = 1'b0;  // PIII/P4: PREFETCH, CLFLUSH, fences
    localparam bit CONF_ENABLE_NEHALEM_EXT  = 1'b0;  // Nehalem+: POPCNT, LZCNT, TZCNT
    localparam bit CONF_ENABLE_DECODE_CACHE = 1'b0;  // Phase 1: decode output cache
    localparam int CONF_DEC_CACHE_ENTRIES   = 256;
    localparam int CONF_DEC_CACHE_IDX_W     = $clog2(CONF_DEC_CACHE_ENTRIES); // 8

    // --- P3: Microcode ---
`ifdef VERILATOR_ENABLE_MICROCODE
    localparam bit CONF_ENABLE_MICROCODE  = 1'b1;
`else
    localparam bit CONF_ENABLE_MICROCODE  = 1'b0;
`endif

    // --- P2: Memory Integration Gates ---
`ifdef SYNTHESIS_ENABLE_MEMORY
    localparam bit CONF_ENABLE_LSQ_MEMIF   = 1'b1;  // P2: LSQ split-phase wiring into core_top
    localparam bit CONF_ENABLE_MEM_FABRIC  = 1'b1;  // P2: split-phase L2 with MSHRs (requires LSQ_MEMIF + L2_CACHE)
    localparam bit CONF_ENABLE_L2_CACHE    = 1'b1;  // L2: 128KB unified cache (replaces mem_ctrl)
    localparam bit CONF_ENABLE_TLB         = 1'b1;  // P3.TLB.a: data-side paging translation
`else
 `ifdef VERILATOR_ENABLE_LSQ_MEMIF
    localparam bit CONF_ENABLE_LSQ_MEMIF   = 1'b1;
 `else
    localparam bit CONF_ENABLE_LSQ_MEMIF   = 1'b0;
 `endif
    localparam bit CONF_ENABLE_MEM_FABRIC  = 1'b0;  // P2: split-phase L2 with MSHRs (requires LSQ_MEMIF + L2_CACHE)
    localparam bit CONF_ENABLE_L2_CACHE    = 1'b0;  // L2: 128KB unified cache (replaces mem_ctrl)
    localparam bit CONF_ENABLE_TLB         = 1'b0;  // P3.TLB.a: data-side paging translation
`endif

    // --- L2 Split-Phase / MSHR ---
    localparam int CONF_L2_NUM_MSHR   = 4;
    localparam int CONF_L2_MSHR_ID_W  = $clog2(CONF_L2_NUM_MSHR);  // 2

    // --- L2 Cache Geometry ---
    localparam int CONF_L2_SETS       = 1024;  // 128KB / 32B / 4 ways
    localparam int CONF_L2_WAYS       = 4;
    localparam int CONF_L2_LINE_BYTES = 32;    // Matches CONF_L1D_LINE_BYTES
    localparam int CONF_L2_INDEX_W    = $clog2(CONF_L2_SETS);       // 10
    localparam int CONF_L2_OFFSET_W   = $clog2(CONF_L2_LINE_BYTES); // 5
    localparam int CONF_L2_TAG_W      = 32 - CONF_L2_INDEX_W - CONF_L2_OFFSET_W; // 17

    localparam int CONF_MEM_REQ_ID_W        = 6;     // Memory transaction ID width
    localparam int CONF_LSQ_OUTSTANDING_DEPTH = 4;   // Max requests in flight from LSQ
    localparam int CONF_LSQ_PEND_ID_W = $clog2(CONF_LSQ_OUTSTANDING_DEPTH);  // 2

    // --- Derived Type Widths ---
    localparam int PHYS_REG_WIDTH = $clog2(CONF_PHYS_REG_NUM);  // 5 for 32
    localparam int ROB_ID_WIDTH   = $clog2(CONF_ROB_ENTRIES);    // 4 for 16
    localparam int IQ_ID_WIDTH    = $clog2(CONF_IQ_ENTRIES);     // 3 for 8
    localparam int LQ_ID_WIDTH    = $clog2(CONF_LSQ_LQ_ENTRIES); // 2 for 4
    localparam int SQ_ID_WIDTH    = $clog2(CONF_LSQ_SQ_ENTRIES); // 2 for 4
    localparam int TLB_ID_WIDTH   = $clog2(CONF_TLB_ENTRIES);    // 5 for 32
    localparam int PHT_IDX_WIDTH  = $clog2(CONF_PHT_ENTRIES);    // 8 for 256
    localparam int FTQ_ID_WIDTH   = $clog2(CONF_FTQ_ENTRIES);    // 3 for 8
    localparam int UCODE_ADDR_W   = $clog2(CONF_UCODE_ROM_DEPTH);// 8 for 256
    localparam int UCODE_STEP_W   = $clog2(CONF_UCODE_STEP_MAX); // 6 for 64

    // --- Derived Typedefs (width from parameters) ---
    typedef logic [PHYS_REG_WIDTH-1:0] phys_reg_t;
    typedef logic [ROB_ID_WIDTH-1:0]   rob_id_t;
    typedef logic [LQ_ID_WIDTH-1:0]    lq_idx_t;   // Load queue index
    typedef logic [SQ_ID_WIDTH-1:0]    sq_idx_t;    // Store queue index
    typedef logic [FTQ_ID_WIDTH-1:0]   ftq_idx_t;   // Fetch target queue index

    // --- Branch Tag / SpecBits (Phase P1) ---
    localparam int BR_TAG_WIDTH = $clog2(CONF_MAX_BR_COUNT);  // 2 for 4
    typedef logic [BR_TAG_WIDTH-1:0]     br_tag_t;
    typedef logic [CONF_MAX_BR_COUNT-1:0] specbits_t;   // 4-bit spec mask

    // --- FTQ Entry (Phase P1) ---
    typedef struct packed {
        logic           valid;
        logic [31:0]    fetch_pc;        // Start PC of the fetch block
        logic           pred_taken;      // Branch predictor said taken?
        logic [31:0]    pred_target;     // Predicted next-fetch PC
        br_tag_t        br_tag;          // Branch tag (if this block has a branch)
        logic           has_branch;      // This fetch block contains a branch
        logic [CONF_GHR_WIDTH-1:0] ghr_snap; // GHR at time of prediction (for repair)
    } ftq_entry_t;

    // --- Micro-op Type (used by microcode sequencer) ---
    typedef struct packed {
        logic [UCODE_ADDR_W-1:0] rom_addr;    // Microcode ROM address
        logic [UCODE_STEP_W-1:0] step;        // Current micro-step
        logic                    last;         // Last step flag
        logic                    atomic;       // Atomic (non-interruptible) sequence
    } micro_op_t;

    // --- Exception Info (carried through ROB for precise exceptions) ---
    typedef struct packed {
        logic        valid;       // Exception pending
        logic [7:0]  vector;      // Exception vector (0-31)
        logic [31:0] error_code;  // Error code (for #GP, #PF, etc.)
        logic        has_error;   // Error code is valid
        logic [31:0] cr2_value;   // Faulting address (for #PF)
    } exc_info_t;

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
        OP_IO_WRITE  = 4'hA,
        OP_MUL_DIV   = 4'hB,    // MUL/IMUL/DIV/IDIV (multi-cycle)
        OP_BITCOUNT  = 4'hC,    // POPCNT, LZCNT, TZCNT (Nehalem extensions)
        OP_CMOV      = 4'hD,    // CMOVcc — conditional move (Pentium extensions)
        OP_FENCE     = 4'hE     // MFENCE, LFENCE, SFENCE (P3/P4 extensions)
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

    // --- Unified Memory-System Request/Response (split-phase, tagged) ---
    // D7: mem_req_t.addr is always a byte address.
    // DDRAM_ADDR is always a 64-bit word address (byte_addr[31:3]).
    // Conversion responsibility: the module that drives DDRAM_ADDR.
    typedef enum logic [2:0] {
        MEM_OP_LD         = 3'd0, // Scalar load (1/2/4/8B)
        MEM_OP_ST         = 3'd1, // Scalar store (1/2/4/8B)
        MEM_OP_IFETCH_FILL= 3'd2, // Instruction line fill
        MEM_OP_DFETCH_FILL= 3'd3, // Data line fill
        MEM_OP_WB         = 3'd4, // Cache line writeback
        MEM_OP_FENCE      = 3'd5  // Ordering barrier / drain point
    } mem_op_t;

    typedef enum logic [1:0] {
        MEM_RESP_OK       = 2'd0,
        MEM_RESP_RETRY    = 2'd1,
        MEM_RESP_FAULT    = 2'd2,
        MEM_RESP_MISALIGN = 2'd3
    } mem_resp_t;

    typedef struct packed {
        logic [CONF_MEM_REQ_ID_W-1:0] id;      // Request/response match tag
        mem_op_t       op;                      // Operation class
        logic [31:0]   addr;                    // Byte address
        logic [1:0]    size;                    // 0=1B, 1=2B, 2=4B, 3=8B
        // Scalar store convention:
        //   byte_en + wdata are aligned to addr[31:3] (64-bit word base).
        //   The producer applies addr[2:0] lane placement before issuing req.
        logic [7:0]    byte_en;                 // Byte lanes in a 64-bit beat
        logic [63:0]   wdata;                   // Store/writeback payload beat
        logic [2:0]    burst_len;               // beats-1 (0 = single beat)
        logic          cacheable;               // 1=cacheable, 0=uncached
        logic          strong_order;            // MMIO/fence-style ordering
    } mem_req_t;

    typedef struct packed {
        logic [CONF_MEM_REQ_ID_W-1:0] id;      // Echoed request ID
        // For scalar loads in bring-up adapter, rdata[63:0] is the raw DDR beat.
        // The consumer performs byte/word/dword extraction using addr[2:0].
        logic [127:0]  rdata;                  // Data beat payload (low 64b used now)
        logic [2:0]    beat_idx;               // Beat number within burst
        logic          last;                   // Last beat of this response
        mem_resp_t     resp;                   // Completion status
    } mem_rsp_t;

    // --- Dispatch/Execute Instruction Packet ---
    // Used by f386_dispatch and f386_execute_stage for decoded instructions
    // flowing from decode → dispatch → execute.
    typedef struct packed {
        logic           is_valid;
        logic [31:0]    pc;
        logic [7:0]     opcode;       // ALU: [5:0] = alu_op, FPU: [3:0] = fp_op
        op_type_t       op_category;
        logic [2:0]     reg_dest;     // Architectural GPR destination (0-7)
        logic [2:0]     reg_src_a;
        logic [2:0]     reg_src_b;
        rob_id_t        rob_tag;      // ROB slot assigned at dispatch
        br_tag_t        br_tag;       // Branch speculation tag
        logic           dest_valid;   // Instruction writes phys_dest
        phys_reg_t      phys_dest;    // Physical destination for CDB writeback
        logic [31:0]    imm_value;    // Immediate / branch displacement
        logic [5:0]     flags_in;     // Incoming EFLAGS {OF,SF,ZF,AF,PF,CF}
        logic [5:0]     flags_mask;   // Per-flag write mask (BOOM/80x86 pattern)
        logic           pred_taken;   // Branch prediction: taken?
        logic [31:0]    pred_target;  // Branch prediction: predicted target
        semantic_tag_t  sem_tag;      // Semantic tag for HARE transition logging
    } instr_info_t;

    // --- Pipeline Packets ---
    typedef struct packed {
        logic           valid;
        logic [31:0]    pc;
        logic [31:0]    raw_instr;
        logic [7:0]     opcode;
        op_type_t       op_cat;

        // Physical Register Mapping
        phys_reg_t      p_dest;
        logic           dest_valid;    // Instruction writes p_dest
        phys_reg_t      p_src_a;
        phys_reg_t      p_src_b;

        // Operand Status
        logic           src_a_ready;
        logic           src_b_ready;
        logic [31:0]    val_a;
        logic [31:0]    val_b;

        rob_id_t        rob_tag;
        br_tag_t        br_tag;        // Branch speculation tag assigned at dispatch
        logic [31:0]    imm_value;

        // P2: Memory integration fields
        lq_idx_t        lq_idx;             // Load queue index (filled at dispatch)
        sq_idx_t        sq_idx;             // Store queue index (filled at dispatch)
        logic           addr_base_valid;    // 1 = val_a is base register for AGU
        logic           addr_index_valid;   // 1 = val_b is index register for AGU (loads only)
        logic [1:0]     addr_scale;         // AGU scale: 0=1x, 1=2x, 2=4x, 3=8x
        logic [1:0]     mem_size;           // Memory op size: 0=byte, 1=word, 2=dword

        // P3: Microcode sequencer fields
        logic           is_0f;              // Two-byte opcode (0F prefix)
        logic [2:0]     modrm_reg;          // ModRM.reg field (group opcode extension)
        logic           is_rep;             // REP/REPE prefix present
        logic           is_repne;           // REPNE prefix (F2)
        logic           is_32bit;           // 32-bit operand size
    } ooo_instr_t;

    // Per-pipe decoded output (trimmed for cache storage)
    typedef struct packed {
        logic           valid;
        logic [31:0]    pc;
        logic [31:0]    raw_instr;
        logic [7:0]     opcode;
        op_type_t       op_cat;
        logic [2:0]     arch_dest;
        logic           dest_valid;
        logic [2:0]     arch_src_a;
        logic [2:0]     arch_src_b;
        logic           src_a_not_needed;
        logic           src_b_not_needed;
        logic [31:0]    imm_value;
        logic [31:0]    branch_target;
        logic           branch_target_valid;
        logic           branch_indirect;
        logic           reads_flags;
        logic           writes_flags;
        logic [2:0]     addr_base;
        logic           addr_base_valid;
        logic [2:0]     addr_index;
        logic           addr_index_valid;
        logic [1:0]     addr_scale;
    } dc_pipe_entry_t;  // 167 bits

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

    // --- Segment Register Index (matches x86 sreg3 encoding) ---
    typedef enum logic [2:0] {
        SEG_ES = 3'd0,
        SEG_CS = 3'd1,
        SEG_SS = 3'd2,
        SEG_DS = 3'd3,
        SEG_FS = 3'd4,
        SEG_GS = 3'd5
    } seg_idx_t;

    // --- Descriptor Table Register Index ---
    typedef enum logic [1:0] {
        DTR_GDTR = 2'd0,
        DTR_IDTR = 2'd1,
        DTR_LDTR = 2'd2,
        DTR_TR   = 2'd3
    } dtr_idx_t;

    // --- Control Register Index ---
    typedef enum logic [2:0] {
        CR_0 = 3'd0,
        CR_2 = 3'd2,
        CR_3 = 3'd3,
        CR_4 = 3'd4
    } cr_idx_t;

    // --- EFLAGS Bit Positions ---
    localparam int EFLAGS_CF      = 0;
    localparam int EFLAGS_PF      = 2;
    localparam int EFLAGS_AF      = 4;
    localparam int EFLAGS_ZF      = 6;
    localparam int EFLAGS_SF      = 7;
    localparam int EFLAGS_TF      = 8;
    localparam int EFLAGS_IF      = 9;
    localparam int EFLAGS_DF      = 10;
    localparam int EFLAGS_OF      = 11;
    localparam int EFLAGS_IOPL_LO = 12;
    localparam int EFLAGS_IOPL_HI = 13;
    localparam int EFLAGS_NT      = 14;
    localparam int EFLAGS_RF      = 16;
    localparam int EFLAGS_VM      = 17;
    localparam int EFLAGS_AC      = 18;

    // --- ALU Flags Mapping (matches f386_alu.v flags_out[5:0]) ---
    // flags_out = {OF, SF, ZF, AF, PF, CF}
    localparam int ALU_FLAG_CF = 0;
    localparam int ALU_FLAG_PF = 1;
    localparam int ALU_FLAG_AF = 2;
    localparam int ALU_FLAG_ZF = 3;
    localparam int ALU_FLAG_SF = 4;
    localparam int ALU_FLAG_OF = 5;

    // --- Descriptor Cache Bit Positions (matches ao486 defines.v) ---
    localparam int DESC_BIT_G      = 55;
    localparam int DESC_BIT_DB     = 54;
    localparam int DESC_BIT_P      = 47;
    localparam int DESC_BIT_SEG    = 44;
    localparam int DESC_BIT_DPL_HI = 46;
    localparam int DESC_BIT_DPL_LO = 45;
    localparam int DESC_BIT_TYPE_3 = 43;  // CODE bit
    localparam int DESC_BIT_TYPE_2 = 42;  // Conforming(code) / Expand-down(data)
    localparam int DESC_BIT_TYPE_1 = 41;  // Readable(code) / Writable(data)
    localparam int DESC_BIT_TYPE_0 = 40;  // Accessed

    // --- Descriptor Type Helper Functions (matches ao486 defines.v:90-98) ---
    // Usage: DESC_IS_CODE(cache_val) etc.
    // These operate on the 64-bit descriptor cache value.
    //   [43]    = 1 for code, 0 for data
    //   [42]    = conforming (code) / expand-down (data)
    //   [41]    = readable (code) / writable (data)
    //   [40]    = accessed
    function automatic logic desc_is_code(input logic [63:0] d);
        return d[43];
    endfunction
    function automatic logic desc_is_data(input logic [63:0] d);
        return ~d[43];
    endfunction
    function automatic logic desc_is_data_ro(input logic [63:0] d);
        return ~d[43] && ~d[41];
    endfunction
    function automatic logic desc_is_data_rw(input logic [63:0] d);
        return ~d[43] && d[41];
    endfunction
    function automatic logic desc_is_code_eo(input logic [63:0] d);
        return d[43] && ~d[41];
    endfunction
    function automatic logic desc_is_code_conforming(input logic [63:0] d);
        return d[43] && d[42];
    endfunction
    function automatic logic desc_is_code_non_conforming(input logic [63:0] d);
        return d[43] && ~d[42];
    endfunction
    function automatic logic desc_is_accessed(input logic [63:0] d);
        return d[40];
    endfunction
    function automatic logic desc_is_expand_down(input logic [63:0] d);
        return ~d[43] && d[42];
    endfunction

    // --- Selector Field Positions ---
    localparam int SEL_BIT_TI  = 2;       // Table Indicator: 0=GDT, 1=LDT
    localparam int SEL_RPL_HI  = 1;
    localparam int SEL_RPL_LO  = 0;

    // --- Gate / TSS Descriptor Type Constants (ao486 defines.v:115-125) ---
    localparam logic [3:0] DESC_TSS_AVAIL_386      = 4'h9;
    localparam logic [3:0] DESC_TSS_BUSY_386       = 4'hB;
    localparam logic [3:0] DESC_TSS_AVAIL_286      = 4'h1;
    localparam logic [3:0] DESC_TSS_BUSY_286       = 4'h3;
    localparam logic [3:0] DESC_INTERRUPT_GATE_386  = 4'hE;
    localparam logic [3:0] DESC_INTERRUPT_GATE_286  = 4'h6;
    localparam logic [3:0] DESC_TRAP_GATE_386       = 4'hF;
    localparam logic [3:0] DESC_TRAP_GATE_286       = 4'h7;
    localparam logic [3:0] DESC_CALL_GATE_386       = 4'hC;
    localparam logic [3:0] DESC_CALL_GATE_286       = 4'h4;
    localparam logic [3:0] DESC_LDT                 = 4'h2;
    localparam logic [3:0] DESC_TASK_GATE           = 4'h5;

    // --- MMIO Address Classification ---
    // P2: VGA hole only. TODO: expand to PCI config, APIC, ISA MMIO.
    function automatic logic is_mmio_addr(input logic [31:0] addr);
        return (addr >= 32'h000A_0000 && addr <= 32'h000B_FFFF);
    endfunction

    // --- Exception Vector Constants (ao486 defines.v:34-51) ---
    localparam logic [7:0] EXC_DE = 8'd0;   // Divide by zero
    localparam logic [7:0] EXC_DB = 8'd1;   // Debug
    localparam logic [7:0] EXC_BP = 8'd3;   // Breakpoint
    localparam logic [7:0] EXC_OF = 8'd4;   // Overflow
    localparam logic [7:0] EXC_BR = 8'd5;   // Bound range
    localparam logic [7:0] EXC_UD = 8'd6;   // Invalid opcode
    localparam logic [7:0] EXC_NM = 8'd7;   // Device not available
    localparam logic [7:0] EXC_DF = 8'd8;   // Double fault
    localparam logic [7:0] EXC_TS = 8'd10;  // Invalid TSS
    localparam logic [7:0] EXC_NP = 8'd11;  // Segment not present
    localparam logic [7:0] EXC_SS = 8'd12;  // Stack segment fault
    localparam logic [7:0] EXC_GP = 8'd13;  // General protection
    localparam logic [7:0] EXC_PF = 8'd14;  // Page fault
    localparam logic [7:0] EXC_AC = 8'd17;  // Alignment check
    localparam logic [7:0] EXC_MC = 8'd18;  // Machine check

    // --- Gate Dependency Assertions ---
    // MEM_FABRIC requires both LSQ_MEMIF (split-phase ports) and L2_CACHE (geometry reuse).
    // Note: Verilator does not allow initial blocks in packages, so these are
    // enforced via generate-if assertions in modules that use the gates.

endpackage
