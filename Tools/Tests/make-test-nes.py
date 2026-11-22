#!/usr/bin/env python3
"""Builds a tiny NES test program (public domain, written for Offline Kit's own tests) for checking games end to end.

  python3 make-test-nes.py <out.nes>

What it does, so a test can tell input, picture and sound apart:
- A checkerboard scrolls sideways every frame, so the picture always changes (frame-rate checks).
- A white square moves with the d-pad (player 1). Player 2's d-pad moves a second, orange square.
- Holding A turns the background red and plays a 440 Hz tone; B turns it green; Start turns it blue.
  Player 2's A turns it purple.
No assembler needed: the 6502 code is assembled here.
"""
import sys

# Opcodes used (addressing mode suffix: imm, abs, zp, absx, impl, rel).
OPS = {
    ("SEI", "impl"): 0x78, ("CLD", "impl"): 0xD8, ("TXS", "impl"): 0x9A, ("INX", "impl"): 0xE8,
    ("DEX", "impl"): 0xCA, ("DEY", "impl"): 0x88, ("RTI", "impl"): 0x40, ("PHA", "impl"): 0x48,
    ("PLA", "impl"): 0x68, ("LSR", "impl"): 0x4A, ("TXA", "impl"): 0x8A, ("TAX", "impl"): 0xAA,
    ("TYA", "impl"): 0x98, ("TAY", "impl"): 0xA8,
    ("LDA", "imm"): 0xA9, ("LDX", "imm"): 0xA2, ("LDY", "imm"): 0xA0, ("AND", "imm"): 0x29,
    ("CPX", "imm"): 0xE0, ("CMP", "imm"): 0xC9,
    ("LDA", "abs"): 0xAD, ("STA", "abs"): 0x8D, ("STX", "abs"): 0x8E, ("BIT", "abs"): 0x2C,
    ("LDA", "zp"): 0xA5, ("STA", "zp"): 0x85, ("INC", "zp"): 0xE6, ("DEC", "zp"): 0xC6,
    ("ROL", "zp"): 0x26, ("LDX", "zp"): 0xA6,
    ("LDA", "absx"): 0xBD, ("STA", "absx"): 0x9D,
    ("JMP", "abs"): 0x4C,
    ("BPL", "rel"): 0x10, ("BNE", "rel"): 0xD0, ("BEQ", "rel"): 0xF0,
}


def assemble(program, origin):
    labels, out = {}, []
    for pass_ in range(2):
        pc, out = origin, []
        for item in program:
            if isinstance(item, str):           # label
                labels[item] = pc
                continue
            if item[0] == "BYTES":
                out += item[1]; pc += len(item[1]); continue
            op, mode, *arg = item
            code = OPS[(op, mode)]
            value = arg[0] if arg else None
            if isinstance(value, str):
                value = labels.get(value, 0) if pass_ else 0
            if mode == "impl":
                out += [code]; pc += 1
            elif mode in ("imm", "zp"):
                out += [code, value & 0xFF]; pc += 2
            elif mode == "rel":
                offset = (value - (pc + 2)) if pass_ else 0
                assert -128 <= offset <= 127, f"branch too far at {pc:04x}"
                out += [code, offset & 0xFF]; pc += 2
            else:
                out += [code, value & 0xFF, (value >> 8) & 0xFF]; pc += 3
    return bytes(out), labels


# Zero page: $10 x, $11 y, $12 pad 1, $13 last pad 1, $14 frame, $15 pad 2, $16 x2, $17 y2
def read_pad(port, store):
    return [("LDX", "imm", 8), f"rd{port}", ("LDA", "abs", port), ("LSR", "impl"), ("ROL", "zp", store),
            ("DEX", "impl"), ("BNE", "rel", f"rd{port}")]


def move(pad, xs, ys, tag):
    code = []
    for bit, op, var in [(0x08, "DEC", ys), (0x04, "INC", ys), (0x02, "DEC", xs), (0x01, "INC", xs)]:
        skip = f"m{tag}{bit}"
        code += [("LDA", "zp", pad), ("AND", "imm", bit), ("BEQ", "rel", skip), (op, "zp", var), (op, "zp", var), skip]
    return code


def sprite(index, xs, ys, tile, attr):
    base = 0x0200 + index * 4
    return [("LDA", "zp", ys), ("STA", "abs", base), ("LDA", "imm", tile), ("STA", "abs", base + 1),
            ("LDA", "imm", attr), ("STA", "abs", base + 2), ("LDA", "zp", xs), ("STA", "abs", base + 3)]


palette = [0x0F, 0x21, 0x11, 0x30] * 4 + [0x0F, 0x30, 0x30, 0x30, 0x0F, 0x27, 0x27, 0x27] + [0x0F, 0x30, 0x30, 0x30] * 2

program = [
    "reset",
    ("SEI", "impl"), ("CLD", "impl"),
    ("LDX", "imm", 0x40), ("STX", "abs", 0x4017),
    ("LDX", "imm", 0xFF), ("TXS", "impl"), ("INX", "impl"),
    ("STX", "abs", 0x2000), ("STX", "abs", 0x2001), ("STX", "abs", 0x4010),
    "vb1", ("BIT", "abs", 0x2002), ("BPL", "rel", "vb1"),
    "clr", ("LDA", "imm", 0), ("STA", "absx", 0x0000), ("STA", "absx", 0x0100), ("STA", "absx", 0x0300),
    ("STA", "absx", 0x0400), ("STA", "absx", 0x0500), ("STA", "absx", 0x0600), ("STA", "absx", 0x0700),
    ("LDA", "imm", 0xFF), ("STA", "absx", 0x0200), ("INX", "impl"), ("BNE", "rel", "clr"),
    "vb2", ("BIT", "abs", 0x2002), ("BPL", "rel", "vb2"),
    ("LDA", "abs", 0x2002), ("LDA", "imm", 0x3F), ("STA", "abs", 0x2006), ("LDA", "imm", 0x00), ("STA", "abs", 0x2006),
    ("LDX", "imm", 0),
    "pal", ("LDA", "absx", "palette"), ("STA", "abs", 0x2007), ("INX", "impl"), ("CPX", "imm", 32), ("BNE", "rel", "pal"),
    ("LDA", "imm", 0x20), ("STA", "abs", 0x2006), ("LDA", "imm", 0x00), ("STA", "abs", 0x2006),
    ("LDY", "imm", 8), ("LDX", "imm", 0), ("LDA", "imm", 2),
    "fill", ("STA", "abs", 0x2007), ("INX", "impl"), ("BNE", "rel", "fill"), ("DEY", "impl"), ("BNE", "rel", "fill"),
    ("LDA", "imm", 120), ("STA", "zp", 0x10), ("LDA", "imm", 112), ("STA", "zp", 0x11),
    ("LDA", "imm", 60), ("STA", "zp", 0x16), ("LDA", "imm", 160), ("STA", "zp", 0x17),
    ("LDA", "imm", 0x01), ("STA", "abs", 0x4015),
    ("LDA", "imm", 0x80), ("STA", "abs", 0x2000),
    ("LDA", "imm", 0x1E), ("STA", "abs", 0x2001),
    "loop", ("JMP", "abs", "loop"),

    "nmi",
    ("PHA", "impl"), ("TXA", "impl"), ("PHA", "impl"), ("TYA", "impl"), ("PHA", "impl"),
    ("LDA", "imm", 0x00), ("STA", "abs", 0x2003), ("LDA", "imm", 0x02), ("STA", "abs", 0x4014),
    ("LDA", "imm", 1), ("STA", "abs", 0x4016), ("LDA", "imm", 0), ("STA", "abs", 0x4016),
    *read_pad(0x4016, 0x12),
    *read_pad(0x4017, 0x15),
    *move(0x12, 0x10, 0x11, "a"),
    *move(0x15, 0x16, 0x17, "b"),
    *sprite(0, 0x10, 0x11, 1, 0),
    *sprite(1, 0x16, 0x17, 1, 1),
    ("LDA", "abs", 0x2002), ("LDA", "imm", 0x3F), ("STA", "abs", 0x2006), ("LDA", "imm", 0x00), ("STA", "abs", 0x2006),
    ("LDA", "zp", 0x12), ("AND", "imm", 0x80), ("BEQ", "rel", "noA"), ("LDA", "imm", 0x16), ("JMP", "abs", "setc"),
    "noA", ("LDA", "zp", 0x12), ("AND", "imm", 0x40), ("BEQ", "rel", "noB"), ("LDA", "imm", 0x1A), ("JMP", "abs", "setc"),
    "noB", ("LDA", "zp", 0x12), ("AND", "imm", 0x10), ("BEQ", "rel", "noS"), ("LDA", "imm", 0x12), ("JMP", "abs", "setc"),
    "noS", ("LDA", "zp", 0x15), ("AND", "imm", 0x80), ("BEQ", "rel", "noP2"), ("LDA", "imm", 0x14), ("JMP", "abs", "setc"),
    "noP2", ("LDA", "imm", 0x0F),
    "setc", ("STA", "abs", 0x2007),
    ("INC", "zp", 0x14),
    ("LDA", "zp", 0x14), ("STA", "abs", 0x2005), ("LDA", "imm", 0), ("STA", "abs", 0x2005),
    ("LDA", "imm", 0x80), ("STA", "abs", 0x2000),
    # Sound: a 440 Hz square wave while A is held. The period's high byte ($4003) is written only when A goes down,
    # since writing it restarts the wave (a buzz if done every frame).
    ("LDA", "zp", 0x12), ("AND", "imm", 0x80), ("BEQ", "rel", "silent"),
    ("LDA", "imm", 0xBF), ("STA", "abs", 0x4000), ("LDA", "imm", 0xFD), ("STA", "abs", 0x4002),
    ("LDA", "zp", 0x13), ("AND", "imm", 0x80), ("BNE", "rel", "done"),
    ("LDA", "imm", 0x00), ("STA", "abs", 0x4003), ("JMP", "abs", "done"),
    "silent", ("LDA", "imm", 0x30), ("STA", "abs", 0x4000),
    "done", ("LDA", "zp", 0x12), ("STA", "zp", 0x13),
    ("PLA", "impl"), ("TAY", "impl"), ("PLA", "impl"), ("TAX", "impl"), ("PLA", "impl"),
    "irq", ("RTI", "impl"),
    "palette", ("BYTES", palette),
]

code, labels = assemble(program, 0xC000)
prg = bytearray(code.ljust(0x4000 - 6, b"\xEA"))
for name in ("nmi", "reset", "irq"):
    prg += labels[name].to_bytes(2, "little")
assert len(prg) == 0x4000

chr_rom = bytearray(0x2000)
chr_rom[16:32] = b"\xFF" * 16                                   # tile 1: solid colour 3
chr_rom[32:48] = bytes([0xF0] * 4 + [0x0F] * 4) + bytes(8)       # tile 2: checker in colour 1

header = b"NES\x1A" + bytes([1, 1, 0, 0]) + bytes(8)            # NROM, 16 KB program, 8 KB tiles
with open(sys.argv[1], "wb") as f:
    f.write(header + prg + chr_rom)
print(f"wrote {sys.argv[1]} ({16 + len(prg) + len(chr_rom)} bytes)")
