.PHONY: all cart clean

PERF_DEBUG ?= 1

# Cart-only build: produces a .32x ROM
all: cart

# Cartridge-boot ROM: SH-2 code in ROM, 68K code embedded
cart:
	$(MAKE) -C 32x cart PERF_DEBUG=$(PERF_DEBUG)
	@mkdir -p build
	cp 32x/build/ggplayer.32x build/ggplayer.32x
	@echo "=== Output: build/ggplayer.32x ==="

clean:
	$(MAKE) -C 32x clean
	rm -rf build

