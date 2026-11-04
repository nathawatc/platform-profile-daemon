#!/usr/bin/env python3
"""Turn a dbus-monitor pcap into the parser test corpus in src/dbus/testdata/.

The corpus holds real messages written by encoders other than ours (sd-bus via
busctl, GDBus via the fake Polkit responder, dbus-daemon itself) plus the
daemon's own replies and signals, so the parser tests are not only checked
against our own writer. Run manually when the protocol surface changes and
commit the result:

    CAPTURE_PCAP=/tmp/ppd.pcap unshare --user --map-root-user \\
        python3 tools/dbus-isolated-smoke.py
    python3 tools/capture-corpus.py /tmp/ppd.pcap

`--verify` (no pcap) re-checks what is committed: every .bin parses, the audit
below passes, and frames.zig is exactly what this script would generate. CI
runs it, so a hand edit or a stale frames.zig fails.

The audit keeps a capture from leaking its machine into the repository: header
names and paths must come from a short allowlist, and text in message bodies
must not look like a home directory, a temp path, or the user or host name.
Unique bus names (:1.N) and serials vary between captures, so regenerating
always produces a diff; review it with `--verify` and `git diff --stat`.

Expected kind/serial/member/signature in the generated frames.zig come from the
independent header parser below, not from the Zig code under test.
"""

import os
import re
import socket
import struct
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "src/dbus/testdata"
DLT_DBUS = 231
MAX_FRAME = 4096
KINDS = {1: "call", 2: "return", 3: "error", 4: "signal"}
FIELDS = {
    1: "path",
    2: "interface",
    3: "member",
    4: "error",
    5: "reply_serial",
    6: "destination",
    7: "sender",
    8: "signature",
}


STRING_FIELDS = ("path", "interface", "destination", "sender", "error")
ALLOWED = {
    "path": re.compile(
        r"/org/freedesktop/(DBus|UPower/PowerProfiles|PolicyKit1/Authority)"
    ),
    "interface": re.compile(
        r"org\.freedesktop\.(DBus(\.(Properties|Introspectable|Peer))?"
        r"|UPower\.PowerProfiles|PolicyKit1\.Authority)"
    ),
    "destination": re.compile(
        r"org\.freedesktop\.(DBus|UPower\.PowerProfiles|PolicyKit1)|:1\.\d+"
    ),
    "error": re.compile(r"org\.freedesktop\.(DBus\.Error|PolicyKit1\.Error)\.\w+"),
}
ALLOWED["sender"] = ALLOWED["destination"]
# Text that must never appear in a body: paths of the capturing machine.
BODY_DENY = re.compile(r"/home/|/run/user|/tmp/|/root|/var/")
TEXT_RUN = re.compile(rb"[ -~]{4,}")


def private_words():
    """The capturing user and host names, if long enough to be meaningful."""
    words = {os.environ.get("USER", ""), socket.gethostname()}
    return {w for w in words if len(w) >= 3}


def audit(name, info, msg):
    """Raises SystemExit if the frame carries anything outside the allowlist."""
    for field in STRING_FIELDS:
        value = info["fields"].get(field)
        if value is not None and not ALLOWED[field].fullmatch(value):
            raise SystemExit(f"{name}: unexpected {field} {value!r}")
    body = msg[align(16 + info["fields_len"], 8) :]
    for run in TEXT_RUN.findall(body):
        text = run.decode()
        if BODY_DENY.search(text) or any(w in text for w in private_words()):
            raise SystemExit(f"{name}: body text looks private: {text!r}")


def read_pcap(data):
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian = "<"
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian = ">"
    else:
        raise SystemExit("not a classic pcap file")
    (linktype,) = struct.unpack_from(endian + "I", data, 20)
    if linktype != DLT_DBUS:
        raise SystemExit(f"link type {linktype} is not DLT_DBUS ({DLT_DBUS})")
    off = 24
    while off + 16 <= len(data):
        _, _, incl, _ = struct.unpack_from(endian + "IIII", data, off)
        off += 16
        if off + incl > len(data):
            break  # truncated final record
        yield data[off : off + incl]
        off += incl


def align(n, a):
    return (n + a - 1) // a * a


def parse_header(msg):
    """Minimal independent D-Bus header parser (little-endian only)."""
    if msg[:1] != b"l":
        return None
    kind, version = msg[1], msg[3]
    body_len, serial, fields_len = struct.unpack_from("<III", msg, 4)
    if version != 1 or serial == 0 or kind not in KINDS:
        return None
    if align(16 + fields_len, 8) + body_len != len(msg):
        return None
    info = {
        "kind": kind,
        "serial": serial,
        "member": "",
        "sig": "",
        "fields": {},
        "fields_len": fields_len,
    }
    pos, end = 16, 16 + fields_len
    while pos < end:
        pos = align(pos, 8)
        code, sig_len = msg[pos], msg[pos + 1]
        vsig = msg[pos + 2 : pos + 2 + sig_len].decode()
        pos += 2 + sig_len + 1
        if vsig in ("s", "o"):
            pos = align(pos, 4)
            (n,) = struct.unpack_from("<I", msg, pos)
            value = msg[pos + 4 : pos + 4 + n].decode()
            pos += 4 + n + 1
        elif vsig == "g":
            n = msg[pos]
            value = msg[pos + 1 : pos + 1 + n].decode()
            pos += 1 + n + 1
        elif vsig == "u":
            pos = align(pos, 4)
            (value,) = struct.unpack_from("<I", msg, pos)
            pos += 4
        else:
            return None
        if code in FIELDS:
            info["fields"][FIELDS[code]] = value
        if FIELDS.get(code) == "member":
            info["member"] = value
        elif FIELDS.get(code) == "signature":
            info["sig"] = value
    return info


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "none"


def frame_name(info):
    return (
        f"{KINDS[info['kind']]}-{slug(info['member'] or 'reply')}-{slug(info['sig'])}"
    )


def render_frames(entries):
    lines = [
        "//! Generated by tools/capture-corpus.py from a dbus-monitor capture.",
        "//! Do not edit by hand. Expected values come from an independent parser.",
        "",
        "pub const Frame = struct {",
        "    name: []const u8,",
        "    bytes: []const u8,",
        "    kind: u8,",
        "    serial: u32,",
        "    member: []const u8,",
        "    sig: []const u8,",
        "};",
        "",
        "pub const frames = [_]Frame{",
    ]
    for name, info in entries:
        lines += [
            "    .{",
            f'        .name = "{name}",',
            f'        .bytes = @embedFile("{name}.bin"),',
            f"        .kind = {info['kind']},",
            f"        .serial = {info['serial']},",
            f'        .member = "{info["member"]}",',
            f'        .sig = "{info["sig"]}",',
            "    },",
        ]
    lines += ["};", ""]
    return "\n".join(lines)


def verify():
    """Checks the committed corpus against this script; exits non-zero on drift."""
    files = {p.name: p for p in OUT.glob("*.bin")}
    if not files:
        raise SystemExit("no committed frames in src/dbus/testdata")
    entries = []
    for fname in sorted(files):
        msg = files[fname].read_bytes()
        info = parse_header(msg)
        if info is None:
            raise SystemExit(f"{fname}: not a well-formed little-endian message")
        name = frame_name(info)
        if fname != f"{name}.bin":
            raise SystemExit(f"{fname}: should be named {name}.bin")
        audit(name, info, msg)
        entries.append((name, info))
    entries.sort(key=lambda e: (e[1]["kind"], e[1]["member"], e[1]["sig"]))
    if (OUT / "frames.zig").read_text() != render_frames(entries):
        raise SystemExit("frames.zig does not match the .bin files; regenerate it")
    print(f"corpus ok: {len(entries)} frames")


def main():
    if sys.argv[1:] == ["--verify"]:
        return verify()
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    chosen = {}
    for msg in read_pcap(Path(sys.argv[1]).read_bytes()):
        info = parse_header(msg)
        if info is None or len(msg) > MAX_FRAME:
            continue
        # One representative per message shape.
        key = (info["kind"], info["member"], info["sig"])
        chosen.setdefault(key, (msg, info))
    if not chosen:
        raise SystemExit("no usable messages in the capture")

    entries = []
    for key in sorted(chosen):
        msg, info = chosen[key]
        name = frame_name(info)
        audit(name, info, msg)
        entries.append((name, info))

    # Only touch the tree once every frame passed the audit.
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.bin"):
        old.unlink()
    for name, _ in entries:
        key = next(k for k, (_, i) in chosen.items() if frame_name(i) == name)
        (OUT / f"{name}.bin").write_bytes(chosen[key][0])
    (OUT / "frames.zig").write_text(render_frames(entries))
    print(f"wrote {len(entries)} frames to {OUT}")
    for name, _ in entries:
        print(" ", name)


if __name__ == "__main__":
    main()
