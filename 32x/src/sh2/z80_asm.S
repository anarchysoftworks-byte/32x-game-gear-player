/*
 * z80_asm.S — Z80 CPU emulator in native SH-2 assembly
 *
 * Complete Z80 implementation: main (256), CB (256), ED, DD/FD (all
 * IX/IY ops), and DDCB/FDCB (indexed rotate/shift/bit). No C fallback.
 *
 * Uses .S extension for C preprocessor (#define struct offsets).
 *
 * Register pinning (callee-saved, persist across C calls):
 *   R7  = Z80 PC (16-bit, zero-extended; synced to struct around C calls)
 *   R8  = Mem_Pages base pointer
 *   R9  = dispatch table pointer
 *   R10 = 0x1FFF page mask constant
 *   R11 = ICount (cycle counter)
 *   R12 = A register (pinned byte, zero-extended in bits 7:0)
 *   R13 = pc_base (Mem_Pages[page] - pc_page_start)
 *   R14 = z80_t *R pointer
 *
 * Dispatch: 16-bit signed offset table (512 bytes). Each handler
 * subtracts its own cycle cost from R11 at entry.
 *
 * Fetch paths:
 *   _z80_fetch    — sequential (no page check), used by non-branch ops
 *   _z80_fetch_bp — branch-protect (page boundary check + rebase)
 *
 * SH-2 addressing constraints:
 *   mov.l @(disp, Rn), Rm — disp 0..60 step 4, any Rm
 *   mov.w @(disp, Rn), R0 — disp 0..30 step 2, dest must be R0
 *   mov.w R0, @(disp, Rn) — disp 0..30 step 2, src must be R0
 *   mov.b @(disp, Rn), R0 — disp 0..15, dest must be R0
 *   mov.b R0, @(disp, Rn) — disp 0..15, src must be R0
 *   For offsets > limits, use add to compute address first.
 *
 * z80_t struct layout (big-endian, 44+4 bytes):
 *   0:  PC.W    2:  AF.W    4:  ICount(32)    8:  HL.W
 *   10: BC.W    12: DE.W    14: IFF(8) 15: R(8)
 *   16: SP.W    18: IX.W    20: IY.W   22: I(8) 23: R7(8)
 *   24: IBackup(32)  28: IPeriod(32)
 *   32: AF1.W   34: BC1.W   36: DE1.W  38: HL1.W
 *   40: IRequest(16) 42: IAutoReset(8) 43: TrapBadOps(8)
 *   44: PageStart(32)
 */

/* z80_t field offsets */
#define Z80_PC       0
#define Z80_AF       2
#define Z80_ICOUNT   4   /* 32-bit, 4-byte aligned — mov.l @(4,Rn) OK */
#define Z80_IFF      14
#define Z80_R        15
#define Z80_IBACKUP  24  /* 32-bit, 4-byte aligned — mov.l @(24,Rn) OK */
#define Z80_IREQUEST 40
#define Z80_PAGE_START 44  /* 32-bit, 4-byte aligned — mov.l @(44,Rn) OK */

/* IFF bit definitions */
#define IFF_EI   0x20
#define IFF_1    0x01
#define IFF_IM1  0x02
#define IFF_IM2  0x04
#define IFF_2    0x08
#define IFF_HALT 0x10

        .section .z80_code,"ax"
        .subsection 0
        .align 2
        .global _z80_run
        .global _z80_run_frame

/*
 * void z80_run_frame(z80_t *R, int cycles_per_line, int (*callback)(z80_t*))
 * R4 = z80_t pointer, R5 = cycles_per_line, R6 = callback function pointer
 *
 * Batched Z80 execution: runs until callback returns 0.
 * After each cycles_per_line of Z80 execution completes (ICount <= 0):
 *   1. Sync pinned state (A, PC, ICount) back to struct
 *   2. Call callback(R) — performs scanline housekeeping
 *   3. If callback returns 0: exit
 *   4. Otherwise: add cycles_per_line to ICount, reload state, continue
 * Single prologue/epilogue for entire batch.
 */
_z80_run_frame:
        mov.l   r8, @-r15
        mov.l   r9, @-r15
        mov.l   r10, @-r15
        mov.l   r11, @-r15
        mov.l   r12, @-r15
        mov.l   r13, @-r15
        mov.l   r14, @-r15
        sts.l   pr, @-r15
        mov.l   r6, @-r15      /* [SP+4] = callback fn ptr */
        bra     _z80_run_shared
        mov.l   r5, @-r15      /* [SP+0] = cycles_per_line (delay slot) */

/*
 * void z80_run(z80_t *R, int cycles)
 * R4 = z80_t pointer, R5 = cycle count to add
 */
_z80_run:
        /* Prologue: save callee-saved regs + PR */
        mov.l   r8, @-r15
        mov.l   r9, @-r15
        mov.l   r10, @-r15
        mov.l   r11, @-r15
        mov.l   r12, @-r15
        mov.l   r13, @-r15
        mov.l   r14, @-r15
        sts.l   pr, @-r15
        mov     #0, r0
        mov.l   r0, @-r15      /* [SP+4] = callback = NULL (non-batched) */
        mov.l   r0, @-r15      /* [SP+0] = cycles_per_line = 0 */

_z80_run_shared:
        mov     r4, r14         /* R14 = z80_t *R */

        /* R->ICount += cycles; pin result in R11 */
        mov.l   @(Z80_ICOUNT, r14), r11
        add     r5, r11

        /* Load constants into callee-saved regs */
        mov.l   .L_1fff, r10   /* R10 = 0x1FFF */
        mov.l   .L_mem_pages, r8
        mov.l   .L_handler_table, r9  /* R9 = handler jump table (256 × 4 bytes) */
        /* R12 = A register (pinned byte, zero-extended) */
        mov.b   @(2, r14), r0
        extu.b  r0, r12

        /* Pin PC in R7 and do initial page rebase */
        mov.w   @r14, r7       /* R7 = PC (pinned for entire run) */
        bsr     _do_rebase_pc
        extu.w  r7, r7 /* delay slot */

/* ================================================================ */
/*  Main fetch loop — JUMP TABLE DISPATCH                           */
/*                                                                  */
/*  Two entry points:                                               */
/*    _z80_fetch    — sequential (DEFAULT): no page check.          */
/*                    All non-branch handlers return here.          */
/*    _z80_fetch_bp — branch-protect: page check + rebase.          */
/*                    Only JP/JR/CALL/RET/RST handlers return here. */
/*                                                                  */
/*  Dispatch: opcode × 4 → index into handler address table (R9).  */
/*  Table is 256 × 4 bytes (1KB). Each entry is a 32-bit handler   */
/*  address. With OD=1, table reads are data (bypass I-cache),     */
/*  freeing cache for handler instruction code.                     */
/*                                                                  */
/*  Register allocation:                                            */
/*    R7  = PC (16-bit, pinned)                                     */
/*    R8  = Mem_Pages base                                          */
/*    R9  = handler address table base (pinned)                     */
/*    R10 = 0x1FFF page mask                                        */
/*    R11 = ICount                                                  */
/*    R12 = A register (pinned byte)                                */
/*    R13 = pc_base                                                 */
/*    R14 = z80_t *                                                 */
/*    z80_t[44] = pc_page_start (in struct, not stack)              */
/* ================================================================ */

/* ---- Sequential fast path: no page check ---- */
        .align 4              /* 16-byte cache line alignment */
_z80_fetch:
        cmp/pl  r11
        bf      _z80_exit_check
        /* Fetch opcode byte — use R0 for indexed table addressing */
        mov     r7, r0
        add     r13, r0
        mov.b   @r0, r0
        add     #1, r7          /* interleave: avoid load-use stall on r0 */
        extu.b  r0, r0
        /* Jump table dispatch: opcode × 4 → table[opcode] */
        mov     r0, r5          /* save opcode for generic handlers */
#if PERF_DEBUG
        /* per-opcode histogram bump (u16 saturating).
         * Clobbers r1,r2,r3. r0 still holds opcode for shll2 below. */
        mov     r0, r2
        shll    r2                    /* r2 = opcode*2 (u16 index) */
        mov.l   .L_op_hist, r1
        add     r2, r1
        mov.w   @r1, r3
        add     #1, r3
        mov.w   r3, @r1
#endif
        shll2   r0              /* ×4 (table entry size) */
        mov.l   @(r0, r9), r1   /* r1 = handler address from table */
        jmp     @r1
        extu.w  r7, r7          /* delay slot: mask PC to 16 bits */

/* ---- Branch-protect path: page check then fetch ---- */
        .align 4              /* 16-byte cache line alignment */
_z80_fetch_bp:
        cmp/pl  r11
        bf      _z80_exit_check
        /* Page boundary check: (PC - page_start) > 0x1FFF?
         * R10 is pinned to 0x1FFF, so cmp/hi R10, R1 replaces:
         *   extu.w + mov #0x20 + shll8 + cmp/hs (saves 3 instr/branch). */
        mov.l   @(Z80_PAGE_START, r14), r2
        mov     r7, r1
        sub     r2, r1
        cmp/hi  r10, r1
        bt      _z80_rebase_and_fetch
        .align 4              /* 16-byte cache line alignment */
_z80_do_fetch:
        /* Fetch opcode byte — use R0 for indexed table addressing */
        mov     r7, r0
        add     r13, r0
        mov.b   @r0, r0
        add     #1, r7          /* interleave: avoid load-use stall on r0 */
        extu.b  r0, r0
        /* Jump table dispatch: opcode × 4 → table[opcode] */
        mov     r0, r5          /* save opcode for generic handlers */
#if PERF_DEBUG
        /* per-opcode histogram bump (u16 saturating). */
        mov     r0, r2
        shll    r2                    /* r2 = opcode*2 (u16 index) */
        mov.l   .L_op_hist, r1
        add     r2, r1
        mov.w   @r1, r3
        add     #1, r3
        mov.w   r3, @r1
#endif
        shll2   r0              /* ×4 (table entry size) */
        mov.l   @(r0, r9), r1   /* r1 = handler address from table */
        jmp     @r1
        extu.w  r7, r7          /* delay slot: mask PC to 16 bits */

/* ---------------------------------------------------------------- */
/*  Page rebase then re-fetch                                       */
/* ---------------------------------------------------------------- */
_z80_rebase_and_fetch:
        bsr     _do_rebase_pc
        nop
        bra     _z80_do_fetch
        nop

/* ---------------------------------------------------------------- */
/*  Rebase subroutine: compute pc_base (R13) and save page_start   */
/*  to z80_t struct at offset Z80_PAGE_START (44).                  */
/*  R12 is NOT modified (holds pinned A register).                  */
/*  Clobbers: r0, r1, r2, r3                                       */
/* ---------------------------------------------------------------- */
_do_rebase_pc:
        mov     r7, r0         /* PC from R7 (pinned register) */

        /* pc_page_start = PC & ~0x1FFF */
        mov     r0, r2         /* r2 will hold pc_page_start */
        mov     r10, r1
        not     r1, r1         /* r1 = ~0x1FFF (0xFFFFE000) */
        and     r1, r2         /* r2 = pc_page_start */

        /* Save pc_page_start to z80_t struct */
        mov.l   r2, @(Z80_PAGE_START, r14)

        /* page_index × 4 = (PC >> 11) & 0x1C */
        mov     r0, r1
        shlr8   r1
        shlr2   r1
        shlr    r1             /* r1 = PC >> 11 */
        mov     #0x1C, r3
        and     r3, r1         /* r1 = (page_index 0-7) × 4 */
        add     r8, r1
        mov.l   @r1, r13
        rts
        sub     r2, r13        /* r13 = pc_base (uses r2 = page_start) (delay slot) */

/* ---------------------------------------------------------------- */
/*  Exit check: handle EI delayed interrupt                         */
/* ---------------------------------------------------------------- */
_z80_exit_check:
        /* Read IFF (offset 14) */
        mov.b   @(14, r14), r0
        extu.b  r0, r1
        mov     #IFF_EI, r2
        tst     r2, r1
        bt      _z80_exit      /* IFF_EI not set → exit */

        /* EI pending: clear IFF_EI, set IFF_1 */
        mov     #IFF_EI, r2
        not     r2, r2
        and     r2, r1         /* clear IFF_EI */
        mov     #IFF_1, r2
        or      r2, r1         /* set IFF_1 */
        mov     r14, r0
        add     #14, r0
        mov.b   r1, @r0

        /* ICount += IBackup - 1 (R11 = ICount) */
        mov     r14, r2
        add     #Z80_IBACKUP, r2
        mov.l   @r2, r3        /* IBackup */
        add     r3, r11
        add     #-1, r11

        /* Check IRequest != 0xFFFF (offset 40) */
        mov     r14, r0
        add     #Z80_IREQUEST, r0
        mov.w   @r0, r0
        extu.w  r0, r0
        mov.l   .L_ffff, r1
        cmp/eq  r0, r1
        bt      _z80_fetch     /* no IRQ pending → seq path OK */

        /* Deliver interrupt — PC may change, need branch-protect */
        mov.w   r7, @r14                  /* sync PC to struct */
        mov.l   r11, @(Z80_ICOUNT, r14)  /* sync ICount to struct */
        mov     r0, r5                    /* r5 = IRequest (save before sync clobbers r0) */
        mov     r12, r0
        mov.b   r0, @(2, r14)            /* sync A to struct */
        mov     r14, r4
        mov.l   .L_set_irq, r0
        jsr     @r0
        nop
        mov.w   @r14, r7                  /* reload PC (IRQ may change it) */
        extu.w  r7, r7
        bra     _z80_fetch_bp             /* use branch-protect path */
        mov.l   @(Z80_ICOUNT, r14), r11  /* reload ICount (delay slot) */

/* ---------------------------------------------------------------- */
/*  Epilogue / scanline boundary for batched mode                   */
/*                                                                  */
/*  Inline hot-path scanline tick.                        */
/*                                                                  */
/*  Hot path (most scanlines): ~20 SH-2 cycles inline               */
/*    - line < 192 (GG_Y_INT)                                       */
/*    - Lines_Left > 0 after decrement (no HBlank IRQ)              */
/*    - No NMI pending                                               */
/*  Cold path: falls through to C callback for IRQ/NMI/VBlank.      */
/*                                                                  */
/*  Global addresses loaded via literal pool (Pool B).               */
/*  Struct offsets (from host offsetof, SH-2 32-bit):               */
/*    gg_t:     VDP[0]=0, VDP[1]=1, VDP[8]=8, VDP[10]=10           */
/*              Lines_Left=24(i16), Pending_NMI=27(u8)              */
/*    tgg_t:    VDP_Line=0(i32)                                     */
/*    machine_t: VDP.scroll_x_latched=56(u8)                        */
/*                                                                  */
/*  Render command: 32-bit packed write to uncached SDRAM.           */
/*    bits 31-16: line, bits 15-8: scroll_x, bits 7-0: flags        */
/* ---------------------------------------------------------------- */

/* GG compile-time constants (must match main.c / gg_emu.h) */
#define GG_Y_INT            192
#define GG_RENDER_START     24
#define GG_RENDER_END       168
#define GG_CYCLES_PER_LINE  228

/* gg_t struct offsets */
#define GG_VDP1             1
#define GG_VDP8             8
#define GG_VDP10            10
#define GG_LINES_LEFT       24    /* int16_t */
#define GG_PENDING_NMI      27    /* uint8_t */

/* Render pipeline addresses (uncached SDRAM) */
#define RENDER_CMD_COUNT_ADDR  0x2603D000
#define RENDER_CMDS_ADDR       0x2603D100

/* Flags */
#define RCMD_F_DISPLAY_ON   0x01
#define VDP_REG1_DISPLAY_EN 0x40

_z80_exit:
        /* Check if batched mode (callback != NULL on stack) */
        mov.l   @(4, r15), r3  /* r3 = callback ptr (SP+4) */
        tst     r3, r3
        bt      _z80_final_exit /* NULL callback → normal z80_run, exit */

        /* ---- Inline hot-path scanline tick ---- */
        /*
         * Scratch regs available: r0-r6 (r7=PC, r8-r14=callee-saved/pinned)
         * r3 = callback ptr (saved for cold path)
         *
         * Strategy: check cheapest bail-outs first, inline the common
         * case, and fall through to C callback for any complexity.
         */

        /* Load frame_line */
        mov.l   .LB_frame_line, r1
        mov.l   @r1, r2         /* r2 = frame_line (also used later) */

        /* Check line < GG_Y_INT (192).  192 > 127 so use two-step. */
        mov     #96, r0
        shll    r0              /* r0 = 192 */
        cmp/ge  r0, r2
        bt      _z80_cold_path  /* line >= 192 → cold path (VBlank etc.) */

        /* Check Pending_NMI == 0 (offset 27 from gg base) */
        mov.l   .LB_gg, r4     /* r4 = &gg */
        mov     r4, r0
        add     #GG_PENDING_NMI, r0
        mov.b   @r0, r0
        tst     r0, r0
        bf      _z80_cold_path  /* NMI pending → cold path */

        /* Check Pending_HBlank == 0 (offset 26 from gg base).
         * HBlank may have been set on a previous line but not yet
         * delivered (HBlank_ON was off, now re-enabled). */
        mov     r4, r0
        add     #26, r0        /* GG_PENDING_HBLANK = 26 */
        mov.b   @r0, r0
        tst     r0, r0
        bf      _z80_cold_path  /* HBlank pending → cold path (needs IRQ check) */

        /* Decrement gg.Lines_Left (int16_t at offset 24).
         * If it goes < 0, HBlank counter expired → cold path.
         * Must undo decrement before cold path since C callback
         * also decrements Lines_Left. */
        mov     r4, r6          /* r6 = &gg (preserve for later) */
        add     #GG_LINES_LEFT, r6
        mov.w   @r6, r0         /* r0 = Lines_Left (sign-extended) */
        add     #-1, r0
        cmp/pz  r0
        bf      _z80_cold_path  /* Lines_Left-1 < 0 → HBlank, cold path (don't write back) */
        mov.w   r0, @r6         /* write back decremented value (only if >= 0) */

        /* ---- HOT PATH: no IRQ/NMI, line < 192 ---- */

        /* Write tgg.VDP_Line = line */
        mov.l   .LB_tgg, r5
        mov.l   r2, @r5         /* tgg.VDP_Line (offset 0) = line */

        /* Latch scroll_x: g_machine.VDP.scroll_x_latched = gg.VDP[8] */
        mov.b   @(GG_VDP8, r4), r0  /* r0 = gg.VDP[8] (disp=8, R0-only dest) */
        mov.l   .LB_g_machine, r5
        mov     r5, r6
        add     #56, r6         /* r6 = &g_machine + 56 = &scroll_x_latched */
        mov.b   r0, @r6         /* scroll_x_latched = gg.VDP[8] */
        mov     r0, r5          /* r5 = scroll_x (saved for render cmd) */

        /* Increment frame_line */
        add     #1, r2
        mov.l   r2, @r1         /* frame_line++ (r1 still = &frame_line) */

        /* Check if we need to post a render command:
         * !skip_render && line >= GG_RENDER_START && line < GG_RENDER_END
         * (Use original line = r2 - 1) */
        mov.l   .LB_skip_render, r6
        mov.l   @r6, r0
        tst     r0, r0
        bf      _z80_hot_no_render  /* skip_render != 0 → skip */

        add     #-1, r2         /* r2 = original line (before increment) */
        mov     #GG_RENDER_START, r0   /* 24 fits in signed 8-bit */
        cmp/ge  r0, r2
        bf      _z80_hot_done_render  /* line < 24 → no render */
        /* 168 > 127: can't use mov #imm directly (sign-extends to -88!) */
        mov     #(GG_RENDER_END / 2), r0
        shll    r0              /* r0 = 168 */
        cmp/ge  r0, r2
        bt      _z80_hot_done_render  /* line >= 168 → no render */

        /* Post render command:
         * Pack: (line << 16) | (scroll_x << 8) | flags
         * flags = (VDP[1] & 0x40) ? 1 : 0  (Display_ON → RCMD_F_DISPLAY_ON) */
        mov.b   @(GG_VDP1, r4), r0  /* r0 = gg.VDP[1] */
        mov     #VDP_REG1_DISPLAY_EN, r1
        tst     r1, r0
        movt    r0              /* r0 = 1 if Display_ON==0, 0 if set */
        xor     #1, r0          /* r0 = RCMD_F_DISPLAY_ON if display on, else 0 */
        /* Build packed cmd: r2=line, r5=scroll_x, r0=flags */
        extu.b  r5, r5          /* ensure clean byte */
        shll8   r5              /* scroll_x << 8 */
        or      r5, r0          /* r0 = (scroll_x << 8) | flags */
        extu.w  r2, r2          /* ensure clean 16-bit line */
        shll16  r2              /* line << 16 */
        or      r2, r0          /* r0 = packed cmd */

        /* Write to RENDER_CMDS[frame_cmd_idx] (4 bytes each) */
        mov.l   .LB_frame_cmd_idx, r1
        mov.l   @r1, r2         /* r2 = frame_cmd_idx */
        mov.l   .LB_render_cmds, r5
        mov     r2, r3
        shll2   r3              /* r3 = frame_cmd_idx * 4 */
        add     r3, r5          /* r5 = &RENDER_CMDS[frame_cmd_idx] */
        mov.l   r0, @r5         /* store packed cmd (uncached) */

        /* frame_cmd_idx++ */
        add     #1, r2
        mov.l   r2, @r1         /* write back */

        /* Publish RENDER_CMD_COUNT (stride=1, always publish) */
        mov.l   .LB_render_cmd_count, r5
        mov.w   r2, @r5         /* RENDER_CMD_COUNT = frame_cmd_idx (16-bit) */

_z80_hot_done_render:
        /* Restore r2 to new frame_line for the add-cycles path */
        /* (not needed — we just need to add cycles and continue) */

_z80_hot_no_render:
        /* Add cycles_per_line to ICount and continue */
        mov.l   @r15, r0       /* r0 = cycles_per_line (SP+0) */
        add     r0, r11        /* ICount += cycles_per_line */
        bra     _z80_fetch
        nop

/* ---- Cold path: sync state and call C callback ---- */
_z80_cold_path:
        /* Sync registers for C callback (z80_set_irq/nmi may modify them) */
        mov.w   r7, @r14                  /* sync PC to struct */
        mov.l   r11, @(Z80_ICOUNT, r14)  /* sync ICount to struct */

        /* Call callback(z80_t *R) — r3 still has callback ptr from above */
        sts.l   pr, @-r15
        jsr     @r3
        mov     r14, r4         /* delay slot: r4 = z80_t* */
        lds.l   @r15+, pr

        tst     r0, r0
        bt      _z80_exit_stop  /* callback returned 0 → sync A and exit */

        cmp/pz  r0
        bf      _z80_exit_irq   /* negative → IRQ/NMI dispatched */

        /* Common path: no IRQ/NMI, PC unchanged in struct.
         * R11 (ICount) and R12 (A) are callee-saved → still valid.
         * R7 is CALLER-SAVED → clobbered by C callback, must reload. */
        add     r0, r11
        mov.w   @r14, r7                  /* reload PC from struct */
        bra     _z80_fetch                /* fast fetch: PC on same page */
        extu.w  r7, r7                    /* delay slot */

_z80_exit_irq:
        /* IRQ or NMI dispatched: PC/ICount/SP modified in struct.
         * Negate return value to get positive cycle count. */
        neg     r0, r0
        mov.l   @(Z80_ICOUNT, r14), r11  /* reload ICount (z80_set_irq subtracted cycles) */
        add     r0, r11
        mov.w   @r14, r7                  /* reload PC (now points to ISR vector) */
        bra     _z80_fetch_bp             /* branch-protect: ISR may be on different page */
        extu.w  r7, r7                    /* delay slot */

_z80_exit_stop:
        /* Frame complete: sync A (not synced before callback) and exit */
        mov     r12, r0
        bra     _z80_batch_done
        mov.b   r0, @(2, r14)            /* delay slot: sync A */

_z80_final_exit:
        /* Normal z80_run exit: sync pinned state to struct */
        mov     r12, r0
        mov.b   r0, @(2, r14)            /* sync A back to struct */
        mov.w   r7, @r14                  /* sync PC back to struct */
        mov.l   r11, @(Z80_ICOUNT, r14)  /* store ICount back to struct */

_z80_batch_done:
        /* Common exit: pop stack frame and restore callee-saved regs */
        add     #8, r15        /* pop cycles_per_line + callback */
        lds.l   @r15+, pr
        mov.l   @r15+, r14
        mov.l   @r15+, r13
        mov.l   @r15+, r12
        mov.l   @r15+, r11
        mov.l   @r15+, r10
        mov.l   @r15+, r9
        rts
        mov.l   @r15+, r8 /* delay slot */

/* ================================================================ */
/*  Pool A — literal pool for fetch loop and exit check.            */
/*  Must be within 1024 bytes FORWARD of references above.          */
/* ================================================================ */
        .align 2
.L_1fff:
        .long   0x00001FFF
.L_ffff:
        .long   0x0000FFFF
.L_mem_pages:
        .long   _Mem_Pages
.L_set_irq:
        .long   _z80_set_irq + 0x20000000
.L_handler_table:
        .long   _z80_handler_table
#if PERF_DEBUG
.L_op_hist:
        .long   _g_op_hist
#endif

/* ================================================================ */
/*  Pool B — literal pool for inline hot-path scanline tick.        */
/*  References: .LB_* labels used by _z80_exit hot path above.      */
/* ================================================================ */
        .align 2
.LB_frame_line:
        .long   _frame_line
.LB_gg:
        .long   _gg
.LB_tgg:
        .long   _tgg
.LB_g_machine:
        .long   _g_machine
.LB_skip_render:
        .long   _skip_render
.LB_frame_cmd_idx:
        .long   _frame_cmd_idx
.LB_render_cmds:
        .long   RENDER_CMDS_ADDR
.LB_render_cmd_count:
        .long   RENDER_CMD_COUNT_ADDR

/* ================================================================ */
/*  Inline opcode handlers                                          */
/*                                                                  */
/*  Each handler reached via JMP from dispatch table.               */
/*  r5 = opcode (set in dispatch delay slot).                       */
/*  Callee-saved R8-R14 intact. R0-R6 scratch. R7=PC (pinned).      */
/*  Each handler ends with BRA _z80_fetch.                          */
/* ================================================================ */

/* ---- NOP (0x00) ---- */
_z80_op_nop:
        bra     _z80_fetch
        add     #-4, r11        /* delay slot */

/* ---- EX AF,AF' (0x08) ---- */
_z80_op_exafaf:
        add     #-4, r11
        /* Build AF word from pinned A (R12) and F (struct) */
        mov     r12, r1
        shll8   r1
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        or      r0, r1          /* r1 = current AF */
        /* Swap with AF1 (offset 32) */
        mov     r14, r2
        add     #32, r2
        mov.w   @r2, r3          /* r3 = AF1 */
        mov.w   r1, @r2          /* AF1 = old AF */
        /* Extract new A and F from swapped AF1 */
        mov     r3, r12
        shlr8   r12
        extu.b  r12, r12        /* R12 = new A */
        mov     r14, r0
        add     #3, r0
        bra     _z80_fetch
        mov.b   r3, @r0 /* delay slot: new F = low byte of AF1 */

/* ================================================================ */
/*  LD r,r — Specialized per-register stubs               */
/*  Eliminates BOTH RegOffsetsSrc and RegOffsetsDst lookups + A sync */
/*  Each stub is 4 instructions (same-reg NOPs: 2 instructions).    */
/*  Struct offsets: B=10 C=11 D=12 E=13 H=8 L=9 A=pinned R12      */
/* ================================================================ */

/* LD B,r */
_z80_ld_b_b:
        bra     _z80_fetch
        add     #-4, r11        /* delay slot */
_z80_ld_b_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(10, r14)  /* delay slot */
_z80_ld_b_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(10, r14)  /* delay slot */
_z80_ld_b_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(10, r14)  /* delay slot */
_z80_ld_b_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(10, r14)  /* delay slot */
_z80_ld_b_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(10, r14)  /* delay slot */
_z80_ld_b_a:
        mov     r12, r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(10, r14)  /* delay slot */

/* LD C,r */
_z80_ld_c_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(11, r14)  /* delay slot */
_z80_ld_c_c:
        bra     _z80_fetch
        add     #-4, r11        /* delay slot */
_z80_ld_c_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(11, r14)  /* delay slot */
_z80_ld_c_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(11, r14)  /* delay slot */
_z80_ld_c_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(11, r14)  /* delay slot */
_z80_ld_c_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(11, r14)  /* delay slot */
_z80_ld_c_a:
        mov     r12, r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(11, r14)  /* delay slot */

/* LD D,r */
_z80_ld_d_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(12, r14)  /* delay slot */
_z80_ld_d_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(12, r14)  /* delay slot */
_z80_ld_d_d:
        bra     _z80_fetch
        add     #-4, r11        /* delay slot */
_z80_ld_d_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(12, r14)  /* delay slot */
_z80_ld_d_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(12, r14)  /* delay slot */
_z80_ld_d_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(12, r14)  /* delay slot */
_z80_ld_d_a:
        mov     r12, r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(12, r14)  /* delay slot */

/* LD E,r */
_z80_ld_e_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(13, r14)  /* delay slot */
_z80_ld_e_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(13, r14)  /* delay slot */
_z80_ld_e_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(13, r14)  /* delay slot */
_z80_ld_e_e:
        bra     _z80_fetch
        add     #-4, r11        /* delay slot */
_z80_ld_e_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(13, r14)  /* delay slot */
_z80_ld_e_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(13, r14)  /* delay slot */
_z80_ld_e_a:
        mov     r12, r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(13, r14)  /* delay slot */

/* LD H,r */
_z80_ld_h_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(8, r14)   /* delay slot */
_z80_ld_h_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(8, r14)   /* delay slot */
_z80_ld_h_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(8, r14)   /* delay slot */
_z80_ld_h_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(8, r14)   /* delay slot */
_z80_ld_h_h:
        bra     _z80_fetch
        add     #-4, r11        /* delay slot */
_z80_ld_h_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(8, r14)   /* delay slot */
_z80_ld_h_a:
        mov     r12, r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(8, r14)   /* delay slot */

/* LD L,r */
_z80_ld_l_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(9, r14)   /* delay slot */
_z80_ld_l_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(9, r14)   /* delay slot */
_z80_ld_l_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(9, r14)   /* delay slot */
_z80_ld_l_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(9, r14)   /* delay slot */
_z80_ld_l_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(9, r14)   /* delay slot */
_z80_ld_l_l:
        bra     _z80_fetch
        add     #-4, r11        /* delay slot */
_z80_ld_l_a:
        mov     r12, r0
        add     #-4, r11
        bra     _z80_fetch
        mov.b   r0, @(9, r14)   /* delay slot */

/* LD A,r */
_z80_ld_a_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        extu.b  r0, r12         /* delay slot: A = src via pinned R12 */
_z80_ld_a_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        extu.b  r0, r12         /* delay slot */
_z80_ld_a_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        extu.b  r0, r12         /* delay slot */
_z80_ld_a_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        extu.b  r0, r12         /* delay slot */
_z80_ld_a_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        extu.b  r0, r12         /* delay slot */
_z80_ld_a_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_fetch
        extu.b  r0, r12         /* delay slot */
_z80_ld_a_a:
        bra     _z80_fetch
        add     #-4, r11        /* delay slot */

/* ---- LD r,n generic (0x06,0x0E,0x16,0x1E,0x26,0x2E,0x3E) ---- */
_z80_ld_r_n:
        add     #-7, r11
        mov     r12, r0
        mov.b   r0, @(2, r14)  /* sync A to struct (generic handler) */
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3

        /* Dst: RegOffsetsDst[opcode] → struct offset → write value */
        mov     r5, r0
        mov.l   .La2_reg_dst, r1
        mov.b   @(r0, r1), r0
        extu.b  r0, r0
        mov     r14, r1
        add     r0, r1
        mov.b   r3, @r1
        /* reload A from struct (dst may be A) */
        mov.b   @(2, r14), r0
        bra     _z80_fetch
        extu.b  r0, r12 /* delay slot */

/* ---- Inline GG memory read subroutine ---- */
_inline_gg_read:
        mov     r4, r0          /* addr */
        shlr8   r0              /* >>8 */
        shlr2   r0              /* >>10 */
        shlr    r0              /* >>11 (was >>13 via 5 shifts) */
        mov     #0x1C, r2       /* page*4 mask = bits [4:2] of addr>>11 */
        and     r2, r0          /* r0 = (addr>>11)&0x1C = page*4 */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base */
        mov     r4, r0          /* addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        rts
        extu.b  r0, r0 /* delay slot */

/* ================================================================ */
/*  INC/DEC register pairs (16-bit, no flags)                       */
/* ================================================================ */

_z80_inc_bc:
        add     #-6, r11
        mov.w   @(10, r14), r0
        add     #1, r0
        bra     _z80_fetch
        mov.w   r0, @(10, r14)

_z80_dec_bc:
        add     #-6, r11
        mov.w   @(10, r14), r0
        add     #-1, r0
        bra     _z80_fetch
        mov.w   r0, @(10, r14)

_z80_inc_de:
        add     #-6, r11
        mov.w   @(12, r14), r0
        add     #1, r0
        bra     _z80_fetch
        mov.w   r0, @(12, r14)

_z80_dec_de:
        add     #-6, r11
        mov.w   @(12, r14), r0
        add     #-1, r0
        bra     _z80_fetch
        mov.w   r0, @(12, r14)

_z80_inc_hl:
        add     #-6, r11
        mov.w   @(8, r14), r0
        add     #1, r0
        bra     _z80_fetch
        mov.w   r0, @(8, r14)

_z80_dec_hl:
        add     #-6, r11
        mov.w   @(8, r14), r0
        add     #-1, r0
        bra     _z80_fetch
        mov.w   r0, @(8, r14)

_z80_inc_sp:
        add     #-6, r11
        mov.w   @(16, r14), r0
        add     #1, r0
        bra     _z80_fetch
        mov.w   r0, @(16, r14)

_z80_dec_sp:
        add     #-6, r11
        mov.w   @(16, r14), r0
        add     #-1, r0
        bra     _z80_fetch
        mov.w   r0, @(16, r14)

/* ================================================================ */
/*  INC r — Specialized per-register stubs                */
/*  Eliminates RegOffsetsDst lookup + A-sync overhead.              */
/*  Non-A stubs branch to _z80_inc_common (R12 untouched).          */
/*  INC A inlines the logic and reloads pinned R12 at the end.      */
/*  Struct offsets: B=10 C=11 D=12 E=13 H=8 L=9 A=2(pinned R12)  */
/* ================================================================ */

_z80_inc_b_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_inc_common
        add     #10, r6         /* delay slot: r6 = &z80.B */
_z80_inc_c_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_inc_common
        add     #11, r6         /* delay slot: r6 = &z80.C */
_z80_inc_d_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_inc_common
        add     #12, r6         /* delay slot: r6 = &z80.D */
_z80_inc_e_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_inc_common
        add     #13, r6         /* delay slot: r6 = &z80.E */
_z80_inc_h_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_inc_common
        add     #8, r6          /* delay slot: r6 = &z80.H */
_z80_inc_l_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_inc_common
        add     #9, r6          /* delay slot: r6 = &z80.L */
/* INC common (non-A): r6 = &struct.reg, R12 NOT touched */
_z80_inc_common:
        mov.b   @r6, r0                /* r0 = old value */
        mov.l   .La2_incflags, r1      /* r1 = IncFlags base */
        add     #1, r0                  /* r0 = result */
        mov.b   r0, @r6                /* store result byte */
        extu.b  r0, r0                  /* r0 = result & 0xFF */
        mov.b   @(r0, r1), r3          /* r3 = IncFlags[result] */
        mov.b   @(3, r14), r0          /* r0 = old F */
        and     #1, r0                  /* r0 = old carry */
        or      r3, r0                  /* r0 = new F */
        bra     _z80_fetch
        mov.b   r0, @(3, r14)          /* store new F (delay slot) */

/* INC A: sync pinned A → struct, increment, reload into R12 */
_z80_inc_a_spec:
        add     #-4, r11
        mov     r12, r0
        mov.b   r0, @(2, r14)          /* sync A to struct */
        mov     r14, r6
        add     #2, r6                  /* r6 = &z80.A */
        mov.b   @r6, r0
        mov.l   .La2_incflags, r1
        add     #1, r0
        mov.b   r0, @r6
        extu.b  r0, r0
        mov.b   @(r0, r1), r3
        mov.b   @(3, r14), r0
        and     #1, r0
        or      r3, r0
        mov.b   r0, @(3, r14)
        mov.b   @(2, r14), r0          /* reload new A */
        bra     _z80_fetch
        extu.b  r0, r12                /* delay slot: update pinned A */

/* ================================================================ */
/*  DEC r — Specialized per-register stubs                */
/* ================================================================ */

_z80_dec_b_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_dec_common
        add     #10, r6         /* delay slot: r6 = &z80.B */
_z80_dec_c_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_dec_common
        add     #11, r6         /* delay slot: r6 = &z80.C */
_z80_dec_d_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_dec_common
        add     #12, r6         /* delay slot: r6 = &z80.D */
_z80_dec_e_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_dec_common
        add     #13, r6         /* delay slot: r6 = &z80.E */
_z80_dec_h_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_dec_common
        add     #8, r6          /* delay slot: r6 = &z80.H */
_z80_dec_l_spec:
        mov     r14, r6
        add     #-4, r11
        bra     _z80_dec_common
        add     #9, r6          /* delay slot: r6 = &z80.L */
/* DEC common (non-A): r6 = &struct.reg, R12 NOT touched */
_z80_dec_common:
        mov.b   @r6, r0                /* r0 = old value */
        mov.l   .La2_decflags, r1      /* r1 = DecFlags base */
        add     #-1, r0                /* r0 = result */
        mov.b   r0, @r6                /* store result byte */
        extu.b  r0, r0                  /* r0 = result & 0xFF */
        mov.b   @(r0, r1), r3          /* r3 = DecFlags[result] */
        mov.b   @(3, r14), r0          /* r0 = old F */
        and     #1, r0                  /* r0 = old carry */
        or      r3, r0                  /* r0 = new F */
        bra     _z80_fetch
        mov.b   r0, @(3, r14)          /* store new F (delay slot) */

/* DEC A: sync pinned A → struct, decrement, reload into R12 */
_z80_dec_a_spec:
        add     #-4, r11
        mov     r12, r0
        mov.b   r0, @(2, r14)          /* sync A to struct */
        mov     r14, r6
        add     #2, r6                  /* r6 = &z80.A */
        mov.b   @r6, r0
        mov.l   .La2_decflags, r1
        add     #-1, r0
        mov.b   r0, @r6
        extu.b  r0, r0
        mov.b   @(r0, r1), r3
        mov.b   @(3, r14), r0
        and     #1, r0
        or      r3, r0
        mov.b   r0, @(3, r14)
        mov.b   @(2, r14), r0          /* reload new A */
        bra     _z80_fetch
        extu.b  r0, r12                /* delay slot: update pinned A */

/* ================================================================ */
/*  AND/OR/XOR A,r — Specialized register stubs           */
/*  Each stub loads the source register directly, eliminating the   */
/*  10-instruction RegOffsetsSrc lookup + A-sync overhead.          */
/*  Struct offsets: B=10 C=11 D=12 E=13 H=8 L=9 A=pinned R12      */
/*  Saves ~8 SH-2 cycles per instruction vs generic handler.        */
/* ================================================================ */

/* --- AND A,<reg> stubs --- */
_z80_and_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_and_common
        extu.b  r0, r3          /* delay slot */
_z80_and_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_and_common
        extu.b  r0, r3          /* delay slot */
_z80_and_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_and_common
        extu.b  r0, r3          /* delay slot */
_z80_and_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_and_common
        extu.b  r0, r3          /* delay slot */
_z80_and_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_and_common
        extu.b  r0, r3          /* delay slot */
_z80_and_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_and_common
        extu.b  r0, r3          /* delay slot */
_z80_and_a_spec:
        add     #-4, r11
        bra     _z80_and_common
        mov     r12, r3         /* delay slot: A from pinned R12 */
/* AND common: r3 = src value */
_z80_and_common:
        mov.l   .La2_pzstable, r1       /* LOAD pool early (gap before use) */
        mov     r12, r0
        and     r3, r0                  /* r0 = A & src */
        mov     r0, r12                 /* pinned A updated */
        mov.b   @(r0, r1), r0          /* PZSTable[result] (r1 ready, no stall) */
        mov     #0x10, r1              /* H flag (interleave: hides r0 load-use) */
        or      r1, r0                 /* flags | H (r0 avail, 1 gap, no stall) */
        bra     _z80_fetch
        mov.b   r0, @(3, r14)          /* F (delay slot) */

/* --- OR A,<reg> stubs --- */
_z80_or_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_or_common
        extu.b  r0, r3          /* delay slot */
_z80_or_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_or_common
        extu.b  r0, r3          /* delay slot */
_z80_or_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_or_common
        extu.b  r0, r3          /* delay slot */
_z80_or_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_or_common
        extu.b  r0, r3          /* delay slot */
_z80_or_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_or_common
        extu.b  r0, r3          /* delay slot */
_z80_or_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_or_common
        extu.b  r0, r3          /* delay slot */
_z80_or_a_spec:
        add     #-4, r11
        bra     _z80_or_common
        mov     r12, r3         /* delay slot */
/* OR common: r3 = src value */
_z80_or_common:
        mov.l   .La2_pzstable, r1       /* LOAD pool early (gap before use) */
        mov     r12, r0
        or      r3, r0                  /* r0 = A | src */
        mov     r0, r12                 /* pinned A updated */
        mov.b   @(r0, r1), r0          /* PZSTable[result] (r1 ready, no stall) */
        bra     _z80_fetch             /* (interleave: hides r0 load-use) */
        mov.b   r0, @(3, r14)          /* F (delay slot, r0 avail, 1 gap) */

/* --- XOR A,<reg> stubs --- */
_z80_xor_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_xor_common
        extu.b  r0, r3          /* delay slot */
_z80_xor_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_xor_common
        extu.b  r0, r3          /* delay slot */
_z80_xor_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_xor_common
        extu.b  r0, r3          /* delay slot */
_z80_xor_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_xor_common
        extu.b  r0, r3          /* delay slot */
_z80_xor_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_xor_common
        extu.b  r0, r3          /* delay slot */
_z80_xor_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_xor_common
        extu.b  r0, r3          /* delay slot */
_z80_xor_a_spec:
        add     #-4, r11
        bra     _z80_xor_common
        mov     r12, r3         /* delay slot */
/* XOR common: r3 = src value */
_z80_xor_common:
        mov.l   .La2_pzstable, r1       /* LOAD pool early (gap before use) */
        mov     r12, r0
        xor     r3, r0                  /* r0 = A ^ src */
        mov     r0, r12                 /* pinned A updated */
        mov.b   @(r0, r1), r0          /* PZSTable[result] (r1 ready, no stall) */
        bra     _z80_fetch             /* (interleave: hides r0 load-use) */
        mov.b   r0, @(3, r14)          /* F (delay slot, r0 avail, 1 gap) */

/* ================================================================ */
/*  Pool A2 — literal pool for inline opcode handlers.              */
/*  Must be AFTER the code that references it (SH-2 = forward-only) */
/* ================================================================ */
        .align 2
.La2_reg_offsets:
        .long   _z80_reg_offsets
.La2_zstable:
        .long   _ZSTable
.La2_pzstable:
        .long   _PZSTable
.La2_incflags:
        .long   _IncFlags
.La2_decflags:
        .long   _DecFlags
.La2_reg_dst:
        .long   _RegOffsetsDst
.La2_reg_src:
        .long   _RegOffsetsSrc

/* ================================================================ */
/*  LD r,(HL) — specialized per-register handlers          */
/*  Each reads byte at HL and stores directly to the target reg,    */
/*  eliminating the RegOffsetsDst lookup + A sync overhead.          */
/*  Struct offsets: B=10 C=11 D=12 E=13 H=8 L=9 A=pinned R12      */
/* ================================================================ */

/* LD B,(HL) — opcode 0x46 */
_z80_ld_b_xhl:
        add     #-7, r11
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4          /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        bra     _z80_fetch
        mov.b   r0, @(10, r14)  /* delay slot: store to B */

/* LD C,(HL) — opcode 0x4E */
_z80_ld_c_xhl:
        add     #-7, r11
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4          /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        bra     _z80_fetch
        mov.b   r0, @(11, r14)  /* delay slot: store to C */

/* LD D,(HL) — opcode 0x56 */
_z80_ld_d_xhl:
        add     #-7, r11
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4          /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        bra     _z80_fetch
        mov.b   r0, @(12, r14)  /* delay slot: store to D */

/* LD E,(HL) — opcode 0x5E */
_z80_ld_e_xhl:
        add     #-7, r11
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4          /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        bra     _z80_fetch
        mov.b   r0, @(13, r14)  /* delay slot: store to E */

/* LD H,(HL) — opcode 0x66 */
_z80_ld_h_xhl:
        add     #-7, r11
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4          /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        bra     _z80_fetch
        mov.b   r0, @(8, r14)   /* delay slot: store to H */

/* LD L,(HL) — opcode 0x6E */
_z80_ld_l_xhl:
        add     #-7, r11
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4          /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        bra     _z80_fetch
        mov.b   r0, @(9, r14)   /* delay slot: store to L */

/* LD A,(HL) — opcode 0x7E */
_z80_ld_a_xhl:
        add     #-7, r11
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4          /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        bra     _z80_fetch
        extu.b  r0, r12         /* delay slot: A = read value (pinned R12) */

/* Generic LD r,(HL) — kept for DD/FD prefix use (IX/IY+d) */
_z80_ld_r_xhl:
        add     #-7, r11
        mov     r12, r0
        mov.b   r0, @(2, r14)  /* sync A to struct (generic handler) */
        /* Read byte at HL address */
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3          /* r3 = read value */

        /* Destination register index = bits 5-3 of opcode */
        /* Dst: RegOffsetsDst[opcode] → struct offset → write value */
        mov     r5, r0
        mov.l   .Lb_reg_dst, r1
        mov.b   @(r0, r1), r0
        extu.b  r0, r0
        mov     r14, r1
        add     r0, r1
        mov.b   r3, @r1
        /* reload A from struct (dst may be A) */
        mov.b   @(2, r14), r0
        bra     _z80_fetch
        extu.b  r0, r12 /* delay slot */

/* Local literal pool: .Lb_reg_dst is referenced only by _z80_ld_r_xhl
   above; keeping it adjacent keeps the forward-only mov.l in range after
   the inlined read body was inserted into this handler. */
.p2align 2
.Lb_reg_dst:
        .long   _RegOffsetsDst

/* ================================================================ */
/*  LD (HL),r — specialized per-register handlers          */
/*  Each reads the source register directly and writes to (HL),     */
/*  eliminating the RegOffsetsSrc lookup + A sync overhead.          */
/*  Struct offsets: B=10 C=11 D=12 E=13 H=8 L=9 A=pinned R12      */
/* ================================================================ */

/* LD (HL),B — opcode 0x70 */
_z80_ld_xhl_b:
        mov.b   @(10, r14), r0  /* B */
        extu.b  r0, r5          /* r5 = value */
        mov.w   @(8, r14), r0   /* HL */
        bsr     _inline_gg_write
        extu.w  r0, r4          /* delay slot: r4 = addr */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

/* LD (HL),C — opcode 0x71 */
_z80_ld_xhl_c:
        mov.b   @(11, r14), r0  /* C */
        extu.b  r0, r5          /* r5 = value */
        mov.w   @(8, r14), r0   /* HL */
        bsr     _inline_gg_write
        extu.w  r0, r4          /* delay slot: r4 = addr */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

/* LD (HL),D — opcode 0x72 */
_z80_ld_xhl_d:
        mov.b   @(12, r14), r0  /* D */
        extu.b  r0, r5          /* r5 = value */
        mov.w   @(8, r14), r0   /* HL */
        bsr     _inline_gg_write
        extu.w  r0, r4          /* delay slot: r4 = addr */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

/* LD (HL),E — opcode 0x73 */
_z80_ld_xhl_e:
        mov.b   @(13, r14), r0  /* E */
        extu.b  r0, r5          /* r5 = value */
        mov.w   @(8, r14), r0   /* HL */
        bsr     _inline_gg_write
        extu.w  r0, r4          /* delay slot: r4 = addr */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

/* LD (HL),H — opcode 0x74 */
_z80_ld_xhl_h:
        mov.b   @(8, r14), r0   /* H */
        extu.b  r0, r5          /* r5 = value */
        mov.w   @(8, r14), r0   /* HL */
        bsr     _inline_gg_write
        extu.w  r0, r4          /* delay slot: r4 = addr */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

/* LD (HL),L — opcode 0x75 */
_z80_ld_xhl_l:
        mov.b   @(9, r14), r0   /* L */
        extu.b  r0, r5          /* r5 = value */
        mov.w   @(8, r14), r0   /* HL */
        bsr     _inline_gg_write
        extu.w  r0, r4          /* delay slot: r4 = addr */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

/* LD (HL),A — opcode 0x77 */
_z80_ld_xhl_a:
        mov     r12, r5          /* A (pinned in R12) */
        mov.w   @(8, r14), r0   /* HL */
        bsr     _inline_gg_write
        extu.w  r0, r4          /* delay slot: r4 = addr */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

/* Generic LD (HL),r — kept for DD/FD prefix use (IX/IY+d) */
_z80_ld_xhl_r:
        mov     r12, r0
        mov.b   r0, @(2, r14)  /* sync A to struct (generic handler) */
        /* Src: RegOffsetsSrc[opcode] → struct offset → read value */
        mov     r5, r0
        mov.l   .Lb_reg_src, r1
        mov.b   @(r0, r1), r0
        extu.b  r0, r0
        mov     r14, r1
        add     r0, r1
        mov.b   @r1, r3
        extu.b  r3, r3          /* r3 = src value */

        /* Get HL address */
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4          /* r4 = HL address */

        /* Write: r4=addr, r3=value → call _inline_gg_write */
        mov     r3, r5          /* r5 = value (param 2) */
        bsr     _inline_gg_write
        mov     r4, r4          /* r4 = addr (param 1) - delay slot nop equiv */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

/* ================================================================ */
/*  LD (xHL),n — write immediate to address HL (0x36)     */
/* ================================================================ */
_z80_ld_xhl_n:
        /* Read immediate byte at PC */
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3          /* r3 = immediate value */

        /* Get HL address */
        mov.w   @(8, r14), r0   /* HL */
        extu.w  r0, r4

        /* Write r3 to address r4 */
        bsr     _inline_gg_write
        mov     r3, r5 /* delay slot */
        bra     _z80_fetch
        add     #-10, r11       /* delay slot */

/* ================================================================ */
/*  LD A,(BC) / LD A,(DE) — indirect loads (0x0A, 0x1A)  */
/* ================================================================ */
_z80_ld_a_xbc:
        add     #-7, r11
        mov.w   @(10, r14), r0  /* BC */
        extu.w  r0, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        bra     _z80_fetch
        mov     r0, r12          /* A (delay slot, pinned in R12) */

_z80_ld_a_xde:
        add     #-7, r11
        mov.w   @(12, r14), r0  /* DE */
        extu.w  r0, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        bra     _z80_fetch
        mov     r0, r12          /* A (delay slot, pinned in R12) */

/* ================================================================ */
/*  LD (BC),A / LD (DE),A — indirect stores (0x02, 0x12) */
/* ================================================================ */
_z80_ld_xbc_a:
        mov     r12, r5          /* A (pinned in R12) */
        mov.w   @(10, r14), r0  /* BC */
        bsr     _inline_gg_write
        extu.w  r0, r4 /* delay slot */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

_z80_ld_xde_a:
        mov     r12, r5          /* A (pinned in R12) */
        mov.w   @(12, r14), r0  /* DE */
        bsr     _inline_gg_write
        extu.w  r0, r4 /* delay slot */
        bra     _z80_fetch
        add     #-7, r11        /* delay slot */

/* ================================================================ */
/*  LD rr,nn — 16-bit immediate loads (0x01,0x11,0x21,0x31) */
/* ================================================================ */
_z80_ld_bc_nn:
        add     #-10, r11
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3          /* r3 = low byte */
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        /* r0 = high byte, r3 = low byte */
        shll8   r0
        or      r3, r0
        bra     _z80_fetch
        mov.w   r0, @(10, r14)  /* BC (delay slot) */

_z80_ld_de_nn:
        add     #-10, r11
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        shll8   r0
        or      r3, r0
        bra     _z80_fetch
        mov.w   r0, @(12, r14)  /* DE (delay slot) */

_z80_ld_hl_nn:
        add     #-10, r11
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        shll8   r0
        or      r3, r0
        bra     _z80_fetch
        mov.w   r0, @(8, r14)   /* HL (delay slot) */

_z80_ld_sp_nn:
        add     #-10, r11
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3
        mov     r7, r4
        add     #1, r7
        extu.w  r7, r7 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        shll8   r0
        or      r3, r0
        bra     _z80_fetch
        mov.w   r0, @(16, r14)  /* SP (delay slot) */

/* ================================================================ */
/*  LD SP,HL (0xF9) / LD PC,HL (0xE9, aka JP (HL))      */
/* ================================================================ */
_z80_ld_sp_hl:
        add     #-6, r11
        mov.w   @(8, r14), r0   /* HL */
        bra     _z80_fetch
        mov.w   r0, @(16, r14)  /* SP (delay slot) */

_z80_jp_hl:
        add     #-4, r11
        mov.w   @(8, r14), r0   /* HL */
        bra     _z80_fetch_bp
        extu.w  r0, r7           /* PC = HL (delay slot) */

/* ================================================================ */
/*  PUSH/POP register pairs                               */
/*  PUSH: SP--, write high; SP--, write low                        */
/*  POP:  read low, SP++; read high, SP++                          */
/*  Stack is always in RAM (0xC000+), use _inline_gg_write for    */
/*  PUSH (handles mapper traps at 0xFFFC+).                        */
/* ================================================================ */

/* PUSH BC (0xC5) */
_z80_push_bc:
        add     #-11, r11
        mov     r14, r0
        add     #10, r0
        mov.w   @r0, r3
        mov.w   @(16, r14), r0  /* SP */
        extu.w  r0, r4
        /* Push high byte */
        add     #-1, r4
        mov     r3, r5
        shlr8   r5
        bsr     _inline_gg_write
        extu.b  r5, r5 /* delay slot */ /* r5 = B */
        /* Push low byte */
        add     #-1, r4
        mov     r3, r5
        bsr     _inline_gg_write
        extu.b  r5, r5 /* delay slot */ /* r5 = C */
        /* Write SP back */
        mov     r14, r0
        add     #16, r0
        bra     _z80_fetch
        mov.w   r4, @r0 /* delay slot */

/* PUSH DE (0xD5) */
_z80_push_de:
        add     #-11, r11
        mov     r14, r0
        add     #12, r0
        mov.w   @r0, r3
        mov.w   @(16, r14), r0  /* SP */
        extu.w  r0, r4
        add     #-1, r4
        mov     r3, r5
        shlr8   r5
        bsr     _inline_gg_write
        extu.b  r5, r5 /* delay slot */
        add     #-1, r4
        mov     r3, r5
        bsr     _inline_gg_write
        extu.b  r5, r5 /* delay slot */
        mov     r14, r0
        add     #16, r0
        bra     _z80_fetch
        mov.w   r4, @r0 /* delay slot */

/* PUSH HL (0xE5) */
_z80_push_hl:
        add     #-11, r11
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r3
        mov.w   @(16, r14), r0  /* SP */
        extu.w  r0, r4
        add     #-1, r4
        mov     r3, r5
        shlr8   r5
        bsr     _inline_gg_write
        extu.b  r5, r5 /* delay slot */
        add     #-1, r4
        mov     r3, r5
        bsr     _inline_gg_write
        extu.b  r5, r5 /* delay slot */
        mov     r14, r0
        add     #16, r0
        bra     _z80_fetch
        mov.w   r4, @r0 /* delay slot */

/* PUSH AF (0xF5) */
_z80_push_af:
        add     #-11, r11
        /* Build AF word from R12 (A) and F (struct) */
        mov     r12, r3
        shll8   r3
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        or      r0, r3          /* r3 = AF word */
        mov.w   @(16, r14), r0  /* SP */
        extu.w  r0, r4
        add     #-1, r4
        mov     r3, r5
        shlr8   r5
        bsr     _inline_gg_write
        extu.b  r5, r5 /* delay slot */ /* r5 = A */
        add     #-1, r4
        mov     r3, r5
        bsr     _inline_gg_write
        extu.b  r5, r5 /* delay slot */ /* r5 = F */
        mov     r14, r0
        add     #16, r0
        bra     _z80_fetch
        mov.w   r4, @r0 /* delay slot */

/* POP BC (0xC1) */
_z80_pop_bc:
        add     #-10, r11
        mov.w   @(16, r14), r0  /* SP */
        /* Read low byte */
        extu.w  r0, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3          /* r3 = low (C) */
        /* Read high byte */
        add     #1, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        /* r0 = high (B), r3 = low (C) */
        shll8   r0
        or      r3, r0
        add     #1, r4
        mov.w   r0, @(10, r14)  /* BC = result */
        /* Write SP back */
        mov     r14, r0
        add     #16, r0
        bra     _z80_fetch
        mov.w   r4, @r0 /* delay slot */

/* POP DE (0xD1) */
_z80_pop_de:
        add     #-10, r11
        mov.w   @(16, r14), r0
        extu.w  r0, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3
        add     #1, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        shll8   r0
        or      r3, r0
        add     #1, r4
        mov.w   r0, @(12, r14)  /* DE */
        mov     r14, r0
        add     #16, r0
        bra     _z80_fetch
        mov.w   r4, @r0 /* delay slot */

/* POP HL (0xE1) */
_z80_pop_hl:
        add     #-10, r11
        mov.w   @(16, r14), r0
        extu.w  r0, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3
        add     #1, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        shll8   r0
        or      r3, r0
        add     #1, r4
        mov.w   r0, @(8, r14)   /* HL */
        mov     r14, r0
        add     #16, r0
        bra     _z80_fetch
        mov.w   r4, @r0 /* delay slot */

/* POP AF (0xF1) */
_z80_pop_af:
        add     #-10, r11
        mov.w   @(16, r14), r0
        extu.w  r0, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        mov     r0, r3          /* r3 = F */
        add     #1, r4 /* delay slot */
        mov     r4, r0          /* page computation; preserve r4 for multi-read */
        shlr8   r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* >>13 = page */
        shll2   r0              /* offset = page * 4 into Mem_Pages[] */
        mov.l   @(r0, r8), r1   /* r1 = Mem_Pages[page] base (LOAD) */
        mov     r4, r0          /* copy addr again for byte index */
        and     r10, r0         /* r0 = addr & 0x1FFF (R0 short form) */
        mov.b   @(r0, r1), r0   /* value -> r0 */
        extu.b  r0, r0
        /* r0 = A, r3 = F — split into R12 and struct */
        extu.b  r0, r12         /* R12 = new A (pinned) */
        mov     r14, r0
        add     #3, r0
        mov.b   r3, @r0         /* F = low byte */
        add     #1, r4
        mov     r14, r0
        add     #16, r0
        bra     _z80_fetch
        mov.w   r4, @r0 /* delay slot */

/* ================================================================ */
/*  Inline GG memory write subroutine                              */
/*  r4 = address (16-bit), r5 = value (8-bit)                      */
/*  Clobbers: r0, r1, r2, r3                                       */
/*  Preserves: r4, r5, r6, r7                                      */
/* ================================================================ */
_inline_gg_write:
        /* Check if addr >= 0xC000 (RAM region) */
        mov     r4, r0
        extu.w  r0, r0
        mov.l   .Lb_c000, r1
        cmp/hs  r1, r0
        bf      _gg_write_slow  /* addr < 0xC000 → C function */

        /* Fast RAM: gg_ram[addr & 0x1FFF] = val */
        mov     r0, r1
        and     r10, r1         /* r1 = addr & 0x1FFF */
        mov.l   .Lb_gg_ram, r2
        add     r1, r2
        mov.b   r5, @r2         /* gg_ram[addr & 0x1FFF] = val */
        /* Check if addr >= 0xFFFC (mapper register) */
        mov.l   .Lb_fffc, r2
        cmp/hs  r2, r0
        bt      _gg_write_mapper
        rts
        nop

_gg_write_mapper:
        /* Call gg_mapper_write(addr, val) */
        sts.l   pr, @-r15
        mov.l   r4, @-r15
        mov.l   r5, @-r15
        mov.l   r6, @-r15
        mov.l   r7, @-r15
        mov     r4, r4          /* addr already in r4 */
        mov     r5, r5          /* val already in r5 */
        mov.l   .Lb_mapper_write, r0
        jsr     @r0
        nop
        mov.l   @r15+, r7
        mov.l   @r15+, r6
        mov.l   @r15+, r5
        mov.l   @r15+, r4
        lds.l   @r15+, pr
        rts
        nop

_gg_write_slow:
        /* Call C gg_write(addr, val) */
        sts.l   pr, @-r15
        mov.l   r4, @-r15
        mov.l   r5, @-r15
        mov.l   r6, @-r15
        mov.l   r7, @-r15
        mov     r4, r4          /* addr */
        mov     r5, r5          /* val */
        mov.l   .Lb_gg_write, r0
        jsr     @r0
        nop
        mov.l   @r15+, r7
        mov.l   @r15+, r6
        mov.l   @r15+, r5
        mov.l   @r15+, r4
        lds.l   @r15+, pr
        rts
        nop

/* ================================================================ */
/*  Pool B — handler literal pool                                   */
/* ================================================================ */
        .align 2
.Lb_reg_offsets:
        .long   _z80_reg_offsets
.Lb_zstable:
        .long   _ZSTable
.Lb_pzstable:
        .long   _PZSTable
.Lb_c000:
        .long   0x0000C000
.Lb_fffc:
        .long   0x0000FFFC
.Lb_gg_ram:
        .long   _gg_ram
.Lb_mapper_write:
        .long   _gg_mapper_write + 0x20000000
.Lb_gg_write:
        .long   _gg_write + 0x20000000
.Lb_reg_src:
        .long   _RegOffsetsSrc

/* ================================================================ */
/*  ADD/ADC/SUB/SBC/CP A,r — Specialized register stubs  */
/*  Struct offsets: B=10 C=11 D=12 E=13 H=8 L=9 A=pinned R12      */
/* ================================================================ */

/* --- ADD A,<reg> stubs --- */
_z80_add_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_add_common
        extu.b  r0, r3          /* delay slot */
_z80_add_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_add_common
        extu.b  r0, r3          /* delay slot */
_z80_add_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_add_common
        extu.b  r0, r3          /* delay slot */
_z80_add_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_add_common
        extu.b  r0, r3          /* delay slot */
_z80_add_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_add_common
        extu.b  r0, r3          /* delay slot */
_z80_add_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_add_common
        extu.b  r0, r3          /* delay slot */
_z80_add_a_spec:
        add     #-4, r11
        bra     _z80_add_common
        mov     r12, r3         /* delay slot */
/* ADD common: r3 = src, r12 = A (pinned)
 * Optimized for SH-2 pipeline (SH7604 @ 23.01 MHz):
 *   - Compute A+src in R12 directly (eliminate temp copies)
 *   - Extract carry from bit 8 before truncation
 *   - Compute (A^src) once, reuse for both V and H flags
 *   - Branchless V: shift bit 7→bit 2 (avoids 3-cycle BT penalty)
 *   - Use "and #imm,R0" short form where possible
 *   - Interleave to avoid load-use stalls on SH-2 5-stage pipeline */
_z80_add_common:
        mov     r12, r4          /* r4 = old A (save before modify) */
        add     r3, r12          /* r12 = old_A + src (32-bit, carry in bit 8) */

        /* Carry flag: bit 8 of 32-bit sum */
        mov     r12, r0
        shlr8   r0
        and     #1, r0           /* r0 = carry (and #imm,R0 short form) */
        mov     r0, r6           /* r6 = flags accumulator (C set) */

        /* Truncate A to 8 bits */
        extu.b  r12, r12         /* r12 = result & 0xFF (pinned A updated) */

        /* Z + S flags via lookup table */
        mov     r12, r0          /* r0 = result (for table index) */
        mov.l   .Lb2_zstable, r1 /* r1 = &ZSTable (LOAD — gap before use) */
        mov     r4, r2           /* r2 = A^src (interleave: hides r1 stall) */
        xor     r3, r2           /* r2 = old_A ^ src (shared for V and H) */
        mov.b   @(r0, r1), r0   /* r0 = ZSTable[result] (r1 ready by now) */
        mov     r2, r1           /* r1 = A^src (interleave: hides r0 load-use) */
        or      r0, r6           /* merge S, Z (r0 avail, 1 gap, no stall) */

        /* H flag: (A^src^result) & 0x10 */
        xor     r12, r1          /* r1 = A^src^result */
        mov     r1, r0           /* need R0 for and #imm */
        and     #0x10, r0        /* r0 = H flag (and #imm,R0 short form) */
        or      r0, r6

        /* V flag (branchless): ~(A^src) & (A^result) & 0x80
         * r1 = A^src^result (from H); XOR src gives A^result.
         * SH-2 manual: SHLR2/SHLR each 1 cycle, no pipeline stall. */
        not     r2, r0           /* r0 = ~(A^src) (r2 still intact) */
        xor     r3, r1           /* r1 = (A^src^result)^src = A^result */
        and     r1, r0           /* r0 = ~(A^src) & (A^result), V in bit 7 */
        shlr2   r0               /* bit 7 → bit 5 */
        shlr2   r0               /* bit 5 → bit 3 */
        shlr    r0               /* bit 3 → bit 2 */
        and     #4, r0           /* isolate V_FLAG (and #imm,R0) */
        or      r0, r6

        /* Store F and return to fetch loop */
        mov     r14, r0
        add     #3, r0
        bra     _z80_fetch
        mov.b   r6, @r0 /* delay slot */

/* --- ADC A,<reg> stubs --- */
_z80_adc_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_adc_common
        extu.b  r0, r3          /* delay slot */
_z80_adc_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_adc_common
        extu.b  r0, r3          /* delay slot */
_z80_adc_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_adc_common
        extu.b  r0, r3          /* delay slot */
_z80_adc_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_adc_common
        extu.b  r0, r3          /* delay slot */
_z80_adc_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_adc_common
        extu.b  r0, r3          /* delay slot */
_z80_adc_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_adc_common
        extu.b  r0, r3          /* delay slot */
_z80_adc_a_spec:
        add     #-4, r11
        bra     _z80_adc_common
        mov     r12, r3         /* delay slot */
/* ADC common: r3 = src (SH-2 pipeline-optimized, see ADD common) */
_z80_adc_common:
        mov     r12, r4          /* r4 = old A */

        /* Old carry from F */
        mov.b   @(3, r14), r0   /* F (LOAD — need gap before use) */
        mov     r4, r6           /* interleave: start building sum */
        and     #1, r0           /* r0 = old carry (and #imm,R0) */

        /* A + src + carry */
        add     r3, r6
        add     r0, r6           /* r6 = old_A + src + carry (32-bit) */

        /* New carry from bit 8 */
        mov     r6, r0
        shlr8   r0
        and     #1, r0
        extu.b  r6, r12          /* r12 = result & 0xFF (pinned A updated) */
        mov     r0, r6           /* r6 = flags (new carry) */

        /* Z + S flags via lookup table */
        mov     r12, r0          /* result for table index */
        mov.l   .Lb2_zstable, r1 /* LOAD (gap before use) */
        mov     r4, r2           /* r2 = A^src (interleave: hides r1 stall) */
        xor     r3, r2
        mov.b   @(r0, r1), r0   /* ZSTable[result] */
        mov     r2, r1           /* r1 = A^src (interleave: hides r0 load-use) */
        or      r0, r6           /* merge ZS (r0 avail, 1 gap, no stall) */

        /* H: (A^src^result) & 0x10 */
        xor     r12, r1          /* r1 = A^src^result */
        mov     r1, r0           /* need R0 for and #imm */
        and     #0x10, r0
        or      r0, r6

        /* V (branchless): ~(A^src) & (A^result) & 0x80
         * r1 = A^src^result (from H); XOR src gives A^result. */
        not     r2, r0           /* r0 = ~(A^src) (r2 still intact) */
        xor     r3, r1           /* r1 = (A^src^result)^src = A^result */
        and     r1, r0           /* V in bit 7 */
        shlr2   r0
        shlr2   r0
        shlr    r0
        and     #4, r0
        or      r0, r6

        mov     r14, r0
        add     #3, r0
        bra     _z80_fetch
        mov.b   r6, @r0 /* delay slot */

/* --- SUB A,<reg> stubs --- */
_z80_sub_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_sub_common
        extu.b  r0, r3          /* delay slot */
_z80_sub_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_sub_common
        extu.b  r0, r3          /* delay slot */
_z80_sub_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_sub_common
        extu.b  r0, r3          /* delay slot */
_z80_sub_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_sub_common
        extu.b  r0, r3          /* delay slot */
_z80_sub_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_sub_common
        extu.b  r0, r3          /* delay slot */
_z80_sub_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_sub_common
        extu.b  r0, r3          /* delay slot */
_z80_sub_a_spec:
        add     #-4, r11
        bra     _z80_sub_common
        mov     r12, r3         /* delay slot */
/* SUB common: r3 = src (SH-2 pipeline-optimized, see ADD common) */
_z80_sub_common:
        mov     r12, r4          /* r4 = old A */

        /* Borrow: unsigned compare A >= src → no borrow */
        cmp/hs  r3, r4
        movt    r0               /* r0 = 1 if no borrow, 0 if borrow */
        xor     #1, r0           /* r0 = borrow (xor #imm,R0) */
        or      #2, r0           /* r0 = borrow | N_FLAG (or #imm,R0) */
        mov     r0, r6           /* r6 = flags accumulator */

        /* A - src */
        sub     r3, r12          /* r12 = old_A - src (32-bit) */
        extu.b  r12, r12         /* truncate to 8 bits (pinned A updated) */

        /* Z + S flags via lookup table */
        mov     r12, r0          /* result for table index */
        mov.l   .Lb2_zstable, r1 /* LOAD (gap before use) */
        mov     r4, r2           /* r2 = A^src (interleave: hides r1 stall) */
        xor     r3, r2
        mov.b   @(r0, r1), r0   /* ZSTable[result] */
        mov     r2, r1           /* r1 = A^src (interleave: hides r0 load-use) */
        or      r0, r6           /* merge ZS (r0 avail, 1 gap, no stall) */

        /* H: (A^src^result) & 0x10 */
        xor     r12, r1          /* r1 = A^src^result */
        mov     r1, r0           /* need R0 for and #imm */
        and     #0x10, r0
        or      r0, r6

        /* V (branchless): (A^src) & (A^result) & 0x80
         * r1 = A^src^result (from H); XOR src gives A^result. */
        mov     r2, r0           /* r0 = A^src (r2 still intact) */
        xor     r3, r1           /* r1 = (A^src^result)^src = A^result */
        and     r1, r0           /* r0 = (A^src) & (A^result), V in bit 7 */
        shlr2   r0
        shlr2   r0
        shlr    r0
        and     #4, r0
        or      r0, r6

        mov     r14, r0
        add     #3, r0
        bra     _z80_fetch
        mov.b   r6, @r0 /* delay slot */

/* --- SBC A,<reg> stubs --- */
_z80_sbc_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_sbc_common
        extu.b  r0, r3          /* delay slot */
_z80_sbc_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_sbc_common
        extu.b  r0, r3          /* delay slot */
_z80_sbc_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_sbc_common
        extu.b  r0, r3          /* delay slot */
_z80_sbc_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_sbc_common
        extu.b  r0, r3          /* delay slot */
_z80_sbc_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_sbc_common
        extu.b  r0, r3          /* delay slot */
_z80_sbc_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_sbc_common
        extu.b  r0, r3          /* delay slot */
_z80_sbc_a_spec:
        add     #-4, r11
        bra     _z80_sbc_common
        mov     r12, r3         /* delay slot */
/* SBC common: r3 = src (SH-2 pipeline-optimized, see SUB common) */
_z80_sbc_common:
        mov     r12, r4          /* r4 = old A */

        /* Old carry from F */
        mov.b   @(3, r14), r0   /* F (LOAD — need gap before use) */
        mov     r4, r6           /* interleave: start building diff */
        and     #1, r0           /* r0 = old carry (and #imm,R0) */

        /* A - src - carry */
        sub     r3, r6
        sub     r0, r6           /* r6 = old_A - src - carry (32-bit, may be negative) */
        extu.b  r6, r12          /* r12 = result & 0xFF (pinned A updated) */

        /* Borrow: negative 32-bit result means borrow occurred */
        cmp/pz  r6
        movt    r0               /* r0 = 1 if no borrow, 0 if borrow */
        xor     #1, r0           /* r0 = borrow (xor #imm,R0) */
        or      #2, r0           /* N flag always set for SBC (or #imm,R0) */
        mov     r0, r6           /* r6 = flags accumulator */

        /* Z + S flags via lookup table */
        mov     r12, r0          /* result for table index */
        mov.l   .Lb2_zstable, r1 /* LOAD (gap before use) */
        mov     r4, r2           /* r2 = A^src (interleave: hides r1 stall) */
        xor     r3, r2
        mov.b   @(r0, r1), r0   /* ZSTable[result] */
        mov     r2, r1           /* r1 = A^src (interleave: hides r0 load-use) */
        or      r0, r6           /* merge ZS (r0 avail, 1 gap, no stall) */

        /* H: (A^src^result) & 0x10 */
        xor     r12, r1          /* r1 = A^src^result */
        mov     r1, r0           /* need R0 for and #imm */
        and     #0x10, r0
        or      r0, r6

        /* V (branchless): (A^src) & (A^result) & 0x80
         * r1 = A^src^result (from H); XOR src gives A^result. */
        mov     r2, r0           /* r0 = A^src (r2 still intact) */
        xor     r3, r1           /* r1 = (A^src^result)^src = A^result */
        and     r1, r0           /* V in bit 7 */
        shlr2   r0
        shlr2   r0
        shlr    r0
        and     #4, r0
        or      r0, r6

        mov     r14, r0
        add     #3, r0
        bra     _z80_fetch
        mov.b   r6, @r0 /* delay slot */

/* --- CP A,<reg> stubs --- */
_z80_cp_b:
        mov.b   @(10, r14), r0
        add     #-4, r11
        bra     _z80_cp_common
        extu.b  r0, r3          /* delay slot */
_z80_cp_c:
        mov.b   @(11, r14), r0
        add     #-4, r11
        bra     _z80_cp_common
        extu.b  r0, r3          /* delay slot */
_z80_cp_d:
        mov.b   @(12, r14), r0
        add     #-4, r11
        bra     _z80_cp_common
        extu.b  r0, r3          /* delay slot */
_z80_cp_e:
        mov.b   @(13, r14), r0
        add     #-4, r11
        bra     _z80_cp_common
        extu.b  r0, r3          /* delay slot */
_z80_cp_h:
        mov.b   @(8, r14), r0
        add     #-4, r11
        bra     _z80_cp_common
        extu.b  r0, r3          /* delay slot */
_z80_cp_l:
        mov.b   @(9, r14), r0
        add     #-4, r11
        bra     _z80_cp_common
        extu.b  r0, r3          /* delay slot */
_z80_cp_a_spec:
        add     #-4, r11
        bra     _z80_cp_common
        mov     r12, r3         /* delay slot */
/* CP common: r3 = src (A not modified, SH-2 pipeline-optimized) */
_z80_cp_common:
        mov     r12, r4          /* r4 = A (pinned in R12, NOT modified) */

        /* Borrow flag */
        cmp/hs  r3, r4
        movt    r0
        xor     #1, r0           /* r0 = borrow (xor #imm,R0) */
        or      #2, r0           /* N flag always set for CP (or #imm,R0) */
        mov     r0, r6           /* r6 = flags accumulator */

        /* Compute result (A - src) without modifying R12 */
        mov     r4, r2
        sub     r3, r2
        extu.b  r2, r2           /* r2 = (A - src) & 0xFF */

        /* Z + S flags via lookup table */
        mov     r2, r0           /* result for table index */
        mov.l   .Lb2_zstable, r1 /* LOAD (gap before use) */
        mov     r4, r5           /* r5 = A^src (interleave: hides r1 stall) */
        xor     r3, r5
        mov.b   @(r0, r1), r0   /* ZSTable[result] */
        mov     r5, r1           /* r1 = A^src (interleave: hides r0 load-use) */
        or      r0, r6           /* merge ZS (r0 avail, 1 gap, no stall) */

        /* H: (A^src^result) & 0x10 */
        xor     r2, r1           /* r1 = A^src^result (CP uses r2 for result) */
        mov     r1, r0           /* need R0 for and #imm */
        and     #0x10, r0
        or      r0, r6

        /* V (branchless): (A^src) & (A^result) & 0x80
         * r1 = A^src^result (from H); XOR src gives A^result. */
        mov     r5, r0           /* r0 = A^src (r5 still intact) */
        xor     r3, r1           /* r1 = (A^src^result)^src = A^result */
        and     r1, r0           /* V in bit 7 */
        shlr2   r0
        shlr2   r0
        shlr    r0
        and     #4, r0
        or      r0, r6

        mov     r14, r0
        add     #3, r0
        bra     _z80_fetch
        mov.b   r6, @r0 /* delay slot */

/* ================================================================ */
/*  Pool B2 — literal pool for ALU handlers (ADD/SUB/CP)            */
/*  Must be AFTER the handlers (SH-2 forward-only PC-relative)     */
/* ================================================================ */
        .align 2
.Lb2_reg_offsets:
        .long   _z80_reg_offsets
.Lb2_zstable:
        .long   _ZSTable
.Lb2_reg_src:
        .long   _RegOffsetsSrc

/* ================================================================ */
/*  LAYOUT (2026-04-20): the ALU helpers / ALU imm / ALU xHL /      */
/*  Handlers below are ALL hot during blanking.                    */
/*  Keep them in subsection 0 so they pack adjacent to the main    */
/*  opcodes.  ED / DD / FD prefix handlers get explicitly pushed   */
/*  to subsection 1 later (see "_z80_pfx_ed" / "_z80_pfx_xx_common" */
/* ================================================================ */
        .align 2

/* ---- Cold-section trampolines for hot-section routines ---- */
/* These bridge BSR calls from cold handlers to hot-section code.   */
/* JMP preserves PR set by the caller's BSR, so RTS returns there. */
_cold_gg_read:
        mov.l   .Lcold_gg_read_addr, r0
        jmp     @r0
        nop
_cold_gg_write:
        mov.l   .Lcold_gg_write_addr, r0
        jmp     @r0
        nop
        .align 2
.Lcold_gg_read_addr:
        .long   _inline_gg_read
.Lcold_gg_write_addr:
        .long   _inline_gg_write

/* ================================================================ */
/*  Remaining main opcodes (ALU imm/xHL, INC/DEC xHL,     */
/*           DAA, INA, OUTA, LD (nn) variants, EX HL,(SP))         */
/*                                                                  */
/*  LAYOUT (2026-04-20): moved from .subsection 1 back to hot.     */
/*  Profiling showed ALU-imm / ALU-(HL) / INC-(HL) handlers are    */
/*  called frequently during blanking VBlank ISR, so they should   */
/*  pack adjacent to the main opcode handlers in subsection 0.    */
/* ================================================================ */

/* ---------------------------------------------------------------- */
/*  Shared subroutines for main opcode handlers                     */
/* ---------------------------------------------------------------- */

/* Fetch immediate byte at PC into r3, increment PC.
   Clobbers: r0. Preserves: r3(result), r4-r7.

   Lever-2 fast path: use the pinned pc_base register (r13) which the
   dispatch loop already set up when fetching the opcode byte.  The
   byte at PC is in the same page as the opcode in every practical
   case (Z80 code never straddles page boundaries on real ROMs), and
   the existing dispatch loop is already built on this same assumption
   (it does not re-rebase r13 after multi-byte opcodes return to the
   sequential fetch path).  Going from 15 insns → 7 insns saves ~8 cyc
   per immediate fetch, and this subroutine is called by every
   ALU-imm, LD-imm, CB/DD/FD/ED prefix, and relative-branch op. */
_fetch_imm_to_r3:
        mov     r7, r0
        add     r13, r0
        mov.b   @r0, r0
        extu.b  r0, r3
        add     #1, r7
        rts
        extu.w  r7, r7 /* delay slot */

/* Read byte at (HL) into r3. Also leaves HL address in r4.
   Clobbers: r0, r1, r2, r4. Preserves: r3(result). */
_read_xhl_to_r3:
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        extu.w  r4, r4         /* r4 = HL address (saved for writeback) */
        mov     r4, r0
        shlr8   r0
        shlr2   r0
        shlr    r0
        shlr    r0
        shlr    r0
        shll2   r0
        mov.l   @(r0, r8), r1
        mov     r4, r0
        and     r10, r0
        mov.b   @(r0, r1), r0
        rts
        extu.b  r0, r3 /* delay slot */

/* ---- Shared ADD flag computation ----
   Entry: r3=src, r4=A. Stores result to A and flags to F.
   Clobbers: r0,r1,r2,r6. Branchless V, R0 short forms. */
_alu_add_flags:
        mov     r4, r6
        add     r3, r6           /* r6 = A + src (32-bit) */
        mov     r6, r0
        shlr8   r0
        and     #1, r0           /* carry (R0 short form) */
        extu.b  r6, r12          /* A = result (pinned in R12) */
        mov     r12, r2          /* r2 = result */
        mov     r0, r6           /* r6 = carry flag */
        mov     r2, r0
        mov.l   .Lb3a_zstable, r1
        mov.b   @(r0, r1), r0
        or      r0, r6           /* merge ZS */
        /* H: (A^src^result) & 0x10 */
        mov     r4, r0
        xor     r3, r0           /* r0 = A^src */
        mov     r0, r1           /* r1 = A^src (save for V) */
        xor     r2, r0           /* r0 = A^src^result */
        and     #0x10, r0
        or      r0, r6
        /* V: ~(A^src) & (A^result) & 0x80, branchless */
        not     r1, r0           /* r0 = ~(A^src) */
        mov     r4, r1
        xor     r2, r1           /* r1 = A^result */
        and     r1, r0           /* V in bit 7 */
        shlr2   r0
        shlr2   r0
        shlr    r0
        and     #4, r0
        or      r0, r6
        mov     r14, r0
        add     #3, r0
        rts
        mov.b   r6, @r0 /* delay slot */

/* ---- Shared ADC flag computation ----
   Entry: r3=src, r4=A. Reads carry from F. Branchless V. */
_alu_adc_flags:
        mov.b   @(3, r14), r0
        and     #1, r0           /* old carry (R0 short form) */
        mov     r4, r6
        add     r3, r6
        add     r0, r6           /* r6 = A + src + carry (32-bit) */
        mov     r6, r0
        shlr8   r0
        and     #1, r0           /* new carry */
        extu.b  r6, r12          /* A = result (pinned in R12) */
        mov     r12, r2          /* r2 = result */
        mov     r0, r6           /* r6 = new carry flag */
        mov     r2, r0
        mov.l   .Lb3a_zstable, r1
        mov.b   @(r0, r1), r0
        or      r0, r6           /* merge ZS */
        /* H: (A^src^result) & 0x10 */
        mov     r4, r0
        xor     r3, r0           /* A^src */
        mov     r0, r1           /* save for V */
        xor     r2, r0           /* A^src^result */
        and     #0x10, r0
        or      r0, r6
        /* V: ~(A^src) & (A^result) & 0x80, branchless */
        not     r1, r0           /* ~(A^src) */
        mov     r4, r1
        xor     r2, r1           /* A^result */
        and     r1, r0           /* V in bit 7 */
        shlr2   r0
        shlr2   r0
        shlr    r0
        and     #4, r0
        or      r0, r6
        mov     r14, r0
        add     #3, r0
        rts
        mov.b   r6, @r0 /* delay slot */

/* ---- Shared SUB flag computation ----
   Entry: r3=src, r4=A. Stores result and flags. Branchless V. */
_alu_sub_flags:
        mov     r4, r6
        sub     r3, r6           /* r6 = A - src (32-bit) */
        extu.b  r6, r12          /* A = result (pinned in R12) */
        mov     r12, r2          /* r2 = result */
        /* Borrow + N */
        cmp/hs  r3, r4
        movt    r0
        xor     #1, r0           /* borrow */
        or      #2, r0           /* N flag (R0 short form) */
        mov     r0, r6
        mov     r2, r0
        mov.l   .Lb3a_zstable, r1
        mov.b   @(r0, r1), r0
        or      r0, r6           /* merge ZS */
        /* H: (A^src^result) & 0x10 */
        mov     r4, r0
        xor     r3, r0           /* A^src */
        mov     r0, r1           /* save for V */
        xor     r2, r0           /* A^src^result */
        and     #0x10, r0
        or      r0, r6
        /* V: (A^src) & (A^result) & 0x80, branchless */
        mov     r4, r0
        xor     r2, r0           /* A^result */
        and     r1, r0           /* (A^src) & (A^result), V in bit 7 */
        shlr2   r0
        shlr2   r0
        shlr    r0
        and     #4, r0
        or      r0, r6
        mov     r14, r0
        add     #3, r0
        rts
        mov.b   r6, @r0 /* delay slot */

/* ---- Shared SBC flag computation ----
   Entry: r3=src, r4=A. Reads carry from F. Branchless V. */
_alu_sbc_flags:
        mov.b   @(3, r14), r0
        and     #1, r0           /* old carry (R0 short form) */
        mov     r4, r6
        sub     r3, r6
        sub     r0, r6           /* r6 = A - src - carry (32-bit) */
        extu.b  r6, r12          /* A = result (pinned in R12) */
        mov     r12, r2          /* r2 = result */
        /* Borrow + N: negative 32-bit result means borrow */
        cmp/pz  r6               /* r6 still full 32-bit diff */
        movt    r0
        xor     #1, r0           /* borrow */
        or      #2, r0           /* N flag (R0 short form) */
        mov     r0, r6
        mov     r2, r0
        mov.l   .Lb3a_zstable, r1
        mov.b   @(r0, r1), r0
        or      r0, r6           /* merge ZS */
        /* H: (A^src^result) & 0x10 */
        mov     r4, r0
        xor     r3, r0           /* A^src */
        mov     r0, r1           /* save for V */
        xor     r2, r0           /* A^src^result */
        and     #0x10, r0
        or      r0, r6
        /* V: (A^src) & (A^result) & 0x80, branchless */
        mov     r4, r0
        xor     r2, r0           /* A^result */
        and     r1, r0           /* (A^src) & (A^result), V in bit 7 */
        shlr2   r0
        shlr2   r0
        shlr    r0
        and     #4, r0
        or      r0, r6
        mov     r14, r0
        add     #3, r0
        rts
        mov.b   r6, @r0 /* delay slot */

/* ---- Shared CP flag computation ----
   Entry: r3=src, r4=A. Stores flags only, A NOT modified. Branchless V. */
_alu_cp_flags:
        mov     r4, r6
        sub     r3, r6           /* r6 = A - src */
        extu.b  r6, r2           /* r2 = result (A NOT modified) */
        /* Borrow + N */
        cmp/hs  r3, r4
        movt    r0
        xor     #1, r0           /* borrow */
        or      #2, r0           /* N flag (R0 short form) */
        mov     r0, r6
        mov     r2, r0
        mov.l   .Lb3a_zstable, r1
        mov.b   @(r0, r1), r0
        or      r0, r6           /* merge ZS */
        /* H: (A^src^result) & 0x10 */
        mov     r4, r0
        xor     r3, r0           /* A^src */
        mov     r0, r1           /* save for V */
        xor     r2, r0           /* A^src^result */
        and     #0x10, r0
        or      r0, r6
        /* V: (A^src) & (A^result) & 0x80, branchless */
        mov     r4, r0
        xor     r2, r0           /* A^result */
        and     r1, r0           /* (A^src) & (A^result), V in bit 7 */
        shlr2   r0
        shlr2   r0
        shlr    r0
        and     #4, r0
        or      r0, r6
        mov     r14, r0
        add     #3, r0
        rts
        mov.b   r6, @r0 /* delay slot */

/* ---------------------------------------------------------------- */
/*  ALU immediate handlers (ADD_BYTE through CP_BYTE)               */
/* ---------------------------------------------------------------- */

_z80_add_imm:
        add     #-7, r11
        bsr     _fetch_imm_to_r3
        nop
        bsr     _alu_add_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3a_ret_fetch
        nop

_z80_adc_imm:
        add     #-7, r11
        bsr     _fetch_imm_to_r3
        nop
        bsr     _alu_adc_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3a_ret_fetch
        nop

_z80_sub_imm:
        add     #-7, r11
        bsr     _fetch_imm_to_r3
        nop
        bsr     _alu_sub_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3a_ret_fetch
        nop

_z80_sbc_imm:
        add     #-7, r11
        bsr     _fetch_imm_to_r3
        nop
        bsr     _alu_sbc_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3a_ret_fetch
        nop

_z80_and_imm:
        add     #-7, r11
        bsr     _fetch_imm_to_r3
        nop
        mov     r12, r1          /* A (pinned in R12) */
        and     r3, r1
        mov     r1, r12
        mov.l   .Lb3a_pzstable, r2
        mov     r1, r0
        mov.b   @(r0, r2), r0
        extu.b  r0, r0
        mov     #0x10, r1
        or      r1, r0
        mov     r14, r1
        add     #3, r1
        bra     .Lb3a_ret_fetch
        mov.b   r0, @r1 /* delay slot */

_z80_or_imm:
        add     #-7, r11
        bsr     _fetch_imm_to_r3
        nop
        mov     r12, r1          /* A (pinned in R12) */
        or      r3, r1
        mov     r1, r12
        mov.l   .Lb3a_pzstable, r2
        mov     r1, r0
        mov.b   @(r0, r2), r0
        extu.b  r0, r0
        mov     r14, r1
        add     #3, r1
        bra     .Lb3a_ret_fetch
        mov.b   r0, @r1 /* delay slot */

_z80_xor_imm:
        add     #-7, r11
        bsr     _fetch_imm_to_r3
        nop
        mov     r12, r1          /* A (pinned in R12) */
        xor     r3, r1
        mov     r1, r12
        mov.l   .Lb3a_pzstable, r2
        mov     r1, r0
        mov.b   @(r0, r2), r0
        extu.b  r0, r0
        mov     r14, r1
        add     #3, r1
        bra     .Lb3a_ret_fetch
        mov.b   r0, @r1 /* delay slot */

_z80_cp_imm:
        add     #-7, r11
        bsr     _fetch_imm_to_r3
        nop
        bsr     _alu_cp_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3a_ret_fetch
        nop

/* Trampoline to _z80_fetch for main opcode handlers */
.Lb3a_ret_fetch:
        mov.l   .Lb3a_z80_fetch, r0
        jmp     @r0
        nop

/* ================================================================ */
/*  Pool B3a — literal pool for shared routines + ALU imm           */
/* ================================================================ */
        .align 2
.Lb3a_zstable:
        .long   _ZSTable
.Lb3a_pzstable:
        .long   _PZSTable
.Lb3a_z80_fetch:
        .long   _z80_fetch
.Lb3a_gg_write:
        .long   _inline_gg_write

/* ---------------------------------------------------------------- */
/*  ALU (HL) handlers                                               */
/* ---------------------------------------------------------------- */

_z80_add_xhl:
        add     #-7, r11
        bsr     _read_xhl_to_r3
        nop
        bsr     _alu_add_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3b_ret_fetch
        nop

_z80_adc_xhl:
        add     #-7, r11
        bsr     _read_xhl_to_r3
        nop
        bsr     _alu_adc_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3b_ret_fetch
        nop

_z80_sub_xhl:
        add     #-7, r11
        bsr     _read_xhl_to_r3
        nop
        bsr     _alu_sub_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3b_ret_fetch
        nop

_z80_sbc_xhl:
        add     #-7, r11
        bsr     _read_xhl_to_r3
        nop
        bsr     _alu_sbc_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3b_ret_fetch
        nop

_z80_and_xhl:
        add     #-7, r11
        bsr     _read_xhl_to_r3
        nop
        mov     r12, r1          /* A (pinned in R12) */
        and     r3, r1
        mov     r1, r12
        mov.l   .Lb3b_pzstable, r2
        mov     r1, r0
        mov.b   @(r0, r2), r0
        extu.b  r0, r0
        mov     #0x10, r1
        or      r1, r0
        mov     r14, r1
        add     #3, r1
        bra     .Lb3b_ret_fetch
        mov.b   r0, @r1 /* delay slot */

_z80_or_xhl:
        add     #-7, r11
        bsr     _read_xhl_to_r3
        nop
        mov     r12, r1          /* A (pinned in R12) */
        or      r3, r1
        mov     r1, r12
        mov.l   .Lb3b_pzstable, r2
        mov     r1, r0
        mov.b   @(r0, r2), r0
        extu.b  r0, r0
        mov     r14, r1
        add     #3, r1
        bra     .Lb3b_ret_fetch
        mov.b   r0, @r1 /* delay slot */

_z80_xor_xhl:
        add     #-7, r11
        bsr     _read_xhl_to_r3
        nop
        mov     r12, r1          /* A (pinned in R12) */
        xor     r3, r1
        mov     r1, r12
        mov.l   .Lb3b_pzstable, r2
        mov     r1, r0
        mov.b   @(r0, r2), r0
        extu.b  r0, r0
        mov     r14, r1
        add     #3, r1
        bra     .Lb3b_ret_fetch
        mov.b   r0, @r1 /* delay slot */

_z80_cp_xhl:
        add     #-7, r11
        bsr     _read_xhl_to_r3
        nop
        bsr     _alu_cp_flags
        mov     r12, r4 /* delay slot: A (pinned in R12) */
        bra     .Lb3b_ret_fetch
        nop

/* ---------------------------------------------------------------- */
/*  INC (HL), DEC (HL): read-modify-write at (HL), LUT-optimized   */
/*  Same LUT approach as INC/DEC r but with gg_read/gg_write.    */
/*  Optimizations: direct LUT→r6, jsr delay slot for mov r3,r5.    */
/* ---------------------------------------------------------------- */

_z80_inc_xhl:
        add     #-11, r11
        bsr     _read_xhl_to_r3
        nop
        /* r3 = value, r4 = HL address */
        add     #1, r3
        extu.b  r3, r3
        /* F = (F & C_FLAG) | IncFlags[result] */
        mov     r3, r0                  /* r0 = result (LUT index) */
        mov.l   .Lb3b_incflags, r1     /* r1 = IncFlags base */
        mov.b   @(r0, r1), r6          /* r6 = IncFlags[result] (sign-ext OK) */
        mov.b   @(3, r14), r0          /* r0 = old F */
        and     #1, r0                  /* r0 = old carry */
        or      r6, r0                  /* r0 = new F */
        mov.b   r0, @(3, r14)          /* store new F */
        /* Write back: gg_write(r4=addr, r5=value) */
        mov.l   .Lb3b_gg_write, r0
        jsr     @r0
        mov     r3, r5                  /* delay slot: r5 = write value */
        bra     .Lb3b_ret_fetch
        nop

_z80_dec_xhl:
        add     #-11, r11
        bsr     _read_xhl_to_r3
        nop
        /* r3 = value, r4 = HL address */
        add     #-1, r3
        extu.b  r3, r3
        /* F = (F & C_FLAG) | DecFlags[result] */
        mov     r3, r0                  /* r0 = result (LUT index) */
        mov.l   .Lb3b_decflags, r1     /* r1 = DecFlags base */
        mov.b   @(r0, r1), r6          /* r6 = DecFlags[result] (sign-ext OK) */
        mov.b   @(3, r14), r0          /* r0 = old F */
        and     #1, r0                  /* r0 = old carry */
        or      r6, r0                  /* r0 = new F */
        mov.b   r0, @(3, r14)          /* store new F */
        /* Write back: gg_write(r4=addr, r5=value) */
        mov.l   .Lb3b_gg_write, r0
        jsr     @r0
        mov     r3, r5                  /* delay slot: r5 = write value */
        bra     .Lb3b_ret_fetch
        nop

/* ---------------------------------------------------------------- */
/*  DAA: Decimal Adjust Accumulator (inline BCD correction)         */
/*                                                                  */
/*  Computes DAA result inline, eliminating the 4 KB DAATable that  */
/*  was thrashing the entire SH-2 cache.                            */
/*                                                                  */
/*  Algorithm:                                                      */
/*    correction = 0; new_c = old_C                                 */
/*    if (A & 0xF) > 9 or H:  correction |= 0x06                  */
/*    if A > 0x99 or C:        correction |= 0x60; new_c = 1       */
/*    if N: A -= correction  else: A += correction                  */
/*    F = PZSTable[A] | (A&0x28) | N | new_c | ((old_A^A) & H)    */
/*                                                                  */
/*  Regs: R0=scratch R1=correction R2=old_F R3=old_A R4=new_c      */
/*        R5=temp R6=temp  R12=A(pinned) R14=z80_t*                */
/* ---------------------------------------------------------------- */

_z80_daa:
        add     #-4, r11                /* 4 Z80 cycles */

        /* --- Load F, save old_A --- */
        mov.b   @(3, r14), r0          /* [LOAD] r0 = F (sign-extended) */
        mov     r12, r3                 /* r3 = old_A (fills load-use gap) */
        extu.b  r0, r2                  /* r2 = F zero-extended */

        /* new_c = old C flag */
        mov     r2, r0
        and     #0x01, r0               /* r0 = F & C_FLAG */
        mov     r0, r4                  /* r4 = new_c */

        /* correction = 0 */
        mov     #0, r1

        /* --- Low nibble: (A & 0x0F) > 9 || H_FLAG → |= 0x06 --- */
        mov     r12, r0
        and     #0x0F, r0               /* r0 = low nibble */
        mov     #9, r5
        cmp/hi  r5, r0                  /* T = (low > 9) unsigned */
        bt/s    .Ldaa_do_low            /* 2 cy taken (delay slot runs) */
        mov     #0x06, r6              /* delay: r6 = 6 (always executes) */
        /* Low ≤ 9: check H flag */
        mov     r2, r0
        tst     #0x10, r0               /* T = !(F & H_FLAG) */
        bt      .Ldaa_check_high        /* H not set → skip low fix */
.Ldaa_do_low:
        or      r6, r1                  /* correction |= 0x06 */

.Ldaa_check_high:
        /* --- High nibble: A > 0x99 || C_FLAG → |= 0x60, C=1 --- */
        mov     #0x99, r5
        cmp/hi  r5, r12                 /* T = (A > 0x99) unsigned */
        bt/s    .Ldaa_do_high           /* 2 cy taken (delay slot runs) */
        mov     #0x60, r6              /* delay: r6 = 0x60 (always executes) */
        /* A ≤ 0x99: check C flag */
        tst     r4, r4                  /* T = (new_c == 0) */
        bt      .Ldaa_apply             /* C not set → skip high fix */
.Ldaa_do_high:
        or      r6, r1                  /* correction |= 0x60 */
        mov     #1, r4                  /* new_c = C_FLAG */

.Ldaa_apply:
        /* --- Add or subtract based on N flag --- */
        mov     r2, r0
        tst     #0x02, r0               /* T = !(F & N_FLAG) */
        bf      .Ldaa_sub               /* N set → subtract: 3 cy taken */
        /* Add path (N=0, common for BCD scores): 1 cy not-taken */
        add     r1, r12
        bra     .Ldaa_flags
        extu.b  r12, r12               /* delay slot: mask to byte */
.Ldaa_sub:
        sub     r1, r12
        extu.b  r12, r12

.Ldaa_flags:
        /* === Build F, pipeline-scheduled for zero stalls === */
        mov     r12, r0                 /* r0 = new_A (PZSTable index) */
        mov.l   .Lb3b_pzstable, r1     /* [LOAD] r1 = PZSTable base */
        mov     r3, r6                  /* r6 = old_A (fills r1 load gap) */
        mov.b   @(r0, r1), r5          /* [LOAD] r5 = PZSTable[new_A] */
        xor     r12, r6                 /* r6 = old_A ^ new_A (fills r5 gap) */
        extu.b  r5, r5                  /* r5 = PZS flags (zero-extend) */
        /* Accumulate non-PZS flags in r0 */
        mov     r6, r0                  /* r0 = old_A ^ new_A */
        and     #0x10, r0               /* r0 = H flag */
        or      r4, r0                  /* r0 |= C */
        mov     r0, r6                  /* save H|C */
        mov     r2, r0                  /* r0 = old_F */
        and     #0x02, r0               /* r0 = N flag */
        or      r6, r0                  /* r0 = H|C|N */
        mov     r0, r6                  /* save H|C|N */
        mov     r12, r0                 /* r0 = new_A */
        and     #0x28, r0               /* r0 = undocumented Y|X (bits 5,3) */
        or      r6, r0                  /* r0 = H|C|N|Y|X */
        or      r5, r0                  /* r0 = final F (all flags) */
        /* Store F and return to fetch loop */
        bra     .Lb3b_ret_fetch
        mov.b   r0, @(3, r14)          /* delay slot: store F byte */

/* ---------------------------------------------------------------- */
/* ---------------------------------------------------------------- */
/*  INA: A = gg_in(port)  /  OUTA: gg_out(port, A)                */
/*                                                                  */
/*  VDP fast path: inline port range check for 0x80-0xBF (bit7=1,  */
/*  bit6=0) and call gg_vdp_*() directly, bypassing gg_in/gg_out   */
/*  dispatch overhead.  Other ports fall through to generic C call. */
/* ---------------------------------------------------------------- */

_z80_ina:
        add     #-11, r11
        bsr     _fetch_imm_to_r3
        nop
        /* r3 = port number. VDP fast path? */
        mov     r3, r0
        tst     #0x80, r0
        bt      .Lina_generic           /* bit7=0 → port < 0x80 */
        tst     #0x40, r0
        bf      .Lina_generic           /* bit6=1 → port >= 0xC0 */
        /* --- VDP port (0x80-0xBF): even=data, odd=status --- */
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        tst     #0x01, r0
        bt      .Lina_vdp_even
        /* Odd port: VDP status read */
        mov.l   .Lb3b_vdp_status_rd, r0
        jsr     @r0
        nop
        bra     .Lina_vdp_done
        nop
.Lina_vdp_even:
        /* Even port: VDP data read */
        mov.l   .Lb3b_vdp_data_rd, r0
        jsr     @r0
        nop
.Lina_vdp_done:
        extu.b  r0, r12                 /* A = result (pinned in R12) */
        mov.l   @r15+, r7
        bra     .Lb3b_ret_fetch
        lds.l   @r15+, pr              /* delay slot */

.Lina_generic:
        /* All other ports: call gg_in(port) */
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov.l   .Lb3b_gg_in, r0
        jsr     @r0
        mov     r3, r4                  /* delay slot: r4 = port */
        mov.l   @r15+, r7
        extu.b  r0, r12                 /* A = gg_in(port) */
        bra     .Lb3b_ret_fetch
        lds.l   @r15+, pr              /* delay slot */

_z80_outa:
        add     #-11, r11
        bsr     _fetch_imm_to_r3
        nop
        /* r3 = port number, A = R12. VDP fast path? */
        mov     r3, r0
        tst     #0x80, r0
        bt      .Louta_generic          /* bit7=0 → port < 0x80 */
        tst     #0x40, r0
        bf      .Louta_generic          /* bit6=1 → port >= 0xC0 */
        /* --- VDP port (0x80-0xBF): even=data, odd=addr --- */
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r12, r4                 /* r4 = val (A) */
        tst     #0x01, r0
        bt      .Louta_vdp_even
        /* Odd port: VDP address/control write */
        mov.l   .Lb3b_vdp_addr_wr, r0
        jsr     @r0
        nop
        bra     .Louta_vdp_done
        nop
.Louta_vdp_even:
        /* Even port: VDP data write */
        mov.l   .Lb3b_vdp_data_wr, r0
        jsr     @r0
        nop
.Louta_vdp_done:
        mov.l   @r15+, r7
        bra     .Lb3b_ret_fetch
        lds.l   @r15+, pr              /* delay slot */

.Louta_generic:
        /* All other ports: call gg_out(port, A) */
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r12, r5                 /* r5 = val (A) */
        mov.l   .Lb3b_gg_out, r0
        jsr     @r0
        mov     r3, r4                  /* delay slot: r4 = port */
        mov.l   @r15+, r7
        bra     .Lb3b_ret_fetch
        lds.l   @r15+, pr              /* delay slot */

/* ---------------------------------------------------------------- */
/*  LD (nn) variants                                                */
/* ---------------------------------------------------------------- */

/* LD (nn),HL: write HL to 16-bit address */
_z80_ld_xword_hl:
        add     #-16, r11
        /* Fetch 16-bit address from PC */
        bsr     _fetch_imm_to_r3
        nop
        bsr     _fetch_imm_to_r3
        mov     r3, r6 /* delay slot */ /* r6 = low byte */
        shll8   r3
        or      r6, r3          /* r3 = address */
        /* Write HL.l to (addr), HL.h to (addr+1) */
        sts.l   pr, @-r15
        mov     r14, r0
        add     #9, r0
        mov.b   @r0, r5
        extu.b  r5, r5          /* r5 = HL.l (offset 9) */
        mov.l   .Lb3b_gg_write, r0
        jsr     @r0
        mov     r3, r4 /* delay slot */ /* r4 = addr */
        mov     r14, r0
        add     #8, r0
        mov.b   @r0, r5
        extu.b  r5, r5          /* r5 = HL.h (offset 8) */
        mov.l   .Lb3b_gg_write, r0
        jsr     @r0
        add     #1, r4 /* delay slot */ /* addr + 1 */
        bra     .Lb3b_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* LD HL,(nn): read 16-bit from address to HL */
_z80_ld_hl_xword:
        add     #-16, r11
        bsr     _fetch_imm_to_r3
        nop
        bsr     _fetch_imm_to_r3
        mov     r3, r6 /* delay slot */
        shll8   r3
        or      r6, r3          /* r3 = address */
        /* Read low byte */
        bsr     _cold_gg_read
        mov     r3, r4 /* delay slot */
        mov     r0, r6          /* r6 = low byte */
        /* Read high byte */
        bsr     _cold_gg_read
        add     #1, r4 /* delay slot */
        /* Store to HL: high at offset 8, low at offset 9 */
        mov     r14, r1
        add     #9, r1
        mov.b   r6, @r1         /* HL.l */
        add     #-1, r1
        bra     .Lb3b_ret_fetch
        mov.b   r0, @r1         /* HL.h (delay slot) */

/* LD A,(nn): A = mem[nn] */
_z80_ld_a_xword:
        add     #-13, r11
        bsr     _fetch_imm_to_r3
        nop
        bsr     _fetch_imm_to_r3
        mov     r3, r6 /* delay slot */
        shll8   r3
        or      r6, r3
        bsr     _cold_gg_read
        mov     r3, r4 /* delay slot */
        extu.b  r0, r12         /* A = value (pinned in R12) */
        bra     .Lb3b_ret_fetch
        nop

/* LD (nn),A: mem[nn] = A */
_z80_ld_xword_a:
        add     #-13, r11
        bsr     _fetch_imm_to_r3
        nop
        bsr     _fetch_imm_to_r3
        mov     r3, r6 /* delay slot */
        shll8   r3
        or      r6, r3
        sts.l   pr, @-r15
        mov     r12, r5          /* r5 = A (pinned in R12) */
        mov.l   .Lb3b_gg_write, r0
        jsr     @r0
        mov     r3, r4 /* delay slot */ /* r4 = addr */
        bra     .Lb3b_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---------------------------------------------------------------- */
/*  EX HL,(SP): swap HL with top of stack                           */
/* ---------------------------------------------------------------- */

_z80_ex_hl_xsp:
        add     #-19, r11
        /* Read low byte from (SP) */
        mov     r14, r0
        add     #16, r0
        mov.w   @r0, r4
        bsr     _cold_gg_read
        extu.w  r4, r4 /* delay slot */ /* r4 = SP */
        mov     r0, r6          /* r6 = old low byte from stack */
        /* Write HL.l to (SP) */
        sts.l   pr, @-r15
        mov     r14, r0
        add     #9, r0
        mov.b   @r0, r5
        mov.l   .Lb3b_gg_write, r0
        jsr     @r0
        extu.b  r5, r5 /* delay slot */ /* r5 = HL.l */
        /* Read high byte from (SP+1) */
        add     #1, r4
        lds.l   @r15+, pr
        bsr     _cold_gg_read
        nop
        mov     r0, r3          /* r3 = old high byte from stack */
        /* Write HL.h to (SP+1) */
        sts.l   pr, @-r15
        mov     r14, r0
        add     #8, r0
        mov.b   @r0, r5
        mov.l   .Lb3b_gg_write, r0
        jsr     @r0
        extu.b  r5, r5 /* delay slot */ /* r5 = HL.h */
        lds.l   @r15+, pr
        /* SP-1 (restore to original, since we incremented once) */
        add     #-1, r4
        mov     r14, r0
        add     #16, r0
        mov.w   r4, @r0
        /* Store old stack values to HL */
        mov     r14, r0
        add     #8, r0
        mov.b   r3, @r0         /* HL.h = old high */
        add     #1, r0
        bra     .Lb3b_ret_fetch
        mov.b   r6, @r0         /* HL.l = old low (delay slot) */

.Lb3b_ret_fetch:
        mov.l   .Lb3b_z80_fetch, r0
        jmp     @r0
        nop

/* ================================================================ */
/*  Pool B3b — literal pool for (HL)/misc handlers                 */
/* ================================================================ */
        .align 2
.Lb3b_zstable:
        .long   _ZSTable
.Lb3b_pzstable:
        .long   _PZSTable
.Lb3b_incflags:
        .long   _IncFlags
.Lb3b_decflags:
        .long   _DecFlags
.Lb3b_z80_fetch:
        .long   _z80_fetch
.Lb3b_gg_write:
        .long   _inline_gg_write
.Lb3b_gg_in:
        .long   _gg_in + 0x20000000
.Lb3b_gg_out:
        .long   _gg_out + 0x20000000
.Lb3b_vdp_data_wr:
        .long   _gg_vdp_data_write + 0x20000000
.Lb3b_vdp_addr_wr:
        .long   _gg_vdp_addr_write + 0x20000000
.Lb3b_vdp_data_rd:
        .long   _gg_vdp_data_read + 0x20000000
.Lb3b_vdp_status_rd:
        .long   _gg_vdp_status_read + 0x20000000

/* ================================================================ */
/*  ED / DD / FD Prefix Handlers                           */
/*                                                                  */
/*  ED prefix: Full dispatch for all 256 sub-opcodes.               */
/*  DD/FD prefix: Fetch sub-opcode, charge CyclesXX, dispatch.     */
/*    Pass-through (CyclesXX[I]==0) → main table handlers.          */
/*    Unique IX/IY ops → call C helper.                             */
/*                                                                  */
/*  LAYOUT (2026-04-20): explicit cold subsection starts here.     */
/*  Sonic and similar games do NOT execute ED/DD/FD during blanking */
/*  so this ~7 KB of code must be evicted from the hot band.       */
/* ================================================================ */
        .subsection 1
        .align 2

/* ================================================================ */
/*  ED Prefix Handler                                               */
/* ================================================================ */
_z80_pfx_ed:
        /* Fetch sub-opcode at PC (inline page table read) */
        bsr     _fetch_imm_to_r3
        nop
        /* r3 = sub-opcode, PC advanced */

#if PERF_DEBUG
        /* Prefix audit: g_ed_sub_hist[sub]++.  r3 stays intact for the CyclesED
         * lookup below; copy it to r2 as index.  r0/r1 are scratch (re-derived by
         * the R++ block).  u16 histogram, matches g_op_hist style. */
        mov     r3, r2                 /* r2 = sub-opcode (r3 preserved) */
        mov.l   .Lg_ed_sub_hist, r0    /* r0 = &g_ed_sub_hist[256] */
        shll    r2                     /* r2 = sub * 2 (u16 index) */
        add     r2, r0                 /* r0 = &g_ed_sub_hist[sub] */
        mov.w   @r0, r1                /* r1 = current count */
        add     #1, r1
        mov.w   r1, @r0                /* write back (wraps at 65536; safe per frame) */
#endif

        /* R++ (offset Z80_R=15) */
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r1
        add     #1, r1
        mov.b   r1, @r0

        /* ICount -= CyclesED[sub-opcode] (R11 = ICount) */
        mov.l   .Led_cyclesed_near, r0
        mov     r3, r1
        add     r0, r1
        mov.b   @r1, r0
        extu.b  r0, r0
        sub     r0, r11

        /* Range check: [0x40, 0xBF] → dispatch table, else NOP */
        mov     r3, r0
        add     #-0x40, r0       /* r0 = sub_opcode - 0x40 */
        extu.b  r0, r0           /* zero-extend to handle wrap */
        mov     #0x80, r1
        extu.b  r1, r1           /* r1 = 128 */
        cmp/hs  r1, r0           /* unsigned: r0 >= 128? (out of range) */
        bt      .Led_nop

        /* In range [0x40, 0xBF]: use 128-entry 16-bit dispatch table */
        mov.l   .Led_table_ptr_near, r1  /* r1 = ED table base (load early) */
        shll    r0                  /* r0 = index × 2 (fills load gap) */
        mov.w   @(r0, r1), r0      /* r0 = signed 16-bit offset */
        add     r1, r0              /* r0 = absolute handler address */
        jmp     @r0
        nop

.Led_nop:
        bra     .Led_ret_fetch
        nop

/* Early literal pool — these are referenced by the ED preamble above
   but the main pool at .Led_cyclesed / .Led_table_ptr is now too far
   (pcrel > 1022 bytes) due to the inline OTIR/OUTI code.            */
        .align 2
.Led_cyclesed_near:
        .long   _CyclesED
.Led_table_ptr_near:
        .long   _z80_ed_dispatch_table
.Lg_ed_sub_hist:
        .long   _g_ed_sub_hist

/* ---- ED: LDIR (0xB0) — Block transfer HL→DE, repeat until BC=0 ---- */
_z80_ed_ldir:
        sts.l   pr, @-r15

        /* Pre-compute R += 2 * (ICount / 21) — approximate */
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r2
        extu.b  r2, r2          /* r2 = R */
        /* R11 = ICount (pinned in register) */

.Lldir_loop:
        /* Read byte at (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _cold_gg_read
        extu.w  r4, r4 /* delay slot */ /* r4 = HL */
        /* r0 = byte read from (HL) */
        mov     r0, r5          /* r5 = value */

        /* Write byte to (DE) */
        mov     r14, r0
        add     #12, r0
        mov.w   @r0, r4
        bsr     _cold_gg_write
        extu.w  r4, r4 /* delay slot */ /* r4 = DE = write address */

        /* HL++ */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0

        /* DE++ */
        mov     r14, r0
        add     #12, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0

        /* BC-- */
        mov     r14, r0
        add     #10, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        mov     r1, r6           /* r6 = new BC */

        /* ICount -= 21 (R11 = ICount) */
        add     #-21, r11

        /* R += 2 per iteration */
        add     #2, r2

        /* Loop while BC != 0 && ICount > 0 */
        extu.w  r6, r6
        tst     r6, r6
        bt      .Lldir_done      /* BC == 0 → done */
        cmp/pl  r11              /* ICount > 0? */
        bt      .Lldir_loop

        /* Not done (BC != 0, ICount exhausted): PC -= 2, set N flag */
        add     #-2, r7
        extu.w  r7, r7
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0xD1, r3        /* ~(N_FLAG|H_FLAG|P_FLAG) = ~0x16 = 0xE9, no... */
        /* Clear N, H, P flags: F &= ~(N|H|P); F |= N */
        mov     #0xE9, r3        /* ~(N_FLAG|H_FLAG|P_FLAG) = ~(0x02|0x10|0x04) = ~0x16 */
        and     r3, r1
        mov     #0x02, r3        /* N_FLAG */
        or      r3, r1
        mov.b   r1, @r0

        /* Write R back */
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

.Lldir_done:
        /* BC == 0: ICount += 5, clear N|H|P */
        add     #5, r11

        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0xE9, r3        /* ~(N|H|P) */
        and     r3, r1
        mov.b   r1, @r0

        /* Write R back */
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---- ED: LDDR (0xB8) — Block transfer HL→DE decrement ---- */
_z80_ed_lddr:
        sts.l   pr, @-r15

        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r2
        extu.b  r2, r2

.Llddr_loop:
        /* Read byte at (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _cold_gg_read
        extu.w  r4, r4 /* delay slot */
        mov     r0, r5

        /* Write byte to (DE) */
        mov     r14, r0
        add     #12, r0
        mov.w   @r0, r4
        bsr     _cold_gg_write
        extu.w  r4, r4 /* delay slot */

        /* HL-- */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0

        /* DE-- */
        mov     r14, r0
        add     #12, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0

        /* BC-- */
        mov     r14, r0
        add     #10, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        mov     r1, r6

        /* ICount -= 21 (R11 = ICount) */
        add     #-21, r11

        add     #2, r2

        extu.w  r6, r6
        tst     r6, r6
        bt      .Llddr_done
        cmp/pl  r11
        bt      .Llddr_loop

        /* Not done: PC -= 2, set N flag */
        add     #-2, r7
        extu.w  r7, r7
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0xE9, r3
        and     r3, r1
        mov     #0x02, r3
        or      r3, r1
        mov.b   r1, @r0

        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

.Llddr_done:
        add     #5, r11

        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0xE9, r3
        and     r3, r1
        mov.b   r1, @r0

        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---- ED: LDI (0xA0) — Single block transfer HL→DE, BC-- ---- */
_z80_ed_ldi:
        sts.l   pr, @-r15

        /* Read (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _cold_gg_read
        extu.w  r4, r4 /* delay slot */
        mov     r0, r5

        /* Write to (DE) */
        mov     r14, r0
        add     #12, r0
        mov.w   @r0, r4
        bsr     _cold_gg_write
        extu.w  r4, r4 /* delay slot */

        /* HL++, DE++, BC-- */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0

        mov     r14, r0
        add     #12, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0

        mov     r14, r0
        add     #10, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        extu.w  r1, r6          /* r6 = new BC */

        /* F = (F & ~(N|H|P)) | (BC ? P_FLAG : 0) */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0xE9, r2       /* ~(N|H|P) */
        and     r2, r1
        tst     r6, r6
        bt      .Lldi_no_p
        mov     #0x04, r2       /* P_FLAG */
        or      r2, r1
.Lldi_no_p:
        mov.b   r1, @r0

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---- ED: LDD (0xA8) — Single block transfer HL→DE (decrement) ---- */
_z80_ed_ldd:
        sts.l   pr, @-r15

        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _cold_gg_read
        extu.w  r4, r4 /* delay slot */
        mov     r0, r5

        mov     r14, r0
        add     #12, r0
        mov.w   @r0, r4
        bsr     _cold_gg_write
        extu.w  r4, r4 /* delay slot */

        /* HL--, DE--, BC-- */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0

        mov     r14, r0
        add     #12, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0

        mov     r14, r0
        add     #10, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        extu.w  r1, r6

        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0xE9, r2
        and     r2, r1
        tst     r6, r6
        bt      .Lldd_no_p
        mov     #0x04, r2
        or      r2, r1
.Lldd_no_p:
        mov.b   r1, @r0

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ================================================================== */
/*  ED: OTIR (0xB3) — Output block: OUT(C), (HL++), B-- repeat       */
/*                                                                    */
/*  INLINE VDP DATA WRITE FAST PATH                                   */
/*  When port C targets VDP data (even port in 0x80-0xBE) and VRAM    */
/*  mode is active (!VDP_Pal), the entire write path is inlined:      */
/*    1. Read byte from (HL) via page table                           */
/*    2. Write byte to gg_vram[VDP_Address]                           */
/*    3. Mark tile_cache_dirty[VDP_Address >> 2] = 1                  */
/*    4. Mark tile_dirty_bits bit                                     */
/*    5. Update VDP_ReadLatch, VDP_Access_Mode                        */
/*    6. VDP_Address = (VDP_Address + 1) & 0x3FFF                     */
/*  No C function calls in the hot loop — cache stays warm.           */
/*                                                                    */
/*  gg_t struct offsets (verified by offsetof):                       */
/*    VDP_Address:     18 (uint16_t)                                  */
/*    VDP_Access_Mode: 20 (uint8_t)                                   */
/*    VDP_ReadLatch:   22 (uint8_t)                                   */
/*    VDP_Pal:         23 (uint8_t)                                   */
/* ================================================================== */

/* gg_t field offsets */
#define GG_VDP_ADDRESS      18
#define GG_VDP_ACCESS_MODE  20
#define GG_VDP_READLATCH    22
#define GG_VDP_PAL          23

_z80_ed_otir:
        sts.l   pr, @-r15

        /* Load R counter (z80_t.R at offset 15) */
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r2
        extu.b  r2, r2

        /* Check if port C qualifies for VDP data fast path:
         * Port must be even and in range 0x80-0xBE.
         * Test: (port & 0xC1) == 0x80
         * BC.B.l (C register) is at z80_t offset 11 */
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r0
        extu.b  r0, r1          /* r1 = port C */
        mov     #0xC1, r0
        and     r1, r0          /* r0 = port & 0xC1 */
        mov     #0x80, r3
        extu.b  r3, r3
        cmp/eq  r3, r0
        bf      .Lotir_slow     /* not VDP data port → generic path */

        /* Check VDP_Pal — must be 0 (VRAM mode, not CRAM) */
        mov.l   .Lotir_gg_addr, r3    /* r3 = &gg */
        mov     r3, r0
        add     #GG_VDP_PAL, r0
        mov.b   @r0, r0
        tst     r0, r0
        bf      .Lotir_slow     /* CRAM mode → generic path */

        /* ============================================================ */
        /* FAST PATH: Inline VDP VRAM write loop                        */
        /*                                                              */
        /* Register allocation:                                         */
        /*   R0  = scratch (SH-2 addressing constraint)                 */
        /*   R1  = scratch                                              */
        /*   R2  = R counter (Z80 refresh)                              */
        /*   R3  = &gg struct base (persistent in loop)                 */
        /*   R4  = HL (kept in reg, written back at end)                */
        /*   R5  = VDP_Address (kept in reg, written back at end)       */
        /*   R6  = B counter / value byte                               */
        /*   R7  = PC (pinned, unused in loop but preserved)            */
        /*   R8  = Mem_Pages (pinned, used by inline gg_read)           */
        /*   R9  = saved (repurposed as gg_vram base)                   */
        /*   R10 = 0x1FFF page mask (pinned, used by inline gg_read)   */
        /*   R11 = ICount (pinned, decremented each iteration)         */
        /*   R12 = A (pinned, untouched)                                */
        /*   R13 = saved (repurposed as tile_cache_dirty base)          */
        /*   R14 = z80_t* (pinned)                                      */
        /* ============================================================ */

        /* Save callee-saved regs we're repurposing */
        mov.l   r9, @-r15
        mov.l   r13, @-r15

        /* Load persistent pointers */
        mov.l   .Lotir_gg_vram, r9      /* R9 = gg_vram base */
        mov.l   .Lotir_tile_dirty, r13  /* R13 = tile_cache_dirty base */

        /* Load HL from struct */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        extu.w  r4, r4                  /* R4 = HL (16-bit) */

        /* Load VDP_Address from gg struct */
        mov     r3, r0
        add     #GG_VDP_ADDRESS, r0
        mov.w   @r0, r5
        extu.w  r5, r5                  /* R5 = VDP_Address */

        /* Load B from z80_t (BC.B.h at offset 10) */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r6
        extu.b  r6, r6                  /* R6 = B */

        /* Reset VDP_Access_Mode = 0 (done once, not per-byte) */
        mov     #0, r0
        mov     r3, r1
        add     #GG_VDP_ACCESS_MODE, r1
        mov.b   r0, @r1

        .align 4
.Lotir_fast_loop:
        /* ---- Step 1: Read byte from (HL) via page table ---- */
        /* Inline _inline_gg_read(R4) → result in R0 */
        mov     r4, r0
        shlr8   r0
        shlr2   r0
        shlr    r0
        shlr    r0
        shlr    r0
        shll2   r0              /* page index × 4 */
        mov.l   @(r0, r8), r1  /* r1 = Mem_Pages[page] */
        mov     r4, r0
        and     r10, r0         /* r0 = HL & 0x1FFF */
        mov.b   @(r0, r1), r0
        extu.b  r0, r0          /* R0 = byte read from (HL) */

        /* ---- Step 2: gg_vram[VDP_Address] = value ---- */
        /* mov.b Rm, @(R0, Rn): R0=offset, Rn=base, Rm=data */
        mov     r0, r1          /* R1 = value (save for later) */
        mov     r5, r0          /* R0 = VDP_Address (offset) */
        mov.b   r1, @(r0, r9)  /* gg_vram[VDP_Address] = value */

        /* ---- Step 3: tile_cache_dirty[VDP_Address >> 2] = 1 ---- */
        mov     r5, r0
        shlr2   r0              /* R0 = VDP_Address >> 2 */
        mov     #1, r6
        mov.b   r6, @(r0, r13) /* tile_cache_dirty[addr>>2] = 1 */

        /* ---- Step 4: tile_dirty_bits[tile_n>>3] |= (1<<(tile_n&7)) ---- */
        /* tile_n = VDP_Address >> 5 */
        mov     r5, r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* R0 = tile_n */
        mov     r0, r6          /* R6 = tile_n (save) */
        shlr2   r0
        shlr    r0              /* R0 = tile_n >> 3 = byte index */

        /* Save value (R1) on stack to free a register for tile_dirty_bits */
        mov.l   r1, @-r15      /* save value on stack */
        mov.l   .Lotir_tile_bits, r1  /* R1 = tile_dirty_bits base */
        add     r0, r1          /* R1 = &tile_dirty_bits[byte_idx] */
        mov     r6, r0
        and     #7, r0          /* R0 = tile_n & 7 */
        /* Compute 1 << R0 using shift loop (SH-2 has no shld) */
        mov     #1, r6          /* R6 = bit = 1 */
        tst     r0, r0
        bt      .Lotir_shift_done
.Lotir_shift_loop:
        shll    r6              /* bit <<= 1 */
        dt      r0              /* r0--; if r0==0 set T */
        bf      .Lotir_shift_loop
.Lotir_shift_done:
        /* R6 = 1 << (tile_n & 7), R1 = &tile_dirty_bits[byte_idx] */
        mov.b   @r1, r0
        extu.b  r0, r0
        or      r6, r0
        mov.b   r0, @r1         /* tile_dirty_bits[byte_idx] |= bit */

        /* Restore value from stack */
        mov.l   @r15+, r1      /* R1 = value */

        /* ---- Step 5: VDP_ReadLatch = value ---- */
        mov     r3, r0
        add     #GG_VDP_READLATCH, r0
        mov.b   r1, @r0

        /* ---- Step 6: VDP_Address = (VDP_Address + 1) & 0x3FFF ---- */
        add     #1, r5
        mov.l   .Lotir_3fff, r0
        and     r0, r5          /* R5 = new VDP_Address */

        /* ---- HL++ ---- */
        add     #1, r4
        extu.w  r4, r4

        /* ---- B-- ---- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r6
        extu.b  r6, r6
        add     #-1, r6
        mov.b   r6, @r0         /* write B back to struct */

        /* ---- ICount -= 21 ---- */
        add     #-21, r11

        /* ---- R += 2 ---- */
        add     #2, r2

        /* ---- Loop control ---- */
        tst     r6, r6
        bt      .Lotir_fast_done
        cmp/pl  r11
        bt      .Lotir_fast_loop

        /* ---- Not done (B > 0, ICount exhausted): PC -= 2 ---- */
        /* Write back HL, VDP_Address to struct/gg */
        mov     r14, r0
        add     #8, r0
        mov.w   r4, @r0         /* write HL */
        mov     r3, r0
        add     #GG_VDP_ADDRESS, r0
        mov.w   r5, @r0         /* write VDP_Address */

        /* Restore callee-saved regs */
        mov.l   @r15+, r13
        mov.l   @r15+, r9

        add     #-2, r7
        extu.w  r7, r7
        /* F = N_FLAG | (L+I > 255 ? C|H : 0) */
        /* R1 still holds last-written value; HL.B.l is R4 low byte */
        mov     r4, r0
        extu.b  r0, r0          /* L (low byte of new HL) */
        add     r1, r0          /* L + I */
        mov     #0x02, r6       /* N_FLAG */
        mov     #0xFF, r3
        extu.b  r3, r3
        cmp/hi  r3, r0          /* r0 > 255? */
        bf      .Lotir_fast_nc1
        mov     #0x11, r3       /* C_FLAG | H_FLAG */
        or      r3, r6
.Lotir_fast_nc1:
        mov     r14, r0
        add     #3, r0
        mov.b   r6, @r0         /* write F */

        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0         /* write R */

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

.Lotir_fast_done:
        /* B == 0: ICount += 5 */
        add     #5, r11

        /* Write back HL, VDP_Address to struct/gg */
        mov     r14, r0
        add     #8, r0
        mov.w   r4, @r0         /* write HL */
        mov     r3, r0
        add     #GG_VDP_ADDRESS, r0
        mov.w   r5, @r0         /* write VDP_Address */

        /* Restore callee-saved regs */
        mov.l   @r15+, r13
        mov.l   @r15+, r9

        /* F = Z|N | (L+I > 255 ? C|H : 0) */
        mov     r4, r0
        extu.b  r0, r0          /* L */
        add     r1, r0          /* L + I */
        mov     #0x42, r6       /* Z_FLAG | N_FLAG */
        mov     #0xFF, r3
        extu.b  r3, r3
        cmp/hi  r3, r0
        bf      .Lotir_fast_nc2
        mov     #0x11, r3
        or      r3, r6
.Lotir_fast_nc2:
        mov     r14, r0
        add     #3, r0
        mov.b   r6, @r0         /* write F */

        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0         /* write R */

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

        .align 2
.Lotir_gg_addr:
        .long   _gg
.Lotir_gg_vram:
        .long   _gg_vram
.Lotir_tile_dirty:
        .long   _tile_cache_dirty
.Lotir_tile_bits:
        .long   _tile_dirty_bits
.Lotir_3fff:
        .long   0x3FFF

/* ---- OTIR slow path: generic gg_out (non-VDP-data or CRAM mode) ---- */
.Lotir_slow:
        /* Reload R counter (already in R2 from above) */

.Lotir_slow_loop:
        /* Read (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _cold_gg_read
        extu.w  r4, r4 /* delay slot */

        /* gg_out(C, I) */
        mov     r0, r5          /* r5 = value */
        mov.l   r0, @-r15      /* save value */
        mov.l   r2, @-r15      /* save R counter */
        mov.l   r7, @-r15      /* save PC */
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led_gg_out, r0
        jsr     @r0
        extu.b  r4, r4 /* delay slot */
        mov.l   @r15+, r7
        mov.l   @r15+, r2
        mov.l   @r15+, r3      /* restore value to r3 */

        /* HL++ */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0

        /* B-- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        extu.b  r1, r6

        add     #-21, r11
        add     #2, r2

        tst     r6, r6
        bt      .Lotir_slow_done
        cmp/pl  r11
        bt      .Lotir_slow_loop

        /* Not done: PC -= 2 */
        add     #-2, r7
        extu.w  r7, r7
        mov     r14, r0
        add     #9, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        add     r3, r1
        mov     #0x02, r6       /* N_FLAG */
        mov.l   .Led_ff, r0
        cmp/hi  r0, r1
        bf      .Lotir_slow_nc1
        mov     #0x11, r3
        or      r3, r6
.Lotir_slow_nc1:
        mov     r14, r0
        add     #3, r0
        mov.b   r6, @r0

        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

.Lotir_slow_done:
        add     #5, r11
        mov     r14, r0
        add     #9, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        add     r3, r1
        mov     #0x42, r6       /* Z|N */
        mov.l   .Led_ff, r0
        cmp/hi  r0, r1
        bf      .Lotir_slow_nc2
        mov     #0x11, r3
        or      r3, r6
.Lotir_slow_nc2:
        mov     r14, r0
        add     #3, r0
        mov.b   r6, @r0

        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ================================================================== */
/*  ED: OUTI (0xA3) — Single output: OUT(C), (HL++), B--              */
/*                                                                    */
/*  Same inline VDP data write fast path as OTIR (single iteration).  */
/* ================================================================== */

_z80_ed_outi:
        sts.l   pr, @-r15

        /* Check if port C qualifies for VDP data fast path */
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r0
        extu.b  r0, r1          /* r1 = port C */
        mov     #0xC1, r0
        and     r1, r0
        mov     #0x80, r3
        extu.b  r3, r3
        cmp/eq  r3, r0
        bf      .Louti_slow

        /* Check VDP_Pal */
        mov.l   .Louti_gg_addr, r3
        mov     r3, r0
        add     #GG_VDP_PAL, r0
        mov.b   @r0, r0
        tst     r0, r0
        bf      .Louti_slow

        /* ---- FAST PATH: single VDP VRAM write ---- */
        /* Read (HL) via page table */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        extu.w  r4, r4          /* R4 = HL */

        mov     r4, r0
        shlr8   r0
        shlr2   r0
        shlr    r0
        shlr    r0
        shlr    r0
        shll2   r0
        mov.l   @(r0, r8), r1
        mov     r4, r0
        and     r10, r0
        mov.b   @(r0, r1), r0
        extu.b  r0, r0          /* R0 = byte from (HL) */
        mov     r0, r6          /* R6 = value (saved for flags) */

        /* Reset VDP_Access_Mode = 0 */
        mov     #0, r0
        mov     r3, r1
        add     #GG_VDP_ACCESS_MODE, r1
        mov.b   r0, @r1

        /* Load VDP_Address */
        mov     r3, r0
        add     #GG_VDP_ADDRESS, r0
        mov.w   @r0, r0
        extu.w  r0, r5          /* R5 = VDP_Address */

        /* gg_vram[VDP_Address] = value */
        mov.l   .Louti_gg_vram, r1
        mov     r5, r0
        mov.b   r6, @(r0, r1)

        /* tile_cache_dirty[VDP_Address >> 2] = 1 */
        mov.l   .Louti_tile_dirty, r1
        mov     r5, r0
        shlr2   r0
        mov     #1, r4          /* reuse R4 since HL no longer needed as-is */
        mov.b   r4, @(r0, r1)

        /* tile_dirty_bits[tile_n >> 3] |= (1 << (tile_n & 7)) */
        mov     r5, r0
        shlr2   r0
        shlr2   r0
        shlr    r0              /* R0 = tile_n = VDP_Address >> 5 */
        mov     r0, r1
        shlr2   r1
        shlr    r1              /* R1 = byte index */
        mov.l   .Louti_tile_bits, r4
        add     r1, r4          /* R4 = &tile_dirty_bits[byte_idx] */
        and     #7, r0          /* R0 = tile_n & 7 */
        /* Compute 1 << R0 using shift loop (SH-2 has no shld) */
        mov     #1, r1
        tst     r0, r0
        bt      .Louti_shift_done
.Louti_shift_loop:
        shll    r1
        dt      r0
        bf      .Louti_shift_loop
.Louti_shift_done:
        mov.b   @r4, r0
        extu.b  r0, r0
        or      r1, r0
        mov.b   r0, @r4

        /* VDP_ReadLatch = value */
        mov     r3, r0
        add     #GG_VDP_READLATCH, r0
        mov.b   r6, @r0

        /* VDP_Address = (VDP_Address + 1) & 0x3FFF */
        add     #1, r5
        mov.l   .Louti_3fff, r0
        and     r0, r5
        /* Write back VDP_Address */
        mov     r3, r0
        add     #GG_VDP_ADDRESS, r0
        mov.w   r5, @r0

        /* HL++ — write back to struct */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        extu.w  r4, r4
        add     #1, r4
        mov.w   r4, @r0

        /* B-- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        extu.b  r1, r1          /* R1 = new B */

        /* F = N | (B==0 ? Z : 0) | (L+I > 255 ? C|H : 0) */
        mov     #0x02, r3       /* N_FLAG */
        tst     r1, r1
        bf      .Louti_fast_nz
        mov     #0x42, r3       /* Z|N */
.Louti_fast_nz:
        mov     r4, r0
        extu.b  r0, r0          /* L = low byte of new HL */
        add     r6, r0          /* L + I */
        mov     #0xFF, r1
        extu.b  r1, r1
        cmp/hi  r1, r0
        bf      .Louti_fast_nc
        mov     #0x11, r1       /* C|H */
        or      r1, r3
.Louti_fast_nc:
        mov     r14, r0
        add     #3, r0
        mov.b   r3, @r0         /* write F */

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

        .align 2
.Louti_gg_addr:
        .long   _gg
.Louti_gg_vram:
        .long   _gg_vram
.Louti_tile_dirty:
        .long   _tile_cache_dirty
.Louti_tile_bits:
        .long   _tile_dirty_bits
.Louti_3fff:
        .long   0x3FFF

/* ---- OUTI slow path: generic gg_out (non-VDP-data or CRAM mode) ---- */
.Louti_slow:
        /* Read (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_a
        extu.w  r4, r4 /* delay slot */

        /* gg_out(C, I) */
        mov     r0, r5
        mov.l   r0, @-r15      /* save value */
        mov.l   r7, @-r15      /* save PC */
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led_gg_out, r0
        jsr     @r0
        extu.b  r4, r4 /* delay slot */
        mov.l   @r15+, r7
        mov.l   @r15+, r3      /* restore value to r3 */

        /* HL++ */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0

        /* B-- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        extu.b  r1, r6

        /* F = N | (B==0 ? Z : 0) | (L+I > 255 ? C|H : 0) */
        mov     #0x02, r3       /* N_FLAG */
        tst     r6, r6
        bf      .Louti_slow_nz
        mov     #0x42, r3       /* Z|N */
.Louti_slow_nz:
        mov     r14, r0
        add     #9, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        add     r3, r1
        mov.l   .Led_ff, r0
        cmp/hi  r0, r1
        bf      .Louti_slow_nc
        mov     #0x11, r1       /* C|H */
        or      r1, r3
.Louti_slow_nc:
        mov     r14, r0
        add     #3, r0
        mov.b   r3, @r0

        bra     .Led_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---- ED trampoline + pool ---- */
.Led_ret_fetch:
        mov.l   .Led_z80_fetch, r0
        jmp     @r0
        nop

        .align 2
.Led_cyclesed:
        .long   _CyclesED
.Led_z80_fetch:
        .long   _z80_fetch
.Led_gg_out:
        .long   _gg_out + 0x20000000
.Led_gg_in:
        .long   _gg_in + 0x20000000
.Led_zstable:
        .long   _ZSTable
.Led_pzstable:
        .long   _PZSTable
.Led_ff:
        .long   0x000000FF
.Led_table_ptr:
        .long   _z80_ed_dispatch_table
.Led_gg_read:
        .long   _inline_gg_read
.Led_gg_write:
        .long   _inline_gg_write

/* ---- Far-call trampolines Set A (tail-call via JMP, preserves PR) ---- */
/* For ED handler code that can't BSR directly to far-away routines */
_far_gg_read_a:
        mov.l   .Lfar_gg_read_a, r0
        jmp     @r0
        nop
_far_gg_write_a:
        mov.l   .Lfar_gg_write_a, r0
        jmp     @r0
        nop
_far_rebase_pc_a:
        mov.l   .Lfar_rebase_a, r0
        jmp     @r0
        nop
        .align 2
.Lfar_gg_read_a:
        .long   _inline_gg_read
.Lfar_gg_write_a:
        .long   _inline_gg_write
.Lfar_rebase_a:
        .long   _do_rebase_pc

/* ---- ED: Remaining C-fallback handler ---- */
/* For operations that are complex or rare, call C functions */
_z80_ed_c_fallback:
        /* Call the C CodesED with sub-opcode already consumed.
           We need to undo the fetch (PC--, R--) and call CodesED. */
        /* Actually, simplest: undo PC and R, then call CodesED */
        add     #-1, r7
        extu.w  r7, r7
        mov.w   r7, @r14        /* sync PC to struct for C */
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        /* Also undo ICount -= CyclesED[I] (add it back) */
        mov.l   .Led2_cyclesed, r0
        mov     r3, r1
        add     r0, r1
        mov.b   @r1, r0
        extu.b  r0, r0
        add     r0, r11        /* undo CyclesED charge (R11 = ICount) */
        /* Call CodesED(R) — sync R11 and A to struct first */
        mov.l   r11, @(Z80_ICOUNT, r14)
        mov     r12, r0
        mov.b   r0, @(2, r14)  /* sync A to struct for C fallback */
        mov     r14, r4
        mov.l   .Led2_codes_ed, r0
        sts.l   pr, @-r15
        jsr     @r0
        nop
        mov.l   @(Z80_ICOUNT, r14), r11  /* reload ICount */
        mov.b   @(2, r14), r0            /* reload A from struct */
        extu.b  r0, r12
        lds.l   @r15+, pr
        /* Reload PC from struct (C code may have changed it) */
        mov.w   @r14, r7
        /* Rebase PC since C code may have changed it */
        bsr     _far_rebase_pc_a
        extu.w  r7, r7 /* delay slot */
        bra     .Led2_ret_fetch
        nop

/* ---- ED: SBC_HL_BC (0x42) and friends ---- */
/* M_SBCW(Rg): HL = HL - Rg - CF, set flags */
/* Rg offset passed in r6 (e.g., 10 for BC, 12 for DE, 8 for HL, 16 for SP) */
_z80_ed_sbc_hl:
        /* Load HL */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        extu.w  r4, r4          /* r4 = HL */
        /* Load Rg */
        mov     r14, r0
        add     r6, r0
        mov.w   @r0, r5
        extu.w  r5, r5          /* r5 = Rg */
        /* I = CF */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x01, r2
        and     r2, r1          /* r1 = carry */
        /* J = (HL - Rg - carry) & 0xFFFF */
        mov     r4, r3
        sub     r5, r3
        sub     r1, r3
        extu.w  r3, r3          /* r3 = result (16-bit) */
        /* Build flags: N_FLAG always set */
        mov     #0x02, r6       /* F = N_FLAG */
        /* C: (long)HL - (long)Rg - (long)carry < 0 => borrow */
        mov     r4, r0
        sub     r5, r0
        sub     r1, r0
        /* Check bit 16 of 32-bit result */
        mov.l   .Led2_10000, r2
        tst     r2, r0
        bt      .Lsbcw_nc
        mov     #0x01, r2
        or      r2, r6          /* C_FLAG */
.Lsbcw_nc:
        /* V: (HL^Rg) & (HL^result) & 0x8000 */
        mov     r4, r0
        xor     r5, r0
        mov     r4, r1
        xor     r3, r1
        and     r0, r1
        mov.l   .Led2_8000, r2
        tst     r2, r1
        bt      .Lsbcw_nv
        mov     #0x04, r2       /* V_FLAG */
        or      r2, r6
.Lsbcw_nv:
        /* H: (HL ^ Rg ^ result) & 0x1000 */
        mov     r4, r0
        xor     r5, r0
        xor     r3, r0
        mov.l   .Led2_1000, r2
        tst     r2, r0
        bt      .Lsbcw_nh
        mov     #0x10, r2       /* H_FLAG */
        or      r2, r6
.Lsbcw_nh:
        /* Z: result == 0 */
        tst     r3, r3
        bf      .Lsbcw_nz
        mov     #0x40, r2       /* Z_FLAG */
        or      r2, r6
.Lsbcw_nz:
        /* S: result bit 15 */
        mov.l   .Led2_8000, r2
        tst     r2, r3
        bt      .Lsbcw_ns
        mov     #0x80, r2       /* S_FLAG - but #0x80 is -128 signed */
        extu.b  r2, r2
        or      r2, r6
.Lsbcw_ns:
        /* Store HL = result */
        mov     r14, r0
        add     #8, r0
        mov.w   r3, @r0
        /* Store F */
        mov     r14, r0
        add     #3, r0
        bra     .Led2_ret_fetch
        mov.b   r6, @r0 /* delay slot */

/* ---- ED: ADC_HL (shared, Rg offset in r6) ---- */
_z80_ed_adc_hl:
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        extu.w  r4, r4
        mov     r14, r0
        add     r6, r0
        mov.w   @r0, r5
        extu.w  r5, r5
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x01, r2
        and     r2, r1
        /* J = (HL + Rg + carry) & 0xFFFF */
        mov     r4, r3
        add     r5, r3
        add     r1, r3
        extu.w  r3, r3
        /* Flags: no N */
        mov     #0, r6
        /* C: (long)HL + (long)Rg + carry > 0xFFFF */
        mov     r4, r0
        add     r5, r0
        add     r1, r0
        mov.l   .Led2_10000, r2
        tst     r2, r0
        bt      .Ladcw_nc
        mov     #0x01, r2
        or      r2, r6
.Ladcw_nc:
        /* V: ~(HL^Rg) & (Rg^result) & 0x8000 */
        mov     r4, r0
        xor     r5, r0
        not     r0, r0
        mov     r5, r1
        xor     r3, r1
        and     r0, r1
        mov.l   .Led2_8000, r2
        tst     r2, r1
        bt      .Ladcw_nv
        mov     #0x04, r2
        or      r2, r6
.Ladcw_nv:
        /* H: (HL ^ Rg ^ result) & 0x1000 */
        mov     r4, r0
        xor     r5, r0
        xor     r3, r0
        mov.l   .Led2_1000, r2
        tst     r2, r0
        bt      .Ladcw_nh
        mov     #0x10, r2
        or      r2, r6
.Ladcw_nh:
        tst     r3, r3
        bf      .Ladcw_nz
        mov     #0x40, r2
        or      r2, r6
.Ladcw_nz:
        mov.l   .Led2_8000, r2
        tst     r2, r3
        bt      .Ladcw_ns
        mov     #0x80, r2
        extu.b  r2, r2
        or      r2, r6
.Ladcw_ns:
        mov     r14, r0
        add     #8, r0
        mov.w   r3, @r0
        mov     r14, r0
        add     #3, r0
        bra     .Led2_ret_fetch
        mov.b   r6, @r0 /* delay slot */

/* ---- ED: Dispatch stubs for SBC_HL / ADC_HL variants ---- */
_z80_ed_sbc_hl_bc:
        bra     _z80_ed_sbc_hl
        mov     #10, r6 /* delay slot */
_z80_ed_sbc_hl_de:
        bra     _z80_ed_sbc_hl
        mov     #12, r6 /* delay slot */
_z80_ed_sbc_hl_hl:
        bra     _z80_ed_sbc_hl
        mov     #8, r6 /* delay slot */
_z80_ed_sbc_hl_sp:
        bra     _z80_ed_sbc_hl
        mov     #16, r6 /* delay slot */
_z80_ed_adc_hl_bc:
        bra     _z80_ed_adc_hl
        mov     #10, r6 /* delay slot */
_z80_ed_adc_hl_de:
        bra     _z80_ed_adc_hl
        mov     #12, r6 /* delay slot */
_z80_ed_adc_hl_hl:
        bra     _z80_ed_adc_hl
        mov     #8, r6 /* delay slot */
_z80_ed_adc_hl_sp:
        bra     _z80_ed_adc_hl
        mov     #16, r6 /* delay slot */

/* ---- ED: NEG (0x44) ---- */
_z80_ed_neg:
        /* I = A; A = 0; M_SUB(I) */
        mov     r12, r3          /* r3 = old A (pinned in R12) */
        bsr     _alu_sub_flags
        mov     #0, r4 /* delay slot */ /* r4 = new A (0) */
        bra     .Led2_ret_fetch
        nop

/* ---- ED: RETI (0x4D) / RETN (0x45) ---- */
_z80_ed_reti:
_z80_ed_retn:
        sts.l   pr, @-r15
        /* if (IFF2) IFF1 = set; else IFF1 = clear */
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #IFF_2, r2
        tst     r2, r1
        bt      .Lretn_clear
        mov     #IFF_1, r2
        bra     .Lretn_store
        or      r2, r1 /* delay slot */
.Lretn_clear:
        mov     #IFF_1, r2
        not     r2, r2
        and     r2, r1
.Lretn_store:
        mov     r14, r0
        add     #14, r0
        mov.b   r1, @r0

        /* M_RET: pop PC from stack */
        /* Read low byte at SP */
        mov     r14, r0
        add     #16, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_a
        extu.w  r4, r4 /* delay slot */ /* r4 = SP */
        mov     r0, r6          /* r6 = low byte */
        /* Read high byte at SP+1 */
        mov     r14, r0
        add     #16, r0
        mov.w   @r0, r4
        extu.w  r4, r4
        bsr     _far_gg_read_a
        add     #1, r4 /* delay slot */
        /* PC = (high << 8) | low */
        shll8   r0
        or      r6, r0
        extu.w  r0, r7
        /* SP += 2 */
        mov     r14, r0
        add     #16, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #2, r1

        /* Rebase PC */
        bsr     _far_rebase_pc_a
        mov.w   r1, @r0 /* delay slot */

        bra     .Led2_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---- ED: IM 0/1/2 ---- */
_z80_ed_im0:
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        /* Clear IFF_IM1 and IFF_IM2: IFF &= ~(IM1|IM2) */
        mov     #IFF_IM1, r2
        not     r2, r2
        and     r2, r1
        mov     #IFF_IM2, r2
        not     r2, r2
        and     r2, r1
        bra     .Led2_ret_fetch
        mov.b   r1, @r0 /* delay slot */

_z80_ed_im1:
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #IFF_IM2, r2
        not     r2, r2
        and     r2, r1          /* clear IM2 */
        mov     #IFF_IM1, r2
        or      r2, r1          /* set IM1 */
        bra     .Led2_ret_fetch
        mov.b   r1, @r0 /* delay slot */

_z80_ed_im2:
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #IFF_IM1, r2
        not     r2, r2
        and     r2, r1          /* clear IM1 */
        mov     #IFF_IM2, r2
        or      r2, r1          /* set IM2 */
        bra     .Led2_ret_fetch
        mov.b   r1, @r0 /* delay slot */

/* ---- ED: LD I,A / LD R,A / LD A,I / LD A,R ---- */
_z80_ed_ld_i_a:
        mov     r14, r0
        add     #2, r0
        mov.b   @r0, r1
        mov     r14, r0
        add     #22, r0         /* I at offset 22 */
        bra     .Led2_ret_fetch
        mov.b   r1, @r0 /* delay slot */

_z80_ed_ld_r_a:
        mov     r14, r0
        add     #2, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     r14, r0
        add     #15, r0
        mov.b   r1, @r0
        /* R7 = A & 0x80 */
        mov     r1, r0
        and     #0x80, r0       /* AND imm only on R0 */
        mov     r14, r2
        add     #23, r2         /* R7 at offset 23 */
        bra     .Led2_ret_fetch
        mov.b   r0, @r2 /* delay slot */

_z80_ed_ld_a_i:
        mov     r14, r0
        add     #22, r0
        mov.b   @r0, r1
        /* A = I */
        mov     r14, r0
        add     #2, r0
        mov.b   r1, @r0
        extu.b  r1, r1
        /* F = (F & C_FLAG) | (IFF2 ? P_FLAG : 0) | ZSTable[A] */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r2
        extu.b  r2, r2
        mov     #0x01, r3
        and     r3, r2          /* r2 = old C_FLAG */
        /* Check IFF2 */
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r3
        extu.b  r3, r3
        mov     #IFF_2, r0
        tst     r0, r3
        bt      .Llai_no_p
        mov     #0x04, r0       /* P_FLAG */
        or      r0, r2
.Llai_no_p:
        /* ZSTable[A] */
        mov.l   .Led2_zstable, r0
        add     r1, r0
        mov.b   @r0, r0
        extu.b  r0, r0
        or      r0, r2
        mov     r14, r0
        add     #3, r0
        bra     .Led2_ret_fetch
        mov.b   r2, @r0 /* delay slot */

_z80_ed_ld_a_r:
        /* A = R7 | (R & 0x7F) */
        mov     r14, r0
        add     #23, r0         /* R7 */
        mov.b   @r0, r1
        extu.b  r1, r1          /* r1 = R7 (bit 7 only) */
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r2
        extu.b  r2, r2
        mov     #0x7F, r3
        and     r3, r2          /* r2 = R & 0x7F */
        or      r2, r1          /* r1 = A = R7 | (R & 0x7F) */
        mov     r14, r0
        add     #2, r0
        mov.b   r1, @r0
        /* F = (F & C) | (IFF2 ? P : 0) | ZSTable[A] */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r2
        extu.b  r2, r2
        mov     #0x01, r3
        and     r3, r2
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r3
        extu.b  r3, r3
        mov     #IFF_2, r0
        tst     r0, r3
        bt      .Llar_no_p
        mov     #0x04, r0
        or      r0, r2
.Llar_no_p:
        mov.l   .Led2_zstable, r0
        add     r1, r0
        mov.b   @r0, r0
        extu.b  r0, r0
        or      r0, r2
        mov     r14, r0
        add     #3, r0
        bra     .Led2_ret_fetch
        mov.b   r2, @r0 /* delay slot */

/* ---- ED: Pool 2 + trampoline ---- */
.Led2_ret_fetch:
        mov.l   .Led2_z80_fetch, r0
        jmp     @r0
        nop

        .align 2
.Led2_z80_fetch:
        .long   _z80_fetch
.Led2_cyclesed:
        .long   _CyclesED
.Led2_codes_ed:
        .long   _CodesED + 0x20000000
.Led2_10000:
        .long   0x00010000
.Led2_8000:
        .long   0x00008000
.Led2_1000:
        .long   0x00001000
.Led2_zstable:
        .long   _ZSTable

/* ================================================================ */
/*  ED: IN r,(C) — Port input with flags                 */
/*  M_IN(Rg): Rg = gg_in(C); F = PZSTable[Rg] | (F & C_FLAG)    */
/*  r3 = sub-opcode from ED dispatch. C port = BC.B.l (offset 11)  */
/* ================================================================ */

/* Generic IN r,(C) handler.
   r3 still holds the sub-opcode; we decode which register from it.
   Sub-opcode pattern: 0x40+reg*8 where reg = B,C,D,E,H,L,F,A
   The register index is in bits [5:3]: (sub_opcode >> 3) & 7
   Maps: 0=B(+10), 1=C(+11), 2=D(+12), 3=E(+13), 4=H(+8), 5=L(+9), 6=F(discard), 7=A(+2)
*/

_z80_ed_in_b_c:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3a_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        lds.l   @r15+, pr
        extu.b  r0, r0
        /* Store to B (BC.B.h = offset 10) */
        mov     r14, r1
        add     #10, r1
        mov.b   r0, @r1
        bra     .Led3_in_flags
        nop

_z80_ed_in_c_c:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3a_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        lds.l   @r15+, pr
        extu.b  r0, r0
        /* Store to C (BC.B.l = offset 11) */
        mov     r14, r1
        add     #11, r1
        mov.b   r0, @r1
        bra     .Led3_in_flags
        nop

_z80_ed_in_d_c:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3a_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        lds.l   @r15+, pr
        extu.b  r0, r0
        /* Store to D (DE.B.h = offset 12) */
        mov     r14, r1
        add     #12, r1
        mov.b   r0, @r1
        bra     .Led3_in_flags
        nop

_z80_ed_in_e_c:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3a_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        lds.l   @r15+, pr
        extu.b  r0, r0
        /* Store to E (DE.B.l = offset 13) */
        mov     r14, r1
        add     #13, r1
        mov.b   r0, @r1
        bra     .Led3_in_flags
        nop

_z80_ed_in_h_c:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3a_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        lds.l   @r15+, pr
        extu.b  r0, r0
        /* Store to H (HL.B.h = offset 8) */
        mov     r14, r1
        add     #8, r1
        mov.b   r0, @r1
        bra     .Led3_in_flags
        nop

_z80_ed_in_l_c:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3a_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        lds.l   @r15+, pr
        extu.b  r0, r0
        /* Store to L (HL.B.l = offset 9) */
        mov     r14, r1
        add     #9, r1
        mov.b   r0, @r1
        bra     .Led3_in_flags
        nop

_z80_ed_in_a_c:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3a_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        lds.l   @r15+, pr
        extu.b  r0, r12         /* Store to A (pinned R12) */
        mov     r12, r0
        bra     .Led3_in_flags
        nop

_z80_ed_in_f_c:
        /* IN F,(C): read port, set flags, discard value */
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3a_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        lds.l   @r15+, pr
        extu.b  r0, r0
        /* Fall through to flags — value discarded */

/* Common IN flag computation: F = PZSTable[r0] | (F & C_FLAG) */
.Led3_in_flags:
        mov.l   .Led3a_pzstable, r1
        add     r0, r1
        mov.b   @r1, r1
        extu.b  r1, r1          /* r1 = PZSTable[val] */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r2
        extu.b  r2, r2
        mov     #0x01, r3       /* C_FLAG */
        and     r3, r2          /* r2 = old carry */
        or      r2, r1          /* r1 = PZSTable[val] | old_C */
        bra     .Led3a_ret_fetch
        mov.b   r1, @r0 /* delay slot */

/* ================================================================ */
/*  ED: OUT (C),r — Port output                          */
/*  gg_out(C, Rg) — no flag changes                               */
/* ================================================================ */

_z80_ed_out_c_b:
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r5
        bra     .Led3_out_common
        extu.b  r5, r5 /* delay slot */

_z80_ed_out_c_c:
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r5
        bra     .Led3_out_common
        extu.b  r5, r5 /* delay slot */

_z80_ed_out_c_d:
        mov     r14, r0
        add     #12, r0
        mov.b   @r0, r5
        bra     .Led3_out_common
        extu.b  r5, r5 /* delay slot */

_z80_ed_out_c_e:
        mov     r14, r0
        add     #13, r0
        mov.b   @r0, r5
        bra     .Led3_out_common
        extu.b  r5, r5 /* delay slot */

_z80_ed_out_c_h:
        mov     r14, r0
        add     #8, r0
        mov.b   @r0, r5
        bra     .Led3_out_common
        extu.b  r5, r5 /* delay slot */

_z80_ed_out_c_l:
        mov     r14, r0
        add     #9, r0
        mov.b   @r0, r5
        bra     .Led3_out_common
        extu.b  r5, r5 /* delay slot */

_z80_ed_out_c_a:
        bra     .Led3_out_common
        mov     r12, r5 /* delay slot */

_z80_ed_out_c_0:
        bra     .Led3_out_common
        mov     #0, r5 /* delay slot */

/* Common OUT (C),val: gg_out(C_port, r5) */
.Led3_out_common:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3a_gg_out, r0
        jsr     @r0
        extu.b  r4, r4 /* delay slot */
        mov.l   @r15+, r7
        bra     .Led3a_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---- ED: Pool 3a (IN/OUT handlers) ---- */
.Led3a_ret_fetch:
        mov.l   .Led3a_z80_fetch, r0
        jmp     @r0
        nop

        .align 2
.Led3a_z80_fetch:
        .long   _z80_fetch
.Led3a_gg_in:
        .long   _gg_in + 0x20000000
.Led3a_gg_out:
        .long   _gg_out + 0x20000000
.Led3a_pzstable:
        .long   _PZSTable

/* ================================================================ */
/*  ED: LD (nn),rr — Store 16-bit register to memory     */
/* ================================================================ */

_z80_ed_ld_xnn_bc:
        mov     #10, r6         /* BC offset */
        bra     .Led3_ld_xnn_rr
        nop

_z80_ed_ld_xnn_de:
        mov     #12, r6         /* DE offset */
        bra     .Led3_ld_xnn_rr
        nop

_z80_ed_ld_xnn_hl:
        mov     #8, r6          /* HL offset */
        bra     .Led3_ld_xnn_rr
        nop

_z80_ed_ld_xnn_sp:
        mov     #16, r6         /* SP offset */
        /* fall through */

/* Common: read nn from PC, write rr.l to (nn), rr.h to (nn+1) */
.Led3_ld_xnn_rr:
        sts.l   pr, @-r15
        /* Fetch low byte of address */
        bsr     _far_fetch_imm3
        nop
        mov     r3, r5          /* r5 = low byte of addr */
        /* Fetch high byte of address */
        bsr     _far_fetch_imm3
        nop
        shll8   r3
        or      r5, r3          /* r3 = 16-bit address */
        /* Load register pair word */
        mov     r14, r0
        add     r6, r0
        mov.w   @r0, r6         /* r6 = rr word (big-endian: high, low) */
        /* Write low byte to (nn) */
        mov     r3, r4          /* r4 = address */
        extu.w  r4, r4
        mov     r6, r5
        bsr     _far_gg_write_c
        extu.b  r5, r5 /* delay slot */
        /* Write high byte to (nn+1) */
        add     #1, r4
        extu.w  r4, r4
        mov     r6, r5
        shlr8   r5
        bsr     _far_gg_write_c
        extu.b  r5, r5 /* delay slot */
        bra     .Led3b_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ================================================================ */
/*  ED: LD rr,(nn) — Load 16-bit register from memory    */
/* ================================================================ */

_z80_ed_ld_bc_xnn:
        mov     #10, r6         /* BC offset */
        bra     .Led3_ld_rr_xnn
        nop

_z80_ed_ld_de_xnn:
        mov     #12, r6         /* DE offset */
        bra     .Led3_ld_rr_xnn
        nop

_z80_ed_ld_hl_xnn:
        mov     #8, r6          /* HL offset */
        bra     .Led3_ld_rr_xnn
        nop

_z80_ed_ld_sp_xnn:
        mov     #16, r6         /* SP offset */
        /* fall through */

/* Common: read nn from PC, read 16-bit from (nn) into rr */
.Led3_ld_rr_xnn:
        sts.l   pr, @-r15
        /* Fetch low byte of address */
        bsr     _far_fetch_imm3
        nop
        mov     r3, r5          /* r5 = low byte of addr */
        /* Fetch high byte of address */
        bsr     _far_fetch_imm3
        nop
        shll8   r3
        or      r5, r3          /* r3 = 16-bit address */
        /* Read low byte from (nn) */
        bsr     _far_gg_read_c
        mov     r3, r4 /* delay slot */
        mov     r0, r5          /* r5 = low byte */
        /* Read high byte from (nn+1) */
        add     #1, r4
        bsr     _far_gg_read_c
        extu.w  r4, r4 /* delay slot */
        /* Combine: word = (high << 8) | low */
        shll8   r0
        or      r5, r0
        /* Store to register pair */
        mov     r14, r1
        add     r6, r1
        mov.w   r0, @r1
        bra     .Led3b_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ================================================================ */
/*  ED: RRD / RLD — BCD nibble rotate                    */
/* ================================================================ */

_z80_ed_rrd:
        sts.l   pr, @-r15
        /* Read (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_c
        extu.w  r4, r4 /* delay slot */
        /* r0 = I = (HL) */
        mov     r0, r3          /* r3 = I */
        /* J = (I >> 4) | (A << 4) */
        mov     r3, r5
        shlr2   r5
        shlr2   r5              /* r5 = I >> 4 */
        mov     r12, r6         /* r6 = A */
        shll2   r6
        shll2   r6              /* r6 = A << 4 */
        or      r5, r6          /* r6 = (I >> 4) | (A << 4) = J */
        extu.b  r6, r6
        /* Write J to (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        mov     r6, r5
        bsr     _far_gg_write_c
        extu.w  r4, r4 /* delay slot */
        /* A = (I & 0x0F) | (A & 0xF0) */
        mov     r3, r0
        and     #0x0F, r0       /* AND imm only on R0 */
        mov     r12, r1
        mov     #0xF0, r2
        extu.b  r2, r2
        and     r2, r1          /* r1 = A & 0xF0 */
        or      r1, r0
        extu.b  r0, r12         /* R12 = new A */
        /* F = PZSTable[A] | (F & C_FLAG) */
        mov.l   .Led3b_pzstable, r1
        mov     r12, r0
        add     r0, r1
        mov.b   @r1, r1
        extu.b  r1, r1
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r2
        extu.b  r2, r2
        mov     #0x01, r3
        and     r3, r2          /* old carry */
        or      r2, r1
        mov.b   r1, @r0
        /* Sync A to struct */
        mov     r12, r0
        mov.b   r0, @(2, r14)
        bra     .Led3b_ret_fetch
        lds.l   @r15+, pr /* delay slot */

_z80_ed_rld:
        sts.l   pr, @-r15
        /* Read (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_c
        extu.w  r4, r4 /* delay slot */
        /* r0 = I = (HL) */
        mov     r0, r3          /* r3 = I */
        /* J = (I << 4) | (A & 0x0F) */
        mov     r3, r5
        shll2   r5
        shll2   r5              /* r5 = I << 4 */
        mov     r12, r0
        and     #0x0F, r0       /* AND imm only on R0: A & 0x0F */
        or      r0, r5          /* r5 = (I << 4) | (A & 0x0F) = J */
        extu.b  r5, r5
        /* Write J to (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_write_c
        extu.w  r4, r4 /* delay slot */
        /* A = (I >> 4) | (A & 0xF0) */
        mov     r3, r0
        shlr2   r0
        shlr2   r0              /* r0 = I >> 4 */
        mov     r12, r1
        mov     #0xF0, r2
        extu.b  r2, r2
        and     r2, r1          /* r1 = A & 0xF0 */
        or      r1, r0
        extu.b  r0, r12         /* R12 = new A */
        /* F = PZSTable[A] | (F & C_FLAG) */
        mov.l   .Led3b_pzstable, r1
        mov     r12, r0
        add     r0, r1
        mov.b   @r1, r1
        extu.b  r1, r1
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r2
        extu.b  r2, r2
        mov     #0x01, r3
        and     r3, r2
        or      r2, r1
        mov.b   r1, @r0
        /* Sync A to struct */
        mov     r12, r0
        mov.b   r0, @(2, r14)
        bra     .Led3b_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---- ED: Pool 3b (LD/RRD/RLD/CPI/CPIR/CPD/CPDR/INI etc.) ---- */
.Led3b_ret_fetch:
        mov.l   .Led3b_z80_fetch, r0
        jmp     @r0
        nop

        .align 2
.Led3b_z80_fetch:
        .long   _z80_fetch
.Led3b_pzstable:
        .long   _PZSTable
.Led3b_zstable:
        .long   _ZSTable
.Led3b_gg_in:
        .long   _gg_in + 0x20000000
.Led3b_gg_out:
        .long   _gg_out + 0x20000000
.Led3b_ff:
        .long   0x000000FF

/* ================================================================ */
/*  ED: CPI (0xA1) — Compare and Increment               */
/* ================================================================ */

_z80_ed_cpi:
        sts.l   pr, @-r15
        /* Read I = (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_c
        extu.w  r4, r4 /* delay slot */
        /* r0 = I = byte at (HL) */
        mov     r0, r3          /* r3 = I */
        /* J.B.l = A - I */
        mov     r12, r0
        sub     r3, r0
        extu.b  r0, r6          /* r6 = J.B.l = (A - I) & 0xFF */
        /* HL++ */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0
        /* BC-- */
        mov     r14, r0
        add     #10, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        mov     r1, r5          /* r5 = new BC */
        /* F = N | (F & C) | ZSTable[J.B.l] | ((A^I^J.B.l)&H) | (BC ? P : 0) */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r2
        extu.b  r2, r2
        mov     #0x01, r1
        and     r1, r2          /* r2 = old carry */
        mov     #0x02, r1       /* N_FLAG */
        or      r1, r2          /* r2 = N | old_C */
        /* ZSTable[J.B.l] */
        mov.l   .Led3c_zstable, r1
        add     r6, r1
        mov.b   @r1, r1
        extu.b  r1, r1
        or      r1, r2
        /* H_FLAG: (A ^ I ^ J.B.l) & 0x10 */
        mov     r12, r0
        xor     r3, r0
        xor     r6, r0
        mov     #0x10, r1       /* H_FLAG */
        and     r1, r0
        or      r0, r2
        /* P_FLAG if BC != 0 */
        extu.w  r5, r5
        tst     r5, r5
        bt      .Lcpi_no_p
        mov     #0x04, r0       /* P_FLAG */
        or      r0, r2
.Lcpi_no_p:
        mov     r14, r0
        add     #3, r0
        mov.b   r2, @r0
        bra     .Led3b_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ================================================================ */
/*  ED: CPD (0xA9) — Compare and Decrement               */
/* ================================================================ */

_z80_ed_cpd:
        sts.l   pr, @-r15
        /* Read I = (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_c
        extu.w  r4, r4 /* delay slot */
        mov     r0, r3          /* r3 = I */
        /* J.B.l = A - I */
        mov     r12, r0
        sub     r3, r0
        extu.b  r0, r6          /* r6 = J.B.l */
        /* HL-- */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        /* BC-- */
        mov     r14, r0
        add     #10, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        mov     r1, r5          /* r5 = new BC */
        /* F = N | (F & C) | ZSTable[J.B.l] | ((A^I^J.B.l)&H) | (BC ? P : 0) */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r2
        extu.b  r2, r2
        mov     #0x01, r1
        and     r1, r2
        mov     #0x02, r1
        or      r1, r2
        mov.l   .Led3c_zstable, r1
        add     r6, r1
        mov.b   @r1, r1
        extu.b  r1, r1
        or      r1, r2
        mov     r12, r0
        xor     r3, r0
        xor     r6, r0
        mov     #0x10, r1
        and     r1, r0
        or      r0, r2
        extu.w  r5, r5
        tst     r5, r5
        bt      .Lcpd_no_p
        mov     #0x04, r0
        or      r0, r2
.Lcpd_no_p:
        mov     r14, r0
        add     #3, r0
        mov.b   r2, @r0
        bra     .Led3b_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ================================================================ */
/*  ED: CPIR (0xB1) — Compare, Increment, Repeat         */
/* ================================================================ */

_z80_ed_cpir:
        sts.l   pr, @-r15

        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r2
        extu.b  r2, r2          /* r2 = R counter */

.Lcpir_loop:
        /* Read I = (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_c
        extu.w  r4, r4 /* delay slot */
        mov     r0, r3          /* r3 = I */
        /* J.B.l = A - I */
        mov     r12, r0
        sub     r3, r0
        extu.b  r0, r6          /* r6 = J.B.l */
        /* HL++ */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0
        /* BC-- */
        mov     r14, r0
        add     #10, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        mov     r1, r5          /* r5 = new BC */
        /* ICount -= 21 */
        add     #-21, r11
        /* R += 2 */
        add     #2, r2
        /* Loop while BC != 0 && J.B.l != 0 && ICount > 0 */
        extu.w  r5, r5
        tst     r5, r5
        bt      .Lcpir_done     /* BC == 0 */
        tst     r6, r6
        bt      .Lcpir_done     /* J.B.l == 0 (match found) */
        cmp/pl  r11
        bt      .Lcpir_loop

        /* Not done: PC -= 2 */
        add     #-2, r7
        extu.w  r7, r7
.Lcpir_done:
        /* If BC && J.B.l: no extra cycles. Else ICount += 5 */
        extu.w  r5, r5
        tst     r5, r5
        bt      .Lcpir_bc_zero
        tst     r6, r6
        bf      .Lcpir_flags    /* BC!=0 && J!=0: exhausted, no +5 */
.Lcpir_bc_zero:
        add     #5, r11
.Lcpir_flags:
        /* F = N | (F & C) | ZSTable[J.B.l] | ((A^I^J.B.l)&H) | (BC ? P : 0) */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x01, r0
        and     r0, r1          /* old carry */
        mov     #0x02, r0       /* N_FLAG */
        or      r0, r1
        mov.l   .Led3c_zstable, r0
        mov     r0, r4
        add     r6, r4
        mov.b   @r4, r0
        extu.b  r0, r0
        or      r0, r1
        mov     r12, r0
        xor     r3, r0
        xor     r6, r0
        mov     #0x10, r4
        and     r4, r0
        or      r0, r1
        extu.w  r5, r5
        tst     r5, r5
        bt      .Lcpir_no_p
        mov     #0x04, r0
        or      r0, r1
.Lcpir_no_p:
        mov     r14, r0
        add     #3, r0
        mov.b   r1, @r0
        /* Write R back */
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0
        bra     .Led3b_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ================================================================ */
/*  ED: CPDR (0xB9) — Compare, Decrement, Repeat         */
/* ================================================================ */

_z80_ed_cpdr:
        sts.l   pr, @-r15

        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r2
        extu.b  r2, r2          /* r2 = R counter */

.Lcpdr_loop:
        /* Read I = (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_c
        extu.w  r4, r4 /* delay slot */
        mov     r0, r3          /* r3 = I */
        /* J.B.l = A - I */
        mov     r12, r0
        sub     r3, r0
        extu.b  r0, r6          /* r6 = J.B.l */
        /* HL-- */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        /* BC-- */
        mov     r14, r0
        add     #10, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        mov     r1, r5          /* r5 = new BC */
        /* ICount -= 21 */
        add     #-21, r11
        /* R += 2 */
        add     #2, r2
        /* Loop while BC != 0 && J.B.l != 0 && ICount > 0 */
        extu.w  r5, r5
        tst     r5, r5
        bt      .Lcpdr_done
        tst     r6, r6
        bt      .Lcpdr_done
        cmp/pl  r11
        bt      .Lcpdr_loop

        /* Not done: PC -= 2 */
        add     #-2, r7
        extu.w  r7, r7
.Lcpdr_done:
        extu.w  r5, r5
        tst     r5, r5
        bt      .Lcpdr_bc_zero
        tst     r6, r6
        bf      .Lcpdr_flags
.Lcpdr_bc_zero:
        add     #5, r11
.Lcpdr_flags:
        /* F = N | (F & C) | ZSTable[J.B.l] | ((A^I^J.B.l)&H) | (BC ? P : 0) */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x01, r0
        and     r0, r1
        mov     #0x02, r0
        or      r0, r1
        mov.l   .Led3c_zstable, r0
        mov     r0, r4
        add     r6, r4
        mov.b   @r4, r0
        extu.b  r0, r0
        or      r0, r1
        mov     r12, r0
        xor     r3, r0
        xor     r6, r0
        mov     #0x10, r4
        and     r4, r0
        or      r0, r1
        extu.w  r5, r5
        tst     r5, r5
        bt      .Lcpdr_no_p
        mov     #0x04, r0
        or      r0, r1
.Lcpdr_no_p:
        mov     r14, r0
        add     #3, r0
        mov.b   r1, @r0
        /* Write R back */
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0
        bra     .Led3_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---- Literal pool 3c (for CPI/CPD/CPIR/CPDR) ---- */
        .align 2
.Led3c_zstable:
        .long   _ZSTable

/* ================================================================ */
/*  ED: INI / IND / INIR / INDR — Block input            */
/* ================================================================ */

_z80_ed_ini:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        /* gg_in(C) → value */
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        mov     r0, r5          /* r5 = value */
        /* gg_write(HL, value) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_write_c
        extu.w  r4, r4 /* delay slot */
        /* HL++ */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0
        /* B-- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        extu.b  r1, r1
        /* F = N | (B ? 0 : Z) */
        mov     #0x02, r2       /* N_FLAG */
        tst     r1, r1
        bf      .Lini_nz
        mov     #0x42, r2       /* Z|N */
.Lini_nz:
        mov     r14, r0
        add     #3, r0
        mov.b   r2, @r0
        bra     .Led3_ret_fetch
        lds.l   @r15+, pr /* delay slot */

_z80_ed_ind:
        sts.l   pr, @-r15
        mov.l   r7, @-r15
        /* gg_in(C) → value */
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        mov     r0, r5          /* r5 = value */
        /* gg_write(HL, value) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_write_c
        extu.w  r4, r4 /* delay slot */
        /* HL-- */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        /* B-- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        extu.b  r1, r1
        /* F = N | (B ? 0 : Z) */
        mov     #0x02, r2       /* N_FLAG */
        tst     r1, r1
        bf      .Lind_nz
        mov     #0x42, r2       /* Z|N */
.Lind_nz:
        mov     r14, r0
        add     #3, r0
        mov.b   r2, @r0
        bra     .Led3_ret_fetch
        lds.l   @r15+, pr /* delay slot */

_z80_ed_inir:
        sts.l   pr, @-r15
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r2
        extu.b  r2, r2          /* r2 = R counter */
.Linir_loop:
        mov.l   r2, @-r15      /* save R across C calls */
        mov.l   r7, @-r15      /* save PC */
        /* gg_in(C) */
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        mov.l   @r15+, r2
        mov     r0, r5          /* r5 = value */
        /* gg_write(HL, value) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_write_c
        extu.w  r4, r4 /* delay slot */
        /* HL++ */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #1, r1
        mov.w   r1, @r0
        /* B-- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        extu.b  r1, r6          /* r6 = new B */
        add     #-21, r11
        add     #2, r2
        tst     r6, r6
        bt      .Linir_done
        cmp/pl  r11
        bt      .Linir_loop
        /* Not done: PC -= 2 */
        add     #-2, r7
        extu.w  r7, r7
        mov     #0x02, r2       /* N_FLAG (reuse r2 as flags now) */
        /* Store R, then flags */
        mov     r14, r0
        add     #15, r0
        /* Oops — R was in r2 but we just clobbered it. Need to save. */
        /* Actually, save R first. The R counter was in r2, but we need
           to store it before reusing r2 for flags. Let's restructure. */
        bra     .Linir_store_flags
        nop
.Linir_done:
        add     #5, r11
        /* Store R counter first */
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0
        mov     #0x42, r2       /* Z|N */
        bra     .Linir_set_f
        nop
.Linir_store_flags:
        /* R counter is still in r2. Save it. */
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0
        mov     #0x02, r2       /* N_FLAG */
.Linir_set_f:
        mov     r14, r0
        add     #3, r0
        mov.b   r2, @r0
        bra     .Led3_ret_fetch
        lds.l   @r15+, pr /* delay slot */

_z80_ed_indr:
        sts.l   pr, @-r15
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r2
        extu.b  r2, r2
.Lindr_loop:
        mov.l   r2, @-r15
        mov.l   r7, @-r15
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3_gg_in, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        mov.l   @r15+, r2
        mov     r0, r5
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_write_c
        extu.w  r4, r4 /* delay slot */
        /* HL-- */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        /* B-- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        extu.b  r1, r6
        add     #-21, r11
        add     #2, r2
        tst     r6, r6
        bt      .Lindr_done
        cmp/pl  r11
        bt      .Lindr_loop
        add     #-2, r7
        extu.w  r7, r7
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0
        mov     #0x02, r2
        bra     .Lindr_set_f
        nop
.Lindr_done:
        add     #5, r11
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0
        mov     #0x42, r2
.Lindr_set_f:
        mov     r14, r0
        add     #3, r0
        mov.b   r2, @r0
        bra     .Led3_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ================================================================ */
/*  ED: OUTD (0xAB) / OTDR (0xBB) — Block output decrement         */
/* ================================================================ */

_z80_ed_outd:
        sts.l   pr, @-r15
        /* Read (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_c
        extu.w  r4, r4 /* delay slot */
        mov     r0, r5          /* r5 = value */
        mov.l   r0, @-r15      /* save value for flag calc */
        mov.l   r7, @-r15
        /* gg_out(C, value) */
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3_gg_out, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        mov.l   @r15+, r3      /* r3 = I (saved value) */
        /* HL-- */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        /* B-- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        extu.b  r1, r6          /* r6 = new B */
        /* F = N | (B ? 0 : Z) | (L+I > 255 ? C|H : 0) */
        mov     #0x02, r2       /* N_FLAG */
        tst     r6, r6
        bf      .Loutd_nz
        mov     #0x42, r2       /* Z|N */
.Loutd_nz:
        mov     r14, r0
        add     #9, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        add     r3, r1          /* L + I */
        mov.l   .Led3_ff, r0
        cmp/hi  r0, r1
        bf      .Loutd_nc
        mov     #0x11, r0       /* C|H */
        or      r0, r2
.Loutd_nc:
        mov     r14, r0
        add     #3, r0
        mov.b   r2, @r0
        bra     .Led3_ret_fetch
        lds.l   @r15+, pr /* delay slot */

_z80_ed_otdr:
        sts.l   pr, @-r15
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r2
        extu.b  r2, r2
.Lotdr_loop:
        /* Read (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        bsr     _far_gg_read_c
        extu.w  r4, r4 /* delay slot */
        mov     r0, r5          /* r5 = value */
        mov.l   r0, @-r15      /* save value */
        mov.l   r2, @-r15      /* save R */
        mov.l   r7, @-r15      /* save PC */
        mov     r14, r0
        add     #11, r0
        mov.b   @r0, r4
        mov.l   .Led3_gg_out, r0
        jsr     @r0
        extu.b  r4, r4
        mov.l   @r15+, r7
        mov.l   @r15+, r2
        mov.l   @r15+, r3      /* r3 = I */
        /* HL-- */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r1
        extu.w  r1, r1
        add     #-1, r1
        mov.w   r1, @r0
        /* B-- */
        mov     r14, r0
        add     #10, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        extu.b  r1, r6
        add     #-21, r11
        add     #2, r2
        tst     r6, r6
        bt      .Lotdr_done
        cmp/pl  r11
        bt      .Lotdr_loop
        /* Not done */
        add     #-2, r7
        extu.w  r7, r7
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0
        /* F = N | (L+I > 255 ? C|H : 0) */
        mov     #0x02, r2
        mov     r14, r0
        add     #9, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        add     r3, r1
        mov.l   .Led3_ff, r0
        cmp/hi  r0, r1
        bf      .Lotdr_nc1
        mov     #0x11, r0
        or      r0, r2
.Lotdr_nc1:
        mov     r14, r0
        add     #3, r0
        mov.b   r2, @r0
        bra     .Led3_ret_fetch
        lds.l   @r15+, pr /* delay slot */
.Lotdr_done:
        add     #5, r11
        mov     r14, r0
        add     #15, r0
        mov.b   r2, @r0
        /* F = Z|N | (L+I > 255 ? C|H : 0) */
        mov     #0x42, r2
        mov     r14, r0
        add     #9, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        add     r3, r1
        mov.l   .Led3_ff, r0
        cmp/hi  r0, r1
        bf      .Lotdr_nc2
        mov     #0x11, r0
        or      r0, r2
.Lotdr_nc2:
        mov     r14, r0
        add     #3, r0
        mov.b   r2, @r0
        bra     .Led3_ret_fetch
        lds.l   @r15+, pr /* delay slot */

/* ---- ED: Pool 3 + trampoline ---- */
.Led3_ret_fetch:
        mov.l   .Led3_z80_fetch, r0
        jmp     @r0
        nop

/* ---- Far-call trampolines Set C (ED prefix handlers) ---- */
_far_gg_read_c:
        mov.l   .Lfar_gg_read_c, r0
        jmp     @r0
        nop
_far_gg_write_c:
        mov.l   .Lfar_gg_write_c, r0
        jmp     @r0
        nop
_far_fetch_imm3:
        mov.l   .Lfar_fetch_imm3, r0
        jmp     @r0
        nop

        .align 2
.Led3_z80_fetch:
        .long   _z80_fetch
.Led3_gg_in:
        .long   _gg_in + 0x20000000
.Led3_gg_out:
        .long   _gg_out + 0x20000000
.Led3_pzstable:
        .long   _PZSTable
.Led3_zstable:
        .long   _ZSTable
.Led3_ff:
        .long   0x000000FF
.Lfar_gg_read_c:
        .long   _inline_gg_read
.Lfar_gg_write_c:
        .long   _inline_gg_write
.Lfar_fetch_imm3:
        .long   _fetch_imm_to_r3

/* ================================================================ */
/*  ED Dispatch Table (128 entries for sub-opcodes 0x40-0xBF)       */
/*  16-bit signed offsets relative to _z80_ed_dispatch_table        */
/* ================================================================ */
        .align 2
_z80_ed_dispatch_table:
#define ET  _z80_ed_dispatch_table
/* 0x40-0x47: IN_B  OUT_B SBC_BC LD(nn)BC NEG   RETN  IM0   LD_I_A */
.word _z80_ed_in_b_c-ET,    _z80_ed_out_c_b-ET,   _z80_ed_sbc_hl_bc-ET, _z80_ed_ld_xnn_bc-ET
.word _z80_ed_neg-ET,        _z80_ed_retn-ET,       _z80_ed_im0-ET,       _z80_ed_ld_i_a-ET
/* 0x48-0x4F: IN_C  OUT_C ADC_BC LD_BC(nn) NEG   RETI  IM0   LD_R_A */
.word _z80_ed_in_c_c-ET,    _z80_ed_out_c_c-ET,   _z80_ed_adc_hl_bc-ET, _z80_ed_ld_bc_xnn-ET
.word _z80_ed_neg-ET,        _z80_ed_reti-ET,       _z80_ed_im0-ET,       _z80_ed_ld_r_a-ET
/* 0x50-0x57: IN_D  OUT_D SBC_DE LD(nn)DE NEG   RETN  IM1   LD_A_I */
.word _z80_ed_in_d_c-ET,    _z80_ed_out_c_d-ET,   _z80_ed_sbc_hl_de-ET, _z80_ed_ld_xnn_de-ET
.word _z80_ed_neg-ET,        _z80_ed_retn-ET,       _z80_ed_im1-ET,       _z80_ed_ld_a_i-ET
/* 0x58-0x5F: IN_E  OUT_E ADC_DE LD_DE(nn) NEG   RETN  IM2   LD_A_R */
.word _z80_ed_in_e_c-ET,    _z80_ed_out_c_e-ET,   _z80_ed_adc_hl_de-ET, _z80_ed_ld_de_xnn-ET
.word _z80_ed_neg-ET,        _z80_ed_retn-ET,       _z80_ed_im2-ET,       _z80_ed_ld_a_r-ET
/* 0x60-0x67: IN_H  OUT_H SBC_HL LD(nn)HL NEG   RETN  IM0   RRD */
.word _z80_ed_in_h_c-ET,    _z80_ed_out_c_h-ET,   _z80_ed_sbc_hl_hl-ET, _z80_ed_ld_xnn_hl-ET
.word _z80_ed_neg-ET,        _z80_ed_retn-ET,       _z80_ed_im0-ET,       _z80_ed_rrd-ET
/* 0x68-0x6F: IN_L  OUT_L ADC_HL LD_HL(nn) NEG   RETN  IM0   RLD */
.word _z80_ed_in_l_c-ET,    _z80_ed_out_c_l-ET,   _z80_ed_adc_hl_hl-ET, _z80_ed_ld_hl_xnn-ET
.word _z80_ed_neg-ET,        _z80_ed_retn-ET,       _z80_ed_im0-ET,       _z80_ed_rld-ET
/* 0x70-0x77: IN_F  OUT_0 SBC_SP LD(nn)SP NEG   RETN  IM1   NOP */
.word _z80_ed_in_f_c-ET,    _z80_ed_out_c_0-ET,   _z80_ed_sbc_hl_sp-ET, _z80_ed_ld_xnn_sp-ET
.word _z80_ed_neg-ET,        _z80_ed_retn-ET,       _z80_ed_im1-ET,       .Led_nop-ET
/* 0x78-0x7F: IN_A  OUT_A ADC_SP LD_SP(nn) NEG   RETN  IM2   NOP */
.word _z80_ed_in_a_c-ET,    _z80_ed_out_c_a-ET,   _z80_ed_adc_hl_sp-ET, _z80_ed_ld_sp_xnn-ET
.word _z80_ed_neg-ET,        _z80_ed_retn-ET,       _z80_ed_im2-ET,       .Led_nop-ET
/* 0x80-0x87: NOP block */
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
/* 0x88-0x8F: NOP block */
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
/* 0x90-0x97: NOP block */
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
/* 0x98-0x9F: NOP block */
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
/* 0xA0-0xA7: LDI   CPI   INI   OUTI  NOP  NOP  NOP  NOP */
.word _z80_ed_ldi-ET, _z80_ed_cpi-ET, _z80_ed_ini-ET, _z80_ed_outi-ET
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
/* 0xA8-0xAF: LDD   CPD   IND   OUTD  NOP  NOP  NOP  NOP */
.word _z80_ed_ldd-ET, _z80_ed_cpd-ET, _z80_ed_ind-ET, _z80_ed_outd-ET
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
/* 0xB0-0xB7: LDIR  CPIR  INIR  OTIR  NOP  NOP  NOP  NOP */
.word _z80_ed_ldir-ET, _z80_ed_cpir-ET, _z80_ed_inir-ET, _z80_ed_otir-ET
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET
/* 0xB8-0xBF: LDDR  CPDR  INDR  OTDR  NOP  NOP  NOP  NOP */
.word _z80_ed_lddr-ET, _z80_ed_cpdr-ET, _z80_ed_indr-ET, _z80_ed_otdr-ET
.word .Led_nop-ET, .Led_nop-ET, .Led_nop-ET, .Led_nop-ET

/* ================================================================ */
/*  DD/FD Prefix Handlers                         */
/*                                                                  */
/*  DD: XX = IX (offset 18 in z80_t)                                */
/*  FD: XX = IY (offset 20 in z80_t)                                */
/*  r6 = XX offset throughout handler execution.                    */
/*  Pass-through opcodes (CyclesXX[I]==0) re-dispatch to main table.*/
/*  Unique IX/IY ops dispatched via classification table.           */
/*  Unimplemented classes fall back to C (CodesDD/CodesFD).         */
/* ================================================================ */

_z80_pfx_dd:
        /* BIT b,(IX+d); JR Z,-6 idle skip (DD mirror of FD).
         * Same semantics as FD path below; only difference is XX=IX at
         * struct offset 18. Shares .Lfd_skip_exit / .Lfd_bitmask_tbl. */
        mov     r7, r1
        and     r10, r1
        tst     r1, r1
        bt      .Ldd_normal
        mov     r10, r2
        add     #-4, r2
        cmp/hi  r2, r1
        bt      .Ldd_normal

        mov     r7, r2
        add     r13, r2
        mov.b   @r2, r0
        cmp/eq  #0xCB, r0
        bf      .Ldd_normal
        mov.b   @(2, r2), r0
        extu.b  r0, r3
        and     #0xC7, r0
        cmp/eq  #0x46, r0
        bf      .Ldd_normal
        mov.b   @(3, r2), r0
        cmp/eq  #0x28, r0
        bf      .Ldd_normal
        mov.b   @(4, r2), r0          /* disp byte */
        cmp/eq  #0xF9, r0             /* -7 (loop back to prefix byte) */
        bf      .Ldd_off5a            /* not -7 -> try next */
        nop
        bra     .Ldd_flag_probe       /* matched -7: busy-wait loop */
        nop
.Ldd_off5a:
        cmp/eq  #0xFA, r0             /* -6 (Sonic's exact VBlank poll) */
        bf      .Ldd_off5b            /* not -6 -> try next */
        nop
        bra     .Ldd_flag_probe       /* matched -6 */
        nop
.Ldd_off5b:
        cmp/eq  #0xFB, r0             /* -5 (loop past the prefix) */
        bf      .Ldd_normal           /* none in {-7,-6,-5}: run normally */
        nop
        bra     .Ldd_flag_probe       /* matched -5 */
        nop
.Ldd_flag_probe:

        mov.b   @(1, r2), r0         /* d */
        mov     r0, r4
        mov.w   @(18, r14), r0       /* IX (offset 18) */
        extu.w  r0, r0
        add     r4, r0
        extu.w  r0, r0
        mov     r0, r1

        mov     r0, r5
        shlr8   r5
        shlr2   r5
        shlr    r5
        shlr    r5
        shlr    r5
        shll2   r5
        mov     r5, r0
        mov.l   @(r0, r8), r6
        and     r10, r1
        mov     r1, r0
        mov.b   @(r0, r6), r0

        mov     r0, r4               /* r4 = flag byte */
        mov     r3, r0
        shlr2   r0
        shlr    r0
        mov     #7, r1
        and     r1, r0
        mov.l   .Lfd_bitmask_ptr, r1
        mov.b   @(r0, r1), r0
        extu.b  r0, r0
        tst     r0, r4
        bf      .Ldd_normal

        /* Skip: rewind PC to DD, force yield. */
        add     #-1, r7
        extu.w  r7, r7
        mov.l   .Lfd_fetch_ptr, r0
        mov     #0, r11
        jmp     @r0
        nop

.Ldd_normal:
        bra     _z80_pfx_xx_common
        mov     #18, r6            /* delay slot: r6 = IX offset */

_z80_pfx_fd:
        /* Pattern-matched FD idle-poll skip.
         *
         * Signature: FD CB dd 7E 28 FA  (BIT 7,(IY+d); JR Z,-6)
         * This is the exact busy-wait pattern Sonic (and many GG games)
         * use against a software "VBlank-ready" flag byte. BIT has no
         * side effects; the only thing that can flip the flag is the
         * IRQ handler.
         *
         * Action when pattern matches AND the tested bit is currently 0
         * (loop would be taken): rewind PC to FD, zero ICount, and exit
         * the slice via _z80_fetch. Master runs the scanline tick; when
         * the IRQ eventually fires, the ISR sets the flag, then on
         * re-entry the BIT returns the new value, JR Z is NOT taken,
         * and real code resumes. No behavioural change.
         *
         * At entry: r7 = PC past FD, r13 = pc_base, r10 = 0x1FFF,
         *           r14 = z80_t*, r8 = Mem_Pages.
         * Scratch:  r0-r6 free.
         *
         * Falls through to .Lfd_normal (the original dispatch) on any
         * miss. Worst-case overhead on a real IY instruction is ~10
         * SH-2 cycles (the early CB check filters them immediately). */

        /* --- Page guard: need PC in (page_base, page_base + 0x1FFB] --- */
        mov     r7, r1
        and     r10, r1              /* r1 = PC & 0x1FFF */
        tst     r1, r1
        bt      .Lfd_normal          /* PC at page start → r13 stale for peek */
        mov     r10, r2
        add     #-4, r2              /* r2 = 0x1FFB */
        cmp/hi  r2, r1
        bt      .Lfd_normal          /* not enough bytes left in page */

        /* --- Peek bytes at PC..PC+4 (all in current page) --- */
        mov     r7, r2
        add     r13, r2              /* r2 = host ptr at PC */
        mov.b   @r2, r0
        /* Branch on opcode form: CB → BIT variant, 7E → LD-A variant. */
        cmp/eq  #0x7E, r0
        bt      .Lfd_lda_variant
        cmp/eq  #0xCB, r0
        bf      .Lfd_normal
        /* Sub-opcode at PC+2: accept any BIT b,(IY+d) = 01bbb110 = 0x46|b<<3.
         * Test: (sub & 0xC7) == 0x46. Save bit index (3 bits in r3). */
        mov.b   @(2, r2), r0
        extu.b  r0, r3               /* r3 = sub-opcode (saved) */
        and     #0xC7, r0            /* immediate-AND on R0 only */
        cmp/eq  #0x46, r0
        bf      .Lfd_normal
        mov.b   @(3, r2), r0
        cmp/eq  #0x28, r0            /* JR Z */
        bf      .Lfd_normal
        mov.b   @(4, r2), r0          /* disp byte */
        cmp/eq  #0xF9, r0             /* -7 (loop back to prefix byte) */
        bf      .Lfd_off5a            /* not -7 -> try next */
        nop
        bra     .Lfd_flag_probe       /* matched -7: busy-wait loop */
        nop
.Lfd_off5a:
        cmp/eq  #0xFA, r0             /* -6 (Sonic's exact VBlank poll) */
        bf      .Lfd_off5b            /* not -6 -> try next */
        nop
        bra     .Lfd_flag_probe       /* matched -6 */
        nop
.Lfd_off5b:
        cmp/eq  #0xFB, r0             /* -5 (loop past the prefix) */
        bf      .Lfd_normal           /* none in {-7,-6,-5}: run normally */
        nop
        bra     .Lfd_flag_probe       /* matched -5 */
        nop
.Lfd_flag_probe:

        /* --- Pattern matched. Load flag byte *(IY+d) --- */
        mov.b   @(1, r2), r0         /* r0 = d (sign-ext by mov.b) */
        mov     r0, r4               /* r4 = d */
        mov.w   @(20, r14), r0       /* r0 = IY (dest must be R0) */
        extu.w  r0, r0
        add     r4, r0               /* r0 = IY + d */
        extu.w  r0, r0               /* 16-bit wrap */
        mov     r0, r1               /* r1 = IY+d */

        /* page index: r5 = (r0 >> 13) * 4 */
        mov     r0, r5
        shlr8   r5
        shlr2   r5
        shlr    r5
        shlr    r5
        shlr    r5
        shll2   r5
        mov     r5, r0               /* r0 = page*4 (indexed form needs R0) */
        mov.l   @(r0, r8), r6        /* r6 = Mem_Pages[page] */
        and     r10, r1              /* r1 = offset in page */
        mov     r1, r0
        mov.b   @(r0, r6), r0        /* r0 = *(IY+d) */

        /* r0 = flag byte. r3 = sub-opcode. Extract bit index (5:3),
         * look up 1<<bit via small table, test against flag byte. */
        mov     r0, r4               /* r4 = flag byte (saved) */
        mov     r3, r0               /* r0 = sub-opcode for shift */
        shlr2   r0
        shlr    r0                   /* r0 = sub >> 3 */
        mov     #7, r1
        and     r1, r0               /* r0 = bit index (0..7) */
        mov.l   .Lfd_bitmask_ptr, r1
        mov.b   @(r0, r1), r0        /* r0 = 1 << bit */
        extu.b  r0, r0
        tst     r0, r4
        bf      .Lfd_normal          /* bit set → BIT clears Z → JR not taken → run normally */

        /* --- Safe to skip: bit clear, loop is stuck until IRQ --- */
.Lfd_skip_exit:
        add     #-1, r7              /* PC back to FD byte */
        extu.w  r7, r7
        mov.l   .Lfd_fetch_ptr, r0
        mov     #0, r11              /* force yield: cmp/pl at fetch top exits */
        jmp     @r0
        nop

        /* --- Variant: LD A,(IY+d); AND A | OR A; JR Z,-6 ---
         * Signature: FD 7E d [A7|B7] 28 FA. r0 = 0x7E already verified,
         * r2 = host ptr at PC. AND A / OR A both yield A unchanged and
         * set Z iff A==0, so skip condition is *(IY+d) == 0. Safe: pure
         * ALU on A, A is re-loaded on re-entry. */
.Lfd_lda_variant:
        mov.b   @(2, r2), r0
        extu.b  r0, r0
        xor     #0xA7, r0            /* accept A7 or B7 via (x^A7)&EF==0 */
        tst     #0xEF, r0
        bf      .Lfd_normal
        mov.b   @(3, r2), r0
        cmp/eq  #0x28, r0
        bf      .Lfd_normal
        mov.b   @(4, r2), r0          /* disp byte */
        cmp/eq  #0xF9, r0             /* -7 (loop back to prefix byte) */
        bf      .Lfd_lda_off5a        /* not -7 -> try next */
        nop
        bra     .Lfd_lda_flag_probe   /* matched -7: busy-wait loop */
        nop
.Lfd_lda_off5a:
        cmp/eq  #0xFA, r0             /* -6 (Sonic's exact VBlank poll) */
        bf      .Lfd_lda_off5b        /* not -6 -> try next */
        nop
        bra     .Lfd_lda_flag_probe   /* matched -6 */
        nop
.Lfd_lda_off5b:
        cmp/eq  #0xFB, r0             /* -5 (loop past the prefix) */
        bf      .Lfd_normal           /* none in {-7,-6,-5}: run normally */
        nop
        bra     .Lfd_lda_flag_probe   /* matched -5 */
        nop
.Lfd_lda_flag_probe:

        mov.b   @(1, r2), r0         /* d (signed) */
        mov     r0, r4
        mov.w   @(20, r14), r0       /* IY */
        extu.w  r0, r0
        add     r4, r0
        extu.w  r0, r0
        mov     r0, r1

        mov     r0, r5
        shlr8   r5
        shlr2   r5
        shlr    r5
        shlr    r5
        shlr    r5
        shll2   r5
        mov     r5, r0
        mov.l   @(r0, r8), r6
        and     r10, r1
        mov     r1, r0
        mov.b   @(r0, r6), r0        /* flag byte */
        extu.b  r0, r0
        tst     r0, r0
        bf      .Lfd_normal          /* non-zero → JR Z not taken → run normally */
        bra     .Lfd_skip_exit
        nop

        .align 2
.Lfd_fetch_ptr:
        .long   _z80_fetch
.Lfd_bitmask_ptr:
        .long   .Lfd_bitmask_tbl
        .align 2
.Lfd_bitmask_tbl:
        .byte   0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
        .align 2

.Lfd_normal:
        bra     _z80_pfx_xx_common
        mov     #20, r6            /* delay slot: r6 = IY offset */

_z80_pfx_xx_common:
        /* === Inline sub-opcode fetch (no BSR — preserves PR) ===
         * Lever-2: r13 is valid from the main-fetch dispatch that got
         * us here; the sub-opcode byte is in the same page as the
         * prefix byte in every practical case.  10 insns → 4 insns. */
        mov     r7, r0
        add     r13, r0
        mov.b   @r0, r0
        extu.b  r0, r3             /* r3 = sub-opcode */
        add     #1, r7
        extu.w  r7, r7             /* PC++ */

        /* === R++ (refresh counter at struct offset 15) === */
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r1
        add     #1, r1
        mov.b   r1, @r0

        /* === ICount -= CyclesXX[sub_opcode] === */
        mov.l   .Lxx_cyclesxx_ptr, r0
        mov     r3, r1
        add     r0, r1
        mov.b   @r1, r0
        extu.b  r0, r0
        mov     r0, r4             /* r4 = CyclesXX value (saved) */
        sub     r0, r11

        /* === Special sub-opcode checks === */
        mov     #0xCB, r0
        extu.b  r0, r0
        cmp/eq  r0, r3
        bt      .Lxx_goto_xxcb

        mov     #0xDD, r0
        extu.b  r0, r0
        cmp/eq  r0, r3
        bt      .Lxx_nested_prefix

        mov     #0xFD, r0
        extu.b  r0, r0
        cmp/eq  r0, r3
        bt      .Lxx_nested_prefix

        /* === Pass-through: CyclesXX[I] == 0 === */
        tst     r4, r4
        bt      .Lxx_passthrough

        /* === Classification table dispatch === */
        mov.l   .Lxx_class_table_ptr, r1
        mov     r3, r0             /* sub-opcode (fill stall on r1) */
        mov.b   @(r0, r1), r0     /* r0 = class (sign-extended) */
        extu.b  r0, r0
        tst     r0, r0
        bt      .Lxx_c_fallback    /* class 0 = not yet inlined */
        mov.l   .Lxx_jump_table_ptr, r2
        shll    r0                 /* class * 2 (fill stall on r2) */
        mov.w   @(r0, r2), r1     /* r1 = signed 16-bit offset */
        add     r2, r1            /* r1 = handler address */
        jmp     @r1
        nop

.Lxx_passthrough:
        /* Re-dispatch sub-opcode through main opcode table */
        mov     r3, r0
        shll    r0              /* x2 for 16-bit table */
        mov.w   @(r0, r9), r0  /* signed 16-bit offset */
        add     r9, r0
        jmp     @r0
        nop

.Lxx_nested_prefix:
        /* Back up PC to re-execute the DD/FD prefix */
        add     #-1, r7
        bra     .Lxx_ret_fetch
        extu.w  r7, r7          /* delay slot */

.Lxx_goto_xxcb:
/* ================================================================ */
/*  DD/FD DDCB/FDCB Inline Handler                        */
/*  All ops: rotate, shift, BIT, RES, SET on (XX+d)                */
/*                                                                  */
/*  Entry from bt .Lxx_goto_xxcb in DD/FD dispatch.                 */
/*    r7 = PC (past CB, points to displacement)                     */
/*    r6 = XX offset (18=IX, 20=IY)                                 */
/*    r11 = ICount (CyclesXX[CB]=0, no charge yet)                  */
/*    r12 = A, r14 = z80_t*                                         */
/*                                                                  */
/*  Regs at operation entry:                                        */
/*    r2 = value from (XX+d), r3 = sub-opcode, r5 = addr           */
/*    r6,r7,r8-r12,r14 = global state   PR saved on stack          */
/*  Scratch: r0, r1, r4                                             */
/* ================================================================ */
        sts.l   pr, @-r15
        /* 1. Fetch displacement byte */
        bsr     _far_fetch_imm3
        nop
        exts.b  r3, r3         /* sign-extend displacement */
        /* 2. Compute effective address: XX + disp */
        mov     r6, r0
        mov.w   @(r0, r14), r4
        extu.w  r4, r4
        add     r3, r4
        extu.w  r4, r5         /* r5 = effective address (preserved) */
        /* 3. Fetch sub-opcode byte */
        bsr     _far_fetch_imm3
        nop                    /* r3 = DDCB/FDCB sub-opcode */

#if PERF_DEBUG
        /* Compound CB (DD/FD + CB): g_cb_sub_hist[sub]++.  r3 holds the DDCB/
         * FDCB sub-opcode here; copy it to r2 as index and preserve r3.  r0/r1
         * are scratch per this handler's contract (see header above). */
        mov     r3, r2                 /* r2 = sub-opcode (r3 preserved) */
        mov.l   .Lg_cb_sub_hist_xx, r0  /* r0 = &g_cb_sub_hist[256] */
        shll    r2                     /* r2 = sub * 2 (u16 index) */
        add     r2, r0                 /* r0 = &g_cb_sub_hist[sub] */
        mov.w   @r0, r1                /* r1 = current count */
        add     #1, r1
        mov.w   r1, @r0                /* write back (wraps at 65536; safe per frame) */
        .align 2
.Lg_cb_sub_hist_xx:
        .long   _g_cb_sub_hist
#endif
        /* 4. Charge 23 cycles (BIT corrects to 20 later) */
        add     #-23, r11
        /* 5. Read byte from (XX+d) */
        bsr     .Lxx_local_gg_read
        mov     r5, r4         /* delay slot: r4 = addr */
        mov     r0, r2         /* r2 = memval for operations */
        /* 6. Dispatch on bits[7:6] */
        mov     r3, r0
        shlr2   r0
        shlr2   r0
        shlr    r0
        shlr    r0             /* r0 = group 0-3 */
        tst     r0, r0
        bt      .Lxx_xxcb_rot  /* 0: rotate/shift */
        dt      r0
        bt      .Lxx_xxcb_bit  /* 1: BIT */
        dt      r0
        bt      .Lxx_xxcb_res  /* 2: RES */
        /* fall through: 3 = SET */

/* ---- SET: r2 |= (1 << bit_number) ---- */
.Lxx_xxcb_set:
        mov     r3, r0
        shlr    r0
        shlr    r0
        shlr    r0
        and     #7, r0         /* r0 = bit number (bits[5:3]) */
        mov.l   .Lxx_bitmask_ptr, r1
        mov.b   @(r0, r1), r1
        extu.b  r1, r1         /* r1 = 1 << bit */
        bra     .Lxx_xxcb_writeback
        or      r1, r2         /* delay slot */

/* ---- RES: r2 &= ~(1 << bit_number) ---- */
.Lxx_xxcb_res:
        mov     r3, r0
        shlr    r0
        shlr    r0
        shlr    r0
        and     #7, r0
        mov.l   .Lxx_bitmask_ptr, r1
        mov.b   @(r0, r1), r1
        extu.b  r1, r1
        not     r1, r1         /* r1 = ~(1 << bit) */
        bra     .Lxx_xxcb_writeback
        and     r1, r2         /* delay slot */

/* ---- BIT: F = (F & C) | H | PZSTable[val & (1<<bit)] ---- */
.Lxx_xxcb_bit:
        add     #3, r11        /* correct: 23-3 = 20 cycles for BIT */
        mov     r3, r0
        shlr    r0
        shlr    r0
        shlr    r0
        and     #7, r0         /* r0 = bit number */
        mov.l   .Lxx_bitmask_ptr, r1
        mov.b   @(r0, r1), r1
        extu.b  r1, r1         /* r1 = 1 << bit */
        and     r2, r1         /* r1 = val & mask (0 or 2^bit) */
        /* F = (old_F & C) | H | PZSTable[masked] */
        mov.l   .Lxx_pzstable_c, r4
        mov     r1, r0
        mov.b   @(r0, r4), r0
        extu.b  r0, r0         /* r0 = PZSTable[val & mask] */
        mov     #0x10, r1      /* H_FLAG */
        or      r1, r0         /* r0 |= H */
        mov     r0, r1         /* r1 = PZS | H (save) */
        mov.b   @(3, r14), r0  /* old F — R0 for AND #imm */
        and     #1, r0         /* old C flag */
        or      r1, r0         /* F = old_C | H | PZS */
        mov.b   r0, @(3, r14)
        bra     .Lxx_xxcb_done
        nop

/* ---- Rotate/Shift dispatch via jump table ---- */
.Lxx_xxcb_rot:
        mov     r3, r0
        shlr    r0
        shlr    r0
        shlr    r0
        and     #7, r0         /* r0 = op 0-7 */
        mov.l   .Lxx_xxcb_rot_jtable_ptr, r1
        shll    r0             /* ×2 for word offsets */
        mov.w   @(r0, r1), r0
        add     r1, r0
        jmp     @r0
        nop

/* ---- RLC: carry=bit7, result=(val<<1)|carry ---- */
.Lxx_xxcb_rlc:
        mov     r2, r0
        shlr2   r0
        shlr2   r0
        shlr2   r0
        shlr    r0             /* r0 = bit7 (carry) */
        shll    r2
        or      r0, r2
        bra     .Lxx_xxcb_rot_flags
        extu.b  r2, r2         /* delay slot */

/* ---- RRC: carry=bit0, result=(val>>1)|(carry<<7) ---- */
.Lxx_xxcb_rrc:
        mov     r2, r0
        and     #1, r0         /* r0 = carry (bit0) */
        shlr    r2
        mov     r0, r1
        shll2   r1
        shll2   r1
        shll2   r1
        shll    r1             /* r1 = carry << 7 */
        or      r1, r2
        bra     .Lxx_xxcb_rot_flags
        extu.b  r2, r2         /* delay slot */

/* ---- RL: new_carry=bit7, result=(val<<1)|old_C ---- */
.Lxx_xxcb_rl:
        mov.b   @(3, r14), r0  /* old F */
        and     #1, r0         /* r0 = old C */
        mov     r0, r1         /* r1 = old C (save) */
        mov     r2, r0
        shlr2   r0
        shlr2   r0
        shlr2   r0
        shlr    r0             /* r0 = bit7 (new carry) */
        shll    r2
        or      r1, r2         /* r2 |= old_C */
        bra     .Lxx_xxcb_rot_flags
        extu.b  r2, r2         /* delay slot */

/* ---- RR: new_carry=bit0, result=(val>>1)|(old_C<<7) ---- */
.Lxx_xxcb_rr:
        mov.b   @(3, r14), r0  /* old F */
        and     #1, r0         /* r0 = old C */
        mov     r0, r4         /* r4 = old C (save) */
        shll2   r4
        shll2   r4
        shll2   r4
        shll    r4             /* r4 = old_C << 7 */
        mov     r2, r0
        and     #1, r0         /* r0 = bit0 (new carry) */
        shlr    r2
        or      r4, r2
        bra     .Lxx_xxcb_rot_flags
        extu.b  r2, r2         /* delay slot */

/* ---- SLA: carry=bit7, result=val<<1 ---- */
.Lxx_xxcb_sla:
        mov     r2, r0
        shlr2   r0
        shlr2   r0
        shlr2   r0
        shlr    r0             /* r0 = carry (bit7) */
        shll    r2
        bra     .Lxx_xxcb_rot_flags
        extu.b  r2, r2         /* delay slot */

/* ---- SRA: carry=bit0, result=(val>>1)|(val&0x80) ---- */
.Lxx_xxcb_sra:
        mov     r2, r0
        and     #1, r0         /* r0 = carry (bit0) */
        mov     r0, r4         /* r4 = carry (save) */
        mov     r2, r0
        and     #0x80, r0      /* r0 = val & 0x80 (sign bit) */
        shlr    r2
        or      r0, r2         /* r2 = (val>>1) | sign */
        bra     .Lxx_xxcb_rot_flags
        mov     r4, r0         /* delay slot: r0 = carry */

/* ---- SLL: carry=bit7, result=(val<<1)|1 ---- */
.Lxx_xxcb_sll:
        mov     r2, r0
        shlr2   r0
        shlr2   r0
        shlr2   r0
        shlr    r0             /* r0 = carry (bit7) */
        shll    r2
        mov     #1, r1
        or      r1, r2
        bra     .Lxx_xxcb_rot_flags
        extu.b  r2, r2         /* delay slot */

/* ---- SRL: carry=bit0, result=val>>1 ---- */
.Lxx_xxcb_srl:
        mov     r2, r0
        and     #1, r0         /* r0 = carry */
        bra     .Lxx_xxcb_rot_flags
        shlr    r2             /* delay slot */

/* ---- Shared rotate/shift flag tail ---- */
/* Entry: r0 = carry (0 or 1), r2 = 8-bit result */
.Lxx_xxcb_rot_flags:
        mov     r0, r4         /* save carry */
        mov.l   .Lxx_pzstable_c, r1
        mov     r2, r0
        mov.b   @(r0, r1), r0
        extu.b  r0, r0         /* PZSTable[result] */
        or      r4, r0         /* F = PZS | carry */
        mov.b   r0, @(3, r14)
        /* fall through to writeback */

/* ---- Write result back to (XX+d) ---- */
.Lxx_xxcb_writeback:
        mov     r5, r4         /* r4 = addr */
        bsr     .Lxx_local_gg_write
        mov     r2, r5         /* delay slot: r5 = value */

/* ---- Return to fetch loop ---- */
.Lxx_xxcb_done:
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot: restore PR */

/* ---- DDCB/FDCB literal pool ---- */
        .align 2
.Lxx_pzstable_c:
        .long   _PZSTable
.Lxx_bitmask_ptr:
        .long   .Lxx_bitmask_data
.Lxx_xxcb_rot_jtable_ptr:
        .long   .Lxx_xxcb_rot_jtable

/* ---- Bitmask lookup: 1<<N for N=0..7 ---- */
        .align 2
.Lxx_bitmask_data:
        .byte   0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80

/* ---- Rotate/shift jump table (8 entries) ---- */
        .align 2
.Lxx_xxcb_rot_jtable:
        .word   .Lxx_xxcb_rlc - .Lxx_xxcb_rot_jtable   /* 0: RLC */
        .word   .Lxx_xxcb_rrc - .Lxx_xxcb_rot_jtable   /* 1: RRC */
        .word   .Lxx_xxcb_rl  - .Lxx_xxcb_rot_jtable   /* 2: RL  */
        .word   .Lxx_xxcb_rr  - .Lxx_xxcb_rot_jtable   /* 3: RR  */
        .word   .Lxx_xxcb_sla - .Lxx_xxcb_rot_jtable   /* 4: SLA */
        .word   .Lxx_xxcb_sra - .Lxx_xxcb_rot_jtable   /* 5: SRA */
        .word   .Lxx_xxcb_sll - .Lxx_xxcb_rot_jtable   /* 6: SLL */
        .word   .Lxx_xxcb_srl - .Lxx_xxcb_rot_jtable   /* 7: SRL */

.Lxx_c_fallback:
        /* Legacy DD/FD C fallback path for class-0 jump-table entries.
         * Normally unused once all DD/FD opcodes are inlined. */
        /* Undo: PC--, R--, add back CyclesXX to ICount */
        add     #-1, r7
        extu.w  r7, r7
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r1
        add     #-1, r1
        mov.b   r1, @r0
        add     r4, r11
        /* Sync state to struct */
        mov.w   r7, @r14
        mov     r12, r0
        mov.b   r0, @(2, r14)
        mov.l   r11, @(Z80_ICOUNT, r14)
        mov     r14, r4
        mov     #18, r0
        cmp/eq  r0, r6
        bf      .Lxx_fallback_fd
        mov.l   .Lxx_codes_dd_ptr, r0
        bra     .Lxx_fallback_call
        nop
.Lxx_fallback_fd:
        mov.l   .Lxx_codes_fd_ptr, r0
.Lxx_fallback_call:
        sts.l   pr, @-r15
        jsr     @r0
        nop
        mov.l   @(Z80_ICOUNT, r14), r11
        mov.b   @(2, r14), r0
        extu.b  r0, r12
        mov.w   @r14, r7
        bsr     .Lxx_local_rebase
        extu.w  r7, r7         /* delay slot */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

.Lxx_ret_fetch:
        mov.l   .Lxx_z80_fetch_ptr, r0
        jmp     @r0
        nop

/* ---- Local trampolines (JMP via literal pool, preserves PR) ---- */
.Lxx_local_rebase:
        mov.l   .Lxx_rebase_ptr, r0
        jmp     @r0
        nop
.Lxx_local_gg_read:
        mov.l   .Lxx_gg_read_ptr, r0
        jmp     @r0
        nop
.Lxx_local_gg_write:
        mov.l   .Lxx_gg_write_ptr, r0
        jmp     @r0
        nop

/* ---- Literal pool A (dispatch + trampolines) ---- */
        .align 2
.Lxx_cyclesxx_ptr:
        .long   _CyclesXX
.Lxx_z80_fetch_ptr:
        .long   _z80_fetch
.Lxx_codes_dd_ptr:
        .long   _CodesDD + 0x20000000
.Lxx_codes_fd_ptr:
        .long   _CodesFD + 0x20000000
.Lxx_codes_ddcb_ptr:
        .long   _CodesDDCB + 0x20000000
.Lxx_codes_fdcb_ptr:
        .long   _CodesFDCB + 0x20000000
.Lxx_class_table_ptr:
        .long   .Lxx_class_table
.Lxx_jump_table_ptr:
        .long   .Lxx_jump_table
.Lxx_rebase_ptr:
        .long   _do_rebase_pc
.Lxx_gg_read_ptr:
        .long   _inline_gg_read
.Lxx_gg_write_ptr:
        .long   _inline_gg_write

/* ---- Jump Table (30 entries: 0=unused + 29 handler classes) ---- */
        .align 2
.Lxx_jump_table:
        .word   0                                       /* 0: unused */
        .word   .Lxx_ld_r_xxd      - .Lxx_jump_table   /* 1: LD r,(XX+d) */
        .word   .Lxx_ld_xxd_r      - .Lxx_jump_table   /* 2: LD (XX+d),r */
        .word   .Lxx_add_xx_rr     - .Lxx_jump_table   /* 3: ADD XX,rr */
        .word   .Lxx_ld_xx_nn      - .Lxx_jump_table   /* 4: LD XX,nn */
        .word   .Lxx_inc_xx        - .Lxx_jump_table   /* 5: INC XX */
        .word   .Lxx_dec_xx        - .Lxx_jump_table   /* 6: DEC XX */
        .word   .Lxx_push_xx       - .Lxx_jump_table   /* 7: PUSH XX */
        .word   .Lxx_pop_xx        - .Lxx_jump_table   /* 8: POP XX */
        .word   .Lxx_jp_xx         - .Lxx_jump_table   /* 9: JP (XX) */
        .word   .Lxx_ld_sp_xx      - .Lxx_jump_table   /* 10: LD SP,XX */
        .word   .Lxx_ld_xnn_xx     - .Lxx_jump_table   /* 11: LD (nn),XX */
        .word   .Lxx_ld_xx_xnn     - .Lxx_jump_table   /* 12: LD XX,(nn) */
        .word   .Lxx_ld_xxd_n      - .Lxx_jump_table   /* 13: LD (XX+d),n */
        .word   .Lxx_inc_xxd       - .Lxx_jump_table   /* 14: INC (XX+d) */
        .word   .Lxx_dec_xxd       - .Lxx_jump_table   /* 15: DEC (XX+d) */
        .word   .Lxx_ex_sp_xx      - .Lxx_jump_table   /* 16: EX (SP),XX */
        .word   .Lxx_alu_xxd       - .Lxx_jump_table   /* 17: ALU A,(XX+d) */
        .word   .Lxx_alu_xxh       - .Lxx_jump_table   /* 18: ALU A,XXh */
        .word   .Lxx_alu_xxl       - .Lxx_jump_table   /* 19: ALU A,XXl */
        .word   .Lxx_ld_r_xxh      - .Lxx_jump_table   /* 20: LD r,XXh */
        .word   .Lxx_ld_r_xxl      - .Lxx_jump_table   /* 21: LD r,XXl */
        .word   .Lxx_ld_xxh_r      - .Lxx_jump_table   /* 22: LD XXh,r */
        .word   .Lxx_ld_xxl_r      - .Lxx_jump_table   /* 23: LD XXl,r */
        .word   .Lxx_inc_xxh       - .Lxx_jump_table   /* 24: INC XXh */
        .word   .Lxx_dec_xxh       - .Lxx_jump_table   /* 25: DEC XXh */
        .word   .Lxx_ld_xxh_n      - .Lxx_jump_table   /* 26: LD XXh,n */
        .word   .Lxx_inc_xxl       - .Lxx_jump_table   /* 27: INC XXl */
        .word   .Lxx_dec_xxl       - .Lxx_jump_table   /* 28: DEC XXl */
        .word   .Lxx_ld_xxl_n      - .Lxx_jump_table   /* 29: LD XXl,n */

/* ---- Classification Table (256 bytes) ---- */
/* Non-zero = handler class. 0 = C fallback.                        */
        .align 2
.Lxx_class_table:
        /* 0x00-0x0F */
        .byte 0,0,0,0,0,0,0,0, 0,3,0,0,0,0,0,0
        /* 0x10-0x1F */
        .byte 0,0,0,0,0,0,0,0, 0,3,0,0,0,0,0,0
        /* 0x20-0x2F */
        .byte 0,4,11,5,24,25,26,0, 0,3,12,6,27,28,29,0
        /* 0x30-0x3F */
        .byte 0,0,0,0,14,15,13,0, 0,3,0,0,0,0,0,0
        /* 0x40-0x4F */
        .byte 0,0,0,0,20,21,1,0, 0,0,0,0,20,21,1,0
        /* 0x50-0x5F */
        .byte 0,0,0,0,20,21,1,0, 0,0,0,0,20,21,1,0
        /* 0x60-0x6F */
        .byte 22,22,22,22,22,22,1,22, 23,23,23,23,23,23,1,23
        /* 0x70-0x7F */
        .byte 2,2,2,2,2,2,0,2, 0,0,0,0,20,21,1,0
        /* 0x80-0x8F */
        .byte 0,0,0,0,18,19,17,0, 0,0,0,0,18,19,17,0
        /* 0x90-0x9F */
        .byte 0,0,0,0,18,19,17,0, 0,0,0,0,18,19,17,0
        /* 0xA0-0xAF */
        .byte 0,0,0,0,18,19,17,0, 0,0,0,0,18,19,17,0
        /* 0xB0-0xBF */
        .byte 0,0,0,0,18,19,17,0, 0,0,0,0,18,19,17,0
        /* 0xC0-0xCF */
        .byte 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
        /* 0xD0-0xDF */
        .byte 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
        /* 0xE0-0xEF */
        .byte 0,8,0,16,0,7,0,0, 0,9,0,0,0,0,0,0
        /* 0xF0-0xFF */
        .byte 0,0,0,0,0,0,0,0, 0,10,0,0,0,0,0,0

/* ================================================================ */
/*  DD/FD Inline Handlers — Loads/Stores                            */
/*  Entry: r3=sub-opcode, r6=XX offset(18/20), r7=PC               */
/*         r11=ICount(adjusted), r12=A, r14=z80_t*                  */
/*  Exit: bra .Lxx_ret_fetch                                        */
/* ================================================================ */

/* ---- Handler 1: LD r,(XX+d) ---- */
/* 0x46(B), 0x4E(C), 0x56(D), 0x5E(E), 0x66(H), 0x6E(L), 0x7E(A) */
/* CRITICAL: 0x66 writes to real H (offset 8), 0x6E to real L (9). */
/* Bits [5:3] naturally decode: 0=B(10), 1=C(11), 2=D(12), 3=E(13),*/
/*                               4=H(8), 5=L(9), 7=A(R12)          */
.Lxx_ld_r_xxd:
        sts.l   pr, @-r15
        bsr     _far_fetch_imm3
        mov.l   r3, @-r15      /* delay slot: save sub-opcode */
        exts.b  r3, r3         /* sign-extend displacement */
        mov     r6, r0
        mov.w   @(r0, r14), r4
        extu.w  r4, r4
        add     r3, r4
        bsr     .Lxx_local_gg_read
        extu.w  r4, r4         /* delay slot: r4 = XX + d */
        /* r0 = memory value */
        mov.l   @r15+, r3     /* restore sub-opcode */
        mov     r0, r5         /* save value in r5 (fill load-use on r3) */
        /* Decode target from bits [5:3] */
        mov     r3, r0
        shlr    r0
        shlr    r0
        shlr    r0
        mov     #7, r1
        and     r1, r0         /* r0 = target index 0-7 */
        cmp/eq  #7, r0
        bt      .Lxx_ld_r_xxd_a
        cmp/eq  #4, r0
        bt      .Lxx_ld_r_xxd_h
        cmp/eq  #5, r0
        bt      .Lxx_ld_r_xxd_l
        /* B(0), C(1), D(2), E(3): struct offset = index + 10 */
        add     #10, r0
        mov     r14, r1
        add     r0, r1
        bra     .Lxx_ld_r_xxd_done
        mov.b   r5, @r1        /* delay slot */
.Lxx_ld_r_xxd_a:
        bra     .Lxx_ld_r_xxd_done
        extu.b  r5, r12        /* delay slot: A = value */
.Lxx_ld_r_xxd_h:
        mov     r14, r1
        add     #8, r1
        bra     .Lxx_ld_r_xxd_done
        mov.b   r5, @r1        /* delay slot */
.Lxx_ld_r_xxd_l:
        mov     r14, r1
        add     #9, r1
        mov.b   r5, @r1
.Lxx_ld_r_xxd_done:
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot: restore PR */

/* ---- Handler 2: LD (XX+d),r ---- */
/* 0x70(B), 0x71(C), 0x72(D), 0x73(E), 0x74(H), 0x75(L), 0x77(A) */
/* CRITICAL: 0x74 reads from real H (offset 8), 0x75 from real L.  */
/* Source bits [2:0]: 0=B(10), 1=C(11), 2=D(12), 3=E(13),         */
/*                    4=H(8), 5=L(9), 7=A(R12)                     */
.Lxx_ld_xxd_r:
        sts.l   pr, @-r15
        bsr     _far_fetch_imm3
        mov.l   r3, @-r15      /* delay slot: save sub-opcode */
        exts.b  r3, r3
        mov     r6, r0
        mov.w   @(r0, r14), r4
        extu.w  r4, r4
        add     r3, r4
        extu.w  r4, r4         /* r4 = XX + d (address) */
        /* Determine source register */
        mov.l   @r15+, r3     /* restore sub-opcode */
        mov     r3, r0
        mov     #7, r1
        and     r1, r0         /* r0 = source index */
        cmp/eq  #7, r0
        bt      .Lxx_ld_xxd_from_a
        cmp/eq  #4, r0
        bt      .Lxx_ld_xxd_from_h
        cmp/eq  #5, r0
        bt      .Lxx_ld_xxd_from_l
        /* B(0), C(1), D(2), E(3): struct offset = index + 10 */
        add     #10, r0
        mov     r14, r1
        add     r0, r1
        mov.b   @r1, r5
        bra     .Lxx_ld_xxd_write
        extu.b  r5, r5         /* delay slot */
.Lxx_ld_xxd_from_a:
        bra     .Lxx_ld_xxd_write
        mov     r12, r5        /* delay slot: r5 = A */
.Lxx_ld_xxd_from_h:
        mov     r14, r1
        add     #8, r1
        mov.b   @r1, r5
        bra     .Lxx_ld_xxd_write
        extu.b  r5, r5         /* delay slot */
.Lxx_ld_xxd_from_l:
        mov     r14, r1
        add     #9, r1
        mov.b   @r1, r5
        extu.b  r5, r5
.Lxx_ld_xxd_write:
        bsr     .Lxx_local_gg_write
        nop
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot: restore PR */

/* ---- Handler 3: ADD XX,rr ---- */
/* 0x09(BC), 0x19(DE), 0x29(XX), 0x39(SP) */
/* Flags: C = carry, H = half-carry bit 11, N = 0, preserve S/Z/P  */
.Lxx_add_xx_rr:
        mov     r3, r0
        shlr2   r0
        shlr2   r0             /* r0 = opcode >> 4 */
        mov     #3, r1
        and     r1, r0         /* r0 = pair index 0-3 */
        cmp/eq  #2, r0
        bt      .Lxx_add_xx_self
        cmp/eq  #0, r0
        bt      .Lxx_add_from_bc
        cmp/eq  #1, r0
        bt      .Lxx_add_from_de
        /* SP (index 3) */
        mov.w   @(16, r14), r0
        bra     .Lxx_add_got_src
        extu.w  r0, r2         /* delay slot */
.Lxx_add_from_bc:
        mov.w   @(10, r14), r0
        bra     .Lxx_add_got_src
        extu.w  r0, r2         /* delay slot */
.Lxx_add_from_de:
        mov.w   @(12, r14), r0
        bra     .Lxx_add_got_src
        extu.w  r0, r2         /* delay slot */
.Lxx_add_xx_self:
        mov     r6, r0
        mov.w   @(r0, r14), r1
        extu.w  r1, r1
        bra     .Lxx_add_compute
        mov     r1, r2         /* delay slot: src = dst = XX */
.Lxx_add_got_src:
        /* r2 = source pair, load XX as destination */
        mov     r6, r0
        mov.w   @(r0, r14), r1
        extu.w  r1, r1
.Lxx_add_compute:
        /* r1 = XX (dst), r2 = source */
        mov     r1, r3         /* save original XX for H flag */
        add     r2, r1         /* r1 = result (may exceed 16 bits) */
        /* H flag = bit 12 of (XX ^ src ^ result) */
        mov     r3, r5
        xor     r2, r5
        xor     r1, r5         /* r5 = XX ^ src ^ result */
        mov     r1, r4
        mov.l   .Lxx_0x1000_b, r0
        shlr16  r4             /* r4 = carry (fill stall on r0) */
        and     r0, r5         /* isolate bit 12 */
        shlr8   r5             /* r5 = H_FLAG (0x10) or 0 */
        or      r4, r5         /* r5 = H | C */
        /* Store 16-bit result */
        extu.w  r1, r1
        mov     r6, r0
        mov.w   r1, @(r0, r14)
        /* Update F: (old_F & 0xEC) | new_flags */
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0xEC, r1
        extu.b  r1, r1
        and     r1, r0
        or      r5, r0
        bra     .Lxx_ret_fetch
        mov.b   r0, @(3, r14)  /* delay slot */

/* Literal pool B — for Handler 3 */
        .align 2
.Lxx_0x1000_b:
        .long   0x00001000

/* ---- Handler 4: LD XX,nn (0x21) ---- */
.Lxx_ld_xx_nn:
        sts.l   pr, @-r15
        bsr     _far_fetch_imm3
        nop
        bsr     _far_fetch_imm3
        mov     r3, r4         /* delay slot: r4 = low byte */
        extu.b  r3, r3
        shll8   r3
        extu.b  r4, r4
        or      r4, r3         /* r3 = (high << 8) | low */
        mov     r6, r0
        mov.w   r3, @(r0, r14)
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ---- Handler 5: INC XX (0x23) ---- */
.Lxx_inc_xx:
        mov     r6, r0
        mov.w   @(r0, r14), r1
        mov     r6, r0         /* fill load-use stall + prep store */
        add     #1, r1
        bra     .Lxx_ret_fetch
        mov.w   r1, @(r0, r14) /* delay slot */

/* ---- Handler 6: DEC XX (0x2B) ---- */
.Lxx_dec_xx:
        mov     r6, r0
        mov.w   @(r0, r14), r1
        mov     r6, r0         /* fill load-use stall */
        add     #-1, r1
        bra     .Lxx_ret_fetch
        mov.w   r1, @(r0, r14) /* delay slot */

/* ---- Handler 7: PUSH XX (0xE5) ---- */
.Lxx_push_xx:
        sts.l   pr, @-r15
        /* Load XX value */
        mov     r6, r0
        mov.w   @(r0, r14), r1
        extu.w  r1, r1
        mov.l   r1, @-r15     /* save XX value */
        /* SP-- and push high byte */
        mov.w   @(16, r14), r0
        extu.w  r0, r0
        add     #-1, r0
        extu.w  r0, r0
        mov.w   r0, @(16, r14)
        mov     r0, r4         /* r4 = SP-1 (address) */
        mov.l   @r15, r5      /* peek XX value */
        shlr8   r5
        bsr     .Lxx_local_gg_write
        extu.b  r5, r5         /* delay slot: r5 = high byte */
        /* SP-- and push low byte */
        mov.w   @(16, r14), r0
        extu.w  r0, r0
        add     #-1, r0
        extu.w  r0, r0
        mov.w   r0, @(16, r14)
        mov     r0, r4         /* r4 = SP-2 (address) */
        mov.l   @r15+, r5     /* pop XX value */
        bsr     .Lxx_local_gg_write
        extu.b  r5, r5         /* delay slot: r5 = low byte */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ---- Handler 8: POP XX (0xE1) ---- */
.Lxx_pop_xx:
        sts.l   pr, @-r15
        /* Read low byte at SP */
        mov.w   @(16, r14), r0
        bsr     .Lxx_local_gg_read
        extu.w  r0, r4         /* delay slot: r4 = SP */
        mov     r0, r5         /* r5 = low byte */
        /* r4 preserved by gg_read; SP+1 */
        add     #1, r4
        /* Read high byte at SP+1 */
        bsr     .Lxx_local_gg_read
        extu.w  r4, r4         /* delay slot */
        /* r0 = high byte, r5 = low byte */
        extu.b  r0, r0
        shll8   r0
        extu.b  r5, r5
        or      r5, r0         /* r0 = (high << 8) | low */
        /* SP += 2 */
        add     #1, r4
        extu.w  r4, r4
        mov     r0, r3         /* save XX value */
        mov     r4, r0
        mov.w   r0, @(16, r14)
        /* Store to XX */
        mov     r6, r0
        mov.w   r3, @(r0, r14)
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ---- Handler 9: JP (XX) (0xE9) ---- */
.Lxx_jp_xx:
        mov     r6, r0
        mov.w   @(r0, r14), r7
        sts.l   pr, @-r15     /* fill load-use stall on r7 */
        bsr     .Lxx_local_rebase
        extu.w  r7, r7         /* delay slot */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ---- Handler 10: LD SP,XX (0xF9) ---- */
.Lxx_ld_sp_xx:
        mov     r6, r0
        mov.w   @(r0, r14), r0 /* r0 = XX value */
        bra     .Lxx_ret_fetch
        mov.w   r0, @(16, r14) /* delay slot: SP = XX */

/* ---- Handler 11: LD (nn),XX (0x22) ---- */
.Lxx_ld_xnn_xx:
        sts.l   pr, @-r15
        /* Fetch 16-bit address nn */
        bsr     _far_fetch_imm3
        nop
        bsr     _far_fetch_imm3
        mov     r3, r4         /* delay slot: r4 = low byte */
        extu.b  r3, r3
        shll8   r3
        extu.b  r4, r4
        or      r4, r3
        extu.w  r3, r4         /* r4 = nn (address) */
        /* Load XX value */
        mov     r6, r0
        mov.w   @(r0, r14), r0
        extu.w  r0, r5         /* r5 = XX value */
        /* Write low byte to (nn) */
        mov.l   r5, @-r15     /* save XX value */
        bsr     .Lxx_local_gg_write
        extu.b  r5, r5         /* delay slot */
        /* r4 preserved; write high byte to (nn+1) */
        add     #1, r4
        extu.w  r4, r4
        mov.l   @r15+, r5     /* restore XX value */
        shlr8   r5
        bsr     .Lxx_local_gg_write
        extu.b  r5, r5         /* delay slot */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ---- Handler 12: LD XX,(nn) (0x2A) ---- */
.Lxx_ld_xx_xnn:
        sts.l   pr, @-r15
        /* Fetch 16-bit address nn */
        bsr     _far_fetch_imm3
        nop
        bsr     _far_fetch_imm3
        mov     r3, r4         /* delay slot: r4 = low byte */
        extu.b  r3, r3
        shll8   r3
        extu.b  r4, r4
        or      r4, r3
        /* Read low byte from (nn) */
        bsr     .Lxx_local_gg_read
        extu.w  r3, r4         /* delay slot: r4 = nn */
        mov     r0, r5         /* r5 = low byte */
        /* Read high byte from (nn+1) */
        add     #1, r4
        bsr     .Lxx_local_gg_read
        extu.w  r4, r4         /* delay slot */
        extu.b  r0, r0
        shll8   r0
        extu.b  r5, r5
        or      r5, r0         /* r0 = (high << 8) | low */
        /* Store to XX */
        mov     r0, r3
        mov     r6, r0
        mov.w   r3, @(r0, r14)
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ---- Handler 13: LD (XX+d),n (0x36) ---- */
.Lxx_ld_xxd_n:
        sts.l   pr, @-r15
        bsr     _far_fetch_imm3
        nop
        exts.b  r3, r3         /* sign-extend displacement */
        mov     r6, r0
        mov.w   @(r0, r14), r4
        extu.w  r4, r4
        add     r3, r4
        /* Fetch immediate value n */
        bsr     _far_fetch_imm3
        extu.w  r4, r4         /* delay slot: r4 = XX + d */
        bsr     .Lxx_local_gg_write
        extu.b  r3, r5         /* delay slot: r5 = n */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ---- Handler 14: INC (XX+d) (0x34) ---- */
/* Flags: ZSTable[result] | V(result==0x80) | H(nibble was 0xF) | old_C */
.Lxx_inc_xxd:
        sts.l   pr, @-r15
        bsr     _far_fetch_imm3
        nop
        exts.b  r3, r3
        mov     r6, r0
        mov.w   @(r0, r14), r4
        extu.w  r4, r4
        add     r3, r4
        extu.w  r4, r4         /* r4 = XX + d */
        bsr     .Lxx_local_gg_read
        mov.l   r4, @-r15     /* delay slot: save address */
        /* r0 = original value */
        mov     r0, r3         /* r3 = original */
        add     #1, r0
        extu.b  r0, r0         /* r0 = result */
        /* Flags: ZSTable[result] */
        mov.l   .Lxx_zstable_c, r1
        mov     r0, r2
        add     r1, r2
        mov.b   @r2, r1
        extu.b  r1, r1         /* r1 = Z + S flags */
        /* V flag: result == 0x80 (0x7F + 1 overflow) */
        mov     #0x80, r2
        extu.b  r2, r2
        cmp/eq  r2, r0
        movt    r2
        shll    r2
        shll    r2             /* r2 = 0x04 (V_FLAG) or 0 */
        or      r2, r1
        /* H flag: original lower nibble == 0x0F */
        mov     r3, r2
        mov     #0x0F, r5
        and     r5, r2
        cmp/eq  r5, r2
        movt    r2
        shll2   r2
        shll2   r2             /* r2 = 0x10 (H_FLAG) or 0 */
        or      r2, r1
        /* Preserve old C flag (mov.b @(disp,Rn) requires R0) */
        mov     r0, r3         /* save result */
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x01, r5
        and     r5, r0
        or      r0, r1
        mov     r1, r0
        mov.b   r0, @(3, r14) /* store new F */
        /* Write back */
        mov.l   @r15+, r4     /* restore address */
        mov     r3, r5         /* result was saved in r3 */
        bsr     .Lxx_local_gg_write
        extu.b  r5, r5         /* delay slot */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ---- Handler 15: DEC (XX+d) (0x35) ---- */
/* Flags: N | ZSTable[result] | V(result==0x7F) | H(nibble==0xF) | old_C */
.Lxx_dec_xxd:
        sts.l   pr, @-r15
        bsr     _far_fetch_imm3
        nop
        exts.b  r3, r3
        mov     r6, r0
        mov.w   @(r0, r14), r4
        extu.w  r4, r4
        add     r3, r4
        extu.w  r4, r4         /* r4 = XX + d */
        bsr     .Lxx_local_gg_read
        mov.l   r4, @-r15     /* delay slot: save address */
        /* r0 = original value */
        mov     r0, r3         /* r3 = original */
        add     #-1, r0
        extu.b  r0, r0         /* r0 = result */
        /* Flags: N_FLAG | ZSTable[result] */
        mov.l   .Lxx_zstable_c, r1
        mov     r0, r2
        add     r1, r2
        mov.b   @r2, r1
        extu.b  r1, r1
        mov     #0x02, r2      /* N_FLAG */
        or      r2, r1
        /* V flag: result == 0x7F (0x80 - 1 underflow) */
        mov     #0x7F, r2
        cmp/eq  r2, r0
        movt    r2
        shll    r2
        shll    r2             /* r2 = V_FLAG or 0 */
        or      r2, r1
        /* H flag: result lower nibble == 0x0F (borrow) */
        mov     r0, r2
        mov     #0x0F, r5
        and     r5, r2
        cmp/eq  r5, r2
        movt    r2
        shll2   r2
        shll2   r2             /* r2 = H_FLAG or 0 */
        or      r2, r1
        /* Preserve old C flag (mov.b @(disp,Rn) requires R0) */
        mov     r0, r3         /* save result */
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x01, r5
        and     r5, r0
        or      r0, r1
        mov     r1, r0
        mov.b   r0, @(3, r14)
        /* Write back */
        mov.l   @r15+, r4
        mov     r3, r5         /* result was saved in r3 */
        bsr     .Lxx_local_gg_write
        extu.b  r5, r5         /* delay slot */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* Literal pool C — for Handlers 14-15 */
        .align 2
.Lxx_zstable_c:
        .long   _ZSTable

/* ---- Handler 16: EX (SP),XX (0xE3) ---- */
/* Read (SP)/(SP+1), write XX to (SP)/(SP+1), store read value to XX */
.Lxx_ex_sp_xx:
        sts.l   pr, @-r15
        /* Read low byte from (SP) */
        mov.w   @(16, r14), r0
        bsr     .Lxx_local_gg_read
        extu.w  r0, r4         /* delay slot: r4 = SP */
        mov     r0, r5         /* r5 = low byte */
        /* Read high byte from (SP+1) */
        add     #1, r4
        bsr     .Lxx_local_gg_read
        extu.w  r4, r4         /* delay slot */
        /* r0 = high, r5 = low */
        extu.b  r0, r0
        shll8   r0
        extu.b  r5, r5
        or      r5, r0         /* r0 = value from stack */
        mov.l   r0, @-r15     /* save stack value */
        /* Load XX value into r3 (will be clobbered by gg_write) */
        mov     r6, r0
        mov.w   @(r0, r14), r0
        extu.w  r0, r3
        mov.l   r3, @-r15     /* save XX value */
        /* Write XX low to (SP) */
        mov.w   @(16, r14), r0
        extu.w  r0, r4
        bsr     .Lxx_local_gg_write
        extu.b  r3, r5         /* delay slot: r5 = XX low byte */
        /* Write XX high to (SP+1); r4 = SP (preserved) */
        add     #1, r4
        extu.w  r4, r4
        mov.l   @r15+, r5     /* pop XX value */
        shlr8   r5
        bsr     .Lxx_local_gg_write
        extu.b  r5, r5         /* delay slot */
        /* Store stack value to XX */
        mov.l   @r15+, r3     /* pop value from stack */
        mov     r6, r0
        mov.w   r3, @(r0, r14)
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ================================================================ */
/*  DD/FD Inline Handlers — ALU/INC/DEC                             */
/*  ALU (XX+d), ALU IXh/IXl, LD IXh/IXl, INC/DEC IXh/IXl          */
/*                                                                  */
/*  ALU trampolines: _alu_*_flags clobber r0,r1,r2,r6.             */
/*    Entry: r3=src, r4=A. Write F to struct, update R12.           */
/*    (OK to clobber r6 — XX offset not needed after ALU.)          */
/*  AND/OR/XOR: done inline with PZSTable lookup.                   */
/* ================================================================ */

/* ---- Handler 17: ALU A,(XX+d) ---- */
/* ADD(0x86), ADC(0x8E), SUB(0x96), SBC(0x9E),                     */
/* AND(0xA6), XOR(0xAE), OR(0xB6), CP(0xBE)                        */
.Lxx_alu_xxd:
        sts.l   pr, @-r15
        bsr     _far_fetch_imm3
        mov.l   r3, @-r15      /* delay slot: save sub-opcode */
        exts.b  r3, r3
        mov     r6, r0
        mov.w   @(r0, r14), r4
        extu.w  r4, r4
        add     r3, r4
        bsr     .Lxx_local_gg_read
        extu.w  r4, r4         /* delay slot: r4 = XX + d */
        /* r0 = byte from memory */
        mov     r0, r5         /* r5 = src value */
        mov.l   @r15+, r0     /* r0 = sub-opcode */
        shlr    r0
        shlr    r0
        shlr    r0
        mov     #7, r1
        and     r1, r0         /* r0 = ALU op 0-7 */
        mov     r5, r3         /* r3 = src (for ALU subroutines) */
        bra     .Lxx_alu_dispatch
        nop

/* ---- Handler 18: ALU A,XXh ---- */
/* ADD(0x84), ADC(0x8C), SUB(0x94), SBC(0x9C),                     */
/* AND(0xA4), XOR(0xAC), OR(0xB4), CP(0xBC)                        */
.Lxx_alu_xxh:
        sts.l   pr, @-r15
        mov     r3, r0
        shlr    r0
        shlr    r0
        shlr    r0
        mov     #7, r1
        and     r1, r0         /* r0 = ALU op 0-7 */
        /* Read XXh: struct_base + r6 */
        mov     r14, r1
        add     r6, r1
        mov.b   @r1, r3
        extu.b  r3, r3         /* r3 = XXh (src) */
        bra     .Lxx_alu_dispatch
        nop

/* ---- Handler 19: ALU A,XXl ---- */
/* ADD(0x85), ADC(0x8D), SUB(0x95), SBC(0x9D),                     */
/* AND(0xA5), XOR(0xAD), OR(0xB5), CP(0xBD)                        */
.Lxx_alu_xxl:
        sts.l   pr, @-r15
        mov     r3, r5         /* save sub-opcode in r5 */
        /* Read XXl: struct_base + r6 + 1 */
        mov     r14, r0
        add     r6, r0
        mov.b   @(1, r0), r0  /* mov.b @(disp,Rn),R0: dest=R0 OK */
        extu.b  r0, r3         /* r3 = XXl (src) */
        /* Decode ALU op from saved sub-opcode */
        mov     r5, r0
        shlr    r0
        shlr    r0
        shlr    r0
        mov     #7, r1
        and     r1, r0         /* r0 = ALU op 0-7 */
        /* Fall through to dispatch */

/* ---- Shared ALU dispatch ---- */
/* Entry: r0 = ALU op (0-7), r3 = src byte, PR saved on stack.     */
/* 0=ADD, 1=ADC, 2=SUB, 3=SBC, 4=AND, 5=XOR, 6=OR, 7=CP          */
.Lxx_alu_dispatch:
        cmp/eq  #4, r0
        bt      .Lxx_alu_and
        cmp/eq  #5, r0
        bt      .Lxx_alu_xor
        cmp/eq  #6, r0
        bt      .Lxx_alu_or
        /* ADD/ADC/SUB/SBC/CP — use trampoline jump table */
        mov.l   .Lxx_alu_jtable_ptr, r1
        shll    r0             /* ×2 for word offsets */
        mov.w   @(r0, r1), r0
        mov     r12, r4        /* r4 = A (fill load-use stall on r0) */
        add     r1, r0         /* r0 = trampoline address */
        jsr     @r0            /* trampoline → _alu_*_flags → RTS */
        nop
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot: restore PR */

.Lxx_alu_and:
        mov.l   .Lxx_pzstable_d, r1
        mov     r12, r0
        and     r3, r0
        mov     r0, r12        /* A = A & src */
        mov.b   @(r0, r1), r0  /* PZSTable[result] */
        mov     #0x10, r1      /* H flag (fill load-use stall on r0) */
        extu.b  r0, r0
        or      r1, r0
        mov.b   r0, @(3, r14)  /* F */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

.Lxx_alu_xor:
        mov.l   .Lxx_pzstable_d, r1
        mov     r12, r0
        xor     r3, r0
        mov     r0, r12        /* A = A ^ src */
        mov.b   @(r0, r1), r0  /* PZSTable[result] */
        extu.b  r0, r0
        mov.b   r0, @(3, r14)  /* F (H=0, N=0, C=0) */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

.Lxx_alu_or:
        mov.l   .Lxx_pzstable_d, r1
        mov     r12, r0
        or      r3, r0
        mov     r0, r12        /* A = A | src */
        mov.b   @(r0, r1), r0  /* PZSTable[result] */
        extu.b  r0, r0
        mov.b   r0, @(3, r14)  /* F (H=0, N=0, C=0) */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ALU trampoline jump table (word offsets from table base) */
        .align 2
.Lxx_alu_jtable:
        .word   .Lxx_far_alu_add  - .Lxx_alu_jtable   /* 0: ADD */
        .word   .Lxx_far_alu_adc  - .Lxx_alu_jtable   /* 1: ADC */
        .word   .Lxx_far_alu_sub  - .Lxx_alu_jtable   /* 2: SUB */
        .word   .Lxx_far_alu_sbc  - .Lxx_alu_jtable   /* 3: SBC */
        .word   0                                       /* 4: AND (inline) */
        .word   0                                       /* 5: XOR (inline) */
        .word   0                                       /* 6: OR  (inline) */
        .word   .Lxx_far_alu_cp   - .Lxx_alu_jtable   /* 7: CP  */
.Lxx_alu_jtable_ptr:
        .long   .Lxx_alu_jtable

/* Far-call trampolines for ALU subroutines (JMP, preserves PR) */
.Lxx_far_alu_add:
        mov.l   .Lxx_alu_add_ptr, r0
        jmp     @r0
        nop
.Lxx_far_alu_adc:
        mov.l   .Lxx_alu_adc_ptr, r0
        jmp     @r0
        nop
.Lxx_far_alu_sub:
        mov.l   .Lxx_alu_sub_ptr, r0
        jmp     @r0
        nop
.Lxx_far_alu_sbc:
        mov.l   .Lxx_alu_sbc_ptr, r0
        jmp     @r0
        nop
.Lxx_far_alu_cp:
        mov.l   .Lxx_alu_cp_ptr, r0
        jmp     @r0
        nop

/* Literal pool D — ALU trampolines + INC/DEC tables */
        .align 2
.Lxx_alu_add_ptr:
        .long   _alu_add_flags
.Lxx_alu_adc_ptr:
        .long   _alu_adc_flags
.Lxx_alu_sub_ptr:
        .long   _alu_sub_flags
.Lxx_alu_sbc_ptr:
        .long   _alu_sbc_flags
.Lxx_alu_cp_ptr:
        .long   _alu_cp_flags
.Lxx_pzstable_d:
        .long   _PZSTable

/* ---- Handler 20: LD r,XXh ---- */
/* 0x44(B), 0x4C(C), 0x54(D), 0x5C(E), 0x7C(A)                    */
/* Bits [5:3] decode target: 0=B, 1=C, 2=D, 3=E, 7=A              */
.Lxx_ld_r_xxh:
        /* Read XXh */
        mov     r14, r0
        add     r6, r0
        mov.b   @r0, r5
        extu.b  r5, r5         /* r5 = XXh value */
        /* Decode target from bits [5:3] */
        mov     r3, r0
        shlr    r0
        shlr    r0
        shlr    r0
        mov     #7, r1
        and     r1, r0         /* r0 = target index */
        cmp/eq  #7, r0
        bt      .Lxx_ld_xxh_to_a
        /* B(0)=10, C(1)=11, D(2)=12, E(3)=13 */
        add     #10, r0
        mov     r14, r1
        add     r0, r1
        bra     .Lxx_ret_fetch
        mov.b   r5, @r1       /* delay slot */
.Lxx_ld_xxh_to_a:
        bra     .Lxx_ret_fetch
        extu.b  r5, r12       /* delay slot: A = XXh */

/* ---- Handler 21: LD r,XXl ---- */
/* 0x45(B), 0x4D(C), 0x55(D), 0x5D(E), 0x7D(A)                    */
.Lxx_ld_r_xxl:
        /* Read XXl (offset r6+1) */
        mov     r14, r0
        add     r6, r0
        mov.b   @(1, r0), r0  /* mov.b @(disp,Rn),R0: dest=R0 */
        extu.b  r0, r5         /* r5 = XXl value */
        /* Decode target from bits [5:3] */
        mov     r3, r0
        shlr    r0
        shlr    r0
        shlr    r0
        mov     #7, r1
        and     r1, r0         /* r0 = target index */
        cmp/eq  #7, r0
        bt      .Lxx_ld_xxl_to_a
        add     #10, r0
        mov     r14, r1
        add     r0, r1
        bra     .Lxx_ret_fetch
        mov.b   r5, @r1       /* delay slot */
.Lxx_ld_xxl_to_a:
        bra     .Lxx_ret_fetch
        extu.b  r5, r12       /* delay slot */

/* ---- Handler 22: LD XXh,r ---- */
/* 0x60(B), 0x61(C), 0x62(D), 0x63(E), 0x67(A)                    */
/* Also 0x64(XXh←XXh = NOP), 0x65(XXh←XXl)                         */
/* Source from bits [2:0]: 0=B(10),1=C(11),2=D(12),3=E(13),        */
/*   4=XXh, 5=XXl, 7=A                                             */
.Lxx_ld_xxh_r:
        mov     r3, r0
        mov     #7, r1
        and     r1, r0         /* r0 = source index */
        cmp/eq  #7, r0
        bt      .Lxx_ld_xxh_from_a
        cmp/eq  #5, r0
        bt      .Lxx_ld_xxh_from_xxl
        cmp/eq  #4, r0
        bt      .Lxx_ret_fetch /* NOP: XXh←XXh, just return */
        /* B(0)=10, C(1)=11, D(2)=12, E(3)=13 */
        add     #10, r0
        mov     r14, r1
        add     r0, r1
        mov.b   @r1, r0
        bra     .Lxx_ld_xxh_store
        extu.b  r0, r0        /* delay slot */
.Lxx_ld_xxh_from_a:
        bra     .Lxx_ld_xxh_store
        mov     r12, r0       /* delay slot */
.Lxx_ld_xxh_from_xxl:
        mov     r14, r1
        add     r6, r1
        add     #1, r1
        mov.b   @r1, r0
        extu.b  r0, r0
.Lxx_ld_xxh_store:
        /* r0 = value to store into XXh */
        mov     r14, r1
        add     r6, r1
        bra     .Lxx_ret_fetch
        mov.b   r0, @r1       /* delay slot */

/* ---- Handler 23: LD XXl,r ---- */
/* 0x68(B), 0x69(C), 0x6A(D), 0x6B(E), 0x6F(A)                    */
/* Also 0x6C(XXl←XXh), 0x6D(XXl←XXl = NOP)                         */
.Lxx_ld_xxl_r:
        mov     r3, r0
        mov     #7, r1
        and     r1, r0         /* r0 = source index */
        cmp/eq  #7, r0
        bt      .Lxx_ld_xxl_from_a
        cmp/eq  #4, r0
        bt      .Lxx_ld_xxl_from_xxh
        cmp/eq  #5, r0
        bt      .Lxx_ret_fetch /* NOP: XXl←XXl, just return */
        /* B(0)=10, C(1)=11, D(2)=12, E(3)=13 */
        add     #10, r0
        mov     r14, r1
        add     r0, r1
        mov.b   @r1, r0
        bra     .Lxx_ld_xxl_store
        extu.b  r0, r0        /* delay slot */
.Lxx_ld_xxl_from_a:
        bra     .Lxx_ld_xxl_store
        mov     r12, r0       /* delay slot */
.Lxx_ld_xxl_from_xxh:
        mov     r14, r1
        add     r6, r1
        mov.b   @r1, r0
        extu.b  r0, r0
.Lxx_ld_xxl_store:
        /* r0 = value to store into XXl */
        mov     r14, r1
        add     r6, r1
        add     #1, r1
        bra     .Lxx_ret_fetch
        mov.b   r0, @r1       /* delay slot */

/* ---- Handler 24: INC XXh (0x24) ---- */
.Lxx_inc_xxh:
        mov     r14, r0
        add     r6, r0
        mov.b   @r0, r3
        extu.b  r3, r3
        add     #1, r3
        extu.b  r3, r3         /* r3 = result */
        /* Store result to XXh */
        mov     r14, r1
        add     r6, r1
        mov.b   r3, @r1
        /* Flags: ZSTable[r] | V(r==0x80) | H((r&0xF)==0) | old_C */
        mov.l   .Lxx_zstable_d, r1
        mov     r3, r0
        add     r1, r0
        mov.b   @r0, r1
        extu.b  r1, r1         /* r1 = Z|S */
        mov     #0x80, r2
        extu.b  r2, r2
        cmp/eq  r2, r3
        movt    r2
        shll    r2
        shll    r2             /* r2 = V_FLAG or 0 */
        or      r2, r1
        mov     r3, r2
        mov     #0x0F, r0
        and     r0, r2
        tst     r2, r2
        movt    r2
        shll2   r2
        shll2   r2             /* r2 = H_FLAG or 0 */
        or      r2, r1
        mov.b   @(3, r14), r0
        and     #1, r0
        or      r0, r1
        mov     r1, r0
        bra     .Lxx_ret_fetch
        mov.b   r0, @(3, r14) /* delay slot */

/* ---- Handler 25: DEC XXh (0x25) ---- */
.Lxx_dec_xxh:
        mov     r14, r0
        add     r6, r0
        mov.b   @r0, r3
        extu.b  r3, r3
        add     #-1, r3
        extu.b  r3, r3
        mov     r14, r1
        add     r6, r1
        mov.b   r3, @r1
        /* Flags: N | ZSTable[r] | V(r==0x7F) | H((r&0xF)==0xF) | old_C */
        mov.l   .Lxx_zstable_d, r1
        mov     r3, r0
        add     r1, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x02, r2      /* N_FLAG */
        or      r2, r1
        mov     #0x7F, r2
        cmp/eq  r2, r3
        movt    r2
        shll    r2
        shll    r2
        or      r2, r1
        mov     r3, r2
        mov     #0x0F, r0
        and     r0, r2
        cmp/eq  r0, r2
        movt    r2
        shll2   r2
        shll2   r2
        or      r2, r1
        mov.b   @(3, r14), r0
        and     #1, r0
        or      r0, r1
        mov     r1, r0
        bra     .Lxx_ret_fetch
        mov.b   r0, @(3, r14) /* delay slot */

/* ---- Handler 26: LD XXh,n (0x26) ---- */
.Lxx_ld_xxh_n:
        sts.l   pr, @-r15
        bsr     _far_fetch_imm3
        nop
        mov     r14, r0
        add     r6, r0
        mov.b   r3, @r0       /* XXh = n */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* ---- Handler 27: INC XXl (0x2C) ---- */
.Lxx_inc_xxl:
        mov     r14, r0
        add     r6, r0
        add     #1, r0
        mov.b   @r0, r3
        extu.b  r3, r3
        add     #1, r3
        extu.b  r3, r3
        mov     r14, r1
        add     r6, r1
        add     #1, r1
        mov.b   r3, @r1
        /* Flags (same as INC XXh) */
        mov.l   .Lxx_zstable_d, r1
        mov     r3, r0
        add     r1, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x80, r2
        extu.b  r2, r2
        cmp/eq  r2, r3
        movt    r2
        shll    r2
        shll    r2
        or      r2, r1
        mov     r3, r2
        mov     #0x0F, r0
        and     r0, r2
        tst     r2, r2
        movt    r2
        shll2   r2
        shll2   r2
        or      r2, r1
        mov.b   @(3, r14), r0
        and     #1, r0
        or      r0, r1
        mov     r1, r0
        bra     .Lxx_ret_fetch
        mov.b   r0, @(3, r14) /* delay slot */

/* ---- Handler 28: DEC XXl (0x2D) ---- */
.Lxx_dec_xxl:
        mov     r14, r0
        add     r6, r0
        add     #1, r0
        mov.b   @r0, r3
        extu.b  r3, r3
        add     #-1, r3
        extu.b  r3, r3
        mov     r14, r1
        add     r6, r1
        add     #1, r1
        mov.b   r3, @r1
        /* Flags (same as DEC XXh) */
        mov.l   .Lxx_zstable_d, r1
        mov     r3, r0
        add     r1, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x02, r2
        or      r2, r1
        mov     #0x7F, r2
        cmp/eq  r2, r3
        movt    r2
        shll    r2
        shll    r2
        or      r2, r1
        mov     r3, r2
        mov     #0x0F, r0
        and     r0, r2
        cmp/eq  r0, r2
        movt    r2
        shll2   r2
        shll2   r2
        or      r2, r1
        mov.b   @(3, r14), r0
        and     #1, r0
        or      r0, r1
        mov     r1, r0
        bra     .Lxx_ret_fetch
        mov.b   r0, @(3, r14) /* delay slot */

/* ---- Handler 29: LD XXl,n (0x2E) ---- */
.Lxx_ld_xxl_n:
        sts.l   pr, @-r15
        bsr     _far_fetch_imm3
        nop
        mov     r14, r0
        add     r6, r0
        add     #1, r0
        mov.b   r3, @r0       /* XXl = n */
        mov.l   @r15+, r0      /* pop PR via r0 */
        bra     .Lxx_ret_fetch
        lds     r0, pr         /* delay slot */

/* Literal pool E — INC/DEC tables */
        .align 2
.Lxx_zstable_d:
        .long   _ZSTable
/* ================================================================ */
        .subsection 0
        .align 2

/* ---- Far-call trampolines Set B (tail-call via JMP, preserves PR) ---- */
/* For DD/FD and branch handler code that can't BSR directly to far-away routines */
_far_gg_read_b:
        mov.l   .Lfar_gg_read_b, r0
        jmp     @r0
        nop
_far_gg_write_b:
        mov.l   .Lfar_gg_write_b, r0
        jmp     @r0
        nop
_far_rebase_pc_b:
        mov.l   .Lfar_rebase_b, r0
        jmp     @r0
        nop
_far_z80_fetch:
        mov.l   .Lfar_z80_fetch, r0
        jmp     @r0
        nop
_far_z80_fetch_bp:
        mov.l   .Lfar_z80_fetch_bp, r0
        jmp     @r0
        nop
        .align 2
.Lfar_gg_read_b:
        .long   _inline_gg_read
.Lfar_gg_write_b:
        .long   _inline_gg_write
.Lfar_rebase_b:
        .long   _do_rebase_pc
.Lfar_z80_fetch:
        .long   _z80_fetch
.Lfar_z80_fetch_bp:
        .long   _z80_fetch_bp

/* ================================================================ */
/*  Branch/flow control opcodes                            */
/* ================================================================ */

/* ---- JP nn (0xC3): unconditional absolute jump ---- */
_z80_jp:
        add     #-10, r11
        /* Read low byte at PC */
        bsr     _far_gg_read_b
        mov     r7, r4 /* delay slot */
        mov     r0, r3          /* r3 = low byte */
        /* Read high byte at PC+1 */
        mov     r7, r4
        bsr     _far_gg_read_b
        add     #1, r4 /* delay slot */
        /* PC = (high << 8) | low */
        shll8   r0
        or      r3, r0
        bra     _far_z80_fetch_bp
        extu.w  r0, r7 /* delay slot */

/* ---- JR e (0x18): unconditional relative jump ---- */
_z80_jr:
        add     #-12, r11
        /* Read signed offset at PC */
        bsr     _far_gg_read_b
        mov     r7, r4 /* delay slot */
        exts.b  r0, r0          /* sign-extend */
        add     r0, r7
        add     #1, r7          /* PC += offset + 1 */
        bra     _far_z80_fetch_bp
        extu.w  r7, r7 /* delay slot */

/* ---- DJNZ (0x10): decrement B, jump if not zero ---- */
_z80_djnz:
        add     #-8, r11
        /* Decrement B */
        mov.b   @(10, r14), r0  /* B */
        add     #-1, r0
        mov.b   r0, @(10, r14)
        extu.b  r0, r1
        tst     r1, r1
        bt      _z80_djnz_skip
        /* Taken: ICount -= 5, do JR */
        bra     _z80_jr
        add     #-5, r11 /* delay slot */
_z80_djnz_skip:
        /* Not taken: skip offset byte (PC++) */
        add     #1, r7
        bra     _far_z80_fetch
        extu.w  r7, r7 /* delay slot */

/* ---- JR_NZ (0x20) ---- */
        /* F offset 3: read for JR cond */
_z80_jr_nz:
        add     #-7, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x40, r1       /* Z_FLAG */
        tst     r1, r0
        bf      _z80_jr_skip    /* Z set → skip */
        /* Taken */
        bra     _z80_jr
        add     #-5, r11 /* delay slot */

/* ---- JR_Z (0x28) ---- */
_z80_jr_z:
        add     #-7, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x40, r1       /* Z_FLAG */
        tst     r1, r0
        bt      _z80_jr_skip    /* Z clear → skip */
        bra     _z80_jr
        add     #-5, r11 /* delay slot */

/* ---- JR_NC (0x30) ---- */
_z80_jr_nc:
        add     #-7, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r1          /* C_FLAG */
        tst     r1, r0
        bf      _z80_jr_skip    /* C set → skip */
        bra     _z80_jr
        add     #-5, r11 /* delay slot */

/* ---- JR_C (0x38) ---- */
_z80_jr_c:
        add     #-7, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r1          /* C_FLAG */
        tst     r1, r0
        bt      _z80_jr_skip    /* C clear → skip */
        bra     _z80_jr
        add     #-5, r11 /* delay slot */

/* Shared: skip JR offset byte (branch not taken) */
_z80_jr_skip:
        add     #1, r7
        bra     _far_z80_fetch
        extu.w  r7, r7 /* delay slot */

/* ---- Conditional JP (0xC2/CA/D2/DA/E2/EA/F2/FA) ---- */
/* These read a 16-bit target; jump if condition met, else PC+=2 */

/* Helper: read 16-bit target into r3 from PC, advance PC by 2 */
_z80_jp_read_target:
        bsr     _far_gg_read_b
        mov     r7, r4 /* delay slot */
        mov     r0, r3
        mov     r7, r4
        bsr     _far_gg_read_b
        add     #1, r4 /* delay slot */
        shll8   r0
        or      r3, r0
        rts
        mov     r0, r3          /* r3 = target address (delay slot) */

_z80_jp_nz:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x40, r1
        tst     r1, r0
        bf      _z80_jp_skip    /* Z set → not taken */
        bra     _z80_jp
        nop

_z80_jp_z:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x40, r1
        tst     r1, r0
        bt      _z80_jp_skip    /* Z clear → not taken */
        bra     _z80_jp
        nop

_z80_jp_nc:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r1
        tst     r1, r0
        bf      _z80_jp_skip    /* C set → not taken */
        bra     _z80_jp
        nop

_z80_jp_c:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r1
        tst     r1, r0
        bt      _z80_jp_skip    /* C clear → not taken */
        bra     _z80_jp
        nop

_z80_jp_po:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #4, r1          /* P_FLAG */
        tst     r1, r0
        bf      _z80_jp_skip    /* P set → not taken (PO=parity odd) */
        bra     _z80_jp
        nop

_z80_jp_pe:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #4, r1
        tst     r1, r0
        bt      _z80_jp_skip    /* P clear → not taken */
        bra     _z80_jp
        nop

_z80_jp_p:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x80, r1       /* S_FLAG */
        tst     r1, r0
        bf      _z80_jp_skip    /* S set → not taken (P=positive) */
        bra     _z80_jp
        nop

_z80_jp_m:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x80, r1
        tst     r1, r0
        bt      _z80_jp_skip    /* S clear → not taken */
        bra     _z80_jp
        nop

/* Shared: JP not taken — skip 2 bytes (PC += 2) */
_z80_jp_skip:
        add     #2, r7
        bra     _far_z80_fetch
        extu.w  r7, r7 /* delay slot */

/* ---- CALL nn (0xCD): unconditional call ---- */
_z80_call:
        add     #-17, r11
        /* Read 16-bit target */
        bsr     _far_gg_read_b
        mov     r7, r4 /* delay slot */
        mov     r0, r3          /* r3 = low byte */
        mov     r7, r4
        bsr     _far_gg_read_b
        add     #1, r4 /* delay slot */
        shll8   r0
        or      r3, r0
        mov     r0, r6          /* r6 = target address */

        /* Return address = PC + 2 */
        mov     r7, r3
        add     #2, r3
        extu.w  r3, r3          /* r3 = return address */

        /* Push return address */
        mov.w   @(16, r14), r0  /* SP */
        extu.w  r0, r4
        add     #-1, r4
        mov     r3, r5
        shlr8   r5
        bsr     _far_gg_write_b
        extu.b  r5, r5 /* delay slot */ /* high byte of return addr */
        add     #-1, r4
        mov     r3, r5
        bsr     _far_gg_write_b
        extu.b  r5, r5 /* delay slot */ /* low byte of return addr */
        /* Update SP */
        mov     r14, r0
        add     #16, r0
        mov.w   r4, @r0
        /* PC = target */
        bra     _far_z80_fetch_bp
        extu.w  r6, r7 /* delay slot */

/* ---- RET (0xC9): unconditional return ---- */
_z80_ret:
        add     #-10, r11
        mov.w   @(16, r14), r0  /* SP */
        /* Read low byte */
        bsr     _far_gg_read_b
        extu.w  r0, r4 /* delay slot */
        mov     r0, r3
        /* Read high byte */
        bsr     _far_gg_read_b
        add     #1, r4 /* delay slot */
        shll8   r0
        or      r3, r0
        add     #1, r4
        /* PC = popped value */
        extu.w  r0, r7
        /* Update SP */
        mov     r14, r0
        add     #16, r0
        bra     _far_z80_fetch_bp
        mov.w   r4, @r0 /* delay slot */

/* ---- Conditional CALL (0xC4/CC/D4/DC/E4/EC/F4/FC) ---- */
/* Extra -7 cycles if taken */

_z80_call_nz:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x40, r1
        tst     r1, r0
        bf      _z80_jp_skip    /* Z set → not taken, skip 2 bytes */
        bra     _z80_call
        add     #-7, r11 /* delay slot */

_z80_call_z:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x40, r1
        tst     r1, r0
        bt      _z80_jp_skip
        bra     _z80_call
        add     #-7, r11 /* delay slot */

_z80_call_nc:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r1
        tst     r1, r0
        bf      _z80_jp_skip
        bra     _z80_call
        add     #-7, r11 /* delay slot */

_z80_call_c:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r1
        tst     r1, r0
        bt      _z80_jp_skip
        bra     _z80_call
        add     #-7, r11 /* delay slot */

_z80_call_po:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #4, r1
        tst     r1, r0
        bf      _z80_jp_skip
        bra     _z80_call
        add     #-7, r11 /* delay slot */

_z80_call_pe:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #4, r1
        tst     r1, r0
        bt      _z80_jp_skip
        bra     _z80_call
        add     #-7, r11 /* delay slot */

_z80_call_p:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x80, r1
        tst     r1, r0
        bf      _z80_jp_skip
        bra     _z80_call
        add     #-7, r11 /* delay slot */

_z80_call_m:
        add     #-10, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x80, r1
        tst     r1, r0
        bt      _z80_jp_skip
        bra     _z80_call
        add     #-7, r11 /* delay slot */

/* ---- Conditional RET (0xC0/C8/D0/D8/E0/E8/F0/F8) ---- */
/* Extra -6 cycles if taken */

_z80_ret_nz:
        add     #-5, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x40, r1
        tst     r1, r0
        bf      _z80_ret_notaken  /* Z set → not taken */
        bra     _z80_ret
        add     #-6, r11 /* delay slot */

_z80_ret_z:
        add     #-5, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x40, r1
        tst     r1, r0
        bt      _z80_ret_notaken  /* Z clear → not taken */
        bra     _z80_ret
        add     #-6, r11 /* delay slot */

_z80_ret_nc:
        add     #-5, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r1
        tst     r1, r0
        bf      _z80_ret_notaken
        bra     _z80_ret
        add     #-6, r11 /* delay slot */

_z80_ret_c:
        add     #-5, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r1
        tst     r1, r0
        bt      _z80_ret_notaken
        bra     _z80_ret
        add     #-6, r11 /* delay slot */

_z80_ret_po:
        add     #-5, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #4, r1
        tst     r1, r0
        bf      _z80_ret_notaken
        bra     _z80_ret
        add     #-6, r11 /* delay slot */

_z80_ret_pe:
        add     #-5, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #4, r1
        tst     r1, r0
        bt      _z80_ret_notaken
        bra     _z80_ret
        add     #-6, r11 /* delay slot */

_z80_ret_p:
        add     #-5, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x80, r1
        tst     r1, r0
        bf      _z80_ret_notaken
        bra     _z80_ret
        add     #-6, r11 /* delay slot */

_z80_ret_m:
        add     #-5, r11
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #0x80, r1
        tst     r1, r0
        bt      _z80_ret_notaken
        bra     _z80_ret
        add     #-6, r11 /* delay slot */

_z80_ret_notaken:
        bra     _far_z80_fetch
        nop

/* ================================================================ */
/*  Cold section: RST, misc ops, CB prefix                          */
/* ================================================================ */
        .subsection 1
        .align 2

/* ---- Cold fragment 2 trampoline for gg_write (RST needs it) ---- */
_cold_gg_write_rst:
        mov.l   .Lcold_gg_write_rst_addr, r0
        jmp     @r0
        nop
        .align 2
.Lcold_gg_write_rst_addr:
        .long   _inline_gg_write

/* ---- RST (restart) opcodes ---- */
/* RST pushes PC then jumps to fixed address */
_z80_rst00:
        add     #-11, r11
        bra     _z80_rst_common
        mov     #0x00, r6 /* delay slot */
_z80_rst08:
        add     #-11, r11
        bra     _z80_rst_common
        mov     #0x08, r6 /* delay slot */
_z80_rst10:
        add     #-11, r11
        bra     _z80_rst_common
        mov     #0x10, r6 /* delay slot */
_z80_rst18:
        add     #-11, r11
        bra     _z80_rst_common
        mov     #0x18, r6 /* delay slot */
_z80_rst20:
        add     #-11, r11
        bra     _z80_rst_common
        mov     #0x20, r6 /* delay slot */
_z80_rst28:
        add     #-11, r11
        bra     _z80_rst_common
        mov     #0x28, r6 /* delay slot */
_z80_rst30:
        add     #-11, r11
        bra     _z80_rst_common
        mov     #0x30, r6 /* delay slot */
_z80_rst38:
        add     #-11, r11
        bra     _z80_rst_common
        mov     #0x38, r6 /* delay slot */

_z80_rst_common:
        /* Push current PC */
        mov     r7, r3
        extu.w  r3, r3          /* return addr = current PC */
        mov.w   @(16, r14), r0  /* SP */
        extu.w  r0, r4
        add     #-1, r4
        mov     r3, r5
        shlr8   r5
        bsr     _cold_gg_write_rst
        extu.b  r5, r5 /* delay slot */
        add     #-1, r4
        mov     r3, r5
        bsr     _cold_gg_write_rst
        extu.b  r5, r5 /* delay slot */
        /* Update SP */
        mov     r14, r0
        add     #16, r0
        mov.w   r4, @r0
        /* PC = RST target */
        bra     .Lc_ret_fetch_bp
        extu.w  r6, r7 /* delay slot */

/* ---- SCF (0x37): set carry flag ---- */
_z80_scf:
        add     #-4, r11
        mov.b   @(3, r14), r0   /* F */
        extu.b  r0, r1
        mov     #1, r2
        or      r2, r1          /* set C */
        mov     #0x12, r2       /* N_FLAG | H_FLAG = 0x02 | 0x10 */
        not     r2, r2
        and     r2, r1          /* clear N, H */
        mov     r14, r0
        add     #3, r0
        bra     .Lc_ret_fetch
        mov.b   r1, @r0 /* delay slot */

/* ---- CCF (0x3F): complement carry flag ---- */
_z80_ccf:
        add     #-4, r11
        mov.b   @(3, r14), r0   /* F */
        extu.b  r0, r1
        /* H = old C (before complement) */
        mov     r1, r2
        mov     #1, r3
        and     r3, r2          /* old C */
        shll2   r2
        shll2   r2              /* old_C << 4 = H position */
        xor     r3, r1          /* complement C */
        mov     #0x12, r3       /* N | H */
        not     r3, r3
        and     r3, r1          /* clear N, H */
        or      r2, r1          /* set H = old C */
        mov     r14, r0
        add     #3, r0
        bra     .Lc_ret_fetch
        mov.b   r1, @r0 /* delay slot */

/* ---- CPL (0x2F): complement A ---- */
_z80_cpl:
        add     #-4, r11
        not     r12, r12
        extu.b  r12, r12        /* A = ~A (pinned in R12) */
        /* Set N and H flags */
        mov.b   @(3, r14), r0   /* F */
        extu.b  r0, r1
        mov     #0x12, r2       /* N | H */
        or      r2, r1
        mov     r14, r0
        add     #3, r0
        bra     .Lc_ret_fetch
        mov.b   r1, @r0 /* delay slot */

/* ---- EXX (0xD9): exchange BC/DE/HL with shadow ---- */
_z80_exx:
        add     #-4, r11
        /* BC <-> BC1 (offsets 10 and 34) */
        mov.w   @(10, r14), r0  /* r0 = main BC */
        mov     r0, r1          /* r1 = save main BC */
        mov     r14, r2
        add     #34, r2
        mov.w   @r2, r0         /* r0 = shadow BC1 */
        mov.w   r0, @(10, r14)  /* main BC = shadow BC1 */
        mov.w   r1, @r2         /* shadow BC1 = old main BC */
        /* DE <-> DE1 (offsets 12 and 36) */
        mov.w   @(12, r14), r0  /* r0 = main DE */
        mov     r0, r1          /* r1 = save main DE */
        mov     r14, r2
        add     #36, r2
        mov.w   @r2, r0         /* r0 = shadow DE1 */
        mov.w   r0, @(12, r14)  /* main DE = shadow DE1 */
        mov.w   r1, @r2         /* shadow DE1 = old main DE */
        /* HL <-> HL1 (offsets 8 and 38) */
        mov.w   @(8, r14), r0   /* r0 = main HL */
        mov     r0, r1          /* r1 = save main HL */
        mov     r14, r2
        add     #38, r2
        mov.w   @r2, r0         /* r0 = shadow HL1 */
        mov.w   r0, @(8, r14)   /* main HL = shadow HL1 */
        bra     .Lc_ret_fetch
        mov.w   r1, @r2         /* shadow HL1 = old main HL (delay slot) */

/* ---- EX DE,HL (0xEB) ---- */
_z80_ex_de_hl:
        add     #-4, r11
        mov     r14, r1
        add     #12, r1         /* r1 = &DE */
        mov.w   @r1, r2         /* r2 = DE */
        mov.w   @(8, r14), r0   /* r0 = HL */
        mov.w   r0, @r1         /* DE = HL */
        mov     r14, r0
        add     #8, r0
        bra     .Lc_ret_fetch
        mov.w   r2, @r0 /* delay slot */

/* ---- DI (0xF3) ---- */
_z80_di:
        add     #-4, r11
        /* Check if EI pending */
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #IFF_EI, r2
        tst     r2, r1
        bt      _z80_di_no_ei

        /* EI was pending: ICount += IBackup - 1 (R11 = ICount) */
        mov     r14, r2
        add     #Z80_IBACKUP, r2
        mov.l   @r2, r4
        add     r4, r11
        add     #-1, r11

_z80_di_no_ei:
        /* Clear IFF_1, IFF_2, IFF_EI */
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x29, r2       /* IFF_1 | IFF_2 | IFF_EI = 0x01|0x08|0x20 */
        not     r2, r2
        and     r2, r1
        bra     .Lc_ret_fetch
        mov.b   r1, @r0 /* delay slot */

/* ---- EI (0xFB) ---- */
_z80_ei:
        add     #-4, r11
        /* Check if already enabled or EI pending */
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x21, r2       /* IFF_1 | IFF_EI */
        tst     r2, r1
        bf      _z80_ei_done    /* already set → nop */

        /* Set IFF_2 | IFF_EI */
        mov     #0x28, r2       /* IFF_2 | IFF_EI = 0x08|0x20 */
        or      r2, r1
        mov.b   r1, @r0

        /* IBackup = ICount (R11 = ICount) */
        mov.l   r11, @(24, r14)

        /* ICount = 1 */
        mov     #1, r11

_z80_ei_done:
        bra     .Lc_ret_fetch
        nop

/* ---- HALT (0x76) ---- */
_z80_halt:
        add     #-4, r11
        /* PC-- (keep executing HALT) */
        add     #-1, r7
        extu.w  r7, r7
        /* Set IFF_HALT */
        mov     r14, r0
        add     #14, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x80, r2       /* IFF_HALT */
        or      r2, r1
        mov.b   r1, @r0
        /* Consume remaining cycles (R11 = ICount) */
        cmp/pl  r11
        bf      .Lhalt_exit     /* ICount <= 0, exit */
        /* R += ICount / 4; ICount %= 4 — O(1) via shift+mask.
         * HALT always costs 4 Z80 cycles, so divide by 4.
         * Old O(N) loop cost 5*N SH-2 cycles (N = ICount/4, up to ~57/line).
         * New code: ~10 SH-2 regardless of ICount. */
        mov     r14, r2
        add     #Z80_R, r2
        mov.b   @r2, r4
        extu.b  r4, r4          /* r4 = R */
        mov     r11, r0
        shlr2   r0              /* r0 = ICount / 4 (quotient) */
        add     r0, r4          /* R += quotient */
        mov.b   r4, @r2         /* store updated R */
        mov     #3, r0
        and     r11, r0         /* r0 = ICount & 3 (remainder) */
        mov     r0, r11         /* ICount = remainder */
        bra     .Lc_ret_fetch
        mov.l   r0, @(24, r14) /* delay slot: IBackup = remainder */
.Lhalt_exit:
        bra     .Lc_ret_fetch
        nop

/* ---- Rotate A opcodes (0x07, 0x17, 0x0F, 0x1F) ---- */

/* RLCA (0x07): rotate A left, old bit 7 to carry */
_z80_rlca:
        add     #-4, r11
        mov     r12, r1          /* A (pinned in R12) */
        /* bit 7 → carry: shift left to bit 8, then right 8 to bit 0 */
        mov     r1, r2
        shll    r2
        shlr8   r2              /* r2 = old bit 7 (0 or 1) */
        /* A = (A << 1) | carry */
        shll    r1
        or      r2, r1
        extu.b  r1, r1
        mov     r1, r12          /* store A (pinned in R12) */
        /* F = (F & ~(C|N|H)) | carry */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x13, r3       /* C|N|H = 1|2|0x10 */
        not     r3, r3
        and     r3, r1
        or      r2, r1
        bra     .Lc_ret_fetch
        mov.b   r1, @r0 /* delay slot */

/* RLA (0x17): rotate A left through carry */
_z80_rla:
        add     #-4, r11
        mov     r12, r1          /* A (pinned in R12) */
        /* old carry */
        mov     r14, r3
        add     #3, r3
        mov.b   @r3, r4
        extu.b  r4, r4
        mov     #1, r6
        and     r4, r6          /* r6 = old carry */
        /* new carry = bit 7 of A: shift left to bit 8, then right 8 */
        mov     r1, r2
        shll    r2
        shlr8   r2              /* r2 = new carry */
        /* A = (A << 1) | old_carry */
        shll    r1
        or      r6, r1
        extu.b  r1, r1
        mov     r1, r12          /* store A (pinned in R12) */
        /* F = (F & ~(C|N|H)) | new_carry */
        mov     #0x13, r5
        not     r5, r5
        and     r5, r4
        or      r2, r4
        bra     .Lc_ret_fetch
        mov.b   r4, @r3 /* delay slot */

/* RRCA (0x0F): rotate A right, old bit 0 to carry */
_z80_rrca:
        add     #-4, r11
        mov     r12, r1          /* A (pinned in R12) */
        mov     #1, r2
        and     r1, r2          /* r2 = old bit 0 (new carry) */
        /* A = (A >> 1) | (bit0 << 7) */
        shlr    r1
        mov     r2, r3
        shll8   r3              /* bit0 → bit 8 */
        shlr    r3              /* bit 8 → bit 7 = 0x00 or 0x80 */
        or      r3, r1
        extu.b  r1, r1
        mov     r1, r12          /* store A (pinned in R12) */
        /* F = (F & ~(C|N|H)) | carry */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r1
        extu.b  r1, r1
        mov     #0x13, r3
        not     r3, r3
        and     r3, r1
        or      r2, r1
        bra     .Lc_ret_fetch
        mov.b   r1, @r0 /* delay slot */

/* RRA (0x1F): rotate A right through carry */
_z80_rra:
        add     #-4, r11
        mov     r12, r1          /* A (pinned in R12) */
        /* old carry */
        mov     r14, r3
        add     #3, r3
        mov.b   @r3, r4
        extu.b  r4, r4
        mov     #1, r6
        and     r4, r6          /* r6 = old carry */
        /* new carry = bit 0 of A */
        mov     #1, r2
        and     r1, r2          /* r2 = new carry */
        /* A = (A >> 1) | (old_carry ? 0x80 : 0) */
        shlr    r1
        shll8   r6              /* old_carry << 8 */
        shlr    r6              /* old_carry << 7 → 0x00 or 0x80 */
        or      r6, r1
        extu.b  r1, r1
        mov     r1, r12          /* store A (pinned in R12) */
        /* F = (F & ~(C|N|H)) | new_carry */
        mov     #0x13, r5
        not     r5, r5
        and     r5, r4
        or      r2, r4
        bra     .Lc_ret_fetch
        mov.b   r4, @r3 /* delay slot */

/* ---- ADD HL,rr (0x09,0x19,0x29,0x39) ---- */
/* F = (F & ~(H|N|C)) | H_if_carry_from_bit11 | C_if_overflow_16 */

_z80_add_hl_bc:
        add     #-11, r11
        bra     _z80_addhl_common
        mov     #10, r3         /* BC offset (delay slot) */
_z80_add_hl_de:
        add     #-11, r11
        bra     _z80_addhl_common
        mov     #12, r3 /* delay slot */
_z80_add_hl_hl:
        add     #-11, r11
        bra     _z80_addhl_common
        mov     #8, r3 /* delay slot */
_z80_add_hl_sp:
        add     #-11, r11
        bra     _z80_addhl_common
        mov     #16, r3 /* delay slot */

_z80_addhl_common:
        /* Load HL */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        extu.w  r4, r4          /* r4 = HL */
        /* Load src pair */
        mov     r14, r0
        add     r3, r0
        mov.w   @r0, r5
        extu.w  r5, r5          /* r5 = src */
        /* Result */
        mov     r4, r6
        add     r5, r6          /* r6 = 32-bit sum */
        mov     r6, r1
        extu.w  r1, r1          /* r1 = result & 0xFFFF */
        /* Store HL */
        mov     r14, r0
        add     #8, r0
        mov.w   r1, @r0

        /* Flags: keep SZPV, clear NHC, recompute H and C */
        /* C: carry from 32-bit sum (check while r6 still holds sum) */
        mov     r6, r2
        shlr16  r2
        mov     #1, r3
        and     r3, r2          /* r2 = new carry (0 or 1) */
        /* r6 now free — use for flag accumulation */
        mov     r14, r0
        add     #3, r0
        mov.b   @r0, r6
        extu.b  r6, r6
        mov     #0x13, r3       /* C|N|H */
        not     r3, r3
        and     r3, r6          /* clear C|N|H in old F */
        or      r2, r6          /* set C flag */

        /* H: (HL ^ src ^ result) & 0x1000 */
        mov     r4, r2
        xor     r5, r2
        xor     r1, r2
        mov.l   .Lc_1000, r3
        tst     r3, r2
        bt      .Laddhl_no_h
        mov     #0x10, r2
        or      r2, r6
.Laddhl_no_h:
        bra     .Lc_ret_fetch
        mov.b   r6, @r0 /* delay slot */

/* Trampoline to _z80_fetch for sequential branch handlers */
.Lc_ret_fetch:
        mov.l   .Lc_z80_fetch, r0
        jmp     @r0
        nop

/* Trampoline to _z80_fetch_bp for branch handlers */
.Lc_ret_fetch_bp:
        mov.l   .Lc_z80_fetch_bp, r0
        jmp     @r0
        nop

/* ================================================================ */
/*  Pool C — complex handler literal pool                           */
/* ================================================================ */
        .align 2
.Lc_reg_offsets:
        .long   _z80_reg_offsets
.Lc_zstable:
        .long   _ZSTable
.Lc_1000:
        .long   0x00001000
.Lc_z80_fetch:
        .long   _z80_fetch
.Lc_z80_fetch_bp:
        .long   _z80_fetch_bp
.Lhalt_cycles:
        .long   _Cycles

/* ================================================================ */
/*  Data tables                                                     */
/* ================================================================ */

        .align 2
_z80_reg_offsets:
        .byte   10, 11, 12, 13, 8, 9, 0xFF, 2

/* ================================================================ */
/*  CB prefix handler (compact computed dispatch)          */
/*                                                                  */
/*  All 256 CB sub-opcodes handled via decoded register/operation.  */
/*  Register usage during handler:                                  */
/*    r4 = value to operate on / result                             */
/*    r5 = CB sub-opcode (preserved through decode)                 */
/*    r6 = register index (bits 2:0 of sub-opcode)                 */
/*    r3 = register byte ptr (reg) / HL address (xhl) for write    */
/* ================================================================ */
        .global _z80_cb_prefix
_z80_cb_prefix:
        /* ---- Fetch CB sub-opcode via page table ---- */
        mov     r7, r0
        shlr8   r0
        shlr2   r0
        shlr    r0
        shlr    r0
        shlr    r0             /* r0 = PC >> 13 */
        shll2   r0             /* r0 = page_index * 4 */
        mov.l   @(r0, r8), r2 /* r2 = Mem_Pages[page_index] */
        mov     r7, r0
        and     r10, r0       /* r0 = PC & 0x1FFF */
        mov.b   @(r0, r2), r0
        extu.b  r0, r5         /* r5 = CB sub-opcode */

#if PERF_DEBUG
        /* Prefix audit: g_cb_sub_hist[r5]++.  r5 stays intact for the decode below;
         * copy it to r2 as index.  r0/r1 are scratch (re-derived later). */
        mov     r5, r2                 /* r2 = sub-opcode (r5 preserved) */
        mov.l   .Lg_cb_sub_hist, r0    /* r0 = &g_cb_sub_hist[256] */
        shll    r2                     /* r2 = sub * 2 (u16 index) */
        add     r2, r0                 /* r0 = &g_cb_sub_hist[sub] */
        mov.w   @r0, r1                /* r1 = current count */
        add     #1, r1
        mov.w   r1, @r0                /* write back (wraps at 65536; safe per frame) */
        .align 2
.Lg_cb_sub_hist:
        .long   _g_cb_sub_hist
#endif

        /* ---- PC++ ---- */
        add     #1, r7
        extu.w  r7, r7

        /* ---- R register++ ---- */
        mov     r14, r0
        add     #15, r0
        mov.b   @r0, r1
        add     #1, r1
        mov.b   r1, @r0

        /* ---- Extract register index ---- */
        mov     r5, r0
        and     #7, r0         /* r0 = reg_idx */
        mov     r0, r6         /* r6 = reg_idx */

        /* ---- Check if (HL) operand ---- */
        cmp/eq  #6, r0
        bt      .Lcb_xhl_entry

        /* ======== Register path: 8 cycles ======== */
        /* CB register: ICount -= 8 (R11 = ICount) */
        add     #-8, r11
        mov     r12, r0
        mov.b   r0, @(2, r14)  /* sync A to struct (CB generic) */

        /* Load register value via offset table */
        mov.l   .Lcb_reg_offsets, r1
        add     r6, r1
        mov.b   @r1, r0
        extu.b  r0, r0         /* r0 = struct offset */
        add     r14, r0        /* r0 = &z80_t.reg */
        mov     r0, r3         /* r3 = register byte address */
        mov.b   @r0, r0

        bra     .Lcb_dispatch_op
        extu.b  r0, r4         /* r4 = register value (delay slot) */

        /* ======== (HL) path ======== */
.Lcb_xhl_entry:
        /* BIT (HL) = 12 cycles, others = 15 */
        mov     r5, r0
        shlr2   r0
        shlr2   r0
        shlr2   r0            /* r0 = sub_opcode >> 6 */
        cmp/eq  #1, r0        /* 1 = BIT group */
        bf      .Lcb_xhl_15

        /* BIT (HL): 12 cycles (R11 = ICount) */
        bra     .Lcb_xhl_read
        add     #-12, r11 /* delay slot */

.Lcb_xhl_15:
        /* Non-BIT (HL): 15 cycles (R11 = ICount) */
        add     #-15, r11

.Lcb_xhl_read:
        /* Read value from (HL) */
        mov     r14, r0
        add     #8, r0
        mov.w   @r0, r4
        extu.w  r4, r4         /* r4 = HL address */
        mov     r4, r3         /* r3 = save HL address for writeback */
        /* Inline gg_read */
        mov     r4, r0
        shlr8   r0
        shlr2   r0
        shlr    r0
        shlr    r0
        shlr    r0
        shll2   r0
        mov.l   @(r0, r8), r1
        mov     r4, r0
        and     r10, r0
        mov.b   @(r0, r1), r0
        extu.b  r0, r4         /* r4 = value from (HL) */
        /* Fall through to dispatch */

.Lcb_dispatch_op:
        /* bits[7:6]: 00=rot/shift, 01=BIT, 10=RES, 11=SET */
        mov     r5, r0
        shlr2   r0
        shlr2   r0
        shlr2   r0            /* r0 = sub_opcode >> 6 */
        tst     r0, r0
        bt      .Lcb_rotshift  /* 0 */
        cmp/eq  #1, r0
        bt      .Lcb_bit       /* 1 */
        cmp/eq  #2, r0
        bt      .Lcb_res       /* 2 */
        bra     .Lcb_set       /* 3 */
        nop

/* ---------------------------------------------------------------- */
/*  Rotate/Shift (bits[7:6] = 00)                                   */
/*  bits[5:3]: 0=RLC 1=RRC 2=RL 3=RR 4=SLA 5=SRA 6=SLL 7=SRL     */
/* ---------------------------------------------------------------- */
.Lcb_rotshift:
        mov     r5, r0
        shlr    r0
        shlr    r0
        shlr    r0
        and     #7, r0
        tst     r0, r0
        bt      .Lcb_rlc
        cmp/eq  #1, r0
        bt      .Lcb_rrc
        cmp/eq  #2, r0
        bt      .Lcb_rl
        cmp/eq  #3, r0
        bt      .Lcb_rr
        cmp/eq  #4, r0
        bt      .Lcb_sla
        cmp/eq  #5, r0
        bt      .Lcb_sra
        cmp/eq  #6, r0
        bt      .Lcb_sll
        /* else: SRL (7) — fall through */

/* ---- SRL: F=val&1; val>>=1; F|=PZSTable[val] ---- */
.Lcb_srl:
        mov     r4, r0
        and     #1, r0
        mov     r0, r1         /* r1 = carry */
        shlr    r4
        bra     .Lcb_rotshift_flags
        extu.b  r4, r4 /* delay slot */

/* ---- RLC: F=val>>7; val=(val<<1)|F; F|=PZSTable[val] ---- */
.Lcb_rlc:
        mov     r4, r1
        shll    r1
        shlr8   r1             /* r1 = val >> 7 = carry (shll pushes bit7→bit8, shlr8 → bit0) */
        shll    r4
        or      r1, r4
        bra     .Lcb_rotshift_flags
        extu.b  r4, r4 /* delay slot */

/* ---- RRC: F=val&1; val=(val>>1)|(F<<7); F|=PZSTable[val] ---- */
.Lcb_rrc:
        mov     r4, r0
        and     #1, r0
        mov     r0, r1         /* r1 = carry */
        shlr    r4
        mov     r1, r0
        shll8   r0
        shlr    r0             /* r0 = carry << 7 (shll8 pushes bit0→bit8, shlr → bit7) */
        or      r0, r4
        bra     .Lcb_rotshift_flags
        extu.b  r4, r4 /* delay slot */

/* ---- RL: val=(val<<1)|old_carry; F=PZSTable[val]|new_carry ---- */
.Lcb_rl:
        /* Get old carry from F (AF.B.l at offset 3) */
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r2
        and     r2, r0
        mov     r0, r2         /* r2 = old carry */
        /* new carry = val >> 7 */
        mov     r4, r1
        shll    r1
        shlr8   r1             /* r1 = new carry (bit7 → bit0) */
        /* val = (val << 1) | old_carry */
        shll    r4
        or      r2, r4
        bra     .Lcb_rotshift_flags
        extu.b  r4, r4 /* delay slot */

/* ---- RR: val=(val>>1)|(old_carry<<7); F=PZSTable[val]|new_carry ---- */
.Lcb_rr:
        /* Get old carry from F */
        mov.b   @(3, r14), r0
        extu.b  r0, r0
        mov     #1, r2
        and     r2, r0
        /* old carry << 7 */
        shll8   r0
        shlr    r0             /* r0 = old_carry << 7 (bit0 → bit7) */
        mov     r0, r2         /* r2 = old_carry << 7 */
        /* new carry = val & 1 */
        mov     r4, r0
        and     #1, r0
        mov     r0, r1         /* r1 = new carry */
        /* val = (val >> 1) | old_carry_shifted */
        shlr    r4
        or      r2, r4
        bra     .Lcb_rotshift_flags
        extu.b  r4, r4 /* delay slot */

/* ---- SLA: F=val>>7; val<<=1; F|=PZSTable[val] ---- */
.Lcb_sla:
        mov     r4, r1
        shll    r1
        shlr8   r1             /* r1 = carry = bit 7 (shll pushes bit7→bit8, shlr8 → bit0) */
        shll    r4
        bra     .Lcb_rotshift_flags
        extu.b  r4, r4 /* delay slot */

/* ---- SRA: F=val&1; val=(val>>1)|(val&0x80); F|=PZSTable[val] ---- */
.Lcb_sra:
        mov     r4, r0
        and     #1, r0
        mov     r0, r1         /* r1 = carry = bit 0 */
        mov     r4, r2
        mov     #0x80, r0
        extu.b  r0, r0         /* r0 = 0x80 */
        and     r0, r2         /* r2 = val & 0x80 (sign bit) */
        shlr    r4
        or      r2, r4
        bra     .Lcb_rotshift_flags
        extu.b  r4, r4 /* delay slot */

/* ---- SLL: F=val>>7; val=(val<<1)|1; F|=PZSTable[val] ---- */
.Lcb_sll:
        mov     r4, r1
        shll    r1
        shlr8   r1             /* r1 = carry (bit7 → bit0) */
        shll    r4
        mov     #1, r0
        or      r0, r4
        extu.b  r4, r4
        /* fall through */

/* ---- Common rotate/shift flag store ---- */
/* r4 = result, r1 = carry (0 or 1) */
.Lcb_rotshift_flags:
        mov.l   .Lcb_pzstable, r2
        mov     r4, r0
        mov.b   @(r0, r2), r0
        extu.b  r0, r0         /* r0 = PZSTable[result] */
        or      r1, r0         /* r0 |= carry */
        /* Store F */
        mov     r14, r2
        add     #3, r2
        bra     .Lcb_writeback
        mov.b   r0, @r2 /* delay slot */

/* ---------------------------------------------------------------- */
/*  BIT (bits[7:6] = 01): test bit, set flags, no writeback        */
/*  F = (F & C_FLAG) | H_FLAG | PZSTable[val & (1 << bit)]          */
/* ---------------------------------------------------------------- */
.Lcb_bit:
        /* Extract bit number: (sub_opcode >> 3) & 7 */
        mov     r5, r0
        shlr    r0
        shlr    r0
        shlr    r0
        and     #7, r0        /* r0 = bit_number */

        /* Load bit mask from table */
        mov.l   .Lcb_bit_masks, r2
        mov.b   @(r0, r2), r1
        extu.b  r1, r1         /* r1 = 1 << bit_number */

        /* val & mask */
        mov     r4, r0
        and     r1, r0         /* r0 = val & (1 << bit) */

        /* PZSTable[val & mask] */
        mov.l   .Lcb_pzstable, r2
        mov.b   @(r0, r2), r0
        extu.b  r0, r0

        /* F = (old_F & C_FLAG) | H_FLAG | PZSTable[...] */
        mov     r14, r1
        add     #3, r1
        mov.b   @r1, r2
        extu.b  r2, r2         /* r2 = old F */
        mov     #1, r3
        and     r3, r2         /* r2 = old_F & C_FLAG */
        or      r2, r0
        mov     #0x10, r2      /* H_FLAG */
        or      r2, r0

        bra     .Lcb_return_fetch
        mov.b   r0, @r1 /* delay slot */

/* ---------------------------------------------------------------- */
/*  RES (bits[7:6] = 10): val &= ~(1 << bit)                       */
/* ---------------------------------------------------------------- */
.Lcb_res:
        mov     r5, r0
        shlr    r0
        shlr    r0
        shlr    r0
        and     #7, r0

        mov.l   .Lcb_bit_masks, r2
        mov.b   @(r0, r2), r0
        extu.b  r0, r0
        not     r0, r0
        and     r0, r4

        bra     .Lcb_writeback
        extu.b  r4, r4 /* delay slot */

/* ---------------------------------------------------------------- */
/*  SET (bits[7:6] = 11): val |= (1 << bit)                        */
/* ---------------------------------------------------------------- */
.Lcb_set:
        mov     r5, r0
        shlr    r0
        shlr    r0
        shlr    r0
        and     #7, r0

        mov.l   .Lcb_bit_masks, r2
        mov.b   @(r0, r2), r0
        extu.b  r0, r0

        bra     .Lcb_writeback
        or      r0, r4 /* delay slot */

/* ---------------------------------------------------------------- */
/*  Writeback: store r4 to register or memory at (HL)               */
/* ---------------------------------------------------------------- */
.Lcb_writeback:
        mov     #6, r0
        cmp/eq  r0, r6
        bt      .Lcb_writeback_xhl

        /* Register: store byte at r3 */
        mov.b   r4, @r3
        /* reload A from struct (register may be A) */
        mov.b   @(2, r14), r0
        bra     .Lcb_return_fetch
        extu.b  r0, r12 /* delay slot */

.Lcb_writeback_xhl:
        /* (HL): write r4 to memory at r3 (HL address) */
        mov     r4, r5         /* r5 = value */
        mov.l   .Lcb_gg_write, r0
        jsr     @r0
        mov     r3, r4 /* delay slot */ /* r4 = HL address */
        bra     .Lcb_return_fetch
        nop

/* Local trampoline: _z80_fetch is too far for BRA */
.Lcb_return_fetch:
        mov.l   .Lcb_z80_fetch, r0
        jmp     @r0
        nop

/* ================================================================ */
/*  Pool CB — literal pool for CB prefix handler                    */
/* ================================================================ */
        .align 2
.Lcb_reg_offsets:
        .long   _z80_reg_offsets
.Lcb_pzstable:
        .long   _PZSTable
.Lcb_bit_masks:
        .long   .Lcb_bit_masks_data
.Lcb_gg_write:
        .long   _inline_gg_write
.Lcb_z80_fetch:
        .long   _z80_fetch

        .align 2
.Lcb_bit_masks_data:
        .byte   0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80

/* ================================================================ */
/* ================================================================ */
/*  Handler address table: 256 × 4 bytes = 1024 bytes               */
/*  Each entry is the 32-bit address of the handler for that opcode. */
/*  Dispatch loads entry via: mov.l @(r0, r9), r1; jmp @r1          */
/*  With OD=1, table reads are data (bypass I-cache), freeing the   */
/*  entire cache for handler instruction code.                       */
/*                                                                   */
/*  PLACEMENT: in .hot_z80_data (data section), NOT in .z80_code.    */
/*  This removes a 1 KB gap in the middle of the hot opcode band,    */
/*  letting hot handlers + ALU helpers pack contiguously.            */
/* ================================================================ */
        .section .hot_z80_data,"a"
        .align 2
        .global _z80_handler_table
_z80_handler_table:
        .long   _z80_op_nop                    /* 0x00 */
        .long   _z80_ld_bc_nn                  /* 0x01 */
        .long   _z80_ld_xbc_a                  /* 0x02 */
        .long   _z80_inc_bc                    /* 0x03 */
        .long   _z80_inc_b_spec                /* 0x04 */
        .long   _z80_dec_b_spec                /* 0x05 */
        .long   _z80_ld_r_n                    /* 0x06 */
        .long   _z80_rlca                      /* 0x07 */
        .long   _z80_op_exafaf                 /* 0x08 */
        .long   _z80_add_hl_bc                 /* 0x09 */
        .long   _z80_ld_a_xbc                  /* 0x0A */
        .long   _z80_dec_bc                    /* 0x0B */
        .long   _z80_inc_c_spec                /* 0x0C */
        .long   _z80_dec_c_spec                /* 0x0D */
        .long   _z80_ld_r_n                    /* 0x0E */
        .long   _z80_rrca                      /* 0x0F */
        .long   _z80_djnz                      /* 0x10 */
        .long   _z80_ld_de_nn                  /* 0x11 */
        .long   _z80_ld_xde_a                  /* 0x12 */
        .long   _z80_inc_de                    /* 0x13 */
        .long   _z80_inc_d_spec                /* 0x14 */
        .long   _z80_dec_d_spec                /* 0x15 */
        .long   _z80_ld_r_n                    /* 0x16 */
        .long   _z80_rla                       /* 0x17 */
        .long   _z80_jr                        /* 0x18 */
        .long   _z80_add_hl_de                 /* 0x19 */
        .long   _z80_ld_a_xde                  /* 0x1A */
        .long   _z80_dec_de                    /* 0x1B */
        .long   _z80_inc_e_spec                /* 0x1C */
        .long   _z80_dec_e_spec                /* 0x1D */
        .long   _z80_ld_r_n                    /* 0x1E */
        .long   _z80_rra                       /* 0x1F */
        .long   _z80_jr_nz                     /* 0x20 */
        .long   _z80_ld_hl_nn                  /* 0x21 */
        .long   _z80_ld_xword_hl               /* 0x22 */
        .long   _z80_inc_hl                    /* 0x23 */
        .long   _z80_inc_h_spec                /* 0x24 */
        .long   _z80_dec_h_spec                /* 0x25 */
        .long   _z80_ld_r_n                    /* 0x26 */
        .long   _z80_daa                       /* 0x27 */
        .long   _z80_jr_z                      /* 0x28 */
        .long   _z80_add_hl_hl                 /* 0x29 */
        .long   _z80_ld_hl_xword               /* 0x2A */
        .long   _z80_dec_hl                    /* 0x2B */
        .long   _z80_inc_l_spec                /* 0x2C */
        .long   _z80_dec_l_spec                /* 0x2D */
        .long   _z80_ld_r_n                    /* 0x2E */
        .long   _z80_cpl                       /* 0x2F */
        .long   _z80_jr_nc                     /* 0x30 */
        .long   _z80_ld_sp_nn                  /* 0x31 */
        .long   _z80_ld_xword_a                /* 0x32 */
        .long   _z80_inc_sp                    /* 0x33 */
        .long   _z80_inc_xhl                   /* 0x34 */
        .long   _z80_dec_xhl                   /* 0x35 */
        .long   _z80_ld_xhl_n                  /* 0x36 */
        .long   _z80_scf                       /* 0x37 */
        .long   _z80_jr_c                      /* 0x38 */
        .long   _z80_add_hl_sp                 /* 0x39 */
        .long   _z80_ld_a_xword                /* 0x3A */
        .long   _z80_dec_sp                    /* 0x3B */
        .long   _z80_inc_a_spec                /* 0x3C */
        .long   _z80_dec_a_spec                /* 0x3D */
        .long   _z80_ld_r_n                    /* 0x3E */
        .long   _z80_ccf                       /* 0x3F */
        .long   _z80_ld_b_b                    /* 0x40 */
        .long   _z80_ld_b_c                    /* 0x41 */
        .long   _z80_ld_b_d                    /* 0x42 */
        .long   _z80_ld_b_e                    /* 0x43 */
        .long   _z80_ld_b_h                    /* 0x44 */
        .long   _z80_ld_b_l                    /* 0x45 */
        .long   _z80_ld_b_xhl                  /* 0x46 */
        .long   _z80_ld_b_a                    /* 0x47 */
        .long   _z80_ld_c_b                    /* 0x48 */
        .long   _z80_ld_c_c                    /* 0x49 */
        .long   _z80_ld_c_d                    /* 0x4A */
        .long   _z80_ld_c_e                    /* 0x4B */
        .long   _z80_ld_c_h                    /* 0x4C */
        .long   _z80_ld_c_l                    /* 0x4D */
        .long   _z80_ld_c_xhl                  /* 0x4E */
        .long   _z80_ld_c_a                    /* 0x4F */
        .long   _z80_ld_d_b                    /* 0x50 */
        .long   _z80_ld_d_c                    /* 0x51 */
        .long   _z80_ld_d_d                    /* 0x52 */
        .long   _z80_ld_d_e                    /* 0x53 */
        .long   _z80_ld_d_h                    /* 0x54 */
        .long   _z80_ld_d_l                    /* 0x55 */
        .long   _z80_ld_d_xhl                  /* 0x56 */
        .long   _z80_ld_d_a                    /* 0x57 */
        .long   _z80_ld_e_b                    /* 0x58 */
        .long   _z80_ld_e_c                    /* 0x59 */
        .long   _z80_ld_e_d                    /* 0x5A */
        .long   _z80_ld_e_e                    /* 0x5B */
        .long   _z80_ld_e_h                    /* 0x5C */
        .long   _z80_ld_e_l                    /* 0x5D */
        .long   _z80_ld_e_xhl                  /* 0x5E */
        .long   _z80_ld_e_a                    /* 0x5F */
        .long   _z80_ld_h_b                    /* 0x60 */
        .long   _z80_ld_h_c                    /* 0x61 */
        .long   _z80_ld_h_d                    /* 0x62 */
        .long   _z80_ld_h_e                    /* 0x63 */
        .long   _z80_ld_h_h                    /* 0x64 */
        .long   _z80_ld_h_l                    /* 0x65 */
        .long   _z80_ld_h_xhl                  /* 0x66 */
        .long   _z80_ld_h_a                    /* 0x67 */
        .long   _z80_ld_l_b                    /* 0x68 */
        .long   _z80_ld_l_c                    /* 0x69 */
        .long   _z80_ld_l_d                    /* 0x6A */
        .long   _z80_ld_l_e                    /* 0x6B */
        .long   _z80_ld_l_h                    /* 0x6C */
        .long   _z80_ld_l_l                    /* 0x6D */
        .long   _z80_ld_l_xhl                  /* 0x6E */
        .long   _z80_ld_l_a                    /* 0x6F */
        .long   _z80_ld_xhl_b                  /* 0x70 */
        .long   _z80_ld_xhl_c                  /* 0x71 */
        .long   _z80_ld_xhl_d                  /* 0x72 */
        .long   _z80_ld_xhl_e                  /* 0x73 */
        .long   _z80_ld_xhl_h                  /* 0x74 */
        .long   _z80_ld_xhl_l                  /* 0x75 */
        .long   _z80_halt                      /* 0x76 */
        .long   _z80_ld_xhl_a                  /* 0x77 */
        .long   _z80_ld_a_b                    /* 0x78 */
        .long   _z80_ld_a_c                    /* 0x79 */
        .long   _z80_ld_a_d                    /* 0x7A */
        .long   _z80_ld_a_e                    /* 0x7B */
        .long   _z80_ld_a_h                    /* 0x7C */
        .long   _z80_ld_a_l                    /* 0x7D */
        .long   _z80_ld_a_xhl                  /* 0x7E */
        .long   _z80_ld_a_a                    /* 0x7F */
        .long   _z80_add_b                     /* 0x80 */
        .long   _z80_add_c                     /* 0x81 */
        .long   _z80_add_d                     /* 0x82 */
        .long   _z80_add_e                     /* 0x83 */
        .long   _z80_add_h                     /* 0x84 */
        .long   _z80_add_l                     /* 0x85 */
        .long   _z80_add_xhl                   /* 0x86 */
        .long   _z80_add_a_spec                /* 0x87 */
        .long   _z80_adc_b                     /* 0x88 */
        .long   _z80_adc_c                     /* 0x89 */
        .long   _z80_adc_d                     /* 0x8A */
        .long   _z80_adc_e                     /* 0x8B */
        .long   _z80_adc_h                     /* 0x8C */
        .long   _z80_adc_l                     /* 0x8D */
        .long   _z80_adc_xhl                   /* 0x8E */
        .long   _z80_adc_a_spec                /* 0x8F */
        .long   _z80_sub_b                     /* 0x90 */
        .long   _z80_sub_c                     /* 0x91 */
        .long   _z80_sub_d                     /* 0x92 */
        .long   _z80_sub_e                     /* 0x93 */
        .long   _z80_sub_h                     /* 0x94 */
        .long   _z80_sub_l                     /* 0x95 */
        .long   _z80_sub_xhl                   /* 0x96 */
        .long   _z80_sub_a_spec                /* 0x97 */
        .long   _z80_sbc_b                     /* 0x98 */
        .long   _z80_sbc_c                     /* 0x99 */
        .long   _z80_sbc_d                     /* 0x9A */
        .long   _z80_sbc_e                     /* 0x9B */
        .long   _z80_sbc_h                     /* 0x9C */
        .long   _z80_sbc_l                     /* 0x9D */
        .long   _z80_sbc_xhl                   /* 0x9E */
        .long   _z80_sbc_a_spec                /* 0x9F */
        .long   _z80_and_b                     /* 0xA0 */
        .long   _z80_and_c                     /* 0xA1 */
        .long   _z80_and_d                     /* 0xA2 */
        .long   _z80_and_e                     /* 0xA3 */
        .long   _z80_and_h                     /* 0xA4 */
        .long   _z80_and_l                     /* 0xA5 */
        .long   _z80_and_xhl                   /* 0xA6 */
        .long   _z80_and_a_spec                /* 0xA7 */
        .long   _z80_xor_b                     /* 0xA8 */
        .long   _z80_xor_c                     /* 0xA9 */
        .long   _z80_xor_d                     /* 0xAA */
        .long   _z80_xor_e                     /* 0xAB */
        .long   _z80_xor_h                     /* 0xAC */
        .long   _z80_xor_l                     /* 0xAD */
        .long   _z80_xor_xhl                   /* 0xAE */
        .long   _z80_xor_a_spec                /* 0xAF */
        .long   _z80_or_b                      /* 0xB0 */
        .long   _z80_or_c                      /* 0xB1 */
        .long   _z80_or_d                      /* 0xB2 */
        .long   _z80_or_e                      /* 0xB3 */
        .long   _z80_or_h                      /* 0xB4 */
        .long   _z80_or_l                      /* 0xB5 */
        .long   _z80_or_xhl                    /* 0xB6 */
        .long   _z80_or_a_spec                 /* 0xB7 */
        .long   _z80_cp_b                      /* 0xB8 */
        .long   _z80_cp_c                      /* 0xB9 */
        .long   _z80_cp_d                      /* 0xBA */
        .long   _z80_cp_e                      /* 0xBB */
        .long   _z80_cp_h                      /* 0xBC */
        .long   _z80_cp_l                      /* 0xBD */
        .long   _z80_cp_xhl                    /* 0xBE */
        .long   _z80_cp_a_spec                 /* 0xBF */
        .long   _z80_ret_nz                    /* 0xC0 */
        .long   _z80_pop_bc                    /* 0xC1 */
        .long   _z80_jp_nz                     /* 0xC2 */
        .long   _z80_jp                        /* 0xC3 */
        .long   _z80_call_nz                   /* 0xC4 */
        .long   _z80_push_bc                   /* 0xC5 */
        .long   _z80_add_imm                   /* 0xC6 */
        .long   _z80_rst00                     /* 0xC7 */
        .long   _z80_ret_z                     /* 0xC8 */
        .long   _z80_ret                       /* 0xC9 */
        .long   _z80_jp_z                      /* 0xCA */
        .long   _z80_cb_prefix                 /* 0xCB */
        .long   _z80_call_z                    /* 0xCC */
        .long   _z80_call                      /* 0xCD */
        .long   _z80_adc_imm                   /* 0xCE */
        .long   _z80_rst08                     /* 0xCF */
        .long   _z80_ret_nc                    /* 0xD0 */
        .long   _z80_pop_de                    /* 0xD1 */
        .long   _z80_jp_nc                     /* 0xD2 */
        .long   _z80_outa                      /* 0xD3 */
        .long   _z80_call_nc                   /* 0xD4 */
        .long   _z80_push_de                   /* 0xD5 */
        .long   _z80_sub_imm                   /* 0xD6 */
        .long   _z80_rst10                     /* 0xD7 */
        .long   _z80_ret_c                     /* 0xD8 */
        .long   _z80_exx                       /* 0xD9 */
        .long   _z80_jp_c                      /* 0xDA */
        .long   _z80_ina                       /* 0xDB */
        .long   _z80_call_c                    /* 0xDC */
        .long   _z80_pfx_dd                    /* 0xDD */
        .long   _z80_sbc_imm                   /* 0xDE */
        .long   _z80_rst18                     /* 0xDF */
        .long   _z80_ret_po                    /* 0xE0 */
        .long   _z80_pop_hl                    /* 0xE1 */
        .long   _z80_jp_po                     /* 0xE2 */
        .long   _z80_ex_hl_xsp                 /* 0xE3 */
        .long   _z80_call_po                   /* 0xE4 */
        .long   _z80_push_hl                   /* 0xE5 */
        .long   _z80_and_imm                   /* 0xE6 */
        .long   _z80_rst20                     /* 0xE7 */
        .long   _z80_ret_pe                    /* 0xE8 */
        .long   _z80_jp_hl                     /* 0xE9 */
        .long   _z80_jp_pe                     /* 0xEA */
        .long   _z80_ex_de_hl                  /* 0xEB */
        .long   _z80_call_pe                   /* 0xEC */
        .long   _z80_pfx_ed                    /* 0xED */
        .long   _z80_xor_imm                   /* 0xEE */
        .long   _z80_rst28                     /* 0xEF */
        .long   _z80_ret_p                     /* 0xF0 */
        .long   _z80_pop_af                    /* 0xF1 */
        .long   _z80_jp_p                      /* 0xF2 */
        .long   _z80_di                        /* 0xF3 */
        .long   _z80_call_p                    /* 0xF4 */
        .long   _z80_push_af                   /* 0xF5 */
        .long   _z80_or_imm                    /* 0xF6 */
        .long   _z80_rst30                     /* 0xF7 */
        .long   _z80_ret_m                     /* 0xF8 */
        .long   _z80_ld_sp_hl                  /* 0xF9 */
        .long   _z80_jp_m                      /* 0xFA */
        .long   _z80_ei                        /* 0xFB */
        .long   _z80_call_m                    /* 0xFC */
        .long   _z80_pfx_fd                    /* 0xFD */
        .long   _z80_cp_imm                    /* 0xFE */
        .long   _z80_rst38                     /* 0xFF */
/* end of handler table — 256 × 4 bytes = 1024 bytes */


