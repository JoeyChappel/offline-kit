#!/usr/bin/env python3
"""Writes Tests/Fixtures/tiny.zim: six short hand-written articles for the unit tests (answer index build and query).

usage: make-tiny-zim.py [out.zim]

Builds the zimwrite helper (make-test-zim/zimwrite.mm, the libzim writer in Vendor/CoreKiwix.xcframework) in a temp
folder. No downloads, no real content. The archive has no full-text index, which keeps it small.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parents[1]

ARTICLES = [
    ("Heat_stroke", "Heat stroke", {
        "lead": "Heat stroke is a medical emergency in which the body temperature rises above 40 degrees and the body's "
                "cooling system fails. It often follows heat exhaustion during hard work or exercise in hot, humid weather, "
                "and it can damage the brain, heart and kidneys within hours. Older adults and young children are at higher risk.",
        "Signs and symptoms": "Confusion, slurred speech or strange behavior are the key warning signs of heat stroke. The skin "
                              "may be hot and dry. A fast, strong pulse, a throbbing headache, nausea and fainting are common, "
                              "and seizures can follow if the person is not cooled quickly.",
        "Treatment": "Call emergency services, then start cooling the person at once. Move them into shade, remove extra "
                     "clothing and immerse them in cold water up to the neck, the fastest way to bring the temperature down. "
                     "If there is no tub, soak them with cool water, fan them and put ice packs in the armpits and groin.",
    }),
    ("Burns", "Burns", {
        "lead": "A burn is damage to the skin and deeper tissues caused by heat, chemicals, electricity, sunlight or radiation. "
                "Scalds from hot liquids are among the most common burns at home, especially in children. Burns are classed "
                "by depth as superficial, partial-thickness or full-thickness.",
        "First aid": "Stop the burning and remove clothing or jewelry near the burn unless it is stuck to the skin. Cool the "
                     "burn under cool running water for twenty minutes as soon as possible, which reduces pain and depth. "
                     "Cover it loosely with cling film or a clean, non-fluffy dressing and do not apply butter or ice.",
    }),
    ("Hypothermia", "Hypothermia", {
        "lead": "Hypothermia is a dangerous drop in body temperature below 35 degrees, caused by losing heat faster than the "
                "body can make it. Cold water, wind and wet clothing speed up heat loss, and shivering, clumsiness and "
                "confusion are early signs that the core of the body is getting cold.",
        "Treatment": "Move the person somewhere warm and dry, replace wet clothing and rewarm the center of the body first "
                     "with blankets, skin-to-skin contact and warm sweet drinks if they are alert. Handle them gently and do "
                     "not rub the arms and legs, which can send cold blood back to the heart.",
    }),
    ("Water_purification", "Water purification", {
        "lead": "Water purification removes germs, chemicals and dirt so water is safe to drink. At home the simplest "
                "methods are boiling, chemical disinfection with unscented bleach or tablets, and filtering, and clear "
                "water works better than cloudy water for every method.",
        "Boiling": "Bring clear water to a rolling boil for one minute, or three minutes above two thousand meters, then let "
                   "it cool in a clean covered container. Boiling kills bacteria, viruses and parasites but does not remove "
                   "chemicals or salt from the water.",
        "References": "Water treatment manual, chapter four. Field guide to safe water storage, second edition, page ten.",
    }),
    ("GFCI_outlet", "Ground fault circuit interrupter", {
        "lead": "A ground fault circuit interrupter, or GFCI outlet, cuts power in a fraction of a second when it senses "
                "current leaking to ground, protecting people from electric shock in kitchens, bathrooms and outdoors. "
                "A tripped outlet can be reset once the fault is cleared.",
        "Resetting a tripped outlet": "Unplug everything on the circuit, then press the reset button firmly until it clicks "
                                      "and stays in. If it trips again at once, an appliance or damp wiring is at fault, so "
                                      "leave it off and test each appliance on its own before calling an electrician.",
    }),
    ("Main_Page", "Tiny test archive", {
        "lead": "This tiny archive holds a handful of short practical articles written for Offline Kit's unit tests. It "
                "covers heat stroke, burns, hypothermia, water purification and resetting a ground fault outlet, and it "
                "contains no real reference content at all.",
    }),
]


def html(title, sections):
    parts = [f"<html><head><title>{title}</title><style>p {{ margin: 0 }}</style></head><body>",
             "<nav>Home | Search | Random article</nav>", f"<h1>{title}</h1>",
             f"<p>{sections['lead']}<sup>[1]</sup></p>"]
    for heading, text in sections.items():
        if heading != "lead":
            parts.append(f"<h2>{heading}</h2><p>{text}</p>")
    parts.append("<footer>Test data for Offline Kit.</footer></body></html>")
    return "".join(parts)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else APP / "Tests/Fixtures/tiny.zim"
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        writer = tmp / "zimwrite"
        k = APP / "Vendor/CoreKiwix.xcframework/macos-arm64_x86_64"
        subprocess.run(["clang++", "-std=gnu++20", "-O1", "-arch", "arm64", f"-I{k}/Headers", str(HERE / "make-test-zim/zimwrite.mm"),
                        str(k / "merged.a"), "-framework", "Foundation", "-framework", "CoreFoundation",
                        "-framework", "Security", "-lz", "-o", str(writer)], check=True)
        records = tmp / "tiny.records"
        records.write_text("\x1e".join(f"{p}\x1f{t}\x1f{html(t, s)}" for p, t, s in ARTICLES), encoding="utf-8")
        out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(writer), str(records), str(out), "test_tiny_en", "Tiny (test)",
                        "Six short articles for Offline Kit unit tests", "noindex"], check=True)
    print(f"{out}: {out.stat().st_size} bytes")


if __name__ == "__main__":
    main()
