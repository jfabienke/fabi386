/*
 * fabi386: Microcode Definitions
 * --------------------------------
 * Encoding constants for micro-op fields.
 * Must match micro_op_defs.py encoding.
 */

// Micro-op bit field positions (48-bit micro-op)
localparam int UOP_OP_TYPE_HI    = 47;
localparam int UOP_OP_TYPE_LO    = 44;
localparam int UOP_ALU_OP_HI     = 43;
localparam int UOP_ALU_OP_LO     = 40;
localparam int UOP_DEST_REG_HI   = 39;
localparam int UOP_DEST_REG_LO   = 37;
localparam int UOP_SRC_A_REG_HI  = 36;
localparam int UOP_SRC_A_REG_LO  = 34;
localparam int UOP_SRC_B_REG_HI  = 33;
localparam int UOP_SRC_B_REG_LO  = 31;
localparam int UOP_SEG_REG_HI    = 30;
localparam int UOP_SEG_REG_LO    = 28;
localparam int UOP_SPECIAL_HI    = 27;
localparam int UOP_SPECIAL_LO    = 20;
localparam int UOP_IMM_HI        = 19;
localparam int UOP_IMM_LO        = 4;
localparam int UOP_IS_LAST       = 3;
localparam int UOP_IS_ATOMIC     = 2;
localparam int UOP_SIZE_HI       = 1;
localparam int UOP_SIZE_LO       = 0;

// Special command encodings
localparam logic [7:0] UCMD_NOP         = 8'h00;
localparam logic [7:0] UCMD_LOAD_SEG    = 8'h01;
localparam logic [7:0] UCMD_STORE_SEG   = 8'h02;
localparam logic [7:0] UCMD_LOAD_CR     = 8'h03;
localparam logic [7:0] UCMD_STORE_CR    = 8'h04;
localparam logic [7:0] UCMD_LOAD_DTR    = 8'h05;
localparam logic [7:0] UCMD_STORE_DTR   = 8'h06;
localparam logic [7:0] UCMD_INT_ENTER   = 8'h07;
localparam logic [7:0] UCMD_INT_EXIT    = 8'h08;
localparam logic [7:0] UCMD_HALT        = 8'h09;
localparam logic [7:0] UCMD_CLI         = 8'h0A;
localparam logic [7:0] UCMD_STI         = 8'h0B;
localparam logic [7:0] UCMD_PUSH_FLAGS  = 8'h0C;
localparam logic [7:0] UCMD_POP_FLAGS   = 8'h0D;
localparam logic [7:0] UCMD_FAR_CALL    = 8'h0E;
localparam logic [7:0] UCMD_FAR_RET     = 8'h0F;
localparam logic [7:0] UCMD_PUSH_PRE    = 8'h80;  // PUSH with ESP pre-decrement
localparam logic [7:0] UCMD_POP_POST    = 8'h81;  // POP with ESP post-increment

// String operations
localparam logic [7:0] UCMD_STRING_LOAD  = 8'h11;
localparam logic [7:0] UCMD_STRING_STORE = 8'h12;
localparam logic [7:0] UCMD_REP_SETUP   = 8'h13;
localparam logic [7:0] UCMD_REP_STEP    = 8'h14;
localparam logic [7:0] UCMD_REP_YIELD   = 8'h15;

// Multiply / Divide
localparam logic [7:0] UCMD_MUL_EXEC    = 8'h16;
localparam logic [7:0] UCMD_DIV_EXEC    = 8'h17;
localparam logic [7:0] UCMD_MUL_READ_HI = 8'h18;
localparam logic [7:0] UCMD_DIV_READ_Q  = 8'h19;
localparam logic [7:0] UCMD_DIV_READ_R  = 8'h1A;

// BCD
localparam logic [7:0] UCMD_BCD_DAA     = 8'h1B;
localparam logic [7:0] UCMD_BCD_DAS     = 8'h1C;
localparam logic [7:0] UCMD_BCD_AAA     = 8'h1D;
localparam logic [7:0] UCMD_BCD_AAS     = 8'h1E;
localparam logic [7:0] UCMD_BCD_AAM     = 8'h1F;
localparam logic [7:0] UCMD_BCD_AAD     = 8'h20;

// Bit manipulation
localparam logic [7:0] UCMD_BIT_TEST    = 8'h21;
localparam logic [7:0] UCMD_BIT_SET     = 8'h22;
localparam logic [7:0] UCMD_BIT_RESET   = 8'h23;
localparam logic [7:0] UCMD_BIT_COMP    = 8'h24;
localparam logic [7:0] UCMD_BSF         = 8'h25;
localparam logic [7:0] UCMD_BSR         = 8'h26;
localparam logic [7:0] UCMD_SHLD        = 8'h27;
localparam logic [7:0] UCMD_SHRD        = 8'h28;

// Byte / Extension
localparam logic [7:0] UCMD_BSWAP       = 8'h29;
localparam logic [7:0] UCMD_MOVZX       = 8'h2A;
localparam logic [7:0] UCMD_MOVSX       = 8'h2B;
localparam logic [7:0] UCMD_CBW_CWDE    = 8'h2C;
localparam logic [7:0] UCMD_CWD_CDQ     = 8'h2D;

// Atomic read-modify-write
localparam logic [7:0] UCMD_XCHG        = 8'h2E;
localparam logic [7:0] UCMD_CMPXCHG     = 8'h2F;
localparam logic [7:0] UCMD_XADD        = 8'h30;

// Control / Misc
localparam logic [7:0] UCMD_ENTER_FRAME = 8'h31;
localparam logic [7:0] UCMD_LEAVE_FRAME = 8'h32;
localparam logic [7:0] UCMD_BOUND_CHK   = 8'h33;
localparam logic [7:0] UCMD_XLAT        = 8'h34;
localparam logic [7:0] UCMD_LOOP_DEC    = 8'h35;
localparam logic [7:0] UCMD_LAHF        = 8'h36;
localparam logic [7:0] UCMD_SAHF        = 8'h37;
localparam logic [7:0] UCMD_SETcc       = 8'h38;
localparam logic [7:0] UCMD_IO_IN       = 8'h39;
localparam logic [7:0] UCMD_IO_OUT      = 8'h3A;

// Segment operations
localparam logic [7:0] UCMD_LOAD_FAR_PTR = 8'h3B;
localparam logic [7:0] UCMD_ARPL_CHK    = 8'h3C;
localparam logic [7:0] UCMD_LAR_CHK     = 8'h3D;
localparam logic [7:0] UCMD_LSL_CHK     = 8'h3E;
localparam logic [7:0] UCMD_VERR_CHK    = 8'h3F;
localparam logic [7:0] UCMD_VERW_CHK    = 8'h40;

// Flag manipulation
localparam logic [7:0] UCMD_CLC         = 8'h41;
localparam logic [7:0] UCMD_STC         = 8'h42;
localparam logic [7:0] UCMD_CMC         = 8'h43;
localparam logic [7:0] UCMD_CLD         = 8'h44;
localparam logic [7:0] UCMD_STD         = 8'h45;
