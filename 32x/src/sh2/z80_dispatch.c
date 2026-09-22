/*
 * z80_dispatch.c — C prefix handlers and Z80 lookup tables
 *
 * Main opcode dispatch is in SH-2 assembly (z80_asm.S). This file keeps
 * C implementations for prefix decode helpers and shared tables.
 */

#include "gg_emu.h"

#if PERF_DEBUG
/* Per-main-opcode histogram, bumped by z80_asm.S fetch loop.
 * u16 saturation (65535 max/frame) — Sonic title frame ~10k insns, safe.
 * 512 bytes, BSS. Reset + read by main.c each frame. */
volatile uint16_t g_op_hist[256] = {0};
#endif

/* Use inline memory access for performance */
#undef gg_read
#define gg_read(addr)          GG_READ(addr)
#undef gg_write
#define gg_write(addr, val)    gg_write_inline((addr), (val))

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
/* Lookup tables (defined here — included once)                        */
/* ------------------------------------------------------------------ */

#include "z80_tables.h"

/* ------------------------------------------------------------------ */
/* Opcode enums                                                        */
/* ------------------------------------------------------------------ */

#include "z80_opcodes.h"

/* ------------------------------------------------------------------ */
/* Instruction macros (same as z80.c)                                  */
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
/* These live in cart ROM (.text) — they are JIT fallback paths and    */
/* do not need fast SDRAM placement.                                   */
/* ------------------------------------------------------------------ */

void CodesCB(z80_t *R)
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

void CodesDDCB(z80_t *R)
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

void CodesFDCB(z80_t *R)
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

void CodesED(z80_t *R)
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

void CodesDD(z80_t *R)
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

void CodesFD(z80_t *R)
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
/* z80_exec_opcode — Execute a single Z80 opcode (C fallback)          */
/*                                                                     */
/* Called from the SH-2 asm fetch loop for every opcode that hasn't    */
/* been converted to native assembly yet.  The asm loop has already    */
/* fetched the opcode byte and subtracted base cycles from ICount.     */
/*                                                                     */
/* Parameters:                                                         */
/*   R      — pointer to z80_t state (already synced by asm caller)    */
/*   opcode — the fetched opcode byte (0x00–0xFF)                      */
/* ------------------------------------------------------------------ */

void z80_exec_opcode(z80_t *R, uint8_t opcode)
{
    uint8_t I;
    z80_pair_t J;

    switch (opcode)
    {
    /* --- Branches/jumps (conditional extra cycles handled here) --- */
    case JR_NZ:   if(R->AF.B.l&Z_FLAG) R->PC.W++; else { R->ICount-=5;M_JR; } break;
    case JR_NC:   if(R->AF.B.l&C_FLAG) R->PC.W++; else { R->ICount-=5;M_JR; } break;
    case JR_Z:    if(R->AF.B.l&Z_FLAG) { R->ICount-=5;M_JR; } else R->PC.W++; break;
    case JR_C:    if(R->AF.B.l&C_FLAG) { R->ICount-=5;M_JR; } else R->PC.W++; break;

    case JP_NZ:   if(R->AF.B.l&Z_FLAG) R->PC.W+=2; else { M_JP; } break;
    case JP_NC:   if(R->AF.B.l&C_FLAG) R->PC.W+=2; else { M_JP; } break;
    case JP_PO:   if(R->AF.B.l&P_FLAG) R->PC.W+=2; else { M_JP; } break;
    case JP_P:    if(R->AF.B.l&S_FLAG) R->PC.W+=2; else { M_JP; } break;
    case JP_Z:    if(R->AF.B.l&Z_FLAG) { M_JP; } else R->PC.W+=2; break;
    case JP_C:    if(R->AF.B.l&C_FLAG) { M_JP; } else R->PC.W+=2; break;
    case JP_PE:   if(R->AF.B.l&P_FLAG) { M_JP; } else R->PC.W+=2; break;
    case JP_M:    if(R->AF.B.l&S_FLAG) { M_JP; } else R->PC.W+=2; break;

    case RET_NZ:  if(!(R->AF.B.l&Z_FLAG)) { R->ICount-=6;M_RET; } break;
    case RET_NC:  if(!(R->AF.B.l&C_FLAG)) { R->ICount-=6;M_RET; } break;
    case RET_PO:  if(!(R->AF.B.l&P_FLAG)) { R->ICount-=6;M_RET; } break;
    case RET_P:   if(!(R->AF.B.l&S_FLAG)) { R->ICount-=6;M_RET; } break;
    case RET_Z:   if(R->AF.B.l&Z_FLAG)    { R->ICount-=6;M_RET; } break;
    case RET_C:   if(R->AF.B.l&C_FLAG)    { R->ICount-=6;M_RET; } break;
    case RET_PE:  if(R->AF.B.l&P_FLAG)    { R->ICount-=6;M_RET; } break;
    case RET_M:   if(R->AF.B.l&S_FLAG)    { R->ICount-=6;M_RET; } break;

    case CALL_NZ: if(R->AF.B.l&Z_FLAG) R->PC.W+=2; else { R->ICount-=7;M_CALL; } break;
    case CALL_NC: if(R->AF.B.l&C_FLAG) R->PC.W+=2; else { R->ICount-=7;M_CALL; } break;
    case CALL_PO: if(R->AF.B.l&P_FLAG) R->PC.W+=2; else { R->ICount-=7;M_CALL; } break;
    case CALL_P:  if(R->AF.B.l&S_FLAG) R->PC.W+=2; else { R->ICount-=7;M_CALL; } break;
    case CALL_Z:  if(R->AF.B.l&Z_FLAG) { R->ICount-=7;M_CALL; } else R->PC.W+=2; break;
    case CALL_C:  if(R->AF.B.l&C_FLAG) { R->ICount-=7;M_CALL; } else R->PC.W+=2; break;
    case CALL_PE: if(R->AF.B.l&P_FLAG) { R->ICount-=7;M_CALL; } else R->PC.W+=2; break;
    case CALL_M:  if(R->AF.B.l&S_FLAG) { R->ICount-=7;M_CALL; } else R->PC.W+=2; break;

    /* --- ALU: ADD --- */
    case ADD_B:    M_ADD(R->BC.B.h); break;
    case ADD_C:    M_ADD(R->BC.B.l); break;
    case ADD_D:    M_ADD(R->DE.B.h); break;
    case ADD_E:    M_ADD(R->DE.B.l); break;
    case ADD_H:    M_ADD(R->HL.B.h); break;
    case ADD_L:    M_ADD(R->HL.B.l); break;
    case ADD_A:    M_ADD(R->AF.B.h); break;
    case ADD_xHL:  I=gg_read(R->HL.W);M_ADD(I); break;
    case ADD_BYTE: I=gg_read(R->PC.W++);M_ADD(I); break;

    /* --- ALU: SUB --- */
    case SUB_B:    M_SUB(R->BC.B.h); break;
    case SUB_C:    M_SUB(R->BC.B.l); break;
    case SUB_D:    M_SUB(R->DE.B.h); break;
    case SUB_E:    M_SUB(R->DE.B.l); break;
    case SUB_H:    M_SUB(R->HL.B.h); break;
    case SUB_L:    M_SUB(R->HL.B.l); break;
    case SUB_A:    R->AF.B.h=0;R->AF.B.l=N_FLAG|Z_FLAG; break;
    case SUB_xHL:  I=gg_read(R->HL.W);M_SUB(I); break;
    case SUB_BYTE: I=gg_read(R->PC.W++);M_SUB(I); break;

    /* --- ALU: AND --- */
    case AND_B:    M_AND(R->BC.B.h); break;
    case AND_C:    M_AND(R->BC.B.l); break;
    case AND_D:    M_AND(R->DE.B.h); break;
    case AND_E:    M_AND(R->DE.B.l); break;
    case AND_H:    M_AND(R->HL.B.h); break;
    case AND_L:    M_AND(R->HL.B.l); break;
    case AND_A:    M_AND(R->AF.B.h); break;
    case AND_xHL:  I=gg_read(R->HL.W);M_AND(I); break;
    case AND_BYTE: I=gg_read(R->PC.W++);M_AND(I); break;

    /* --- ALU: OR --- */
    case OR_B:     M_OR(R->BC.B.h); break;
    case OR_C:     M_OR(R->BC.B.l); break;
    case OR_D:     M_OR(R->DE.B.h); break;
    case OR_E:     M_OR(R->DE.B.l); break;
    case OR_H:     M_OR(R->HL.B.h); break;
    case OR_L:     M_OR(R->HL.B.l); break;
    case OR_A:     M_OR(R->AF.B.h); break;
    case OR_xHL:   I=gg_read(R->HL.W);M_OR(I); break;
    case OR_BYTE:  I=gg_read(R->PC.W++);M_OR(I); break;

    /* --- ALU: ADC --- */
    case ADC_B:    M_ADC(R->BC.B.h); break;
    case ADC_C:    M_ADC(R->BC.B.l); break;
    case ADC_D:    M_ADC(R->DE.B.h); break;
    case ADC_E:    M_ADC(R->DE.B.l); break;
    case ADC_H:    M_ADC(R->HL.B.h); break;
    case ADC_L:    M_ADC(R->HL.B.l); break;
    case ADC_A:    M_ADC(R->AF.B.h); break;
    case ADC_xHL:  I=gg_read(R->HL.W);M_ADC(I); break;
    case ADC_BYTE: I=gg_read(R->PC.W++);M_ADC(I); break;

    /* --- ALU: SBC --- */
    case SBC_B:    M_SBC(R->BC.B.h); break;
    case SBC_C:    M_SBC(R->BC.B.l); break;
    case SBC_D:    M_SBC(R->DE.B.h); break;
    case SBC_E:    M_SBC(R->DE.B.l); break;
    case SBC_H:    M_SBC(R->HL.B.h); break;
    case SBC_L:    M_SBC(R->HL.B.l); break;
    case SBC_A:    M_SBC(R->AF.B.h); break;
    case SBC_xHL:  I=gg_read(R->HL.W);M_SBC(I); break;
    case SBC_BYTE: I=gg_read(R->PC.W++);M_SBC(I); break;

    /* --- ALU: XOR --- */
    case XOR_B:    M_XOR(R->BC.B.h); break;
    case XOR_C:    M_XOR(R->BC.B.l); break;
    case XOR_D:    M_XOR(R->DE.B.h); break;
    case XOR_E:    M_XOR(R->DE.B.l); break;
    case XOR_H:    M_XOR(R->HL.B.h); break;
    case XOR_L:    M_XOR(R->HL.B.l); break;
    case XOR_A:    R->AF.B.h=0;R->AF.B.l=P_FLAG|Z_FLAG; break;
    case XOR_xHL:  I=gg_read(R->HL.W);M_XOR(I); break;
    case XOR_BYTE: I=gg_read(R->PC.W++);M_XOR(I); break;

    /* --- ALU: CP --- */
    case CP_B:     M_CP(R->BC.B.h); break;
    case CP_C:     M_CP(R->BC.B.l); break;
    case CP_D:     M_CP(R->DE.B.h); break;
    case CP_E:     M_CP(R->DE.B.l); break;
    case CP_H:     M_CP(R->HL.B.h); break;
    case CP_L:     M_CP(R->HL.B.l); break;
    case CP_A:     R->AF.B.l=N_FLAG|Z_FLAG; break;
    case CP_xHL:   I=gg_read(R->HL.W);M_CP(I); break;
    case CP_BYTE:  I=gg_read(R->PC.W++);M_CP(I); break;

    /* --- 16-bit loads --- */
    case LD_BC_WORD: M_LDWORD(BC); break;
    case LD_DE_WORD: M_LDWORD(DE); break;
    case LD_HL_WORD: M_LDWORD(HL); break;
    case LD_SP_WORD: M_LDWORD(SP); break;

    case LD_PC_HL: R->PC.W=R->HL.W; break;
    case LD_SP_HL: R->SP.W=R->HL.W; break;
    case LD_A_xBC: R->AF.B.h=gg_read(R->BC.W); break;
    case LD_A_xDE: R->AF.B.h=gg_read(R->DE.W); break;

    /* --- 16-bit arithmetic --- */
    case ADD_HL_BC:  M_ADDW(HL,BC); break;
    case ADD_HL_DE:  M_ADDW(HL,DE); break;
    case ADD_HL_HL:  M_ADDW(HL,HL); break;
    case ADD_HL_SP:  M_ADDW(HL,SP); break;

    case DEC_BC:   R->BC.W--; break;
    case DEC_DE:   R->DE.W--; break;
    case DEC_HL:   R->HL.W--; break;
    case DEC_SP:   R->SP.W--; break;

    case INC_BC:   R->BC.W++; break;
    case INC_DE:   R->DE.W++; break;
    case INC_HL:   R->HL.W++; break;
    case INC_SP:   R->SP.W++; break;

    /* --- 8-bit INC/DEC --- */
    case DEC_B:    M_DEC(R->BC.B.h); break;
    case DEC_C:    M_DEC(R->BC.B.l); break;
    case DEC_D:    M_DEC(R->DE.B.h); break;
    case DEC_E:    M_DEC(R->DE.B.l); break;
    case DEC_H:    M_DEC(R->HL.B.h); break;
    case DEC_L:    M_DEC(R->HL.B.l); break;
    case DEC_A:    M_DEC(R->AF.B.h); break;
    case DEC_xHL:  I=gg_read(R->HL.W);M_DEC(I);gg_write(R->HL.W,I); break;

    case INC_B:    M_INC(R->BC.B.h); break;
    case INC_C:    M_INC(R->BC.B.l); break;
    case INC_D:    M_INC(R->DE.B.h); break;
    case INC_E:    M_INC(R->DE.B.l); break;
    case INC_H:    M_INC(R->HL.B.h); break;
    case INC_L:    M_INC(R->HL.B.l); break;
    case INC_A:    M_INC(R->AF.B.h); break;
    case INC_xHL:  I=gg_read(R->HL.W);M_INC(I);gg_write(R->HL.W,I); break;

    /* --- Rotate A --- */
    case RLCA:
      I=R->AF.B.h&0x80? C_FLAG:0;
      R->AF.B.h=(R->AF.B.h<<1)|I;
      R->AF.B.l=(R->AF.B.l&~(C_FLAG|N_FLAG|H_FLAG))|I;
      break;
    case RLA:
      I=R->AF.B.h&0x80? C_FLAG:0;
      R->AF.B.h=(R->AF.B.h<<1)|(R->AF.B.l&C_FLAG);
      R->AF.B.l=(R->AF.B.l&~(C_FLAG|N_FLAG|H_FLAG))|I;
      break;
    case RRCA:
      I=R->AF.B.h&0x01;
      R->AF.B.h=(R->AF.B.h>>1)|(I? 0x80:0);
      R->AF.B.l=(R->AF.B.l&~(C_FLAG|N_FLAG|H_FLAG))|I;
      break;
    case RRA:
      I=R->AF.B.h&0x01;
      R->AF.B.h=(R->AF.B.h>>1)|(R->AF.B.l&C_FLAG? 0x80:0);
      R->AF.B.l=(R->AF.B.l&~(C_FLAG|N_FLAG|H_FLAG))|I;
      break;

    /* --- RST --- */
    case RST00:    M_RST(0x0000); break;
    case RST08:    M_RST(0x0008); break;
    case RST10:    M_RST(0x0010); break;
    case RST18:    M_RST(0x0018); break;
    case RST20:    M_RST(0x0020); break;
    case RST28:    M_RST(0x0028); break;
    case RST30:    M_RST(0x0030); break;
    case RST38:    M_RST(0x0038); break;

    /* --- PUSH/POP --- */
    case PUSH_BC:  M_PUSH(BC); break;
    case PUSH_DE:  M_PUSH(DE); break;
    case PUSH_HL:  M_PUSH(HL); break;
    case PUSH_AF:  M_PUSH(AF); break;

    case POP_BC:   M_POP(BC); break;
    case POP_DE:   M_POP(DE); break;
    case POP_HL:   M_POP(HL); break;
    case POP_AF:   M_POP(AF); break;

    /* --- Misc flow --- */
    case DJNZ: if(--R->BC.B.h) {R->ICount-=5;M_JR; } else R->PC.W++; break;
    case JP:   M_JP; break;
    case JR:   M_JR; break;
    case CALL: M_CALL; break;
    case RET:  M_RET; break;
    case SCF:  S(C_FLAG);R(N_FLAG|H_FLAG); break;
    case CPL:  R->AF.B.h=~R->AF.B.h;S(N_FLAG|H_FLAG); break;
    case NOP:  break;
    case OUTA: I=gg_read(R->PC.W++);gg_out(I,R->AF.B.h); break;
    case INA:  I=gg_read(R->PC.W++);R->AF.B.h=gg_in(I); break;

    case HALT:
      R->PC.W--;
      R->IFF|=IFF_HALT;
      if (R->ICount > 0)
      {
        const int cycles = Cycles[opcode];
        R->R += R->ICount / cycles;
        R->ICount %= cycles;
        R->IBackup = R->ICount;
      }
      break;

    case DI:
      if (R->IFF & IFF_EI)
         R->ICount += R->IBackup - 1;
      R->IFF &= ~(IFF_1|IFF_2|IFF_EI);
      break;

    case EI:
      if(!(R->IFF & (IFF_1|IFF_EI)))
      {
        R->IFF |= IFF_2|IFF_EI;
        R->IBackup = R->ICount;
        R->ICount = 1;
      }
      break;

    case CCF:
      R->AF.B.l^=C_FLAG;R(N_FLAG|H_FLAG);
      R->AF.B.l|=R->AF.B.l&C_FLAG? 0:H_FLAG;
      break;

    case EXX:
      J.W=R->BC.W;R->BC.W=R->BC1.W;R->BC1.W=J.W;
      J.W=R->DE.W;R->DE.W=R->DE1.W;R->DE1.W=J.W;
      J.W=R->HL.W;R->HL.W=R->HL1.W;R->HL1.W=J.W;
      break;

    case EX_DE_HL: J.W=R->DE.W;R->DE.W=R->HL.W;R->HL.W=J.W; break;
    case EX_AF_AF: J.W=R->AF.W;R->AF.W=R->AF1.W;R->AF1.W=J.W; break;

    /* --- LD r,r (register to register) --- */
    case LD_B_B:   break; /* R->BC.B.h=R->BC.B.h; */
    case LD_C_B:   R->BC.B.l=R->BC.B.h; break;
    case LD_D_B:   R->DE.B.h=R->BC.B.h; break;
    case LD_E_B:   R->DE.B.l=R->BC.B.h; break;
    case LD_H_B:   R->HL.B.h=R->BC.B.h; break;
    case LD_L_B:   R->HL.B.l=R->BC.B.h; break;
    case LD_A_B:   R->AF.B.h=R->BC.B.h; break;
    case LD_xHL_B: gg_write(R->HL.W,R->BC.B.h); break;

    case LD_B_C:   R->BC.B.h=R->BC.B.l; break;
    case LD_C_C:   break; /* R->BC.B.l=R->BC.B.l; */
    case LD_D_C:   R->DE.B.h=R->BC.B.l; break;
    case LD_E_C:   R->DE.B.l=R->BC.B.l; break;
    case LD_H_C:   R->HL.B.h=R->BC.B.l; break;
    case LD_L_C:   R->HL.B.l=R->BC.B.l; break;
    case LD_A_C:   R->AF.B.h=R->BC.B.l; break;
    case LD_xHL_C: gg_write(R->HL.W,R->BC.B.l); break;

    case LD_B_D:   R->BC.B.h=R->DE.B.h; break;
    case LD_C_D:   R->BC.B.l=R->DE.B.h; break;
    case LD_D_D:   break; /* R->DE.B.h=R->DE.B.h; */
    case LD_E_D:   R->DE.B.l=R->DE.B.h; break;
    case LD_H_D:   R->HL.B.h=R->DE.B.h; break;
    case LD_L_D:   R->HL.B.l=R->DE.B.h; break;
    case LD_A_D:   R->AF.B.h=R->DE.B.h; break;
    case LD_xHL_D: gg_write(R->HL.W,R->DE.B.h); break;

    case LD_B_E:   R->BC.B.h=R->DE.B.l; break;
    case LD_C_E:   R->BC.B.l=R->DE.B.l; break;
    case LD_D_E:   R->DE.B.h=R->DE.B.l; break;
    case LD_E_E:   break; /* R->DE.B.l=R->DE.B.l; */
    case LD_H_E:   R->HL.B.h=R->DE.B.l; break;
    case LD_L_E:   R->HL.B.l=R->DE.B.l; break;
    case LD_A_E:   R->AF.B.h=R->DE.B.l; break;
    case LD_xHL_E: gg_write(R->HL.W,R->DE.B.l); break;

    case LD_B_H:   R->BC.B.h=R->HL.B.h; break;
    case LD_C_H:   R->BC.B.l=R->HL.B.h; break;
    case LD_D_H:   R->DE.B.h=R->HL.B.h; break;
    case LD_E_H:   R->DE.B.l=R->HL.B.h; break;
    case LD_H_H:   break; /* R->HL.B.h=R->HL.B.h; */
    case LD_L_H:   R->HL.B.l=R->HL.B.h; break;
    case LD_A_H:   R->AF.B.h=R->HL.B.h; break;
    case LD_xHL_H: gg_write(R->HL.W,R->HL.B.h); break;

    case LD_B_L:   R->BC.B.h=R->HL.B.l; break;
    case LD_C_L:   R->BC.B.l=R->HL.B.l; break;
    case LD_D_L:   R->DE.B.h=R->HL.B.l; break;
    case LD_E_L:   R->DE.B.l=R->HL.B.l; break;
    case LD_H_L:   R->HL.B.h=R->HL.B.l; break;
    case LD_L_L:   break; /* R->HL.B.l=R->HL.B.l; */
    case LD_A_L:   R->AF.B.h=R->HL.B.l; break;
    case LD_xHL_L: gg_write(R->HL.W,R->HL.B.l); break;

    case LD_B_A:   R->BC.B.h=R->AF.B.h; break;
    case LD_C_A:   R->BC.B.l=R->AF.B.h; break;
    case LD_D_A:   R->DE.B.h=R->AF.B.h; break;
    case LD_E_A:   R->DE.B.l=R->AF.B.h; break;
    case LD_H_A:   R->HL.B.h=R->AF.B.h; break;
    case LD_L_A:   R->HL.B.l=R->AF.B.h; break;
    case LD_A_A:   break; /* R->AF.B.h=R->AF.B.h; */
    case LD_xHL_A: gg_write(R->HL.W,R->AF.B.h); break;

    case LD_xBC_A: gg_write(R->BC.W,R->AF.B.h); break;
    case LD_xDE_A: gg_write(R->DE.W,R->AF.B.h); break;

    /* --- LD r,(HL) --- */
    case LD_B_xHL:    R->BC.B.h=gg_read(R->HL.W); break;
    case LD_C_xHL:    R->BC.B.l=gg_read(R->HL.W); break;
    case LD_D_xHL:    R->DE.B.h=gg_read(R->HL.W); break;
    case LD_E_xHL:    R->DE.B.l=gg_read(R->HL.W); break;
    case LD_H_xHL:    R->HL.B.h=gg_read(R->HL.W); break;
    case LD_L_xHL:    R->HL.B.l=gg_read(R->HL.W); break;
    case LD_A_xHL:    R->AF.B.h=gg_read(R->HL.W); break;

    /* --- LD r,n --- */
    case LD_B_BYTE:   R->BC.B.h=gg_read(R->PC.W++); break;
    case LD_C_BYTE:   R->BC.B.l=gg_read(R->PC.W++); break;
    case LD_D_BYTE:   R->DE.B.h=gg_read(R->PC.W++); break;
    case LD_E_BYTE:   R->DE.B.l=gg_read(R->PC.W++); break;
    case LD_H_BYTE:   R->HL.B.h=gg_read(R->PC.W++); break;
    case LD_L_BYTE:   R->HL.B.l=gg_read(R->PC.W++); break;
    case LD_A_BYTE:   R->AF.B.h=gg_read(R->PC.W++); break;
    case LD_xHL_BYTE: gg_write(R->HL.W,gg_read(R->PC.W++)); break;

    /* --- LD (nn),HL / LD HL,(nn) / LD A,(nn) / LD (nn),A --- */
    case LD_xWORD_HL:
      J.B.l=gg_read(R->PC.W++);
      J.B.h=gg_read(R->PC.W++);
      gg_write(J.W++,R->HL.B.l);
      gg_write(J.W,R->HL.B.h);
      break;

    case LD_HL_xWORD:
      J.B.l=gg_read(R->PC.W++);
      J.B.h=gg_read(R->PC.W++);
      R->HL.B.l=gg_read(J.W++);
      R->HL.B.h=gg_read(J.W);
      break;

    case LD_A_xWORD:
      J.B.l=gg_read(R->PC.W++);
      J.B.h=gg_read(R->PC.W++);
      R->AF.B.h=gg_read(J.W);
      break;

    case LD_xWORD_A:
      J.B.l=gg_read(R->PC.W++);
      J.B.h=gg_read(R->PC.W++);
      gg_write(J.W,R->AF.B.h);
      break;

    case EX_HL_xSP:
      J.B.l=gg_read(R->SP.W);gg_write(R->SP.W++,R->HL.B.l);
      J.B.h=gg_read(R->SP.W);gg_write(R->SP.W--,R->HL.B.h);
      R->HL.W=J.W;
      break;

    case DAA:
      R->AF.W=z80_compute_daa(R->AF.B.h, R->AF.B.l);
      break;

    /* --- Prefix opcodes: delegate to prefix handlers --- */
    case PFX_CB: CodesCB(R); break;
    case PFX_ED: CodesED(R); break;
    case PFX_DD: CodesDD(R); break;
    case PFX_FD: CodesFD(R); break;

    default: break;
    }
}
