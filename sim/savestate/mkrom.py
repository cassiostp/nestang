#!/usr/bin/env python3
"""Test ROMs for the save-state A/B determinism sim.

Two cartridges whose whole machine state evolves every frame, so a state
restored even slightly wrong diverges audibly/visibly within a few frames:

  m1: MMC1, 128 KB PRG, CHR RAM, battery WRAM (like Zelda). Serial PRG
      bank switches, CHR-RAM writes during vblank, WRAM/CPU-RAM counters,
      OAM DMA, scrolling, square+triangle+noise APU activity.
  m3: MMC3, 256 KB PRG, 128 KB CHR ROM, battery WRAM (like SMB3). PRG/CHR
      bank switches every frame, scanline IRQ counter, banked-ROM data
      reads feeding the scroll, DMC looping sample (periodic DMA steals),
      OAM DMA, APU activity.

Both read joypad bit 0 per frame and mix it into the scroll, so the C++
driver's input script is part of the trajectory.

usage: mkrom.py <outdir>   (writes m1.hex/.nes and m3.hex/.nes)
"""
import os
import sys


class Asm:
    def __init__(self, org):
        self.org = org
        self.code = bytearray()
        self.labels = {}
        self.fix = []

    def pc(self):
        return self.org + len(self.code)

    def label(self, name):
        self.labels[name] = self.pc()

    def b(self, *bytes_):
        self.code.extend(bytes_)

    def abs(self, op, addr):
        self.b(op, addr & 0xFF, addr >> 8)

    def zp(self, op, addr):
        self.b(op, addr & 0xFF)

    def branch(self, op, name):
        self.b(op, 0)
        self.fix.append((len(self.code) - 1, name, 'rel'))

    def jmp(self, name):
        self.b(0x4C, 0, 0)
        self.fix.append((len(self.code) - 2, name, 'abs'))

    def jsr(self, name):
        self.b(0x20, 0, 0)
        self.fix.append((len(self.code) - 2, name, 'abs'))

    def done(self):
        for at, name, kind in self.fix:
            tgt = self.labels[name]
            if kind == 'rel':
                off = tgt - (self.org + at + 1)
                assert -128 <= off <= 127, (name, off)
                self.code[at] = off & 0xFF
            else:
                self.code[at] = tgt & 0xFF
                self.code[at + 1] = tgt >> 8
        return bytes(self.code)


def common_init(a):
    """SEI/stack, two vblank waits, palette + nametable fill, OAM page."""
    a.b(0x78)                       # SEI
    a.b(0xD8)                       # CLD
    a.b(0xA2, 0xFF)                 # LDX #$FF
    a.b(0x9A)                       # TXS
    a.b(0xA9, 0x00)
    a.abs(0x8D, 0x2000)             # PPUCTRL = 0
    a.abs(0x8D, 0x2001)             # PPUMASK = 0
    # wait for vblank twice
    for _ in range(2):
        lbl = 'vw%d' % a.pc()
        a.label(lbl)
        a.abs(0x2C, 0x2002)         # BIT $2002
        a.branch(0x10, lbl)         # BPL vw
    # palette $3F00: 32 bytes of i
    a.b(0xA9, 0x3F)
    a.abs(0x8D, 0x2006)
    a.b(0xA9, 0x00)
    a.abs(0x8D, 0x2006)
    a.b(0xA2, 0x00)                 # LDX #0
    a.label('pal')
    a.b(0x8A)                       # TXA
    a.abs(0x8D, 0x2007)
    a.b(0xE8)                       # INX
    a.b(0xE0, 0x20)                 # CPX #$20
    a.branch(0xD0, 'pal')
    # nametable $2000..$23FF: tile = addr low ^ addr high
    a.b(0xA9, 0x20)
    a.abs(0x8D, 0x2006)
    a.b(0xA9, 0x00)
    a.abs(0x8D, 0x2006)
    a.b(0xA0, 0x04)                 # LDY #4 (4 pages)
    a.b(0xA2, 0x00)
    a.label('nt')
    a.b(0x8A)
    a.b(0x49, 0x5A)                 # EOR #$5A
    a.abs(0x8D, 0x2007)
    a.b(0xE8)
    a.branch(0xD0, 'nt')
    a.b(0x88)                       # DEY
    a.branch(0xD0, 'nt')
    # OAM page at $0200: 8 sprites, byte = index*4 + slot
    a.b(0xA2, 0x00)
    a.label('oam')
    a.b(0x8A)
    a.abs(0x9D, 0x0200)             # STA $0200,X
    a.b(0xE8)
    a.b(0xE0, 0x20)
    a.branch(0xD0, 'oam')
    # zero state bytes $10-$17, $FF
    a.b(0xA9, 0x00)
    for z in range(0x10, 0x18):
        a.zp(0x85, z)
    a.zp(0x85, 0xFF)


def common_frame(a, mmc3):
    """Per-frame work (main loop body, entered after NMI flag)."""
    # OAM DMA
    a.b(0xA9, 0x00)
    a.abs(0x8D, 0x2003)
    a.b(0xA9, 0x02)
    a.abs(0x8D, 0x4014)
    # sprites move with frame counter ($10)
    a.zp(0xA5, 0x10)                # LDA $10
    a.b(0x0A)                       # ASL A
    a.abs(0x8D, 0x0200)             # sprite0 Y
    a.zp(0xA5, 0x10)
    a.b(0x0A)
    a.b(0x6D, 0x00, 0x02)           # ADC $0200 (sic, evolving)
    a.abs(0x8D, 0x0203)             # sprite0 X
    # joypad serial bit -> $12
    a.abs(0xAD, 0x4016)
    a.b(0x29, 0x01)                 # AND #1
    a.zp(0x85, 0x12)
    # scroll = frame + joy + banked byte ($13, set by mapper code)
    a.abs(0xAD, 0x2002)             # reset latch
    a.zp(0xA5, 0x10)
    a.b(0x65, 0x12)                 # ADC $12
    a.b(0x65, 0x13)                 # ADC $13
    a.abs(0x8D, 0x2005)
    a.zp(0xA5, 0x10)
    a.b(0x4A)                       # LSR A
    a.abs(0x8D, 0x2005)
    # WRAM: $6000 + (frame & 0xFF) = frame
    a.zp(0xA6, 0x10)                # LDX $10
    a.zp(0xA5, 0x10)
    a.abs(0x9D, 0x6000)             # STA $6000,X
    # APU square 1: retrigger every 4 frames with frame-scaled period
    a.zp(0xA5, 0x10)
    a.b(0x29, 0x03)                 # AND #3
    a.branch(0xD0, 'nosq')          # BNE nosq
    a.b(0xA9, 0x7F)
    a.abs(0x8D, 0x4000)             # duty 01, constant vol 15
    a.b(0xA9, 0x08)
    a.abs(0x8D, 0x4001)             # sweep off
    a.zp(0xA5, 0x10)
    a.b(0x0A)
    a.b(0x0A)
    a.abs(0x8D, 0x4002)
    a.b(0xA9, 0x09)
    a.abs(0x8D, 0x4003)
    a.label('nosq')
    # noise burst every 16 frames
    a.zp(0xA5, 0x10)
    a.b(0x29, 0x0F)
    a.branch(0xD0, 'nonoise')
    a.b(0xA9, 0x3F)
    a.abs(0x8D, 0x400C)
    a.b(0xA9, 0x85)
    a.abs(0x8D, 0x400E)
    a.b(0xA9, 0x08)
    a.abs(0x8D, 0x400F)
    a.label('nonoise')


def nmi_handler(a, chr_ram_write):
    a.b(0x48)                       # PHA
    a.zp(0xE6, 0x10)                # INC $10 (frame)
    if chr_ram_write:
        # CHR-RAM byte at $0040 + (frame & 63) = frame (vblank-safe slot)
        a.b(0xA9, 0x00)
        a.abs(0x8D, 0x2006)
        a.zp(0xA5, 0x10)
        a.b(0x29, 0x3F)
        a.b(0x69, 0x40)             # ADC #$40
        a.abs(0x8D, 0x2006)
        a.zp(0xA5, 0x10)
        a.abs(0x8D, 0x2007)
    a.b(0xA9, 0x01)
    a.zp(0x85, 0xFF)                # nmi flag
    a.b(0x68)                       # PLA
    a.b(0x40)                       # RTI


def build_m1():
    a = Asm(0xC000)
    a.label('reset')
    common_init(a)
    # -- MMC1 init: reset, control $0E, CHR0/CHR1 0, PRG 0 (serial, LSB first)
    a.b(0xA9, 0x80)
    a.abs(0x8D, 0x8000)
    a.b(0xA9, 0x0E)
    for i in range(5):
        a.abs(0x8D, 0x8000)
        if i < 4:
            a.b(0x4A)
    a.b(0xA9, 0x00)
    for reg in (0xA000, 0xC000, 0xE000):
        for _ in range(5):
            a.abs(0x8D, reg)
    # CHR-RAM base pattern $0000..$00FF (rendering still off)
    a.b(0xA9, 0x00)
    a.abs(0x8D, 0x2006)
    a.abs(0x8D, 0x2006)
    a.b(0xA2, 0x00)
    a.label('chrpat')
    a.b(0x8A)
    a.abs(0x8D, 0x2007)
    a.b(0xE8)
    a.branch(0xD0, 'chrpat')
    # APU on: sq1 + tri + noise
    a.b(0xA9, 0x0D)
    a.abs(0x8D, 0x4015)
    a.b(0xA9, 0x80)
    a.abs(0x8D, 0x4008)             # tri linear = $80 (ctrl, reload 0)
    a.b(0xA9, 0xB0)
    a.abs(0x8D, 0x400A)             # tri period lo
    a.b(0xA9, 0x09)
    a.abs(0x8D, 0x400B)             # tri period hi + length
    # rendering + NMI on
    a.b(0xA9, 0x88)
    a.abs(0x8D, 0x2000)
    a.b(0xA9, 0x1E)
    a.abs(0x8D, 0x2001)
    a.label('main')
    a.zp(0xA5, 0xFF)                # wait nmi
    a.branch(0xF0, 'main')          # BEQ main
    a.b(0xA9, 0x00)
    a.zp(0x85, 0xFF)
    common_frame(a, mmc3=False)
    # banked byte $8000 -> $13, PRG bank switch every 8 frames
    a.abs(0xAD, 0x8000)
    a.zp(0x85, 0x13)
    a.zp(0xA5, 0x10)
    a.b(0x29, 0x07)
    a.branch(0xD0, 'nosw')
    a.zp(0xA5, 0x10)
    a.b(0x4A)
    a.b(0x4A)
    a.b(0x4A)                       # bank = (frame>>3) & ...
    a.b(0x29, 0x03)
    a.b(0xA2, 0x05)                 # 5 serial writes
    a.label('ser')
    a.abs(0x8D, 0xE000)
    a.b(0x4A)
    a.b(0xCA)                       # DEX
    a.branch(0xD0, 'ser')
    a.label('nosw')
    a.jmp('main')
    a.label('nmi')
    nmi_handler(a, chr_ram_write=True)
    a.label('irq')
    a.b(0x40)
    code = a.done()

    prg = bytearray(b'\xEA' * (8 * 16384))
    for bank in range(8):           # bank marker byte at each bank start
        prg[bank * 16384] = 0x30 + bank
    last = 7 * 16384
    prg[last:last + len(code)] = code
    # vectors from the assembler's label map
    prg[last + (0xFFFA - 0xC000) + 0] = a.labels['nmi'] & 0xFF
    prg[last + (0xFFFA - 0xC000) + 1] = a.labels['nmi'] >> 8
    prg[last + (0xFFFC - 0xC000) + 0] = 0x00
    prg[last + (0xFFFC - 0xC000) + 1] = 0xC0
    prg[last + (0xFFFE - 0xC000) + 0] = a.labels['irq'] & 0xFF
    prg[last + (0xFFFE - 0xC000) + 1] = a.labels['irq'] >> 8
    hdr = bytearray(16)
    hdr[0:4] = b'NES\x1a'
    hdr[4] = 8
    hdr[5] = 0                      # CHR RAM
    hdr[6] = 0x12                   # mapper 1 low nibble, battery
    hdr[7] = 0x00
    return bytes(hdr) + bytes(prg)


def build_m3():
    a = Asm(0xE000)
    a.label('reset')
    common_init(a)
    # -- MMC3 init: PRG fixed at $E000 (this code), WRAM on at $A001,
    # CHR banks 0..5 = 0,2,4,5,6,7, IRQ latch 99.
    a.b(0xA9, 0x80)
    a.abs(0x8D, 0xA001)             # WRAM enable
    for sel, val in ((0, 0), (1, 2), (2, 4), (3, 5), (4, 6), (5, 7), (6, 0), (7, 1)):
        a.b(0xA9, sel)
        a.abs(0x8D, 0x8000)
        a.b(0xA9, val)
        a.abs(0x8D, 0x8001)
    a.b(0xA9, 99)
    a.abs(0x8D, 0xC000)             # IRQ latch
    a.abs(0x8D, 0xC001)             # reload (any write)
    a.abs(0x8D, 0xE001)             # IRQ enable
    # APU: sq1+tri+noise+DMC loop ($C000 in banked PRG? use fixed $E100 area:
    # sample address register: $C000 + val*64; point at $E000 code bytes)
    a.b(0xA9, 0x1D)
    a.abs(0x8D, 0x4015)
    a.b(0xA9, 0x40)                 # 0x40: loop, rate 0
    a.abs(0x8D, 0x4010)
    a.b(0xA9, 0x40)                 # $C000 + $40*$40 = $D000 (pattern bytes)
    a.abs(0x8D, 0x4012)
    a.b(0xA9, 0x02)                 # length 33 bytes
    a.abs(0x8D, 0x4013)
    a.b(0xA9, 0x80)
    a.abs(0x8D, 0x4008)
    a.b(0xA9, 0xB0)
    a.abs(0x8D, 0x400A)
    a.b(0xA9, 0x09)
    a.abs(0x8D, 0x400B)
    a.b(0xA9, 0x88)
    a.abs(0x8D, 0x2000)
    a.b(0xA9, 0x1E)
    a.abs(0x8D, 0x2001)
    a.b(0x58)                       # CLI (MMC3 IRQ)
    a.label('main')
    a.zp(0xA5, 0xFF)
    a.branch(0xF0, 'main')
    a.b(0xA9, 0x00)
    a.zp(0x85, 0xFF)
    common_frame(a, mmc3=True)
    # banked byte + per-frame bank switches
    a.abs(0xAD, 0x8000)
    a.zp(0x85, 0x13)
    a.b(0xA9, 0x06)
    a.abs(0x8D, 0x8000)             # select PRG bank 0 ($8000)
    a.zp(0xA5, 0x10)
    a.b(0x29, 0x07)
    a.abs(0x8D, 0x8001)
    a.b(0xA9, 0x00)
    a.abs(0x8D, 0x8000)             # select CHR 2K bank 0
    a.zp(0xA5, 0x10)
    a.b(0x29, 0x3E)
    a.abs(0x8D, 0x8001)
    a.jmp('main')
    a.label('nmi')
    nmi_handler(a, chr_ram_write=False)
    a.label('irqh')
    a.b(0x48)                       # PHA
    a.zp(0xE6, 0x11)                # INC $11 (IRQ count)
    a.b(0xA9, 0x00)
    a.abs(0x8D, 0xE000)             # IRQ disable (ack)
    a.abs(0x8D, 0xE001)             # re-enable
    a.b(0x68)                       # PLA
    a.b(0x40)                       # RTI
    code = a.done()

    prg = bytearray(b'\xEA' * (32 * 8192))     # 256 KB = 32 x 8 KB
    for bank in range(32):
        prg[bank * 8192] = 0x40 + bank
    # DMC sample area at CPU $D000: in mode 0 $C000-$DFFF is bank (len/16K*2-2)=30
    for i in range(64):
        prg[30 * 8192 + 0x1000 + i] = (i * 37) & 0xFF
    last8 = 31 * 8192               # fixed $E000 bank
    prg[last8:last8 + len(code)] = code
    def vec(at, val):
        o = last8 + (at - 0xE000)
        prg[o] = val & 0xFF
        prg[o + 1] = val >> 8
    vec(0xFFFA, a.labels['nmi'])
    vec(0xFFFC, 0xE000)
    vec(0xFFFE, a.labels['irqh'])
    chrrom = bytearray(128 * 1024)
    for i in range(len(chrrom)):
        chrrom[i] = (i >> 4) & 0xFF
    hdr = bytearray(16)
    hdr[0:4] = b'NES\x1a'
    hdr[4] = 16                     # 16 x 16 KB = 256 KB
    hdr[5] = 16                     # 16 x 8 KB = 128 KB CHR ROM
    hdr[6] = 0x42                   # mapper 4 low nibble, battery
    hdr[7] = 0x00
    return bytes(hdr) + bytes(prg) + bytes(chrrom)


if __name__ == '__main__':
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    for name, rom in (('m1', build_m1()), ('m3', build_m3())):
        with open(os.path.join(outdir, name + '.hex'), 'w') as f:
            for b in rom:
                f.write('%02x\n' % b)
        with open(os.path.join(outdir, name + '.nes'), 'wb') as f:
            f.write(rom)
        print('%s: %d bytes' % (name, len(rom)))
