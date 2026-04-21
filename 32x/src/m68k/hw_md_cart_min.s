| ======================================================================
| Genesis 68K code for 32X cart: boot text + handshake + joypad relay
|
| This binary is embedded by crt0_cart.s at ROM offset 0x800.
| Fixed trampolines are required at these offsets within this blob:
|   0x000: reset/hot-start entry
|   0x040: generic exception
|   0x080: HBlank
|   0x0C0: VBlank
|   0x100: Level 2 EXT
|
| Behavior:
|   - Display "Init 32X... " on Genesis VDP
|   - Wait for SH-2 M_OK / S_OK tokens in MARS COMM0/COMM4
|   - Display "OK!" and "Loading..."
|   - Clear both COMM pairs to release SH-2s
|   - On each VBlank: read Genesis pad 1, write buttons to COMM8
| ======================================================================

        .equ    MARS_COMM0, 0xA15120
        .equ    MARS_COMM4, 0xA15124
        .equ    MARS_COMM6, 0xA15126
        .equ    MARS_COMM8, 0xA15128
        .equ    MARS_COMM14, 0xA1512E

        .equ    PSG_PORT,   0xC00011

        .equ    PAD1_DATA,  0xA10003
        .equ    PAD1_CTRL,  0xA10009
        .equ    PAD1_TH,    0x40

        .equ    VDP_DATA,   0xC00000
        .equ    VDP_CTRL,   0xC00004

| VDP register set command: 0x8RVV where R=reg, VV=value
        .equ    VRAM_WRITE, 0x40000000
        .equ    CRAM_WRITE, 0xC0000000

| Nametable A is at VRAM 0xC000 (set by bootstrap reg $02 = 0x30)
        .equ    NTA_VRAM,   0xC000

| Font tiles start at tile index 0 in VRAM (addr 0x0000)
        .equ    FONT_VRAM,  0x0000
        .equ    FONT_FIRST_CHAR, 0x20

        .text
        .align  2

| --- Offset 0x000: Reset / Hot Start ---
        jmp     _md_entry

| --- Offset 0x040: Generic Exception ---
        .org    0x40
        rte

| --- Offset 0x080: HBlank ---
        .org    0x80
        rte

| --- Offset 0x0C0: VBlank ---
        .org    0xC0
        jmp     _md_vblank

| --- Offset 0x100: Level 2 EXT ---
        .org    0x100
        rte

| ======================================================================
| VBlank handler — read 3-button Genesis pad → COMM8
| ======================================================================

_md_vblank:
        movem.l d0-d2/a0,-(sp)

        lea     PAD1_DATA,a0

        | TH = 1: read Up, Down, Left, Right, B, C
        move.b  #PAD1_TH,(6,a0)         | write PAD1_CTRL = 0x40
        move.b  #PAD1_TH,(a0)           | TH = 1
        nop
        nop
        move.b  (a0),d0                 | d0 = xxCBRLDU (active-low)

        | TH = 0: read Up, Down, A, Start
        move.b  #0,(a0)                 | TH = 0
        nop
        nop
        move.b  (a0),d1                 | d1 = xxSAxxDU (active-low)

        | Restore TH = 1
        move.b  #PAD1_TH,(a0)

        | Build active-high button word in d2
        moveq   #0,d2

        not.b   d0
        btst    #0,d0
        beq.b   .no_up
        bset    #0,d2
.no_up:
        btst    #1,d0
        beq.b   .no_dn
        bset    #1,d2
.no_dn:
        btst    #2,d0
        beq.b   .no_lt
        bset    #2,d2
.no_lt:
        btst    #3,d0
        beq.b   .no_rt
        bset    #3,d2
.no_rt:
        btst    #4,d0
        beq.b   .no_b
        bset    #4,d2
.no_b:
        btst    #5,d0
        beq.b   .no_c
        bset    #5,d2
.no_c:

        not.b   d1
        btst    #4,d1
        beq.b   .no_a
        bset    #6,d2
.no_a:
        btst    #5,d1
        beq.b   .no_st
        bset    #7,d2
.no_st:

        move.w  d2,MARS_COMM8

        movem.l (sp)+,d0-d2/a0
        rte

| ======================================================================
| Main entry — boot text, handshake, then idle loop
| ======================================================================

        .global _md_entry
_md_entry:
        bcs.w   _md_error

        move.w  #0x2700,sr              | disable interrupts
        movea.l #0xFFFFFE,sp

        | Set up controller 1 port
        move.b  #PAD1_TH,PAD1_CTRL

        | --- Set up VDP for text display ---
        | The bootstrap at 0x3F0 already initialized VDP registers.
        | We need to:
        |   1. Confirm display is enabled with the right settings
        |   2. Set a text-friendly palette in CRAM
        |   3. Load font tiles into VRAM
        |   4. Write text to nametable A

        | Wait for VDP ready
        lea     VDP_CTRL,a5
        lea     VDP_DATA,a6

        | Set VDP registers for text mode:
        | Reg $00 = 0x04: H-int disabled, standard mode
        | Reg $01 = 0x64: display enabled, V-int enabled, DMA disabled, 224 lines, MD mode
        | Reg $02 = 0x30: Scroll A nametable at VRAM 0xC000
        | Reg $05 = 0x70: Sprite table at VRAM 0xE000
        | Reg $07 = 0x00: background color = palette 0, color 0
        | Reg $0A = 0xFF: H-int every 256 lines (effectively disabled)
        | Reg $0C = 0x00: 32-cell wide (256px), no interlace
        | Reg $0F = 0x02: auto-increment = 2
        | Reg $10 = 0x01: scroll size = 64x32

        move.w  #0x8004,(a5)
        move.w  #0x8164,(a5)
        move.w  #0x8230,(a5)
        move.w  #0x8570,(a5)
        move.w  #0x8700,(a5)
        move.w  #0x8AFF,(a5)
        move.w  #0x8C00,(a5)
        move.w  #0x8F02,(a5)
        move.w  #0x9001,(a5)

        | --- Set palette: color 0 = black, color 15 = white ---
        | Font tiles use nibble 0xF for lit pixels → palette 0, color 15
        | CRAM write to address 0x0000 (palette 0, color 0)
        move.l  #CRAM_WRITE,(a5)
        move.w  #0x0000,(a6)            | color 0 = black (BGR)
        | CRAM write to address 0x001E (palette 0, color 15)
        move.l  #0xC01E0000,(a5)
        move.w  #0x0EEE,(a6)            | color 15 = white

        | --- Load font tiles into VRAM at tile 0 ---
        | Set VRAM write address to 0x0000
        move.l  #VRAM_WRITE,(a5)

        | Copy font data (starts at 0x20, 107 chars × 8 longs = 3424 bytes)
        lea     font_data(pc),a0
        move.w  #(107*8)-1,d0           | 856 longs - 1
.load_font:
        move.l  (a0)+,(a6)
        dbra    d0,.load_font

        | --- Print "Init 32X... " at row 12, col 13 ---
        | Nametable address = NTA_VRAM + (row * 64 + col) * 2
        | Row 12, col 13 = 0xC000 + (12*64 + 13)*2 = 0xC000 + 0x61A = 0xC61A
        bsr     .vdp_vsync
        move.l  #0x461A0003,(a5)
        lea     str_init(pc),a0
        bsr     .print_string

        | --- Wait for Master SH-2 handshake ---
        | Poll COMM0 for 'M_' (0x4D5F) — upper half of M_OK token
.wait_m_ok:
        move.w  MARS_COMM0,d0
        cmpi.w  #0x4D5F,d0              | 'M_'
        bne.b   .wait_m_ok

        | --- Wait for Slave SH-2 handshake ---
        | Poll COMM4 for 'S_' (0x535F) — upper half of S_OK token
.wait_s_ok:
        move.w  MARS_COMM4,d0
        cmpi.w  #0x535F,d0              | 'S_'
        bne.b   .wait_s_ok

        | --- Print "OK!" after init message ---
        | Continue on same line (VDP auto-increments)
        lea     str_ok(pc),a0
        bsr     .print_string

        | --- Print "Loading..." on the next line (row 14, col 15) ---
        | 0xC000 + (14*64 + 15)*2 = 0xC000 + 0x071E = 0xC71E
        bsr     .vdp_vsync
        move.l  #0x471E0003,(a5)
        lea     str_loading(pc),a0
        bsr     .print_string

        | --- Release SH-2s (use 16-bit writes for COMM register compat) ---
        moveq   #0,d0
        move.w  d0,MARS_COMM0           | clear COMM0
        move.w  d0,MARS_COMM0+2         | clear COMM2
        move.w  d0,MARS_COMM4           | clear COMM4
        move.w  d0,MARS_COMM4+2         | clear COMM6

        | Clear boot text so Genesis layer is clean once emulation starts
        bsr     .vdp_vsync
        move.l  #0x461A0003,(a5)        | row 12, col 13
        lea     str_clear_init(pc),a0
        bsr     .print_string

        bsr     .vdp_vsync
        move.l  #0x471E0003,(a5)        | row 14, col 15
        lea     str_clear_loading(pc),a0
        bsr     .print_string

        | Enable VBlank interrupts
        move.w  #0x2000,sr

| --- Main idle loop: relay PSG writes + slave CMD wakeup ---
| PSG protocol: SH-2 writes (0x0100 | psg_byte) to COMM4
| (primary) or COMM14 (overflow).  M68K drains both.
|
| CMD relay: SH-2 master writes COMM6 non-zero to request
| slave CMD interrupt. M68K writes INTS bit at 0xA15102, clears COMM6.
.idle:
        move.w  MARS_COMM4,d0
        bne.b   .psg_write4             | PSG data in COMM4
        move.w  MARS_COMM14,d0
        bne.b   .psg_write14            | PSG data in COMM14
        move.w  MARS_COMM6,d0
        bne.b   .trigger_slave_cmd      | slave wakeup requested
        bra.b   .idle
.psg_write4:
        move.b  d0,PSG_PORT             | write low byte to Genesis SN76489
        clr.w   MARS_COMM4              | acknowledge — slot free
        bra.b   .idle
.psg_write14:
        move.b  d0,PSG_PORT             | write low byte to Genesis SN76489
        clr.w   MARS_COMM14             | acknowledge — overflow slot free
        bra.b   .idle
.trigger_slave_cmd:
        move.w  #0x0002,0xA15102        | INTS bit → trigger slave CMD interrupt
        clr.w   MARS_COMM6              | acknowledge — request consumed
        bra.b   .idle

_md_error:
        | On error, try to show "ERR!" on screen
        lea     VDP_CTRL,a5
        lea     VDP_DATA,a6
        move.w  #0x8F02,(a5)            | auto-inc = 2
        move.l  #0x461A0003,(a5)
        lea     str_err(pc),a0
        bsr     .print_string
.error_halt:
        stop    #0x2700
        bra.b   .error_halt

| ======================================================================
| Subroutine: print 4-digit hex value in d3
|   d3 = 16-bit value to print
|   a5 = VDP_CTRL (write address already set and auto-incrementing)
|   a6 = VDP_DATA
| ======================================================================
.print_hex4:
        movem.l d0-d4,-(sp)
        moveq   #3,d4                   | 4 digits
.ph_loop:
        move.w  d3,d0
        rol.w   #4,d3                   | rotate next nibble into low 4 bits
        move.w  d3,d0
        andi.w  #0x000F,d0
        cmpi.b  #10,d0
        blt.b   .ph_digit
        addi.b  #7,d0                   | A-F offset: 'A'-'0'-10 = 7
.ph_digit:
        addi.b  #0x10,d0                | '0' tile = ASCII 0x30-0x20 = 0x10
        move.w  d0,(a6)
        dbra    d4,.ph_loop
        movem.l (sp)+,d0-d4
        rts

| ======================================================================
| Subroutine: print null-terminated ASCII string
|   a0 = pointer to string
|   a5 = VDP_CTRL (already set with write address)
|   a6 = VDP_DATA
| ======================================================================
.print_string:
        moveq   #0,d0
.ps_loop:
        move.b  (a0)+,d0
        beq.b   .ps_done
        subi.b  #FONT_FIRST_CHAR,d0     | tile index = ASCII - 0x20
        move.w  d0,(a6)                 | write tile index to nametable
        bra.b   .ps_loop
.ps_done:
        rts

| ======================================================================
| Subroutine: wait for vertical blank
|   a5 = VDP_CTRL
| ======================================================================
.vdp_vsync:
        move.w  (a5),d0
        btst    #3,d0                   | bit 3 = vblank flag
        beq.b   .vdp_vsync
        rts

| ======================================================================
| String data
| ======================================================================

str_init:
        .asciz  "GG Player... "
str_ok:
        .asciz  "OK!"
str_loading:
        .asciz  "Loading..."
str_clear_init:
        .asciz  "                    "
str_clear_loading:
        .asciz  "            "
str_err:
        .asciz  "BOOT ERR!"
str_sh2:
        .asciz  "SH2:"
str_t:
        .asciz  " T:"
str_fb:
        .asciz  "FB:"
str_d:
        .asciz  " D:"

        .align  2

| ======================================================================
| Font tile data — 8x8 4bpp Genesis tile format
| 107 characters starting from ASCII 0x20 (space)
| Included from font.s via .include
| ======================================================================

        .include "font.s"
