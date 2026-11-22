#!/usr/bin/env python3
"""Builds a tiny NES test program (public domain, written for Offline Kit's own tests) for checking games end to end.

  python3 make-test-nes.py <out.nes>
  python3 make-test-nes.py <out.nes> --title "SKY RIDER" [--splash "LICENSED BY|NINTENDO"] [--splash-seconds 2]

What it does, so a test can tell input, picture and sound apart:
- A checkerboard scrolls sideways every frame, so the picture always changes (frame-rate checks).
- A white square moves with the d-pad (player 1). Player 2's d-pad moves a second, orange square.
- Holding A turns the background red and plays a 440 Hz tone; B turns it green; Start turns it blue.
  Player 2's A turns it purple.
No assembler needed: the 6502 code is assembled here.

With --title it builds a different program, for the automatic title-screen art (GameTitleCards): a black screen with
splash text (default "LICENSED BY" / "NINTENDO", like a licensor's card) for --splash-seconds, then a title screen with
the title, "PRESS START" and "(C) 2026 TEST SOFT" in an 8x8 capital-letter font. Nothing moves and no input is read.
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

# A 5x7 font for the title-screen mode: A-Z, 0-9, ( and ). Tile 0 is blank.
FONT = {
    "A": "01110 10001 10001 11111 10001 10001 10001", "B": "11110 10001 10001 11110 10001 10001 11110",
    "C": "01110 10001 10000 10000 10000 10001 01110", "D": "11110 10001 10001 10001 10001 10001 11110",
    "E": "11111 10000 10000 11110 10000 10000 11111", "F": "11111 10000 10000 11110 10000 10000 10000",
    "G": "01110 10001 10000 10111 10001 10001 01111", "H": "10001 10001 10001 11111 10001 10001 10001",
    "I": "01110 00100 00100 00100 00100 00100 01110", "J": "00111 00010 00010 00010 00010 10010 01100",
    "K": "10001 10010 10100 11000 10100 10010 10001", "L": "10000 10000 10000 10000 10000 10000 11111",
    "M": "10001 11011 10101 10101 10001 10001 10001", "N": "10001 10001 11001 10101 10011 10001 10001",
    "O": "01110 10001 10001 10001 10001 10001 01110", "P": "11110 10001 10001 11110 10000 10000 10000",
    "Q": "01110 10001 10001 10001 10101 10010 01101", "R": "11110 10001 10001 11110 10100 10010 10001",
    "S": "01111 10000 10000 01110 00001 00001 11110", "T": "11111 00100 00100 00100 00100 00100 00100",
    "U": "10001 10001 10001 10001 10001 10001 01110", "V": "10001 10001 10001 10001 10001 01010 00100",
    "W": "10001 10001 10001 10101 10101 10101 01010", "X": "10001 10001 01010 00100 01010 10001 10001",
    "Y": "10001 10001 01010 00100 00100 00100 00100", "Z": "11111 00001 00010 00100 01000 10000 11111",
    "0": "01110 10001 10011 10101 11001 10001 01110", "1": "00100 01100 00100 00100 00100 00100 01110",
    "2": "01110 10001 00001 00010 00100 01000 11111", "3": "11111 00010 00100 00010 00001 10001 01110",
    "4": "00010 00110 01010 10010 11111 00010 00010", "5": "11111 10000 11110 00001 00001 10001 01110",
    "6": "00110 01000 10000 11110 10001 10001 01110", "7": "11111 00001 00010 00100 01000 01000 01000",
    "8": "01110 10001 10001 01110 10001 10001 01110", "9": "01110 10001 10001 01111 00001 00010 01100",
    "(": "00010 00100 01000 01000 01000 00100 00010", ")": "01000 00100 00010 00010 00010 00100 01000",
}
GLYPHS = list(FONT)


def tile_of(ch):
    return 0 if ch == " " else GLYPHS.index(ch) + 1


def title_program(splash, title, splash_frames):
    """Splash lines for `splash_frames` frames, then the title screen. Rows are centred on the 32-column screen."""
    def at(row, text):
        addr = 0x2000 + row * 32 + (32 - len(text)) // 2
        return addr, [tile_of(c) for c in text]

    def write(rows):
        code = []
        for addr, tiles in rows:
            code += [("LDA", "abs", 0x2002), ("LDA", "imm", addr >> 8), ("STA", "abs", 0x2006),
                     ("LDA", "imm", addr & 0xFF), ("STA", "abs", 0x2006)]
            for t in tiles:
                code += [("LDA", "imm", t), ("STA", "abs", 0x2007)]
        return code

    def clear(rows):
        return write([(addr, [0] * len(tiles)) for addr, tiles in rows])

    first = len(splash) and 13 - len(splash)
    splash_rows = [at(first + 2 * i, line) for i, line in enumerate(splash)]
    title_rows = [at(9, title), at(18, "PRESS START"), at(24, "(C) 2026 TEST SOFT")]
    pal = [0x0F, 0x30, 0x10, 0x00] * 4 + [0x0F, 0x30, 0x30, 0x30] * 4
    show = [("LDA", "abs", 0x2002), ("LDA", "imm", 0), ("STA", "abs", 0x2005), ("STA", "abs", 0x2005),
            ("LDA", "imm", 0x80), ("STA", "abs", 0x2000), ("LDA", "imm", 0x0A), ("STA", "abs", 0x2001)]
    hide = [("LDA", "imm", 0), ("STA", "abs", 0x2000), ("STA", "abs", 0x2001)]
    return [
        "reset",
        ("SEI", "impl"), ("CLD", "impl"),
        ("LDX", "imm", 0x40), ("STX", "abs", 0x4017),
        ("LDX", "imm", 0xFF), ("TXS", "impl"), ("INX", "impl"),
        ("STX", "abs", 0x2000), ("STX", "abs", 0x2001), ("STX", "abs", 0x4010),
        "vb1", ("BIT", "abs", 0x2002), ("BPL", "rel", "vb1"),
        "clr", ("LDA", "imm", 0), ("STA", "absx", 0x0000), ("STA", "absx", 0x0100), ("STA", "absx", 0x0300),
        ("INX", "impl"), ("BNE", "rel", "clr"),
        "vb2", ("BIT", "abs", 0x2002), ("BPL", "rel", "vb2"),
        ("LDA", "abs", 0x2002), ("LDA", "imm", 0x3F), ("STA", "abs", 0x2006), ("LDA", "imm", 0x00), ("STA", "abs", 0x2006),
        ("LDX", "imm", 0),
        "pal", ("LDA", "absx", "palette"), ("STA", "abs", 0x2007), ("INX", "impl"), ("CPX", "imm", 32), ("BNE", "rel", "pal"),
        # Blank the whole first screen (tiles and attributes).
        ("LDA", "imm", 0x20), ("STA", "abs", 0x2006), ("LDA", "imm", 0x00), ("STA", "abs", 0x2006),
        ("LDY", "imm", 4), ("LDX", "imm", 0), ("LDA", "imm", 0),
        "fill", ("STA", "abs", 0x2007), ("INX", "impl"), ("BNE", "rel", "fill"), ("DEY", "impl"), ("BNE", "rel", "fill"),
        *write(splash_rows),
        *show,
        "wait", ("LDA", "zp", 0x14), ("CMP", "imm", splash_frames & 0xFF), ("BNE", "rel", "wait"),
        *hide,
        *clear(splash_rows),
        *write(title_rows),
        "vb3", ("BIT", "abs", 0x2002), ("BPL", "rel", "vb3"),
        *show,
        "forever", ("JMP", "abs", "forever"),
        "nmi", ("INC", "zp", 0x14),
        "irq", ("RTI", "impl"),
        "palette", ("BYTES", pal),
    ]


args = sys.argv[1:]
title_mode = "--title" in args
if title_mode:
    def option(name, default):
        return args[args.index(name) + 1] if name in args else default
    title_text = option("--title", "SKY RIDER").upper()
    splash_lines = [line.upper() for line in option("--splash", "LICENSED BY|NINTENDO").split("|") if line]
    seconds = float(option("--splash-seconds", "2"))
    for ch in title_text + "".join(splash_lines):
        assert ch == " " or ch in FONT, f"no glyph for {ch!r}"
    program = title_program(splash_lines, title_text, max(1, min(255, int(seconds * 60))))

code, labels = assemble(program, 0xC000)
prg = bytearray(code.ljust(0x4000 - 6, b"\xEA"))
for name in ("nmi", "reset", "irq"):
    prg += labels[name].to_bytes(2, "little")
assert len(prg) == 0x4000

chr_rom = bytearray(0x2000)
if title_mode:
    for index, ch in enumerate(GLYPHS):                          # tiles 1…: the font, colour 1 (plane 0)
        rows = [0] + [int(bits, 2) << 2 for bits in FONT[ch].split()]
        base = (index + 1) * 16
        chr_rom[base:base + 8] = bytes(rows)
else:
    chr_rom[16:32] = b"\xFF" * 16                               # tile 1: solid colour 3
    chr_rom[32:48] = bytes([0xF0] * 4 + [0x0F] * 4) + bytes(8)   # tile 2: checker in colour 1

header = b"NES\x1A" + bytes([1, 1, 0, 0]) + bytes(8)            # NROM, 16 KB program, 8 KB tiles
with open(args[0], "wb") as f:
    f.write(header + prg + chr_rom)
print(f"wrote {args[0]} ({16 + len(prg) + len(chr_rom)} bytes)")
