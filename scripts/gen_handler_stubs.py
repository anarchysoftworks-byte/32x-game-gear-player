#!/usr/bin/env python3
"""
Generate _z80_handler_stubs: 256 x 16-byte computed-jump dispatch table for SH-2.

Two stub types:
  INDIRECT (default): mov.l + jmp @r1 + nop(delay) + 3*nop + .long handler
  INLINE (trivial handlers): actual handler code + mov.l + jmp @r1 + delay + .long _z80_fetch

Inline stubs eliminate a cache line load per execution by combining the
handler code with the dispatch stub.  All instructions are scheduled to
avoid SH-2 load-use stalls (1-cycle gap between load and use).

The .long at offset 12 is in the SAME 16-byte cache line as the
executing stub code, so the mov.l data load is a guaranteed cache hit.
"""

# z80_t struct offsets (big-endian)
OFF_B = 10; OFF_C = 11; OFF_D = 12; OFF_E = 13; OFF_H = 8; OFF_L = 9
PAIR_BC = 10; PAIR_DE = 12; PAIR_HL = 8; PAIR_SP = 16
# A is pinned in R12, no struct offset needed for inline ops

# Source/dest offset for register index (0=B,1=C,2=D,3=E,4=H,5=L,6=(HL),7=A)
REG_OFF = [OFF_B, OFF_C, OFF_D, OFF_E, OFF_H, OFF_L, None, None]
REG_CHAR = ['B', 'C', 'D', 'E', 'H', 'L', '(HL)', 'A']

# The 256 main opcode handler labels
HANDLERS = [
    # 0x00-0x07
    "_z80_op_nop", "_z80_ld_bc_nn", "_z80_ld_xbc_a", "_z80_inc_bc",
    "_z80_inc_b_spec", "_z80_dec_b_spec", "_z80_ld_r_n", "_z80_rlca",
    # 0x08-0x0F
    "_z80_op_exafaf", "_z80_add_hl_bc", "_z80_ld_a_xbc", "_z80_dec_bc",
    "_z80_inc_c_spec", "_z80_dec_c_spec", "_z80_ld_r_n", "_z80_rrca",
    # 0x10-0x17
    "_z80_djnz", "_z80_ld_de_nn", "_z80_ld_xde_a", "_z80_inc_de",
    "_z80_inc_d_spec", "_z80_dec_d_spec", "_z80_ld_r_n", "_z80_rla",
    # 0x18-0x1F
    "_z80_jr", "_z80_add_hl_de", "_z80_ld_a_xde", "_z80_dec_de",
    "_z80_inc_e_spec", "_z80_dec_e_spec", "_z80_ld_r_n", "_z80_rra",
    # 0x20-0x27
    "_z80_jr_nz", "_z80_ld_hl_nn", "_z80_ld_xword_hl", "_z80_inc_hl",
    "_z80_inc_h_spec", "_z80_dec_h_spec", "_z80_ld_r_n", "_z80_daa",
    # 0x28-0x2F
    "_z80_jr_z", "_z80_add_hl_hl", "_z80_ld_hl_xword", "_z80_dec_hl",
    "_z80_inc_l_spec", "_z80_dec_l_spec", "_z80_ld_r_n", "_z80_cpl",
    # 0x30-0x37
    "_z80_jr_nc", "_z80_ld_sp_nn", "_z80_ld_xword_a", "_z80_inc_sp",
    "_z80_inc_xhl", "_z80_dec_xhl", "_z80_ld_xhl_n", "_z80_scf",
    # 0x38-0x3F
    "_z80_jr_c", "_z80_add_hl_sp", "_z80_ld_a_xword", "_z80_dec_sp",
    "_z80_inc_a_spec", "_z80_dec_a_spec", "_z80_ld_r_n", "_z80_ccf",
    # 0x40-0x47: LD B,r
    "_z80_ld_b_b", "_z80_ld_b_c", "_z80_ld_b_d", "_z80_ld_b_e",
    "_z80_ld_b_h", "_z80_ld_b_l", "_z80_ld_b_xhl", "_z80_ld_b_a",
    # 0x48-0x4F: LD C,r
    "_z80_ld_c_b", "_z80_ld_c_c", "_z80_ld_c_d", "_z80_ld_c_e",
    "_z80_ld_c_h", "_z80_ld_c_l", "_z80_ld_c_xhl", "_z80_ld_c_a",
    # 0x50-0x57: LD D,r
    "_z80_ld_d_b", "_z80_ld_d_c", "_z80_ld_d_d", "_z80_ld_d_e",
    "_z80_ld_d_h", "_z80_ld_d_l", "_z80_ld_d_xhl", "_z80_ld_d_a",
    # 0x58-0x5F: LD E,r
    "_z80_ld_e_b", "_z80_ld_e_c", "_z80_ld_e_d", "_z80_ld_e_e",
    "_z80_ld_e_h", "_z80_ld_e_l", "_z80_ld_e_xhl", "_z80_ld_e_a",
    # 0x60-0x67: LD H,r
    "_z80_ld_h_b", "_z80_ld_h_c", "_z80_ld_h_d", "_z80_ld_h_e",
    "_z80_ld_h_h", "_z80_ld_h_l", "_z80_ld_h_xhl", "_z80_ld_h_a",
    # 0x68-0x6F: LD L,r
    "_z80_ld_l_b", "_z80_ld_l_c", "_z80_ld_l_d", "_z80_ld_l_e",
    "_z80_ld_l_h", "_z80_ld_l_l", "_z80_ld_l_xhl", "_z80_ld_l_a",
    # 0x70-0x77: LD (HL),r / HALT
    "_z80_ld_xhl_b", "_z80_ld_xhl_c", "_z80_ld_xhl_d", "_z80_ld_xhl_e",
    "_z80_ld_xhl_h", "_z80_ld_xhl_l", "_z80_halt", "_z80_ld_xhl_a",
    # 0x78-0x7F: LD A,r
    "_z80_ld_a_b", "_z80_ld_a_c", "_z80_ld_a_d", "_z80_ld_a_e",
    "_z80_ld_a_h", "_z80_ld_a_l", "_z80_ld_a_xhl", "_z80_ld_a_a",
    # 0x80-0x87: ADD A,r
    "_z80_add_b", "_z80_add_c", "_z80_add_d", "_z80_add_e",
    "_z80_add_h", "_z80_add_l", "_z80_add_xhl", "_z80_add_a_spec",
    # 0x88-0x8F: ADC A,r
    "_z80_adc_b", "_z80_adc_c", "_z80_adc_d", "_z80_adc_e",
    "_z80_adc_h", "_z80_adc_l", "_z80_adc_xhl", "_z80_adc_a_spec",
    # 0x90-0x97: SUB A,r
    "_z80_sub_b", "_z80_sub_c", "_z80_sub_d", "_z80_sub_e",
    "_z80_sub_h", "_z80_sub_l", "_z80_sub_xhl", "_z80_sub_a_spec",
    # 0x98-0x9F: SBC A,r
    "_z80_sbc_b", "_z80_sbc_c", "_z80_sbc_d", "_z80_sbc_e",
    "_z80_sbc_h", "_z80_sbc_l", "_z80_sbc_xhl", "_z80_sbc_a_spec",
    # 0xA0-0xA7: AND A,r
    "_z80_and_b", "_z80_and_c", "_z80_and_d", "_z80_and_e",
    "_z80_and_h", "_z80_and_l", "_z80_and_xhl", "_z80_and_a_spec",
    # 0xA8-0xAF: XOR A,r
    "_z80_xor_b", "_z80_xor_c", "_z80_xor_d", "_z80_xor_e",
    "_z80_xor_h", "_z80_xor_l", "_z80_xor_xhl", "_z80_xor_a_spec",
    # 0xB0-0xB7: OR A,r
    "_z80_or_b", "_z80_or_c", "_z80_or_d", "_z80_or_e",
    "_z80_or_h", "_z80_or_l", "_z80_or_xhl", "_z80_or_a_spec",
    # 0xB8-0xBF: CP A,r
    "_z80_cp_b", "_z80_cp_c", "_z80_cp_d", "_z80_cp_e",
    "_z80_cp_h", "_z80_cp_l", "_z80_cp_xhl", "_z80_cp_a_spec",
    # 0xC0-0xC7
    "_z80_ret_nz", "_z80_pop_bc", "_z80_jp_nz", "_z80_jp",
    "_z80_call_nz", "_z80_push_bc", "_z80_add_imm", "_z80_rst00",
    # 0xC8-0xCF
    "_z80_ret_z", "_z80_ret", "_z80_jp_z", "_z80_cb_prefix",
    "_z80_call_z", "_z80_call", "_z80_adc_imm", "_z80_rst08",
    # 0xD0-0xD7
    "_z80_ret_nc", "_z80_pop_de", "_z80_jp_nc", "_z80_outa",
    "_z80_call_nc", "_z80_push_de", "_z80_sub_imm", "_z80_rst10",
    # 0xD8-0xDF
    "_z80_ret_c", "_z80_exx", "_z80_jp_c", "_z80_ina",
    "_z80_call_c", "_z80_pfx_dd", "_z80_sbc_imm", "_z80_rst18",
    # 0xE0-0xE7
    "_z80_ret_po", "_z80_pop_hl", "_z80_jp_po", "_z80_ex_hl_xsp",
    "_z80_call_po", "_z80_push_hl", "_z80_and_imm", "_z80_rst20",
    # 0xE8-0xEF
    "_z80_ret_pe", "_z80_jp_hl", "_z80_jp_pe", "_z80_ex_de_hl",
    "_z80_call_pe", "_z80_pfx_ed", "_z80_xor_imm", "_z80_rst28",
    # 0xF0-0xF7
    "_z80_ret_p", "_z80_pop_af", "_z80_jp_p", "_z80_di",
    "_z80_call_p", "_z80_push_af", "_z80_or_imm", "_z80_rst30",
    # 0xF8-0xFF
    "_z80_ret_m", "_z80_ld_sp_hl", "_z80_jp_m", "_z80_ei",
    "_z80_call_m", "_z80_pfx_fd", "_z80_cp_imm", "_z80_rst38",
]

assert len(HANDLERS) == 256, f"Expected 256 handlers, got {len(HANDLERS)}"

# Z80 opcode names for comments
NAMES = [
    "NOP","LD BC,nn","LD (BC),A","INC BC","INC B","DEC B","LD B,n","RLCA",
    "EX AF,AF'","ADD HL,BC","LD A,(BC)","DEC BC","INC C","DEC C","LD C,n","RRCA",
    "DJNZ","LD DE,nn","LD (DE),A","INC DE","INC D","DEC D","LD D,n","RLA",
    "JR e","ADD HL,DE","LD A,(DE)","DEC DE","INC E","DEC E","LD E,n","RRA",
    "JR NZ","LD HL,nn","LD (nn),HL","INC HL","INC H","DEC H","LD H,n","DAA",
    "JR Z","ADD HL,HL","LD HL,(nn)","DEC HL","INC L","DEC L","LD L,n","CPL",
    "JR NC","LD SP,nn","LD (nn),A","INC SP","INC (HL)","DEC (HL)","LD (HL),n","SCF",
    "JR C","ADD HL,SP","LD A,(nn)","DEC SP","INC A","DEC A","LD A,n","CCF",
] + [f"LD {d},{s}" for d in "BCDEHL" for s in ["B","C","D","E","H","L","(HL)","A"]] + [
    f"LD (HL),{s}" for s in ["B","C","D","E","H","L"]
] + ["HALT"] + ["LD (HL),A"] + [
    f"LD A,{s}" for s in ["B","C","D","E","H","L","(HL)","A"]
] + [
    f"{op} A,{s}" for op in ["ADD","ADC","SUB","SBC","AND","XOR","OR","CP"]
    for s in ["B","C","D","E","H","L","(HL)","A"]
] + [
    "RET NZ","POP BC","JP NZ,nn","JP nn","CALL NZ","PUSH BC","ADD A,n","RST 00",
    "RET Z","RET","JP Z,nn","CB prefix","CALL Z","CALL nn","ADC A,n","RST 08",
    "RET NC","POP DE","JP NC,nn","OUT (n),A","CALL NC","PUSH DE","SUB n","RST 10",
    "RET C","EXX","JP C,nn","IN A,(n)","CALL C","DD prefix","SBC n","RST 18",
    "RET PO","POP HL","JP PO,nn","EX (SP),HL","CALL PO","PUSH HL","AND n","RST 20",
    "RET PE","JP (HL)","JP PE,nn","EX DE,HL","CALL PE","ED prefix","XOR n","RST 28",
    "RET P","POP AF","JP P,nn","DI","CALL P","PUSH AF","OR n","RST 30",
    "RET M","LD SP,HL","JP M,nn","EI","CALL M","FD prefix","CP n","RST 38",
]

# ================================================================
# Build inline stub definitions
# Each entry: (list_of_6_asm_lines, return_label)
# Instructions are scheduled to avoid SH-2 load-use stalls.
# ================================================================
INLINE = {}

def nop_stub(cycles=4, ret="_z80_fetch"):
    """Pattern A: NOP or self-move — 1 work instruction."""
    return ([
        f"mov.l   .Ls_{{op:02X}}, r1",
        f"add     #-{cycles}, r11",
        f"jmp     @r1",
        f"nop",
        f"nop",
        f"nop",
    ], ret)

def ld_reg_reg(src_off, dst_off):
    """Pattern B: LD r,r' — load src from struct, store to dst."""
    return ([
        f"mov.b   @({src_off}, r14), r0",
        f"mov.l   .Ls_{{op:02X}}, r1",
        f"add     #-4, r11",
        f"jmp     @r1",
        f"mov.b   r0, @({dst_off}, r14)",
        f"nop",
    ], "_z80_fetch")

def ld_reg_a(dst_off):
    """Pattern C: LD r,A — A pinned in R12."""
    return ([
        f"mov     r12, r0",
        f"mov.l   .Ls_{{op:02X}}, r1",
        f"add     #-4, r11",
        f"jmp     @r1",
        f"mov.b   r0, @({dst_off}, r14)",
        f"nop",
    ], "_z80_fetch")

def ld_a_reg(src_off):
    """Pattern D: LD A,r — dst is pinned R12."""
    return ([
        f"mov.b   @({src_off}, r14), r0",
        f"mov.l   .Ls_{{op:02X}}, r1",
        f"add     #-4, r11",
        f"jmp     @r1",
        f"extu.b  r0, r12",
        f"nop",
    ], "_z80_fetch")

def inc_pair(pair_off):
    """Pattern E: INC rr — increment register pair."""
    return ([
        f"mov.w   @({pair_off}, r14), r0",
        f"add     #-6, r11",
        f"mov.l   .Ls_{{op:02X}}, r1",
        f"add     #1, r0",
        f"jmp     @r1",
        f"mov.w   r0, @({pair_off}, r14)",
    ], "_z80_fetch")

def dec_pair(pair_off):
    """Pattern F: DEC rr — decrement register pair."""
    return ([
        f"mov.w   @({pair_off}, r14), r0",
        f"add     #-6, r11",
        f"mov.l   .Ls_{{op:02X}}, r1",
        f"add     #-1, r0",
        f"jmp     @r1",
        f"mov.w   r0, @({pair_off}, r14)",
    ], "_z80_fetch")

# NOP
INLINE[0x00] = nop_stub(4)

# INC/DEC register pairs
INLINE[0x03] = inc_pair(PAIR_BC)
INLINE[0x0B] = dec_pair(PAIR_BC)
INLINE[0x13] = inc_pair(PAIR_DE)
INLINE[0x1B] = dec_pair(PAIR_DE)
INLINE[0x23] = inc_pair(PAIR_HL)
INLINE[0x2B] = dec_pair(PAIR_HL)
INLINE[0x33] = inc_pair(PAIR_SP)
INLINE[0x3B] = dec_pair(PAIR_SP)

# LD r,r' block (0x40-0x6F, excluding (HL) column at bit pattern xx110)
for dst_idx in range(6):  # B,C,D,E,H,L (rows 0-5)
    dst_off = REG_OFF[dst_idx]
    for src_idx in range(8):  # B,C,D,E,H,L,(HL),A (cols 0-7)
        if src_idx == 6:  # (HL) column → LD r,(HL), not inlineable
            continue
        opcode = 0x40 + dst_idx * 8 + src_idx
        if dst_idx == src_idx:
            INLINE[opcode] = nop_stub(4)  # self-move = NOP
        elif src_idx == 7:
            INLINE[opcode] = ld_reg_a(dst_off)
        else:
            INLINE[opcode] = ld_reg_reg(REG_OFF[src_idx], dst_off)

# LD A,r (0x78-0x7F, excluding (HL) at 0x7E)
for src_idx in range(8):
    if src_idx == 6:  # (HL) column
        continue
    opcode = 0x78 + src_idx
    if src_idx == 7:
        INLINE[opcode] = nop_stub(4)  # LD A,A = NOP
    else:
        INLINE[opcode] = ld_a_reg(REG_OFF[src_idx])

# JP (HL) — uses _z80_fetch_bp
INLINE[0xE9] = ([
    f"mov.w   @(8, r14), r0",
    f"mov.l   .Ls_{{op:02X}}, r1",
    f"add     #-4, r11",
    f"jmp     @r1",
    f"extu.w  r0, r7",
    f"nop",
], "_z80_fetch_bp")

# LD SP,HL
INLINE[0xF9] = ([
    f"mov.w   @(8, r14), r0",
    f"mov.l   .Ls_{{op:02X}}, r1",
    f"add     #-6, r11",
    f"jmp     @r1",
    f"mov.w   r0, @(16, r14)",
    f"nop",
], "_z80_fetch")


def main():
    assert len(NAMES) == 256, f"Expected 256 names, got {len(NAMES)}"

    lines = []
    lines.append("/* ================================================================ */")
    lines.append("/*  Handler stub table: 256 x 16 bytes = 4096 bytes                 */")
    lines.append("/*  Two types:                                                       */")
    lines.append("/*    INDIRECT: mov.l + jmp @r1 + nop(delay) + 3*nop + .long addr   */")
    lines.append("/*    INLINE:   handler code + mov.l + jmp @r1 + delay + .long fetch */")
    lines.append("/*  Inline stubs eliminate a cache line load per execution.           */")
    lines.append("/*  The .long at offset 12 shares the cache line with the stub code, */")
    lines.append("/*  making the data load a guaranteed I-cache hit on SH-2.           */")
    lines.append("/* ================================================================ */")
    lines.append("        .subsection 0")
    lines.append("        .balign 16            /* cache-line aligned */")
    lines.append("        .global _z80_handler_stubs")
    lines.append("_z80_handler_stubs:")

    inline_count = 0
    for opcode in range(256):
        handler = HANDLERS[opcode]
        name = NAMES[opcode]

        if opcode in INLINE:
            # Inline stub: handler code embedded in the 16-byte slot
            insns, ret_label = INLINE[opcode]
            lines.append(f"/* 0x{opcode:02X}: {name} [INLINE] */")
            for insn in insns:
                formatted = insn.format(op=opcode)
                lines.append(f"        {formatted}")
            lines.append(f".Ls_{opcode:02X}: .long {ret_label}")
            inline_count += 1
        else:
            # Indirect stub: jump to external handler
            lines.append(f"/* 0x{opcode:02X}: {name} */")
            lines.append(f"        mov.l   .Ls_{opcode:02X}, r1")
            lines.append(f"        jmp     @r1")
            lines.append(f"        nop")
            lines.append(f"        nop")
            lines.append(f"        nop")
            lines.append(f"        nop")
            lines.append(f".Ls_{opcode:02X}: .long {handler}")

    lines.append("/* end of handler stubs */")
    lines.append(f"/* {inline_count} inline stubs, {256-inline_count} indirect stubs */")
    lines.append("")

    for line in lines:
        print(line)


if __name__ == "__main__":
    main()
