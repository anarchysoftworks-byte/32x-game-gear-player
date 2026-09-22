/*
 * gg_vdp.c — Game Gear VDP register writes, address latch, palette
 *
 * Ported from MEKA vdp.cpp (Tms_VDP_Out, Tms_VDP_Out_Data,
 * Tms_VDP_Out_Address, Tms_VDP_In_Data, Tms_VDP_In_Status,
 * Tms_VDP_Palette_Write).
 *
 * Stripped: Game Gear palette, TMS9918 modes, debugger hooks,
 * VDP model differentiation, Allegro GUI.
 */

#include "gg_emu.h"
#include "gg_vdp.h"
#include "32x.h"

/* ------------------------------------------------------------------ */
/* GG 12-bit color → 32X 15-bit direct color                          */
/*                                                                     */
/* GG CRAM: 2 bytes per color, 32 colors in 64 bytes                  */
/*   Byte 0: ggggrrrr (4 bits green, 4 bits red)                      */
/*   Byte 1: 0000bbbb (4 bits blue)                                   */
/* 32X pixel: 0BBBBBGGGGGRRRRR (5 bits per channel, 0-31)             */
/* Scale: 4-bit (0-15) → 5-bit (0-31) via (v<<1)|(v>>3)              */
/* ------------------------------------------------------------------ */

static const uint16_t gg_4bit_to_5bit[16] = {
     0,  2,  4,  6,  8, 10, 12, 14,
    17, 19, 21, 23, 25, 27, 29, 31
};

__attribute__((section(".sdram_code")))
static uint16_t gg_color_to_32x(uint8_t lo, uint8_t hi)
{
    uint16_t r = gg_4bit_to_5bit[lo & 0x0F];
    uint16_t g = gg_4bit_to_5bit[(lo >> 4) & 0x0F];
    uint16_t b = gg_4bit_to_5bit[hi & 0x0F];
    return 0x8000 | r | (g << 5) | (b << 10);
}

/* ------------------------------------------------------------------ */
/* VDP init                                                            */
/* ------------------------------------------------------------------ */

void gg_vdp_init(void)
{
    int i;

    /* Clear VDP state */
    for (i = 0; i < 16; i++)
        gg.VDP[i] = 0;
    gg.VDP_Status      = 0;
    gg.VDP_Address     = 0;
    gg.VDP_Access_Mode = 0;
    gg.VDP_Access_First= 0;
    gg.VDP_ReadLatch   = 0;
    gg.VDP_Pal         = 0;
    gg.Lines_Left      = 0;
    gg.Pending_HBlank  = 0;
    gg.Pending_NMI     = 0;

    /* Default palette: all black → 32X opaque black */
    for (i = 0; i < GG_CRAM_SIZE; i++)
        gg_cram[i] = 0;
    for (i = 0; i < 32; i++)
        gg_palette_32x[i] = 0x8000;   /* opaque black (bit 15 set) */

    /* Compute VDP derived addresses (will be recomputed on reg writes) */
    gg_vdp_update_addresses();
}

/* ------------------------------------------------------------------ */
/* Recompute derived VDP pointers from register state                  */
/* ------------------------------------------------------------------ */

/* Kept in .sdram_code for lower access latency from SH-2 hot path.
 * Called via +0x20000000 alias from z80_asm.S to avoid cache churn. */
__attribute__((section(".sdram_code")))
void gg_vdp_update_addresses(void)
{
    /* Name table: Register 2, bits 3-1, × 0x0800 */
    if (Wide_Screen_28)
        g_machine.VDP.name_table_address = gg_vram + 0x700 + ((gg.VDP[2] & 0x0C) << 10);
    else
        g_machine.VDP.name_table_address = gg_vram + ((gg.VDP[2] & 0x0E) << 10);

    /* Sprite attribute table: Register 5, bits 6-1, × 0x80 */
    g_machine.VDP.sprite_attribute_table = gg_vram + (((int)gg.VDP[5] << 7) & 0x3F00);

    /* Sprite pattern generator: Register 6, bit 2 → 0x0000 or 0x2000 */
    g_machine.VDP.sprite_pattern_gen_index = (gg.VDP[6] & 4) ? 256 : 0;
    g_machine.VDP.sprite_pattern_gen_address = gg_vram + ((gg.VDP[6] & 4) ? 0x2000 : 0x0000);

    /* Sprite left-8 shift */
    g_machine.VDP.sprite_shift_x = (Sprites_Left_8) ? 8 : 0;
}

/* ------------------------------------------------------------------ */
/* VDP register write                                                  */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
void gg_vdp_reg_write(uint8_t reg, uint8_t value)
{
    switch (reg)
    {
    case 0:
        /* H-blank IRQ enable toggle while IRQ pending */
        if (gg.Pending_HBlank && ((gg.VDP[0] & 0x10) != (value & 0x10)))
        {
            if (!(value & 0x10))
                z80.IRequest = Z80_INT_NONE;
            else
                z80.IRequest = Z80_INT_IRQ;
        }
        gg.VDP[0] = value;
        g_machine.VDP.sprite_shift_x = (value & VDP_REG0_SPRITES_SHIFT) ? 8 : 0;
        break;

    case 1:
        gg.VDP[1] = value;
        /* Name table address depends on 224-line mode */
        if (Wide_Screen_28)
            g_machine.VDP.name_table_address = gg_vram + 0x700 + ((gg.VDP[2] & 0x0C) << 10);
        else
            g_machine.VDP.name_table_address = gg_vram + ((gg.VDP[2] & 0x0E) << 10);
        break;

    case 2:
        gg.VDP[2] = value;
        if (Wide_Screen_28)
            g_machine.VDP.name_table_address = gg_vram + 0x700 + ((value & 0x0C) << 10);
        else
            g_machine.VDP.name_table_address = gg_vram + ((value & 0x0E) << 10);
        break;

    case 5:
        gg.VDP[5] = value;
        g_machine.VDP.sprite_attribute_table = gg_vram + (((int)value << 7) & 0x3F00);
        break;

    case 6:
        gg.VDP[6] = value;
        g_machine.VDP.sprite_pattern_gen_index = (value & 4) ? 256 : 0;
        g_machine.VDP.sprite_pattern_gen_address = gg_vram + ((value & 4) ? 0x2000 : 0x0000);
        break;

    case 8:
        /* H-scroll latch (latched at beginning of active display) */
        g_machine.VDP.scroll_x_latched = value;
        gg.VDP[8] = value;
        break;

    default:
        if (reg < 16)
            gg.VDP[reg] = value;
        break;
    }
}

/* ------------------------------------------------------------------ */
/* VDP palette / CRAM write                                            */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
static void gg_vdp_palette_write(uint8_t addr, uint8_t value)
{
    /* Flag palette change for dirty-line tracking */
    gg_cram_dirty();

    /* GG 12-bit palette: 2 bytes per color, 32 colors in 64 bytes.
     * Store every byte; update the 32X palette only on the second
     * (odd) byte write, when the full 12-bit color is available. */
    addr &= 0x3F;
    gg_cram[addr] = value;
    if (addr & 0x01)
    {
        int color_idx = addr >> 1;
        gg_palette_32x[color_idx] = gg_color_to_32x(
            gg_cram[addr & 0xFE], value);
    }
}

/* ------------------------------------------------------------------ */
/* VDP data port write (active on even ports 0x80-0xBE)                */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
void gg_vdp_data_write(uint8_t value)
{
    gg.VDP_Access_Mode = 0;  /* reset latch */

    if (!gg.VDP_Pal)
    {
        /* VRAM write */
        gg_vram[gg.VDP_Address] = value;
        gg_tile_dirty(gg.VDP_Address);
        gg.VDP_ReadLatch = value;
        gg.VDP_Address = (gg.VDP_Address + 1) & 0x3FFF;
    }
    else
    {
        /* CRAM write */
        gg_vdp_palette_write(gg.VDP_Address & 0x3F, value);
        gg.VDP_ReadLatch = value;
        gg.VDP_Address++;
    }
}

/* ------------------------------------------------------------------ */
/* VDP address/control port write (active on odd ports 0x81-0xBF)      */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
void gg_vdp_addr_write(uint8_t value)
{
    if (gg.VDP_Access_Mode == 0)
    {
        /* First byte: latch */
        gg.VDP_Access_First = value;
        gg.VDP_Access_Mode  = 1;
        /* Low byte of address is updated immediately (Cosmic Spacehead fix) */
        gg.VDP_Address = (gg.VDP_Address & 0xFF00) | value;
        return;
    }

    /* Second byte */
    gg.VDP_Access_Mode = 0;

    if ((value & 0xC0) == 0xC0)
    {
        /* CRAM write mode */
        gg.VDP_Pal = 1;
        gg.VDP_Address = (((uint16_t)value << 8) | gg.VDP_Access_First) & 0x3FFF;
    }
    else
    {
        if (value & 0x80)
        {
            /* VDP register write */
            gg_vdp_reg_write(value & 0x0F, gg.VDP_Access_First);
        }
        gg.VDP_Pal = 0;
        gg.VDP_Address = (((uint16_t)value << 8) | gg.VDP_Access_First) & 0x3FFF;

        if ((value & 0xC0) == 0)
        {
            /* Read mode: pre-fetch byte into latch */
            gg.VDP_ReadLatch = gg_vram[gg.VDP_Address];
            gg.VDP_Address = (gg.VDP_Address + 1) & 0x3FFF;
        }
    }
}

/* ------------------------------------------------------------------ */
/* VDP data port read (active on even ports 0x80-0xBE)                 */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
uint8_t gg_vdp_data_read(void)
{
    uint8_t b;

    gg.VDP_Access_Mode = 0;
    b = gg.VDP_ReadLatch;
    gg.VDP_ReadLatch = gg_vram[gg.VDP_Address];
    gg.VDP_Address = (gg.VDP_Address + 1) & 0x3FFF;
    return b;
}

/* ------------------------------------------------------------------ */
/* VDP status port read (active on odd ports 0x81-0xBF)                */
/* ------------------------------------------------------------------ */

__attribute__((section(".sdram_code")))
uint8_t gg_vdp_status_read(void)
{
    uint8_t b;

    /* Read VDP_Status through uncached SDRAM so we see any sprite
     * collision/overflow flags set by the slave SH-2's renderer. */
    b = *(volatile uint8_t *)SH2_UNCACHED(&gg.VDP_Status);
    gg.VDP_Status = b & 0x1F;       /* Clear VBlank, 9th sprite, collision */
    /* Write cleared value back through uncached path too. The cached write
     * above is required: main.c and the VDP_STATUS_SET macro OR new flags
     * into gg.VDP_Status via the CACHED view, so it must stay coherent with
     * the cleared byte here (an uncached-only write would leave a stale cache
     * line and re-set bits we just cleared). */
    *(volatile uint8_t *)SH2_UNCACHED(&gg.VDP_Status) = gg.VDP_Status;
    gg.VDP_Access_Mode = 0;
    gg.Pending_HBlank = 0;
    gg.Pending_NMI = 0;
    z80.IRequest = Z80_INT_NONE;      /* De-assert IRQ line */
    return b | 0x1F;                  /* Low 5 bits always set on SMS2 VDP */
}
