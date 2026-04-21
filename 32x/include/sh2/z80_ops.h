/*
 * z80_ops.h — Main opcode table (computed goto labels)
 * Ported from Marat Fayzullin's Z80 core (Codes.h)
 * Included from z80.c z80_run() — each label falls through to z80_fetch.
 */

z80_JR_NZ:   if(R->AF.B.l&Z_FLAG) R->PC.W++; else { R->ICount-=5;M_JR; } goto z80_fetch;
z80_JR_NC:   if(R->AF.B.l&C_FLAG) R->PC.W++; else { R->ICount-=5;M_JR; } goto z80_fetch;
z80_JR_Z:    if(R->AF.B.l&Z_FLAG) { R->ICount-=5;M_JR; } else R->PC.W++; goto z80_fetch;
z80_JR_C:    if(R->AF.B.l&C_FLAG) { R->ICount-=5;M_JR; } else R->PC.W++; goto z80_fetch;

z80_JP_NZ:   if(R->AF.B.l&Z_FLAG) R->PC.W+=2; else { M_JP; } goto z80_fetch;
z80_JP_NC:   if(R->AF.B.l&C_FLAG) R->PC.W+=2; else { M_JP; } goto z80_fetch;
z80_JP_PO:   if(R->AF.B.l&P_FLAG) R->PC.W+=2; else { M_JP; } goto z80_fetch;
z80_JP_P:    if(R->AF.B.l&S_FLAG) R->PC.W+=2; else { M_JP; } goto z80_fetch;
z80_JP_Z:    if(R->AF.B.l&Z_FLAG) { M_JP; } else R->PC.W+=2; goto z80_fetch;
z80_JP_C:    if(R->AF.B.l&C_FLAG) { M_JP; } else R->PC.W+=2; goto z80_fetch;
z80_JP_PE:   if(R->AF.B.l&P_FLAG) { M_JP; } else R->PC.W+=2; goto z80_fetch;
z80_JP_M:    if(R->AF.B.l&S_FLAG) { M_JP; } else R->PC.W+=2; goto z80_fetch;

z80_RET_NZ:  if(!(R->AF.B.l&Z_FLAG)) { R->ICount-=6;M_RET; } goto z80_fetch;
z80_RET_NC:  if(!(R->AF.B.l&C_FLAG)) { R->ICount-=6;M_RET; } goto z80_fetch;
z80_RET_PO:  if(!(R->AF.B.l&P_FLAG)) { R->ICount-=6;M_RET; } goto z80_fetch;
z80_RET_P:   if(!(R->AF.B.l&S_FLAG)) { R->ICount-=6;M_RET; } goto z80_fetch;
z80_RET_Z:   if(R->AF.B.l&Z_FLAG)    { R->ICount-=6;M_RET; } goto z80_fetch;
z80_RET_C:   if(R->AF.B.l&C_FLAG)    { R->ICount-=6;M_RET; } goto z80_fetch;
z80_RET_PE:  if(R->AF.B.l&P_FLAG)    { R->ICount-=6;M_RET; } goto z80_fetch;
z80_RET_M:   if(R->AF.B.l&S_FLAG)    { R->ICount-=6;M_RET; } goto z80_fetch;

z80_CALL_NZ: if(R->AF.B.l&Z_FLAG) R->PC.W+=2; else { R->ICount-=7;M_CALL; } goto z80_fetch;
z80_CALL_NC: if(R->AF.B.l&C_FLAG) R->PC.W+=2; else { R->ICount-=7;M_CALL; } goto z80_fetch;
z80_CALL_PO: if(R->AF.B.l&P_FLAG) R->PC.W+=2; else { R->ICount-=7;M_CALL; } goto z80_fetch;
z80_CALL_P:  if(R->AF.B.l&S_FLAG) R->PC.W+=2; else { R->ICount-=7;M_CALL; } goto z80_fetch;
z80_CALL_Z:  if(R->AF.B.l&Z_FLAG) { R->ICount-=7;M_CALL; } else R->PC.W+=2; goto z80_fetch;
z80_CALL_C:  if(R->AF.B.l&C_FLAG) { R->ICount-=7;M_CALL; } else R->PC.W+=2; goto z80_fetch;
z80_CALL_PE: if(R->AF.B.l&P_FLAG) { R->ICount-=7;M_CALL; } else R->PC.W+=2; goto z80_fetch;
z80_CALL_M:  if(R->AF.B.l&S_FLAG) { R->ICount-=7;M_CALL; } else R->PC.W+=2; goto z80_fetch;

z80_ADD_B:    M_ADD(R->BC.B.h);goto z80_fetch;
z80_ADD_C:    M_ADD(R->BC.B.l);goto z80_fetch;
z80_ADD_D:    M_ADD(R->DE.B.h);goto z80_fetch;
z80_ADD_E:    M_ADD(R->DE.B.l);goto z80_fetch;
z80_ADD_H:    M_ADD(R->HL.B.h);goto z80_fetch;
z80_ADD_L:    M_ADD(R->HL.B.l);goto z80_fetch;
z80_ADD_A:    M_ADD(R->AF.B.h);goto z80_fetch;
z80_ADD_xHL:  I=gg_read(R->HL.W);M_ADD(I);goto z80_fetch;
z80_ADD_BYTE: I=FETCH_BYTE();M_ADD(I);goto z80_fetch;

z80_SUB_B:    M_SUB(R->BC.B.h);goto z80_fetch;
z80_SUB_C:    M_SUB(R->BC.B.l);goto z80_fetch;
z80_SUB_D:    M_SUB(R->DE.B.h);goto z80_fetch;
z80_SUB_E:    M_SUB(R->DE.B.l);goto z80_fetch;
z80_SUB_H:    M_SUB(R->HL.B.h);goto z80_fetch;
z80_SUB_L:    M_SUB(R->HL.B.l);goto z80_fetch;
z80_SUB_A:    R->AF.B.h=0;R->AF.B.l=N_FLAG|Z_FLAG;goto z80_fetch;
z80_SUB_xHL:  I=gg_read(R->HL.W);M_SUB(I);goto z80_fetch;
z80_SUB_BYTE: I=FETCH_BYTE();M_SUB(I);goto z80_fetch;

z80_AND_B:    M_AND(R->BC.B.h);goto z80_fetch;
z80_AND_C:    M_AND(R->BC.B.l);goto z80_fetch;
z80_AND_D:    M_AND(R->DE.B.h);goto z80_fetch;
z80_AND_E:    M_AND(R->DE.B.l);goto z80_fetch;
z80_AND_H:    M_AND(R->HL.B.h);goto z80_fetch;
z80_AND_L:    M_AND(R->HL.B.l);goto z80_fetch;
z80_AND_A:    M_AND(R->AF.B.h);goto z80_fetch;
z80_AND_xHL:  I=gg_read(R->HL.W);M_AND(I);goto z80_fetch;
z80_AND_BYTE: I=FETCH_BYTE();M_AND(I);goto z80_fetch;

z80_OR_B:     M_OR(R->BC.B.h);goto z80_fetch;
z80_OR_C:     M_OR(R->BC.B.l);goto z80_fetch;
z80_OR_D:     M_OR(R->DE.B.h);goto z80_fetch;
z80_OR_E:     M_OR(R->DE.B.l);goto z80_fetch;
z80_OR_H:     M_OR(R->HL.B.h);goto z80_fetch;
z80_OR_L:     M_OR(R->HL.B.l);goto z80_fetch;
z80_OR_A:     M_OR(R->AF.B.h);goto z80_fetch;
z80_OR_xHL:   I=gg_read(R->HL.W);M_OR(I);goto z80_fetch;
z80_OR_BYTE:  I=FETCH_BYTE();M_OR(I);goto z80_fetch;

z80_ADC_B:    M_ADC(R->BC.B.h);goto z80_fetch;
z80_ADC_C:    M_ADC(R->BC.B.l);goto z80_fetch;
z80_ADC_D:    M_ADC(R->DE.B.h);goto z80_fetch;
z80_ADC_E:    M_ADC(R->DE.B.l);goto z80_fetch;
z80_ADC_H:    M_ADC(R->HL.B.h);goto z80_fetch;
z80_ADC_L:    M_ADC(R->HL.B.l);goto z80_fetch;
z80_ADC_A:    M_ADC(R->AF.B.h);goto z80_fetch;
z80_ADC_xHL:  I=gg_read(R->HL.W);M_ADC(I);goto z80_fetch;
z80_ADC_BYTE: I=FETCH_BYTE();M_ADC(I);goto z80_fetch;

z80_SBC_B:    M_SBC(R->BC.B.h);goto z80_fetch;
z80_SBC_C:    M_SBC(R->BC.B.l);goto z80_fetch;
z80_SBC_D:    M_SBC(R->DE.B.h);goto z80_fetch;
z80_SBC_E:    M_SBC(R->DE.B.l);goto z80_fetch;
z80_SBC_H:    M_SBC(R->HL.B.h);goto z80_fetch;
z80_SBC_L:    M_SBC(R->HL.B.l);goto z80_fetch;
z80_SBC_A:    M_SBC(R->AF.B.h);goto z80_fetch;
z80_SBC_xHL:  I=gg_read(R->HL.W);M_SBC(I);goto z80_fetch;
z80_SBC_BYTE: I=FETCH_BYTE();M_SBC(I);goto z80_fetch;

z80_XOR_B:    M_XOR(R->BC.B.h);goto z80_fetch;
z80_XOR_C:    M_XOR(R->BC.B.l);goto z80_fetch;
z80_XOR_D:    M_XOR(R->DE.B.h);goto z80_fetch;
z80_XOR_E:    M_XOR(R->DE.B.l);goto z80_fetch;
z80_XOR_H:    M_XOR(R->HL.B.h);goto z80_fetch;
z80_XOR_L:    M_XOR(R->HL.B.l);goto z80_fetch;
z80_XOR_A:    R->AF.B.h=0;R->AF.B.l=P_FLAG|Z_FLAG;goto z80_fetch;
z80_XOR_xHL:  I=gg_read(R->HL.W);M_XOR(I);goto z80_fetch;
z80_XOR_BYTE: I=FETCH_BYTE();M_XOR(I);goto z80_fetch;

z80_CP_B:     M_CP(R->BC.B.h);goto z80_fetch;
z80_CP_C:     M_CP(R->BC.B.l);goto z80_fetch;
z80_CP_D:     M_CP(R->DE.B.h);goto z80_fetch;
z80_CP_E:     M_CP(R->DE.B.l);goto z80_fetch;
z80_CP_H:     M_CP(R->HL.B.h);goto z80_fetch;
z80_CP_L:     M_CP(R->HL.B.l);goto z80_fetch;
z80_CP_A:     R->AF.B.l=N_FLAG|Z_FLAG;goto z80_fetch;
z80_CP_xHL:   I=gg_read(R->HL.W);M_CP(I);goto z80_fetch;
z80_CP_BYTE:  I=FETCH_BYTE();M_CP(I);goto z80_fetch;

z80_LD_BC_WORD: M_LDWORD(BC);goto z80_fetch;
z80_LD_DE_WORD: M_LDWORD(DE);goto z80_fetch;
z80_LD_HL_WORD: M_LDWORD(HL);goto z80_fetch;
z80_LD_SP_WORD: M_LDWORD(SP);goto z80_fetch;

z80_LD_PC_HL: R->PC.W=R->HL.W;goto z80_fetch;
z80_LD_SP_HL: R->SP.W=R->HL.W;goto z80_fetch;
z80_LD_A_xBC: R->AF.B.h=gg_read(R->BC.W);goto z80_fetch;
z80_LD_A_xDE: R->AF.B.h=gg_read(R->DE.W);goto z80_fetch;

z80_ADD_HL_BC:  M_ADDW(HL,BC);goto z80_fetch;
z80_ADD_HL_DE:  M_ADDW(HL,DE);goto z80_fetch;
z80_ADD_HL_HL:  M_ADDW(HL,HL);goto z80_fetch;
z80_ADD_HL_SP:  M_ADDW(HL,SP);goto z80_fetch;

z80_DEC_BC:   R->BC.W--;goto z80_fetch;
z80_DEC_DE:   R->DE.W--;goto z80_fetch;
z80_DEC_HL:   R->HL.W--;goto z80_fetch;
z80_DEC_SP:   R->SP.W--;goto z80_fetch;

z80_INC_BC:   R->BC.W++;goto z80_fetch;
z80_INC_DE:   R->DE.W++;goto z80_fetch;
z80_INC_HL:   R->HL.W++;goto z80_fetch;
z80_INC_SP:   R->SP.W++;goto z80_fetch;

z80_DEC_B:    M_DEC(R->BC.B.h);goto z80_fetch;
z80_DEC_C:    M_DEC(R->BC.B.l);goto z80_fetch;
z80_DEC_D:    M_DEC(R->DE.B.h);goto z80_fetch;
z80_DEC_E:    M_DEC(R->DE.B.l);goto z80_fetch;
z80_DEC_H:    M_DEC(R->HL.B.h);goto z80_fetch;
z80_DEC_L:    M_DEC(R->HL.B.l);goto z80_fetch;
z80_DEC_A:    M_DEC(R->AF.B.h);goto z80_fetch;
z80_DEC_xHL:  I=gg_read(R->HL.W);M_DEC(I);gg_write(R->HL.W,I);goto z80_fetch;

z80_INC_B:    M_INC(R->BC.B.h);goto z80_fetch;
z80_INC_C:    M_INC(R->BC.B.l);goto z80_fetch;
z80_INC_D:    M_INC(R->DE.B.h);goto z80_fetch;
z80_INC_E:    M_INC(R->DE.B.l);goto z80_fetch;
z80_INC_H:    M_INC(R->HL.B.h);goto z80_fetch;
z80_INC_L:    M_INC(R->HL.B.l);goto z80_fetch;
z80_INC_A:    M_INC(R->AF.B.h);goto z80_fetch;
z80_INC_xHL:  I=gg_read(R->HL.W);M_INC(I);gg_write(R->HL.W,I);goto z80_fetch;

z80_RLCA:
  I=R->AF.B.h&0x80? C_FLAG:0;
  R->AF.B.h=(R->AF.B.h<<1)|I;
  R->AF.B.l=(R->AF.B.l&~(C_FLAG|N_FLAG|H_FLAG))|I;
  goto z80_fetch;
z80_RLA:
  I=R->AF.B.h&0x80? C_FLAG:0;
  R->AF.B.h=(R->AF.B.h<<1)|(R->AF.B.l&C_FLAG);
  R->AF.B.l=(R->AF.B.l&~(C_FLAG|N_FLAG|H_FLAG))|I;
  goto z80_fetch;
z80_RRCA:
  I=R->AF.B.h&0x01;
  R->AF.B.h=(R->AF.B.h>>1)|(I? 0x80:0);
  R->AF.B.l=(R->AF.B.l&~(C_FLAG|N_FLAG|H_FLAG))|I;
  goto z80_fetch;
z80_RRA:
  I=R->AF.B.h&0x01;
  R->AF.B.h=(R->AF.B.h>>1)|(R->AF.B.l&C_FLAG? 0x80:0);
  R->AF.B.l=(R->AF.B.l&~(C_FLAG|N_FLAG|H_FLAG))|I;
  goto z80_fetch;

z80_RST00:    M_RST(0x0000);goto z80_fetch;
z80_RST08:    M_RST(0x0008);goto z80_fetch;
z80_RST10:    M_RST(0x0010);goto z80_fetch;
z80_RST18:    M_RST(0x0018);goto z80_fetch;
z80_RST20:    M_RST(0x0020);goto z80_fetch;
z80_RST28:    M_RST(0x0028);goto z80_fetch;
z80_RST30:    M_RST(0x0030);goto z80_fetch;
z80_RST38:    M_RST(0x0038);goto z80_fetch;

z80_PUSH_BC:  M_PUSH(BC);goto z80_fetch;
z80_PUSH_DE:  M_PUSH(DE);goto z80_fetch;
z80_PUSH_HL:  M_PUSH(HL);goto z80_fetch;
z80_PUSH_AF:  M_PUSH(AF);goto z80_fetch;

z80_POP_BC:   M_POP(BC);goto z80_fetch;
z80_POP_DE:   M_POP(DE);goto z80_fetch;
z80_POP_HL:   M_POP(HL);goto z80_fetch;
z80_POP_AF:   M_POP(AF);goto z80_fetch;

z80_DJNZ: if(--R->BC.B.h) {R->ICount-=5;M_JR; } else R->PC.W++;goto z80_fetch;
z80_JP:   M_JP;goto z80_fetch;
z80_JR:   M_JR;goto z80_fetch;
z80_CALL: M_CALL;goto z80_fetch;
z80_RET:  M_RET;goto z80_fetch;
z80_SCF:  S(C_FLAG);R(N_FLAG|H_FLAG);goto z80_fetch;
z80_CPL:  R->AF.B.h=~R->AF.B.h;S(N_FLAG|H_FLAG);goto z80_fetch;
z80_NOP:  goto z80_fetch;
z80_OUTA: I=FETCH_BYTE();gg_out(I,R->AF.B.h);goto z80_fetch;
z80_INA:  I=FETCH_BYTE();R->AF.B.h=gg_in(I);goto z80_fetch;

z80_HALT:
  R->PC.W--;
  R->IFF|=IFF_HALT;
  if (R->ICount > 0)
  {
    const int cycles = Cycles[I];
    R->R += R->ICount / cycles;
    R->ICount %= cycles;
    R->IBackup = R->ICount;
  }
  goto z80_fetch;

z80_DI:
  if (R->IFF & IFF_EI)
     R->ICount += R->IBackup - 1;
  R->IFF &= ~(IFF_1|IFF_2|IFF_EI);
  goto z80_fetch;

z80_EI:
  if(!(R->IFF & (IFF_1|IFF_EI)))
  {
    R->IFF |= IFF_2|IFF_EI;
    R->IBackup = R->ICount;
    R->ICount = 1;
  }
  goto z80_fetch;

z80_CCF:
  R->AF.B.l^=C_FLAG;R(N_FLAG|H_FLAG);
  R->AF.B.l|=R->AF.B.l&C_FLAG? 0:H_FLAG;
  goto z80_fetch;

z80_EXX:
  J.W=R->BC.W;R->BC.W=R->BC1.W;R->BC1.W=J.W;
  J.W=R->DE.W;R->DE.W=R->DE1.W;R->DE1.W=J.W;
  J.W=R->HL.W;R->HL.W=R->HL1.W;R->HL1.W=J.W;
  goto z80_fetch;

z80_EX_DE_HL: J.W=R->DE.W;R->DE.W=R->HL.W;R->HL.W=J.W;goto z80_fetch;
z80_EX_AF_AF: J.W=R->AF.W;R->AF.W=R->AF1.W;R->AF1.W=J.W;goto z80_fetch;

z80_LD_B_B:   R->BC.B.h=R->BC.B.h;goto z80_fetch;
z80_LD_C_B:   R->BC.B.l=R->BC.B.h;goto z80_fetch;
z80_LD_D_B:   R->DE.B.h=R->BC.B.h;goto z80_fetch;
z80_LD_E_B:   R->DE.B.l=R->BC.B.h;goto z80_fetch;
z80_LD_H_B:   R->HL.B.h=R->BC.B.h;goto z80_fetch;
z80_LD_L_B:   R->HL.B.l=R->BC.B.h;goto z80_fetch;
z80_LD_A_B:   R->AF.B.h=R->BC.B.h;goto z80_fetch;
z80_LD_xHL_B: gg_write(R->HL.W,R->BC.B.h);goto z80_fetch;

z80_LD_B_C:   R->BC.B.h=R->BC.B.l;goto z80_fetch;
z80_LD_C_C:   R->BC.B.l=R->BC.B.l;goto z80_fetch;
z80_LD_D_C:   R->DE.B.h=R->BC.B.l;goto z80_fetch;
z80_LD_E_C:   R->DE.B.l=R->BC.B.l;goto z80_fetch;
z80_LD_H_C:   R->HL.B.h=R->BC.B.l;goto z80_fetch;
z80_LD_L_C:   R->HL.B.l=R->BC.B.l;goto z80_fetch;
z80_LD_A_C:   R->AF.B.h=R->BC.B.l;goto z80_fetch;
z80_LD_xHL_C: gg_write(R->HL.W,R->BC.B.l);goto z80_fetch;

z80_LD_B_D:   R->BC.B.h=R->DE.B.h;goto z80_fetch;
z80_LD_C_D:   R->BC.B.l=R->DE.B.h;goto z80_fetch;
z80_LD_D_D:   R->DE.B.h=R->DE.B.h;goto z80_fetch;
z80_LD_E_D:   R->DE.B.l=R->DE.B.h;goto z80_fetch;
z80_LD_H_D:   R->HL.B.h=R->DE.B.h;goto z80_fetch;
z80_LD_L_D:   R->HL.B.l=R->DE.B.h;goto z80_fetch;
z80_LD_A_D:   R->AF.B.h=R->DE.B.h;goto z80_fetch;
z80_LD_xHL_D: gg_write(R->HL.W,R->DE.B.h);goto z80_fetch;

z80_LD_B_E:   R->BC.B.h=R->DE.B.l;goto z80_fetch;
z80_LD_C_E:   R->BC.B.l=R->DE.B.l;goto z80_fetch;
z80_LD_D_E:   R->DE.B.h=R->DE.B.l;goto z80_fetch;
z80_LD_E_E:   R->DE.B.l=R->DE.B.l;goto z80_fetch;
z80_LD_H_E:   R->HL.B.h=R->DE.B.l;goto z80_fetch;
z80_LD_L_E:   R->HL.B.l=R->DE.B.l;goto z80_fetch;
z80_LD_A_E:   R->AF.B.h=R->DE.B.l;goto z80_fetch;
z80_LD_xHL_E: gg_write(R->HL.W,R->DE.B.l);goto z80_fetch;

z80_LD_B_H:   R->BC.B.h=R->HL.B.h;goto z80_fetch;
z80_LD_C_H:   R->BC.B.l=R->HL.B.h;goto z80_fetch;
z80_LD_D_H:   R->DE.B.h=R->HL.B.h;goto z80_fetch;
z80_LD_E_H:   R->DE.B.l=R->HL.B.h;goto z80_fetch;
z80_LD_H_H:   R->HL.B.h=R->HL.B.h;goto z80_fetch;
z80_LD_L_H:   R->HL.B.l=R->HL.B.h;goto z80_fetch;
z80_LD_A_H:   R->AF.B.h=R->HL.B.h;goto z80_fetch;
z80_LD_xHL_H: gg_write(R->HL.W,R->HL.B.h);goto z80_fetch;

z80_LD_B_L:   R->BC.B.h=R->HL.B.l;goto z80_fetch;
z80_LD_C_L:   R->BC.B.l=R->HL.B.l;goto z80_fetch;
z80_LD_D_L:   R->DE.B.h=R->HL.B.l;goto z80_fetch;
z80_LD_E_L:   R->DE.B.l=R->HL.B.l;goto z80_fetch;
z80_LD_H_L:   R->HL.B.h=R->HL.B.l;goto z80_fetch;
z80_LD_L_L:   R->HL.B.l=R->HL.B.l;goto z80_fetch;
z80_LD_A_L:   R->AF.B.h=R->HL.B.l;goto z80_fetch;
z80_LD_xHL_L: gg_write(R->HL.W,R->HL.B.l);goto z80_fetch;

z80_LD_B_A:   R->BC.B.h=R->AF.B.h;goto z80_fetch;
z80_LD_C_A:   R->BC.B.l=R->AF.B.h;goto z80_fetch;
z80_LD_D_A:   R->DE.B.h=R->AF.B.h;goto z80_fetch;
z80_LD_E_A:   R->DE.B.l=R->AF.B.h;goto z80_fetch;
z80_LD_H_A:   R->HL.B.h=R->AF.B.h;goto z80_fetch;
z80_LD_L_A:   R->HL.B.l=R->AF.B.h;goto z80_fetch;
z80_LD_A_A:   R->AF.B.h=R->AF.B.h;goto z80_fetch;
z80_LD_xHL_A: gg_write(R->HL.W,R->AF.B.h);goto z80_fetch;

z80_LD_xBC_A: gg_write(R->BC.W,R->AF.B.h);goto z80_fetch;
z80_LD_xDE_A: gg_write(R->DE.W,R->AF.B.h);goto z80_fetch;

z80_LD_B_xHL:    R->BC.B.h=gg_read(R->HL.W);goto z80_fetch;
z80_LD_C_xHL:    R->BC.B.l=gg_read(R->HL.W);goto z80_fetch;
z80_LD_D_xHL:    R->DE.B.h=gg_read(R->HL.W);goto z80_fetch;
z80_LD_E_xHL:    R->DE.B.l=gg_read(R->HL.W);goto z80_fetch;
z80_LD_H_xHL:    R->HL.B.h=gg_read(R->HL.W);goto z80_fetch;
z80_LD_L_xHL:    R->HL.B.l=gg_read(R->HL.W);goto z80_fetch;
z80_LD_A_xHL:    R->AF.B.h=gg_read(R->HL.W);goto z80_fetch;

z80_LD_B_BYTE:   R->BC.B.h=FETCH_BYTE();goto z80_fetch;
z80_LD_C_BYTE:   R->BC.B.l=FETCH_BYTE();goto z80_fetch;
z80_LD_D_BYTE:   R->DE.B.h=FETCH_BYTE();goto z80_fetch;
z80_LD_E_BYTE:   R->DE.B.l=FETCH_BYTE();goto z80_fetch;
z80_LD_H_BYTE:   R->HL.B.h=FETCH_BYTE();goto z80_fetch;
z80_LD_L_BYTE:   R->HL.B.l=FETCH_BYTE();goto z80_fetch;
z80_LD_A_BYTE:   R->AF.B.h=FETCH_BYTE();goto z80_fetch;
z80_LD_xHL_BYTE: gg_write(R->HL.W,FETCH_BYTE());goto z80_fetch;

z80_LD_xWORD_HL:
  J.B.l=FETCH_BYTE();
  J.B.h=FETCH_BYTE();
  gg_write(J.W++,R->HL.B.l);
  gg_write(J.W,R->HL.B.h);
  goto z80_fetch;

z80_LD_HL_xWORD:
  J.B.l=FETCH_BYTE();
  J.B.h=FETCH_BYTE();
  R->HL.B.l=gg_read(J.W++);
  R->HL.B.h=gg_read(J.W);
  goto z80_fetch;

z80_LD_A_xWORD:
  J.B.l=FETCH_BYTE();
  J.B.h=FETCH_BYTE();
  R->AF.B.h=gg_read(J.W);
  goto z80_fetch;

z80_LD_xWORD_A:
  J.B.l=FETCH_BYTE();
  J.B.h=FETCH_BYTE();
  gg_write(J.W,R->AF.B.h);
  goto z80_fetch;

z80_EX_HL_xSP:
  J.B.l=gg_read(R->SP.W);gg_write(R->SP.W++,R->HL.B.l);
  J.B.h=gg_read(R->SP.W);gg_write(R->SP.W--,R->HL.B.h);
  R->HL.W=J.W;
  goto z80_fetch;

z80_DAA:
  R->AF.W=z80_compute_daa(R->AF.B.h, R->AF.B.l);
  goto z80_fetch;
