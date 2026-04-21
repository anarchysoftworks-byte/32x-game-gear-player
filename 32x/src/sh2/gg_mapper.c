/*
 * gg_mapper.c — cartridge mapper
 *
 * Game Gear-only build supports Sega standard banking and a no-mapper
 * fallback for small ROMs.
 */

#include "gg_emu.h"

/* ------------------------------------------------------------------ */
/* Standard GG mapper (0xFFFC-0xFFFF)                                 */
/*                                                                     */
/* mapper_regs[0] = 0xFFFC SRAM control register                       */
/* mapper_regs[1] = 0xFFFD bank 0 (0x0000-0x3FFF)                     */
/* mapper_regs[2] = 0xFFFE bank 1 (0x4000-0x7FFF)                     */
/* mapper_regs[3] = 0xFFFF bank 2 (0x8000-0xBFFF)                     */
/* ------------------------------------------------------------------ */

static void mapper_write_standard(uint16_t addr, uint8_t val)
{
    switch (addr) {
    case 0xFFFC:
        /* SRAM mapping register */
        g_machine.mapper_regs[0] = val;

        /* Bits 3-2: SRAM bank select (bit 4 is the "has SRAM" flag,
         * bit 3 = SRAM enabled for slot 2).
         * For simplicity, we support mapping SRAM into 0x8000-0xBFFF
         * when bit 3 is set, and ROM otherwise.                       */
        if (val & 0x08) {
            /* Map SRAM page into slot 2 (pages 4-5) */
            int sram_bank = (val >> 2) & 1;
            gg_map_8k_sram(4, sram_bank * 2);
            gg_map_8k_sram(5, sram_bank * 2 + 1);
        } else {
            /* Restore ROM mapping for slot 2 */
            gg_map_16k_rom(4, g_machine.mapper_regs[3]);
        }
        break;

    case 0xFFFD:
        /* Bank 0: maps 16 KB ROM bank to 0x0000-0x3FFF */
        val &= (uint8_t)tgg.Pages_Mask_16k;
        if (g_machine.mapper_regs[1] != val) {
            g_machine.mapper_regs[1] = val;
            gg_map_16k_rom(0, val);
        }
        break;

    case 0xFFFE:
        /* Bank 1: maps 16 KB ROM bank to 0x4000-0x7FFF */
        val &= (uint8_t)tgg.Pages_Mask_16k;
        if (g_machine.mapper_regs[2] != val) {
            g_machine.mapper_regs[2] = val;
            gg_map_16k_rom(2, val);
        }
        break;

    case 0xFFFF:
        /* Bank 2: maps 16 KB ROM bank to 0x8000-0xBFFF */
        val &= (uint8_t)tgg.Pages_Mask_16k;
        if (g_machine.mapper_regs[3] != val) {
            g_machine.mapper_regs[3] = val;
            /* Only remap if SRAM is not active in slot 2 */
            if (!(g_machine.mapper_regs[0] & 0x08))
                gg_map_16k_rom(4, val);
        }
        break;
    }
}

/* ------------------------------------------------------------------ */
/* Mapper write — dispatches to the active mapper handler              */
/* ------------------------------------------------------------------ */

/* Moved to ROM (.text) — SDRAM cache conflict with Z80 interpreter */
void gg_mapper_write(uint16_t addr, uint8_t val)
{
    switch (g_machine.mapper) {
    case MAPPER_Standard:
        mapper_write_standard(addr, val);
        break;
    case MAPPER_NoMapper:
        /* No banking — writes do nothing */
        break;
    }
}

/* ------------------------------------------------------------------ */
/* Mapper init                                                         */
/*                                                                     */
/* Called after gg_mem_init().  Runs autodetect if no mapper was       */
/* explicitly set, then configures initial bank mapping.               */
/* ------------------------------------------------------------------ */

void gg_mapper_init(const uint8_t *rom_base, uint32_t rom_size)
{
    (void)rom_base;

    if (rom_size <= 0xC000) {
        /* ≤ 48 KB: no mapper needed */
        g_machine.mapper = MAPPER_NoMapper;
    } else {
        g_machine.mapper = MAPPER_Standard;
    }

    /* Set up initial bank mapping based on mapper type */
    switch (g_machine.mapper) {
    case MAPPER_Standard:
        g_machine.mapper_regs[0] = 0x00;   /* SRAM control */
        g_machine.mapper_regs[1] = 0x00;   /* bank 0 */
        g_machine.mapper_regs[2] = 0x01;   /* bank 1 */
        g_machine.mapper_regs[3] = 0x02;   /* bank 2 */
        gg_map_16k_rom(0, 0);
        gg_map_16k_rom(2, 1);
        gg_map_16k_rom(4, 2);
        break;

    case MAPPER_NoMapper:
        /* Map the full ROM linearly, up to 48 KB */
        gg_map_16k_rom(0, 0);
        if (rom_size > 0x4000)
            gg_map_16k_rom(2, 1);
        if (rom_size > 0x8000)
            gg_map_16k_rom(4, 2);
        break;
    }
}
