SH2_CC      = sh-elf-gcc
SH2_AS      = sh-elf-as
SH2_OBJCOPY = sh-elf-objcopy

M68K_GAS     = m68k-elf-as
M68K_LD      = m68k-elf-ld
M68K_OBJCOPY = m68k-elf-objcopy

PERF_DEBUG  ?= 1

# Base flags shared by all SH-2 modules
SH2_CFLAGS_BASE = -m2 -mb -Wall -g -c -fomit-frame-pointer -fno-tree-loop-distribute-patterns -fno-strict-aliasing -ffunction-sections -fdata-sections -D__32X__ -DPERF_DEBUG=$(PERF_DEBUG) -Iinclude/sh2 -I../shared

# Hot path (Z80, renderer): -O3 + unrolling for maximum throughput
SH2_CFLAGS_HOT  = $(SH2_CFLAGS_BASE) -O3 -funroll-loops -finline-functions

# Default: -O2 for correctness-sensitive code
SH2_CFLAGS      = $(SH2_CFLAGS_BASE) -O2

# Cold path (mapper, init): -Os to minimize cache footprint
SH2_CFLAGS_COLD = $(SH2_CFLAGS_BASE) -Os

M68K_GAS_FLAGS = -m68000 --register-prefix-optional

CART_SH2_OBJS = \
    build/sh2_crt0_cart.o \
    build/sh2_main.o \
    build/sh2_gg_mem.o \
    build/sh2_gg_mapper.o \
    build/sh2_gg_io.o \
    build/sh2_gg_vdp.o \
    build/sh2_gg_render.o \
    build/sh2_gg_psg.o \
    build/sh2_gg_psg_relay.o \
    build/sh2_z80_asm.o \
    build/sh2_z80_dispatch.o \
    build/sh2_render_asm.o

build:
	mkdir -p build

all: cart

cart: build/ggplayer.32x

build/sh2_crt0_cart.o: src/sh2/crt0_cart.s build/m68k.bin | build
	$(SH2_AS) --big $< -o $@

build/sh2_main.o: src/sh2/main.c | build
	$(SH2_CC) $(SH2_CFLAGS_HOT) -c $< -o $@

build/sh2_gg_mem.o: src/sh2/gg_mem.c | build
	$(SH2_CC) $(SH2_CFLAGS_HOT) -c $< -o $@

build/sh2_gg_mapper.o: src/sh2/gg_mapper.c | build
	$(SH2_CC) $(SH2_CFLAGS_COLD) -c $< -o $@

build/sh2_gg_io.o: src/sh2/gg_io.c | build
	$(SH2_CC) $(SH2_CFLAGS_HOT) -c $< -o $@

build/sh2_z80_asm.o: src/sh2/z80_asm.S | build
	$(SH2_CC) -m2 -mb -DPERF_DEBUG=$(PERF_DEBUG) -c $< -o $@

build/sh2_z80_dispatch.o: src/sh2/z80_dispatch.c | build
	$(SH2_CC) $(SH2_CFLAGS_HOT) -c $< -o $@

build/sh2_gg_vdp.o: src/sh2/gg_vdp.c | build
	$(SH2_CC) $(SH2_CFLAGS_HOT) -c $< -o $@

build/sh2_gg_render.o: src/sh2/gg_render.c | build
	$(SH2_CC) $(SH2_CFLAGS_HOT) -c $< -o $@

build/sh2_render_asm.o: src/sh2/render_asm.S | build
	$(SH2_CC) -m2 -mb -c $< -o $@

build/sh2_gg_psg.o: src/sh2/gg_psg.c | build
	$(SH2_CC) $(SH2_CFLAGS_HOT) -c $< -o $@

build/sh2_gg_psg_relay.o: src/sh2/gg_psg_relay.c | build
	$(SH2_CC) $(SH2_CFLAGS) -c $< -o $@

build/sh2_cart.elf: $(CART_SH2_OBJS) | build
	$(SH2_CC) -m2 -mb -T linker_mars.ld -Wl,-Map=build/sh2_cart.map -Wl,--gc-sections -nostdlib $(CART_SH2_OBJS) -lgcc -o $@

build/ggplayer.32x: build/sh2_cart.elf | build
	$(SH2_OBJCOPY) -O binary $< $@
	@SIZE=$$(stat -c%s $@); \
	 ALIGNED=$$(( (SIZE + 0xFFFF) & ~0xFFFF )); \
	 if [ $$ALIGNED -lt 131072 ]; then ALIGNED=131072; fi; \
	 truncate -s $$ALIGNED $@
	python3 ../scripts/romheaderfix.py $@
	@echo "Built ggplayer.32x: $$(stat -c%s $@) bytes"

build/m68k_cart.o: src/m68k/hw_md_cart_min.s | build
	$(M68K_GAS) $(M68K_GAS_FLAGS) -I src/m68k $< -o $@

build/m68k_cart.elf: build/m68k_cart.o | build
	$(M68K_LD) -T linker_m68k_cart.ld -o $@ $<

build/m68k.bin: build/m68k_cart.elf | build
	$(M68K_OBJCOPY) -O binary $< $@
	@echo "Built m68k.bin: $$(stat -c%s $@) bytes"

clean:
	rm -rf build/*.o build/*.elf build/*.bin build/*.map build/*.32x ../build/ggplayer.32x ggplayer.32x

.PHONY: all cart clean
