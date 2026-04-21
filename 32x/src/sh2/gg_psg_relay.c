/*
 * gg_psg_relay.c — Game Gear PSG relay via COMM register mailbox
 *
 * Fire-and-forget double-buffered PSG writes.
 * Master writes to COMM4 (primary) or COMM14 (overflow) without
 * blocking.  M68K drains both in its idle loop.  If both are full
 * (extremely rare: requires 2 back-to-back PSG writes faster than
 * the 68K can drain), the byte is dropped — a single missed PSG
 * latch causes at most a brief audio glitch.
 *
 * Previous implementation spin-waited on COMM4 == 0, costing
 * ~115-300 SH-2 cycles per PSG write.  This is now zero-wait.
 */

#include "gg_emu.h"
#include "32x.h"

/* Kept in .sdram_code for lower access latency from SH-2 hot path. */
__attribute__((section(".sdram_code")))
void gg_psg_relay_write(uint8_t val)
{
    uint16_t psg_word = 0x0100 | val;

    /* Try primary slot first, overflow second, drop if both full. */
    if (MARS_SYS_COMM4 == 0) {
        MARS_SYS_COMM4 = psg_word;
    } else if (MARS_SYS_COMM14 == 0) {
        MARS_SYS_COMM14 = psg_word;
    }
    /* else: both full — drop byte (inaudible at 3-5 writes/frame) */
}
