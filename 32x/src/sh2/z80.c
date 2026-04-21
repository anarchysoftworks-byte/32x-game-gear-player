/*
 * z80.c — Z80 CPU core for GG emulator on Sega 32X
 * Ported from Marat Fayzullin's Z80 interpreter (meka/srcs/z80marat/Z80.cpp)
 *
 * Modified for bare-metal SH-2 execution:
 *  - No LoopZ80() callback; z80_run() takes a cycle budget
 *  - No debugger hooks or opcode usage tracking
 *  - RdZ80/WrZ80/InZ80/OutZ80 replaced with gg_read/gg_write/gg_in/gg_out
 *  - Types: pair→z80_pair_t, byte→uint8_t, word→uint16_t, offset→int8_t
 *
 * Performance: gg_read() calls are replaced with the GG_READ() inline
 * macro (page table lookup without function call overhead).  gg_write()
 * uses the inline fast path for the common RAM case.
 */

#include "gg_emu.h"

/* Override gg_read/gg_write with inline versions in this file.
   This eliminates ~10 SH-2 cycles per memory access in the Z80 core. */
#undef gg_read
#define gg_read(addr)          GG_READ(addr)
#undef gg_write
#define gg_write(addr, val)    gg_write_inline((addr), (val))

/* ------------------------------------------------------------------ */
/* Direct PC fetch — avoid page table lookup on every opcode fetch     */
/*                                                                     */
/* pc_base is adjusted so pc_base[R->PC.W] gives the correct byte     */
/* without any shift/mask/index into Mem_Pages[].  A cheap bounds      */
/* check detects page crossings (~0.1% of fetches) and rebases.        */
/*                                                                     */
/* Only z80_run() and its included z80_ops.h use these macros;         */
/* prefix handler functions still use gg_read() for their PC reads.   */
/* ------------------------------------------------------------------ */

#define Z80_REBASE_PC() do { \
    pc_page_start = R->PC.W & 0xE000u; \
    pc_base = Mem_Pages[R->PC.W >> 13] - pc_page_start; \
} while(0)

#define FETCH_BYTE() ({ \
    if (__builtin_expect((unsigned)(R->PC.W - pc_page_start) >= 0x2000u, 0)) \
        Z80_REBASE_PC(); \
    pc_base[R->PC.W++]; \
})

/* ------------------------------------------------------------------ */
/* Z80 flag constants                                                  */
/* ------------------------------------------------------------------ */

#define S_FLAG  0x80
#define Z_FLAG  0x40
#define H_FLAG  0x10
#define P_FLAG  0x04
#define V_FLAG  0x04
#define N_FLAG  0x02
#define C_FLAG  0x01

/* IM0 interrupt vectors (RST opcode encodings) */
#define INT_RST00  0x00C7
#define INT_RST08  0x00CF
#define INT_RST10  0x00D7
#define INT_RST18  0x00DF
#define INT_RST20  0x00E7
#define INT_RST28  0x00EF
#define INT_RST30  0x00F7
#define INT_RST38  0x00FF

/* ------------------------------------------------------------------ */
/* Lookup tables                                                       */
/* ------------------------------------------------------------------ */

#include "z80_tables.h"

/* ------------------------------------------------------------------ */
/* Opcode enums                                                        */
/* ------------------------------------------------------------------ */

#include "z80_opcodes.h"

/* ------------------------------------------------------------------ */
/* Instruction macros (ported from Z80.cpp)                            */
/* ------------------------------------------------------------------ */

#define S(Fl)        R->AF.B.l|=Fl
#define R(Fl)        R->AF.B.l&=~(Fl)
#define FLAGS(Rg,Fl) R->AF.B.l=Fl|ZSTable[Rg]

#define M_RLC(Rg)      \
  R->AF.B.l=Rg>>7;Rg=(Rg<<1)|R->AF.B.l;R->AF.B.l|=PZSTable[Rg]
#define M_RRC(Rg)      \
  R->AF.B.l=Rg&0x01;Rg=(Rg>>1)|(R->AF.B.l<<7);R->AF.B.l|=PZSTable[Rg]
#define M_RL(Rg)       \
  if(Rg&0x80)          \
  {                    \
    Rg=(Rg<<1)|(R->AF.B.l&C_FLAG); \
    R->AF.B.l=PZSTable[Rg]|C_FLAG; \
  }                    \
  else                 \
  {                    \
    Rg=(Rg<<1)|(R->AF.B.l&C_FLAG); \
    R->AF.B.l=PZSTable[Rg];        \
  }
#define M_RR(Rg)       \
  if(Rg&0x01)          \
  {                    \
    Rg=(Rg>>1)|(R->AF.B.l<<7);     \
    R->AF.B.l=PZSTable[Rg]|C_FLAG; \
  }                    \
  else                 \
  {                    \
    Rg=(Rg>>1)|(R->AF.B.l<<7);     \
    R->AF.B.l=PZSTable[Rg];        \
  }

#define M_SLA(Rg)      \
  R->AF.B.l=Rg>>7;Rg<<=1;R->AF.B.l|=PZSTable[Rg]
#define M_SRA(Rg)      \
  R->AF.B.l=Rg&C_FLAG;Rg=(Rg>>1)|(Rg&0x80);R->AF.B.l|=PZSTable[Rg]

#define M_SLL(Rg)      \
  R->AF.B.l=Rg>>7;Rg=(Rg<<1)|0x01;R->AF.B.l|=PZSTable[Rg]
#define M_SRL(Rg)      \
  R->AF.B.l=Rg&0x01;Rg>>=1;R->AF.B.l|=PZSTable[Rg]

#define M_BIT(Bit,Rg)  \
  R->AF.B.l=(R->AF.B.l&C_FLAG)|H_FLAG|PZSTable[Rg&(1<<Bit)]

#define M_SET(Bit,Rg) Rg|=1<<Bit
#define M_RES(Bit,Rg) Rg&=~(1<<Bit)

#define M_POP(Rg)      \
  R->Rg.B.l=gg_read(R->SP.W++);R->Rg.B.h=gg_read(R->SP.W++)
#define M_PUSH(Rg)     \
  gg_write(--R->SP.W,R->Rg.B.h);gg_write(--R->SP.W,R->Rg.B.l)

#define M_CALL         \
  J.B.l=gg_read(R->PC.W++);J.B.h=gg_read(R->PC.W++);         \
  gg_write(--R->SP.W,R->PC.B.h);gg_write(--R->SP.W,R->PC.B.l); \
  R->PC.W=J.W

#define M_JP  J.B.l=gg_read(R->PC.W++);J.B.h=gg_read(R->PC.W);R->PC.W=J.W
#define M_JR  R->PC.W+=(int8_t)gg_read(R->PC.W)+1
#define M_RET R->PC.B.l=gg_read(R->SP.W++);R->PC.B.h=gg_read(R->SP.W++)

#define M_RST(Ad)      \
  gg_write(--R->SP.W,R->PC.B.h);gg_write(--R->SP.W,R->PC.B.l);R->PC.W=Ad

#define M_LDWORD(Rg)   \
  R->Rg.B.l=gg_read(R->PC.W++);R->Rg.B.h=gg_read(R->PC.W++)

#define M_ADD(Rg)      \
  J.W=R->AF.B.h+Rg;     \
  R->AF.B.l=            \
    (~(R->AF.B.h^Rg)&(Rg^J.B.l)&0x80? V_FLAG:0)| \
    J.B.h|ZSTable[J.B.l]|                        \
    ((R->AF.B.h^Rg^J.B.l)&H_FLAG);               \
  R->AF.B.h=J.B.l

#define M_SUB(Rg)      \
  J.W=R->AF.B.h-Rg;    \
  R->AF.B.l=           \
    ((R->AF.B.h^Rg)&(R->AF.B.h^J.B.l)&0x80? V_FLAG:0)| \
    N_FLAG|-J.B.h|ZSTable[J.B.l]|                      \
    ((R->AF.B.h^Rg^J.B.l)&H_FLAG);                     \
  R->AF.B.h=J.B.l

#define M_ADC(Rg)      \
  J.W=R->AF.B.h+Rg+(R->AF.B.l&C_FLAG); \
  R->AF.B.l=                           \
    (~(R->AF.B.h^Rg)&(Rg^J.B.l)&0x80? V_FLAG:0)| \
    J.B.h|ZSTable[J.B.l]|              \
    ((R->AF.B.h^Rg^J.B.l)&H_FLAG);     \
  R->AF.B.h=J.B.l

#define M_SBC(Rg)      \
  J.W=R->AF.B.h-Rg-(R->AF.B.l&C_FLAG); \
  R->AF.B.l=                           \
    ((R->AF.B.h^Rg)&(R->AF.B.h^J.B.l)&0x80? V_FLAG:0)| \
    N_FLAG|-J.B.h|ZSTable[J.B.l]|      \
    ((R->AF.B.h^Rg^J.B.l)&H_FLAG);     \
  R->AF.B.h=J.B.l

#define M_CP(Rg)       \
  J.W=R->AF.B.h-Rg;    \
  R->AF.B.l=           \
    ((R->AF.B.h^Rg)&(R->AF.B.h^J.B.l)&0x80? V_FLAG:0)| \
    N_FLAG|-J.B.h|ZSTable[J.B.l]|                      \
    ((R->AF.B.h^Rg^J.B.l)&H_FLAG)

#define M_AND(Rg) R->AF.B.h&=Rg;R->AF.B.l=H_FLAG|PZSTable[R->AF.B.h]
#define M_OR(Rg)  R->AF.B.h|=Rg;R->AF.B.l=PZSTable[R->AF.B.h]
#define M_XOR(Rg) R->AF.B.h^=Rg;R->AF.B.l=PZSTable[R->AF.B.h]

#define M_IN(Rg)        \
  Rg=gg_in(R->BC.B.l);  \
  R->AF.B.l=PZSTable[Rg]|(R->AF.B.l&C_FLAG)

#define M_INC(Rg)       \
  Rg++;                 \
  R->AF.B.l=            \
    (R->AF.B.l&C_FLAG)|ZSTable[Rg]|           \
    (Rg==0x80? V_FLAG:0)|(Rg&0x0F? 0:H_FLAG)

#define M_DEC(Rg)       \
  Rg--;                 \
  R->AF.B.l=            \
    N_FLAG|(R->AF.B.l&C_FLAG)|ZSTable[Rg]| \
    (Rg==0x7F? V_FLAG:0)|((Rg&0x0F)==0x0F? H_FLAG:0)

#define M_ADDW(Rg1,Rg2) \
  J.W=(R->Rg1.W+R->Rg2.W)&0xFFFF;                        \
  R->AF.B.l=                                             \
    (R->AF.B.l&~(H_FLAG|N_FLAG|C_FLAG))|                 \
    ((R->Rg1.W^R->Rg2.W^J.W)&0x1000? H_FLAG:0)|          \
    (((long)R->Rg1.W+(long)R->Rg2.W)&0x10000? C_FLAG:0); \
  R->Rg1.W=J.W

#define M_ADCW(Rg)      \
  I=R->AF.B.l&C_FLAG;J.W=(R->HL.W+R->Rg.W+I)&0xFFFF;           \
  R->AF.B.l=                                                   \
    (((long)R->HL.W+(long)R->Rg.W+(long)I)&0x10000? C_FLAG:0)| \
    (~(R->HL.W^R->Rg.W)&(R->Rg.W^J.W)&0x8000? V_FLAG:0)|       \
    ((R->HL.W^R->Rg.W^J.W)&0x1000? H_FLAG:0)|                  \
    (J.W? 0:Z_FLAG)|(J.B.h&S_FLAG);                            \
  R->HL.W=J.W

#define M_SBCW(Rg)      \
  I=R->AF.B.l&C_FLAG;J.W=(R->HL.W-R->Rg.W-I)&0xFFFF;           \
  R->AF.B.l=                                                   \
    N_FLAG|                                                    \
    (((long)R->HL.W-(long)R->Rg.W-(long)I)&0x10000? C_FLAG:0)| \
    ((R->HL.W^R->Rg.W)&(R->HL.W^J.W)&0x8000? V_FLAG:0)|        \
    ((R->HL.W^R->Rg.W^J.W)&0x1000? H_FLAG:0)|                  \
    (J.W? 0:Z_FLAG)|(J.B.h&S_FLAG);                            \
  R->HL.W=J.W

/* ------------------------------------------------------------------ */
/* Prefix handler functions                                            */
/* ------------------------------------------------------------------ */

static void CodesCB(z80_t *R)
{
    uint8_t I;

    I = gg_read(R->PC.W++);
    R->R++;
    R->ICount -= CyclesCB[I];
    switch (I)
    {
#include "z80_ops_cb.h"
    default: break;
    }
}

static void CodesDDCB(z80_t *R)
{
    z80_pair_t J;
    uint8_t I;

#define XX IX
    J.W = R->XX.W + (int8_t)gg_read(R->PC.W++);
    I = gg_read(R->PC.W++);
    R->ICount -= CyclesXXCB[I];
    switch (I)
    {
#include "z80_ops_xcb.h"
    default: break;
    }
#undef XX
}

static void CodesFDCB(z80_t *R)
{
    z80_pair_t J;
    uint8_t I;

#define XX IY
    J.W = R->XX.W + (int8_t)gg_read(R->PC.W++);
    I = gg_read(R->PC.W++);
    R->ICount -= CyclesXXCB[I];
    switch (I)
    {
#include "z80_ops_xcb.h"
    default: break;
    }
#undef XX
}

static void CodesED(z80_t *R)
{
    uint8_t I;
    z80_pair_t J;

    I = gg_read(R->PC.W++);
    R->R++;
    R->ICount -= CyclesED[I];
    switch (I)
    {
#include "z80_ops_ed.h"
    default: break;
    }
}

static void CodesDD(z80_t *R)
{
    uint8_t I;
    z80_pair_t J;

#define XX IX
    I = gg_read(R->PC.W++);
    R->R++;
    R->ICount -= CyclesXX[I];
    switch (I)
    {
#include "z80_ops_xx.h"
    case PFX_FD:
    case PFX_DD:
        R->PC.W--;
        break;
    case PFX_CB:
        CodesDDCB(R); break;
    default: break;
    }
#undef XX
}

static void CodesFD(z80_t *R)
{
    uint8_t I;
    z80_pair_t J;

#define XX IY
    I = gg_read(R->PC.W++);
    R->R++;
    R->ICount -= CyclesXX[I];
    switch (I)
    {
#include "z80_ops_xx.h"
    case PFX_FD:
    case PFX_DD:
        R->PC.W--;
        break;
    case PFX_CB:
        CodesFDCB(R); break;
    default: break;
    }
#undef XX
}

/* ------------------------------------------------------------------ */
/* z80_reset — Initialize CPU state                                    */
/* ------------------------------------------------------------------ */

void z80_reset(z80_t *R)
{
    R->PC.W     = 0x0000;
    R->SP.W     = 0xDFF0;
    R->AF.W     = 0x0000;
    R->BC.W     = 0x0000;
    R->DE.W     = 0x0000;
    R->HL.W     = 0x0000;
    R->AF1.W    = 0x0000;
    R->BC1.W    = 0x0000;
    R->DE1.W    = 0x0000;
    R->HL1.W    = 0x0000;
    R->IX.W     = 0x0000;
    R->IY.W     = 0x0000;
    R->I        = 0x00;
    R->IFF      = 0x00;
    R->R        = 0x00;
    R->R7       = 0x00;
    R->ICount   = 0;
    R->IBackup  = 0;
    R->IRequest = Z80_INT_NONE;
}

/* ------------------------------------------------------------------ */
/* z80_set_irq — Deliver an interrupt to the Z80                       */
/* ------------------------------------------------------------------ */

void z80_set_irq(z80_t *R, uint16_t Vector)
{
    if ((R->IFF & IFF_1) || (Vector == Z80_INT_NMI))
    {
        /* If HALTed, resume execution after HALT */
        if (R->IFF & IFF_HALT) { R->PC.W++; R->IFF &= ~IFF_HALT; }

        /* Save PC on stack */
        M_PUSH(PC);

        /* NMI */
        if (Vector == Z80_INT_NMI)
        {
            R->IFF &= ~(IFF_1 | IFF_EI);
            R->PC.W = 0x0066;
            R->ICount -= 11;
            return;
        }

        /* Maskable interrupt — disable further interrupts */
        R->IFF &= ~(IFF_1 | IFF_2 | IFF_EI);

        /* IM2: vectored interrupt */
        if (R->IFF & IFF_IM2)
        {
            Vector = (Vector & 0xFF) | ((uint16_t)(R->I) << 8);
            R->PC.B.l = gg_read(Vector++);
            R->PC.B.h = gg_read(Vector);
            R->ICount -= 19;
            return;
        }

        /* IM1: jump to 0x0038 */
        if (R->IFF & IFF_IM1)
        {
            R->PC.W = 0x0038;
            R->ICount -= 13;
            return;
        }

        /* IM0: execute RST instruction on data bus */
        R->ICount -= 13;
        switch (Vector)
        {
        case INT_RST00: R->PC.W = 0x0000; break;
        case INT_RST08: R->PC.W = 0x0008; break;
        case INT_RST10: R->PC.W = 0x0010; break;
        case INT_RST18: R->PC.W = 0x0018; break;
        case INT_RST20: R->PC.W = 0x0020; break;
        case INT_RST28: R->PC.W = 0x0028; break;
        case INT_RST30: R->PC.W = 0x0030; break;
        case INT_RST38: R->PC.W = 0x0038; break;
        }
    }
}

/* ------------------------------------------------------------------ */
/* z80_nmi — Trigger a non-maskable interrupt                          */
/* ------------------------------------------------------------------ */

void z80_nmi(z80_t *R)
{
    z80_set_irq(R, Z80_INT_NMI);
}

/* ------------------------------------------------------------------ */
/* z80_run — Execute Z80 instructions for the given number of cycles   */
/*                                                                     */
/* Uses GCC computed goto (threaded dispatch) for faster opcode        */
/* decode on the SH-2.  Each opcode label jumps to z80_fetch after     */
/* execution, avoiding switch/while overhead every instruction.        */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
void z80_run(z80_t *R, int cycles)
{
    uint8_t I;
    z80_pair_t J;
    uint8_t *pc_base;
    uint16_t pc_page_start;

    /* Threaded dispatch table — label addresses for all 256 opcodes.
       Placed in .sdram_code (SDRAM) for fast access; without this, GCC
       puts it in .rodata (ROM via adapter bus), costing ~8 extra cycles
       per opcode dispatch (~20K/frame). */
    static void *dispatch[256] __attribute__((section(".sdram_data"))) = {
        /* 0x00 */ &&z80_NOP,       &&z80_LD_BC_WORD, &&z80_LD_xBC_A,   &&z80_INC_BC,
        /* 0x04 */ &&z80_INC_B,     &&z80_DEC_B,      &&z80_LD_B_BYTE,  &&z80_RLCA,
        /* 0x08 */ &&z80_EX_AF_AF,  &&z80_ADD_HL_BC,  &&z80_LD_A_xBC,   &&z80_DEC_BC,
        /* 0x0C */ &&z80_INC_C,     &&z80_DEC_C,      &&z80_LD_C_BYTE,  &&z80_RRCA,
        /* 0x10 */ &&z80_DJNZ,      &&z80_LD_DE_WORD, &&z80_LD_xDE_A,   &&z80_INC_DE,
        /* 0x14 */ &&z80_INC_D,     &&z80_DEC_D,      &&z80_LD_D_BYTE,  &&z80_RLA,
        /* 0x18 */ &&z80_JR,        &&z80_ADD_HL_DE,  &&z80_LD_A_xDE,   &&z80_DEC_DE,
        /* 0x1C */ &&z80_INC_E,     &&z80_DEC_E,      &&z80_LD_E_BYTE,  &&z80_RRA,
        /* 0x20 */ &&z80_JR_NZ,     &&z80_LD_HL_WORD, &&z80_LD_xWORD_HL,&&z80_INC_HL,
        /* 0x24 */ &&z80_INC_H,     &&z80_DEC_H,      &&z80_LD_H_BYTE,  &&z80_DAA,
        /* 0x28 */ &&z80_JR_Z,      &&z80_ADD_HL_HL,  &&z80_LD_HL_xWORD,&&z80_DEC_HL,
        /* 0x2C */ &&z80_INC_L,     &&z80_DEC_L,      &&z80_LD_L_BYTE,  &&z80_CPL,
        /* 0x30 */ &&z80_JR_NC,     &&z80_LD_SP_WORD, &&z80_LD_xWORD_A, &&z80_INC_SP,
        /* 0x34 */ &&z80_INC_xHL,   &&z80_DEC_xHL,    &&z80_LD_xHL_BYTE,&&z80_SCF,
        /* 0x38 */ &&z80_JR_C,      &&z80_ADD_HL_SP,  &&z80_LD_A_xWORD, &&z80_DEC_SP,
        /* 0x3C */ &&z80_INC_A,     &&z80_DEC_A,      &&z80_LD_A_BYTE,  &&z80_CCF,
        /* 0x40 */ &&z80_LD_B_B,    &&z80_LD_B_C,     &&z80_LD_B_D,     &&z80_LD_B_E,
        /* 0x44 */ &&z80_LD_B_H,    &&z80_LD_B_L,     &&z80_LD_B_xHL,   &&z80_LD_B_A,
        /* 0x48 */ &&z80_LD_C_B,    &&z80_LD_C_C,     &&z80_LD_C_D,     &&z80_LD_C_E,
        /* 0x4C */ &&z80_LD_C_H,    &&z80_LD_C_L,     &&z80_LD_C_xHL,   &&z80_LD_C_A,
        /* 0x50 */ &&z80_LD_D_B,    &&z80_LD_D_C,     &&z80_LD_D_D,     &&z80_LD_D_E,
        /* 0x54 */ &&z80_LD_D_H,    &&z80_LD_D_L,     &&z80_LD_D_xHL,   &&z80_LD_D_A,
        /* 0x58 */ &&z80_LD_E_B,    &&z80_LD_E_C,     &&z80_LD_E_D,     &&z80_LD_E_E,
        /* 0x5C */ &&z80_LD_E_H,    &&z80_LD_E_L,     &&z80_LD_E_xHL,   &&z80_LD_E_A,
        /* 0x60 */ &&z80_LD_H_B,    &&z80_LD_H_C,     &&z80_LD_H_D,     &&z80_LD_H_E,
        /* 0x64 */ &&z80_LD_H_H,    &&z80_LD_H_L,     &&z80_LD_H_xHL,   &&z80_LD_H_A,
        /* 0x68 */ &&z80_LD_L_B,    &&z80_LD_L_C,     &&z80_LD_L_D,     &&z80_LD_L_E,
        /* 0x6C */ &&z80_LD_L_H,    &&z80_LD_L_L,     &&z80_LD_L_xHL,   &&z80_LD_L_A,
        /* 0x70 */ &&z80_LD_xHL_B,  &&z80_LD_xHL_C,   &&z80_LD_xHL_D,   &&z80_LD_xHL_E,
        /* 0x74 */ &&z80_LD_xHL_H,  &&z80_LD_xHL_L,   &&z80_HALT,       &&z80_LD_xHL_A,
        /* 0x78 */ &&z80_LD_A_B,    &&z80_LD_A_C,      &&z80_LD_A_D,    &&z80_LD_A_E,
        /* 0x7C */ &&z80_LD_A_H,    &&z80_LD_A_L,     &&z80_LD_A_xHL,   &&z80_LD_A_A,
        /* 0x80 */ &&z80_ADD_B,     &&z80_ADD_C,      &&z80_ADD_D,      &&z80_ADD_E,
        /* 0x84 */ &&z80_ADD_H,     &&z80_ADD_L,      &&z80_ADD_xHL,    &&z80_ADD_A,
        /* 0x88 */ &&z80_ADC_B,     &&z80_ADC_C,      &&z80_ADC_D,      &&z80_ADC_E,
        /* 0x8C */ &&z80_ADC_H,     &&z80_ADC_L,      &&z80_ADC_xHL,    &&z80_ADC_A,
        /* 0x90 */ &&z80_SUB_B,     &&z80_SUB_C,      &&z80_SUB_D,      &&z80_SUB_E,
        /* 0x94 */ &&z80_SUB_H,     &&z80_SUB_L,      &&z80_SUB_xHL,    &&z80_SUB_A,
        /* 0x98 */ &&z80_SBC_B,     &&z80_SBC_C,      &&z80_SBC_D,      &&z80_SBC_E,
        /* 0x9C */ &&z80_SBC_H,     &&z80_SBC_L,      &&z80_SBC_xHL,    &&z80_SBC_A,
        /* 0xA0 */ &&z80_AND_B,     &&z80_AND_C,      &&z80_AND_D,      &&z80_AND_E,
        /* 0xA4 */ &&z80_AND_H,     &&z80_AND_L,      &&z80_AND_xHL,    &&z80_AND_A,
        /* 0xA8 */ &&z80_XOR_B,     &&z80_XOR_C,      &&z80_XOR_D,      &&z80_XOR_E,
        /* 0xAC */ &&z80_XOR_H,     &&z80_XOR_L,      &&z80_XOR_xHL,    &&z80_XOR_A,
        /* 0xB0 */ &&z80_OR_B,      &&z80_OR_C,       &&z80_OR_D,       &&z80_OR_E,
        /* 0xB4 */ &&z80_OR_H,      &&z80_OR_L,       &&z80_OR_xHL,     &&z80_OR_A,
        /* 0xB8 */ &&z80_CP_B,      &&z80_CP_C,       &&z80_CP_D,       &&z80_CP_E,
        /* 0xBC */ &&z80_CP_H,      &&z80_CP_L,       &&z80_CP_xHL,     &&z80_CP_A,
        /* 0xC0 */ &&z80_RET_NZ,    &&z80_POP_BC,     &&z80_JP_NZ,      &&z80_JP,
        /* 0xC4 */ &&z80_CALL_NZ,   &&z80_PUSH_BC,    &&z80_ADD_BYTE,   &&z80_RST00,
        /* 0xC8 */ &&z80_RET_Z,     &&z80_RET,        &&z80_JP_Z,       &&z80_PFX_CB,
        /* 0xCC */ &&z80_CALL_Z,    &&z80_CALL,       &&z80_ADC_BYTE,   &&z80_RST08,
        /* 0xD0 */ &&z80_RET_NC,    &&z80_POP_DE,     &&z80_JP_NC,      &&z80_OUTA,
        /* 0xD4 */ &&z80_CALL_NC,   &&z80_PUSH_DE,    &&z80_SUB_BYTE,   &&z80_RST10,
        /* 0xD8 */ &&z80_RET_C,     &&z80_EXX,        &&z80_JP_C,       &&z80_INA,
        /* 0xDC */ &&z80_CALL_C,    &&z80_PFX_DD,     &&z80_SBC_BYTE,   &&z80_RST18,
        /* 0xE0 */ &&z80_RET_PO,    &&z80_POP_HL,     &&z80_JP_PO,      &&z80_EX_HL_xSP,
        /* 0xE4 */ &&z80_CALL_PO,   &&z80_PUSH_HL,    &&z80_AND_BYTE,   &&z80_RST20,
        /* 0xE8 */ &&z80_RET_PE,    &&z80_LD_PC_HL,   &&z80_JP_PE,      &&z80_EX_DE_HL,
        /* 0xEC */ &&z80_CALL_PE,   &&z80_PFX_ED,     &&z80_XOR_BYTE,   &&z80_RST28,
        /* 0xF0 */ &&z80_RET_P,     &&z80_POP_AF,     &&z80_JP_P,       &&z80_DI,
        /* 0xF4 */ &&z80_CALL_P,    &&z80_PUSH_AF,    &&z80_OR_BYTE,    &&z80_RST30,
        /* 0xF8 */ &&z80_RET_M,     &&z80_LD_SP_HL,   &&z80_JP_M,       &&z80_EI,
        /* 0xFC */ &&z80_CALL_M,    &&z80_PFX_FD,     &&z80_CP_BYTE,    &&z80_RST38,
    };

    R->ICount += cycles;
    Z80_REBASE_PC();

    /* ---- Threaded fetch/decode/execute ---- */
z80_fetch:
    if (R->ICount <= 0)
        goto z80_exit_check;
    I = FETCH_BYTE();
    R->ICount -= Cycles[I];
    goto *dispatch[I];

    /* ---- Main opcode implementations (labels, not cases) ---- */
#include "z80_ops.h"

    /* ---- Prefix handlers (still use switch internally) ---- */
z80_PFX_CB: CodesCB(R); Z80_REBASE_PC(); goto z80_fetch;
z80_PFX_ED: CodesED(R); Z80_REBASE_PC(); goto z80_fetch;
z80_PFX_DD: CodesDD(R); Z80_REBASE_PC(); goto z80_fetch;
z80_PFX_FD: CodesFD(R); Z80_REBASE_PC(); goto z80_fetch;

    /* ---- Exit check: handle EI delayed interrupt enable ---- */
z80_exit_check:
    if (R->IFF & IFF_EI)
    {
        R->IFF = (R->IFF & ~IFF_EI) | IFF_1;
        R->ICount += R->IBackup - 1;

        /* Deliver pending interrupt now that IFF1 is set */
        if (R->IRequest != Z80_INT_NONE)
        {
            z80_set_irq(R, R->IRequest);
        }
        goto z80_fetch;
    }
}
