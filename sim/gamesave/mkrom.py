#!/usr/bin/env python3
"""Build the test ROM for the NES game-pattern sim: an MMC1 (mapper 1)
cartridge with 128 KB of PRG ROM, CHR RAM and a battery, like The Legend of
Zelda. Its 6502 code does what such a game does at power-on:

  1. resets MMC1 and writes its control and PRG registers through the serial
     port, 5 writes each (PRG-RAM enabled: bit 4 of the PRG register = 0);
  2. looks for a signature ($5A $A5) at $6000, the start of the battery RAM;
  3. no signature (first boot): writes the signature, a pattern over
     $6002-$60FF and $6102-$61FF, a $11 marker at $6400 and a byte at $7FFF;
     signature found (a restored save): writes only a $77 marker at $6400;
  4. loops forever.

usage: mkrom.py <out.hex> [out.nes]    (one hex byte per line, like hexdump -ve)
"""
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

    def branch(self, op, name):
        self.b(op, 0)
        self.fix.append((len(self.code) - 1, name, 'rel'))

    def jmp(self, name):
        self.b(0x4C, 0, 0)
        self.fix.append((len(self.code) - 2, name, 'abs'))

    def done(self):
        for at, name, kind in self.fix:
            tgt = self.labels[name]
            if kind == 'rel':
                off = tgt - (self.org + at + 1)
                assert -128 <= off <= 127
                self.code[at] = off & 0xFF
            else:
                self.code[at] = tgt & 0xFF
                self.code[at + 1] = tgt >> 8
        return bytes(self.code)


def program():
    a = Asm(0xC000)
    a.label('reset')
    a.b(0x78)                       # SEI
    a.b(0xD8)                       # CLD
    a.b(0xA2, 0xFF)                 # LDX #$FF
    a.b(0x9A)                       # TXS
    a.b(0xA9, 0x80)                 # LDA #$80   MMC1 reset
    a.abs(0x8D, 0x8000)             # STA $8000
    # control = $0E (vertical mirroring, PRG mode 3, CHR 8 KB), LSB first
    a.b(0xA9, 0x0E)
    for i in range(5):
        a.abs(0x8D, 0x8000)
        if i < 4:
            a.b(0x4A)               # LSR A
    # CHR bank 0, CHR bank 1, PRG bank: 5 writes of 0 each
    a.b(0xA9, 0x00)
    for reg in (0xA000, 0xC000, 0xE000):
        for i in range(5):
            a.abs(0x8D, reg)
    # is there a save?
    a.abs(0xAD, 0x6000)             # LDA $6000
    a.b(0xC9, 0x5A)                 # CMP #$5A
    a.branch(0xD0, 'init')          # BNE init
    a.abs(0xAD, 0x6001)             # LDA $6001
    a.b(0xC9, 0xA5)                 # CMP #$A5
    a.branch(0xD0, 'init')
    a.b(0xA9, 0x77)                 # found: LDA #$77
    a.abs(0x8D, 0x6400)             # STA $6400
    a.jmp('idle')
    a.label('init')
    a.b(0xA9, 0x5A)
    a.abs(0x8D, 0x6000)
    a.b(0xA9, 0xA5)
    a.abs(0x8D, 0x6001)
    a.b(0xA2, 0x02)                 # LDX #2
    a.label('loop')
    a.b(0x8A)                       # TXA
    a.b(0x49, 0x3C)                 # EOR #$3C
    a.abs(0x9D, 0x6000)             # STA $6000,X
    a.abs(0x9D, 0x6100)             # STA $6100,X
    a.b(0xE8)                       # INX
    a.branch(0xD0, 'loop')          # BNE loop (X wraps at 256)
    a.b(0xA9, 0x11)
    a.abs(0x8D, 0x6400)
    a.abs(0x8D, 0x7FFF)
    a.label('idle')
    a.jmp('idle')
    return a.done()


def build():
    prg = bytearray(b'\xFF' * (8 * 16384))
    code = program()
    last = 7 * 16384
    prg[last:last + len(code)] = code
    for vec in (0xFFFA, 0xFFFC, 0xFFFE):    # NMI, RESET, IRQ -> $C000
        o = last + (vec - 0xC000)
        prg[o] = 0x00
        prg[o + 1] = 0xC0
    hdr = bytearray(16)
    hdr[0:4] = b'NES\x1a'
    hdr[4] = 8                      # 8 x 16 KB PRG
    hdr[5] = 0                      # CHR RAM
    hdr[6] = 0x12                   # mapper 1, battery
    return bytes(hdr) + bytes(prg)


if __name__ == '__main__':
    rom = build()
    with open(sys.argv[1], 'w') as f:
        for b in rom:
            f.write('%02x\n' % b)
    if len(sys.argv) > 2:
        with open(sys.argv[2], 'wb') as f:
            f.write(rom)
    print('%d bytes' % len(rom))
