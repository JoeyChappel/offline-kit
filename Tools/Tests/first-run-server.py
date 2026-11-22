#!/usr/bin/env python3
"""A tiny local stand-in for library.kiwix.org and download.kiwix.org, for the first-run smoke test.

usage: first-run-server.py <fixtures folder> [--port N] [--rate BYTES_PER_SECOND] [--log FILE] [--portfile FILE]

Serves, on 127.0.0.1 only:
  /catalog/v2/entries         an OPDS catalog (the same shape as Kiwix's) of a few small packs and a few that are
                              listed but too big to be downloaded (to check they start unticked)
  /zim/<file>.zim.meta4       a metalink with the real size, SHA-256 and SHA-1 piece hashes of the file
  /zim/<file>.zim             the archive, with Range support
--port 0 (the default) picks a free port and prints it. --rate slows every download so a run has time to pause,
resume or drop the server in the middle. The app reaches this server only in a Debug build, in a test home, with
OFFLINEKIT_TEST_SERVER=http://127.0.0.1:<port> set (see LocalTestServer in Catalog.swift).

The fixtures folder holds tiny.zim, tiny-indexed.zim, practical.zim and encyclopedia.zim (Tools/Tests/make-tiny-zim.py and
make-test-zim/make-test-zim.py write them).
"""
import argparse
import hashlib
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from xml.sax.saxutils import escape

PIECE = 1 << 20
ISSUED = "2026-10-01"

# (catalog name, flavour, title, summary, fixture file or None, listed size when there is no file, article count)
PACKS = [
    ("mdwiki_en_all", "maxi", "WikiMed Medical Encyclopedia", "Medical articles from Wikipedia (test copy).", "practical.zim", 0, 304),
    ("mdwiki_en_all", "nopic", "WikiMed Medical Encyclopedia", "Medical articles without pictures (test copy).", "tiny-indexed.zim", 0, 6),
    ("wikipedia_en_medicine", "maxi", "Wikipedia: Medicine", "Every medical article (test copy, 20,000 short articles).", "encyclopedia.zim", 0, 20000),
    ("ready.gov_en_all", "", "Ready.gov", "Disaster plans (test copy).", "tiny.zim", 0, 6),
    ("zimgit-water_en", "", "Zimgit Water", "How to make water safe (test copy).", "tiny-indexed.zim", 0, 6),
    ("armypubs_en_all", "", "Army Publications", "Listed only, never served: too large to start ticked.", None, 3_400_000_000, 9000),
    ("ted_mul_ted-ed", "", "TED-Ed", "Listed only, never served: a video pack.", None, 900_000_000, 800),
]


class Fixture:
    def __init__(self, root: Path):
        self.entries = []   # dicts
        for name, flavour, title, summary, file, listed, count in PACKS:
            stem = name + (f"_{flavour}" if flavour else "") + f"_{ISSUED[:7]}"
            e = dict(name=name, flavour=flavour, title=title, summary=summary, count=count, file=f"{stem}.zim", path=None)
            if file:
                e["path"] = root / file
                e["size"] = e["path"].stat().st_size
                data = e["path"].read_bytes()
                e["sha256"] = hashlib.sha256(data).hexdigest()
                e["pieces"] = [hashlib.sha1(data[i:i + PIECE]).hexdigest() for i in range(0, len(data), PIECE)]
            else:
                e["size"] = listed
            self.entries.append(e)

    def catalog(self, base: str) -> bytes:
        out = ['<?xml version="1.0" encoding="UTF-8"?>',
               '<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/">',
               "<title>Test catalog</title>"]
        for e in self.entries:
            out.append("<entry>")
            out.append(f"<title>{escape(e['title'])}</title>")
            out.append(f"<name>{e['name']}</name>")
            if e["flavour"]:
                out.append(f"<flavour>{e['flavour']}</flavour>")
            out.append(f"<summary>{escape(e['summary'])}</summary>")
            out.append(f"<articleCount>{e['count']}</articleCount>")
            out.append(f"<dc:issued>{ISSUED}T00:00:00Z</dc:issued>")
            out.append(f'<author><name>Test</name></author><publisher><name>Test</name></publisher>')
            out.append(f'<link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" '
                       f'href="{base}/zim/{e["file"]}.meta4" length="{e["size"]}"/>')
            out.append("</entry>")
        out.append("</feed>")
        return "\n".join(out).encode()

    def meta4(self, e, base: str) -> bytes:
        pieces = "".join(f"<hash>{h}</hash>" for h in e["pieces"])
        return (f'<?xml version="1.0" encoding="UTF-8"?><metalink xmlns="urn:ietf:params:xml:ns:metalink">'
                f'<file name="{e["file"]}"><size>{e["size"]}</size><hash type="sha-256">{e["sha256"]}</hash>'
                f'<pieces length="{PIECE}" type="sha-1">{pieces}</pieces>'
                f'<url>{base}/zim/{e["file"]}</url></file></metalink>').encode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fixtures")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--rate", type=int, default=0, help="bytes per second per download (0 = unthrottled)")
    ap.add_argument("--log", default="")
    ap.add_argument("--portfile", default="")
    args = ap.parse_args()
    fx = Fixture(Path(args.fixtures))
    logfile = open(args.log, "a", buffering=1) if args.log else None
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):
            if logfile:
                with lock:
                    logfile.write(f"{time.strftime('%H:%M:%S')} {self.command} {self.path} {self.headers.get('Range', '')}\n")

        def base(self):
            return f"http://127.0.0.1:{self.server.server_port}"

        def reply(self, code, body=b"", ctype="text/plain", extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            path = self.path.split("?")[0]
            try:
                if path == "/catalog/v2/entries":
                    return self.reply(200, fx.catalog(self.base()), "application/atom+xml")
                if path.startswith("/zim/"):
                    name = path[len("/zim/"):]
                    want_meta = name.endswith(".meta4")
                    name = name[:-len(".meta4")] if want_meta else name
                    e = next((x for x in fx.entries if x["file"] == name and x["path"]), None)
                    if not e:
                        return self.reply(404, b"not found")
                    if want_meta:
                        return self.reply(200, fx.meta4(e, self.base()), "application/metalink4+xml")
                    return self.send_file(e)
                self.reply(404, b"not found")
            except (BrokenPipeError, ConnectionResetError):
                pass

        def send_file(self, e):
            size = e["size"]
            start, end, code = 0, size - 1, 200
            rng = self.headers.get("Range", "")
            if rng.startswith("bytes="):
                a, _, b = rng[6:].partition("-")
                start = int(a) if a else 0
                end = min(int(b), size - 1) if b else size - 1
                code = 206
            length = end - start + 1
            self.send_response(code)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if code == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if self.command == "HEAD":
                return
            with open(e["path"], "rb") as f:
                f.seek(start)
                left = length
                block = 16384 if args.rate else 1 << 20
                while left > 0:
                    data = f.read(min(block, left))
                    self.wfile.write(data)
                    left -= len(data)
                    if args.rate:
                        time.sleep(len(data) / args.rate)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    if args.portfile:
        Path(args.portfile).write_text(str(server.server_port))
    print(server.server_port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
