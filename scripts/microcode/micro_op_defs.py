"""
fabi386: Micro-Operation Field Definitions
-------------------------------------------
Defines the encoding format for micro-ops emitted by the microcode compiler.
Each micro-op is 48 bits wide, packed into the ROM.

Reference: 80x86/rtl/microcode/ .us file format
"""

from enum import IntEnum
from dataclasses import dataclass

# --- Micro-op operation types (matches f386_pkg op_type_t) ---
class MicroOpType(IntEnum):
    ALU_REG   = 0x0
    ALU_IMM   = 0x1
    LOAD      = 0x2
    STORE     = 0x3
    BRANCH    = 0x4
    FLOAT     = 0x5
    MICROCODE = 0x6
    SYS_CALL  = 0x7
    IO_READ   = 0x9
    IO_WRITE  = 0xA

# --- Register encoding (x86 GPR) ---
class Reg(IntEnum):
    EAX = 0; ECX = 1; EDX = 2; EBX = 3
    ESP = 4; EBP = 5; ESI = 6; EDI = 7

# --- Segment register encoding ---
class SegReg(IntEnum):
    ES = 0; CS = 1; SS = 2; DS = 3; FS = 4; GS = 5

# --- ALU operation encoding (matches f386_alu.v) ---
class AluOp(IntEnum):
    ADD = 0x0; SUB = 0x1; AND = 0x2; OR  = 0x3
    XOR = 0x4; SHL = 0x5; SHR = 0x6; SAR = 0x7
    ADC = 0x8; SBB = 0x9; NOT = 0xA; NEG = 0xB
    INC = 0xC; DEC = 0xD; ROL = 0xE; ROR = 0xF

# --- Special micro-op commands ---
class SpecialCmd(IntEnum):
    NOP       = 0x00
    LOAD_SEG  = 0x01  # Load segment register
    STORE_SEG = 0x02  # Store segment register
    LOAD_CR   = 0x03  # Load control register
    STORE_CR  = 0x04  # Store control register
    LOAD_DTR  = 0x05  # Load descriptor table register
    STORE_DTR = 0x06  # Store descriptor table register
    INT_ENTER = 0x07  # Interrupt entry sequence
    INT_EXIT  = 0x08  # Interrupt return sequence
    HALT      = 0x09  # HLT instruction
    CLI       = 0x0A  # Clear interrupt flag
    STI       = 0x0B  # Set interrupt flag
    PUSH_FLAGS= 0x0C  # Push EFLAGS to stack
    POP_FLAGS = 0x0D  # Pop EFLAGS from stack
    FAR_CALL  = 0x0E  # Far call sequence
    FAR_RET   = 0x0F  # Far return sequence
    TASK_SW   = 0x10  # Task switch

    # String operations
    STRING_LOAD  = 0x11  # Load from DS:ESI, auto-inc/dec
    STRING_STORE = 0x12  # Store to ES:EDI, auto-inc/dec
    REP_SETUP    = 0x13  # Check ECX, init REP loop
    REP_STEP     = 0x14  # Dec ECX, check continuation
    REP_YIELD    = 0x15  # Yield to interrupts in REP loop

    # Multiply / Divide
    MUL_EXEC     = 0x16  # Start hardware multiply
    DIV_EXEC     = 0x17  # Start hardware divide
    MUL_READ_HI  = 0x18  # Read high result word (DX or EDX)
    DIV_READ_Q   = 0x19  # Read quotient
    DIV_READ_R   = 0x1A  # Read remainder

    # BCD
    BCD_DAA      = 0x1B  # Decimal adjust after add
    BCD_DAS      = 0x1C  # Decimal adjust after sub
    BCD_AAA      = 0x1D  # ASCII adjust after add
    BCD_AAS      = 0x1E  # ASCII adjust after sub
    BCD_AAM      = 0x1F  # ASCII adjust after mul (uses DIV by 10)
    BCD_AAD      = 0x20  # ASCII adjust before div (AH*10 + AL)

    # Bit manipulation
    BIT_TEST     = 0x21  # BT: test bit, set CF
    BIT_SET      = 0x22  # BTS: test and set
    BIT_RESET    = 0x23  # BTR: test and reset
    BIT_COMP     = 0x24  # BTC: test and complement
    BIT_SCAN_FWD = 0x25  # BSF: bit scan forward
    BIT_SCAN_REV = 0x26  # BSR: bit scan reverse
    SHLD_OP      = 0x27  # SHLD double-precision shift left
    SHRD_OP      = 0x28  # SHRD double-precision shift right

    # Byte / Extension
    BSWAP_OP     = 0x29  # Byte swap 32-bit register
    MOVZX_OP     = 0x2A  # Zero-extend
    MOVSX_OP     = 0x2B  # Sign-extend
    CBW_CWDE     = 0x2C  # Sign-extend AL→AX or AX→EAX
    CWD_CDQ      = 0x2D  # Sign-extend AX→DX:AX or EAX→EDX:EAX

    # Atomic read-modify-write
    XCHG_OP      = 0x2E  # Exchange
    CMPXCHG_OP   = 0x2F  # Compare and exchange
    XADD_OP      = 0x30  # Exchange and add

    # Control / Misc
    ENTER_FRAME  = 0x31  # ENTER stack frame setup
    LEAVE_FRAME  = 0x32  # LEAVE stack frame teardown
    BOUND_CHK    = 0x33  # BOUND array check
    XLAT_OP      = 0x34  # XLAT table lookup
    LOOP_DEC     = 0x35  # LOOP decrement + check
    LAHF_OP      = 0x36  # Load AH from flags
    SAHF_OP      = 0x37  # Store AH to flags
    SETcc_OP     = 0x38  # Set byte on condition
    IO_IN        = 0x39  # IN port
    IO_OUT       = 0x3A  # OUT port

    # Segment operations
    LOAD_FAR_PTR = 0x3B  # Load far pointer (LES/LDS/LFS/LGS/LSS)
    ARPL_CHK     = 0x3C  # ARPL privilege adjust
    LAR_CHK      = 0x3D  # LAR access rights
    LSL_CHK      = 0x3E  # LSL segment limit
    VERR_CHK     = 0x3F  # VERR verify read
    VERW_CHK     = 0x40  # VERW verify write

    # Flag manipulation
    CLC_OP       = 0x41  # Clear carry flag
    STC_OP       = 0x42  # Set carry flag
    CMC_OP       = 0x43  # Complement carry flag
    CLD_OP       = 0x44  # Clear direction flag
    STD_OP       = 0x45  # Set direction flag

# --- Micro-op encoding (48-bit) ---
# [47:44] op_type     (4 bits)
# [43:40] alu_op      (4 bits, if ALU type)
# [39:37] dest_reg    (3 bits)
# [36:34] src_a_reg   (3 bits)
# [33:31] src_b_reg   (3 bits)
# [30:28] seg_reg     (3 bits)
# [27:20] special_cmd (8 bits)
# [19:4]  immediate   (16 bits)
# [3]     is_last     (1 bit) — last micro-op in sequence
# [2]     is_atomic   (1 bit) — non-interruptible
# [1:0]   size        (2 bits) — 00=32, 01=16, 10=8

MICRO_OP_WIDTH = 48

@dataclass
class MicroOp:
    """Represents a single micro-operation."""
    op_type: int = 0
    alu_op: int = 0
    dest_reg: int = 0
    src_a_reg: int = 0
    src_b_reg: int = 0
    seg_reg: int = 0
    special_cmd: int = 0
    immediate: int = 0
    is_last: bool = False
    is_atomic: bool = False
    size: int = 0  # 0=32, 1=16, 2=8

    def encode(self) -> int:
        """Encode micro-op to 48-bit integer."""
        val = 0
        val |= (self.op_type & 0xF) << 44
        val |= (self.alu_op & 0xF) << 40
        val |= (self.dest_reg & 0x7) << 37
        val |= (self.src_a_reg & 0x7) << 34
        val |= (self.src_b_reg & 0x7) << 31
        val |= (self.seg_reg & 0x7) << 28
        val |= (self.special_cmd & 0xFF) << 20
        val |= (self.immediate & 0xFFFF) << 4
        val |= (int(self.is_last) & 0x1) << 3
        val |= (int(self.is_atomic) & 0x1) << 2
        val |= (self.size & 0x3)
        return val

    def to_hex(self) -> str:
        """Return hex string representation."""
        return f"48'h{self.encode():012X}"
