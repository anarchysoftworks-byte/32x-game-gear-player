/*
 * z80_ops_ed.h — ED-prefix opcode table case statements
 * Ported from Marat Fayzullin's Z80 core (CodesED.h)
 * Included from z80.c inside CodesED() switch.
 */

/* PatchZ80 (ED FE) — BIOS patch, no-op on real hardware */
case DB_FE:     break;

case ADC_HL_BC: M_ADCW(BC);break;
case ADC_HL_DE: M_ADCW(DE);break;
case ADC_HL_HL: M_ADCW(HL);break;
case ADC_HL_SP: M_ADCW(SP);break;

case SBC_HL_BC: M_SBCW(BC);break;
case SBC_HL_DE: M_SBCW(DE);break;
case SBC_HL_HL: M_SBCW(HL);break;
case SBC_HL_SP: M_SBCW(SP);break;

case LD_xWORDe_HL:
  J.B.l=gg_read(R->PC.W++);
  J.B.h=gg_read(R->PC.W++);
  gg_write(J.W++,R->HL.B.l);
  gg_write(J.W,R->HL.B.h);
  break;
case LD_xWORDe_DE:
  J.B.l=gg_read(R->PC.W++);
  J.B.h=gg_read(R->PC.W++);
  gg_write(J.W++,R->DE.B.l);
  gg_write(J.W,R->DE.B.h);
  break;
case LD_xWORDe_BC:
  J.B.l=gg_read(R->PC.W++);
  J.B.h=gg_read(R->PC.W++);
  gg_write(J.W++,R->BC.B.l);
  gg_write(J.W,R->BC.B.h);
  break;
case LD_xWORDe_SP:
  J.B.l=gg_read(R->PC.W++);
  J.B.h=gg_read(R->PC.W++);
  gg_write(J.W++,R->SP.B.l);
  gg_write(J.W,R->SP.B.h);
  break;

case LD_HL_xWORDe:
  J.B.l=gg_read(R->PC.W++);
  J.B.h=gg_read(R->PC.W++);
  R->HL.B.l=gg_read(J.W++);
  R->HL.B.h=gg_read(J.W);
  break;
case LD_DE_xWORDe:
  J.B.l=gg_read(R->PC.W++);
  J.B.h=gg_read(R->PC.W++);
  R->DE.B.l=gg_read(J.W++);
  R->DE.B.h=gg_read(J.W);
  break;
case LD_BC_xWORDe:
  J.B.l=gg_read(R->PC.W++);
  J.B.h=gg_read(R->PC.W++);
  R->BC.B.l=gg_read(J.W++);
  R->BC.B.h=gg_read(J.W);
  break;
case LD_SP_xWORDe:
  J.B.l=gg_read(R->PC.W++);
  J.B.h=gg_read(R->PC.W++);
  R->SP.B.l=gg_read(J.W++);
  R->SP.B.h=gg_read(J.W);
  break;

case RRD:
  I=gg_read(R->HL.W);
  J.B.l=(I>>4)|(R->AF.B.h<<4);
  gg_write(R->HL.W,J.B.l);
  R->AF.B.h=(I&0x0F)|(R->AF.B.h&0xF0);
  R->AF.B.l=PZSTable[R->AF.B.h]|(R->AF.B.l&C_FLAG);
  break;
case RLD:
  I=gg_read(R->HL.W);
  J.B.l=(I<<4)|(R->AF.B.h&0x0F);
  gg_write(R->HL.W,J.B.l);
  R->AF.B.h=(I>>4)|(R->AF.B.h&0xF0);
  R->AF.B.l=PZSTable[R->AF.B.h]|(R->AF.B.l&C_FLAG);
  break;

case LD_A_I:
  R->AF.B.h=R->I;
  R->AF.B.l=(R->AF.B.l&C_FLAG)|(R->IFF&IFF_2? P_FLAG:0)|ZSTable[R->AF.B.h];
  break;

case LD_A_R:
  R->AF.B.h = R->R7 | (R->R & 0x7f);
  R->AF.B.l=(R->AF.B.l&C_FLAG)|(R->IFF&IFF_2? P_FLAG:0)|ZSTable[R->AF.B.h];
  break;

case LD_I_A:   R->I=R->AF.B.h;break;
case LD_R_A:
  R->R = R->AF.B.h;
  R->R7 = R->AF.B.h & 0x80;
  break;

case DB_4E: case DB_66: case DB_6E: /* Undocumented */
case IM_0:     R->IFF&=~(IFF_IM1|IFF_IM2);break;
case DB_76: /* Undocumented */
case IM_1:     R->IFF=(R->IFF&~IFF_IM2)|IFF_IM1;break;
case DB_7E: /* Undocumented */
case IM_2:     R->IFF=(R->IFF&~IFF_IM1)|IFF_IM2;break;

case DB_77: case DB_7F: /* Undocumented NOP */
               break;

case RETI:     if(R->IFF&IFF_2) R->IFF|=IFF_1; else R->IFF&=~IFF_1;
               M_RET;break;

case DB_55: case DB_5D: case DB_65: case DB_6D: case DB_75: case DB_7D: /* Undocumented */
case RETN:     if(R->IFF&IFF_2) R->IFF|=IFF_1; else R->IFF&=~IFF_1;
               M_RET;break;

case DB_4C: case DB_54: case DB_5C: case DB_64: case DB_6C: case DB_74: case DB_7C: /* Undocumented */
case NEG:      I=R->AF.B.h;R->AF.B.h=0;M_SUB(I);break;

case IN_B_xC:  M_IN(R->BC.B.h);break;
case IN_C_xC:  M_IN(R->BC.B.l);break;
case IN_D_xC:  M_IN(R->DE.B.h);break;
case IN_E_xC:  M_IN(R->DE.B.l);break;
case IN_H_xC:  M_IN(R->HL.B.h);break;
case IN_L_xC:  M_IN(R->HL.B.l);break;
case IN_A_xC:  M_IN(R->AF.B.h);break;
case IN_F_xC:  M_IN(J.B.l);break;

case OUT_xC_B: gg_out(R->BC.B.l,R->BC.B.h);break;
case OUT_xC_C: gg_out(R->BC.B.l,R->BC.B.l);break;
case OUT_xC_D: gg_out(R->BC.B.l,R->DE.B.h);break;
case OUT_xC_E: gg_out(R->BC.B.l,R->DE.B.l);break;
case OUT_xC_H: gg_out(R->BC.B.l,R->HL.B.h);break;
case OUT_xC_L: gg_out(R->BC.B.l,R->HL.B.l);break;
case OUT_xC_A: gg_out(R->BC.B.l,R->AF.B.h);break;
case OUT_xC_0: gg_out(R->BC.B.l,0); break; /* Undocumented OUT (C), 0 */

case INI:
  gg_write(R->HL.W++,gg_in(R->BC.B.l));
  R->BC.B.h--;
  R->AF.B.l=N_FLAG|(R->BC.B.h? 0:Z_FLAG);
  break;

case INIR:
  R->R += 2 * (R->ICount / 21);
  do
  {
    gg_write(R->HL.W++,gg_in(R->BC.B.l));
    R->BC.B.h--;R->ICount-=21;
  }
  while(R->BC.B.h&&(R->ICount>0));
  if(R->BC.B.h) { R->AF.B.l=N_FLAG;R->PC.W-=2; }
  else { R->AF.B.l=Z_FLAG|N_FLAG;R->ICount+=5; }
  break;

case IND:
  gg_write(R->HL.W--,gg_in(R->BC.B.l));
  R->BC.B.h--;
  R->AF.B.l=N_FLAG|(R->BC.B.h? 0:Z_FLAG);
  break;

case INDR:
  R->R += 2 * (R->ICount / 21);
  do
  {
    gg_write(R->HL.W--,gg_in(R->BC.B.l));
    R->BC.B.h--;R->ICount-=21;
  }
  while(R->BC.B.h&&(R->ICount>0));
  if(R->BC.B.h) { R->AF.B.l=N_FLAG;R->PC.W-=2; }
  else { R->AF.B.l=Z_FLAG|N_FLAG;R->ICount+=5; }
  break;

case OUTI:
  I = gg_read(R->HL.W++);
  gg_out(R->BC.B.l, I);
  R->BC.B.h--;
  R->AF.B.l=N_FLAG|(R->BC.B.h? 0:Z_FLAG)|(R->HL.B.l+I>255? (C_FLAG|H_FLAG):0);
  break;

case OTIR:
  R->R += 2 * (R->ICount / 21);
  do
  {
    I=gg_read(R->HL.W++);
    gg_out(R->BC.B.l,I);
    R->BC.B.h--;
    R->ICount-=21;
  }
  while(R->BC.B.h&&(R->ICount>0));
  if(R->BC.B.h)
  {
    R->AF.B.l=N_FLAG|(R->HL.B.l+I>255? (C_FLAG|H_FLAG):0);
    R->PC.W-=2;
  }
  else
  {
    R->AF.B.l=Z_FLAG|N_FLAG|(R->HL.B.l+I>255? (C_FLAG|H_FLAG):0);
    R->ICount+=5;
  }
  break;

case OUTD:
  I=gg_read(R->HL.W--);
  gg_out(R->BC.B.l,I);
  R->BC.B.h--;
  R->AF.B.l=N_FLAG|(R->BC.B.h? 0:Z_FLAG)|(R->HL.B.l+I>255? (C_FLAG|H_FLAG):0);
  break;

case OTDR:
  R->R += 2 * (R->ICount / 21);
  do
  {
    I=gg_read(R->HL.W--);
    gg_out(R->BC.B.l,I);
    R->BC.B.h--;
    R->ICount-=21;
  }
  while(R->BC.B.h&&(R->ICount>0));
  if(R->BC.B.h)
  {
    R->AF.B.l=N_FLAG|(R->HL.B.l+I>255? (C_FLAG|H_FLAG):0);
    R->PC.W-=2;
  }
  else
  {
    R->AF.B.l=Z_FLAG|N_FLAG|(R->HL.B.l+I>255? (C_FLAG|H_FLAG):0);
    R->ICount+=5;
  }
  break;

case LDI:
  gg_write(R->DE.W++,gg_read(R->HL.W++));
  R->BC.W--;
  R->AF.B.l=(R->AF.B.l&~(N_FLAG|H_FLAG|P_FLAG))|(R->BC.W? P_FLAG:0);
  break;

case LDIR:
  R->R += 2 * (R->ICount / 21);
  do
  {
    gg_write(R->DE.W++, gg_read(R->HL.W++));
    R->BC.W--; R->ICount -= 21;
  }
  while (R->BC.W && (R->ICount > 0));
  R->AF.B.l &=~ (N_FLAG | H_FLAG | P_FLAG);
  if (R->BC.W) { R->AF.B.l |= N_FLAG; R->PC.W -= 2; }
  else R->ICount += 5;
  break;

case LDD:
  gg_write(R->DE.W--,gg_read(R->HL.W--));
  R->BC.W--;
  R->AF.B.l=(R->AF.B.l&~(N_FLAG|H_FLAG|P_FLAG))|(R->BC.W? P_FLAG:0);
  break;

case LDDR:
  R->R += 2 * (R->ICount / 21);
  do
  {
    gg_write(R->DE.W--,gg_read(R->HL.W--));
    R->BC.W--;R->ICount-=21;
  }
  while(R->BC.W&&(R->ICount>0));
  R->AF.B.l&=~(N_FLAG|H_FLAG|P_FLAG);
  if(R->BC.W) { R->AF.B.l|=N_FLAG;R->PC.W-=2; }
  else R->ICount+=5;
  break;

case CPI:
  I=gg_read(R->HL.W++);
  J.B.l=R->AF.B.h-I;
  R->BC.W--;
  R->AF.B.l =
    N_FLAG|(R->AF.B.l&C_FLAG)|ZSTable[J.B.l]|
    ((R->AF.B.h^I^J.B.l)&H_FLAG)|(R->BC.W? P_FLAG:0);
  break;

case CPIR:
  R->R += 2 * (R->ICount / 21);
  do
  {
    I=gg_read(R->HL.W++);
    J.B.l=R->AF.B.h-I;
    R->BC.W--;R->ICount-=21;
  }
  while(R->BC.W&&J.B.l&&(R->ICount>0));
  R->AF.B.l =
    N_FLAG|(R->AF.B.l&C_FLAG)|ZSTable[J.B.l]|
    ((R->AF.B.h^I^J.B.l)&H_FLAG)|(R->BC.W? P_FLAG:0);
  if(R->BC.W&&J.B.l) R->PC.W-=2; else R->ICount+=5;
  break;

case CPD:
  I=gg_read(R->HL.W--);
  J.B.l=R->AF.B.h-I;
  R->BC.W--;
  R->AF.B.l =
    N_FLAG|(R->AF.B.l&C_FLAG)|ZSTable[J.B.l]|
    ((R->AF.B.h^I^J.B.l)&H_FLAG)|(R->BC.W? P_FLAG:0);
  break;

case CPDR:
  R->R += 2 * (R->ICount / 21);
  do
  {
    I=gg_read(R->HL.W--);
    J.B.l=R->AF.B.h-I;
    R->BC.W--;R->ICount-=21;
  }
  while(R->BC.W&&J.B.l&&(R->ICount>0));
  R->AF.B.l =
    N_FLAG|(R->AF.B.l&C_FLAG)|ZSTable[J.B.l]|
    ((R->AF.B.h^I^J.B.l)&H_FLAG)|(R->BC.W? P_FLAG:0);
  if(R->BC.W&&J.B.l) R->PC.W-=2; else R->ICount+=5;
  break;
