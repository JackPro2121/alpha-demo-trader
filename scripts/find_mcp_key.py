"""Discover the live MetaTrader5 MCP bearer key from terminal64 memory / config.

Fresh installs may not expose a GUI-readable key. Strategies, in order:
  1. Probe a known key we pre-seeded into assistant.ini (server loads at start).
  2. Scan terminal64 process memory for base64url-like candidates (ASCII + UTF-16LE).
  3. Parse every assistant.ini ApiKey hex and try common deobfuscations.
Prints the working key to stdout; exits 0 on success, 1 on failure.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import ctypes
import ctypes.wintypes as wt
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
MEM_COMMIT = 0x1000
PAGE_GUARD = 0x100
PAGE_NOACCESS = 0x01
READABLE_PROTECT = {0x02, 0x04, 0x08, 0x20, 0x40}

CAND_RE = re.compile(rb"(?<![A-Za-z0-9_-])([A-Za-z0-9_-]{40,64})(?![A-Za-z0-9_-])")

INIT_BODY = json.dumps(
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "mcp-key-probe", "version": "0"},
        },
    }
).encode()


class MEMORY_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BaseAddress", ctypes.c_void_p),
        ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wt.DWORD),
        ("RegionSize", ctypes.c_size_t),
        ("State", wt.DWORD),
        ("Protect", wt.DWORD),
        ("Type", wt.DWORD),
    ]


def _looks_like_key(s: str) -> bool:
    if not (40 <= len(s) <= 64):
        return False
    if not re.fullmatch(r"[A-Za-z0-9_-]+", s):
        return False
    # prefer mixed entropy but allow pure base64url of known GUI length
    if len(s) in (41, 42, 43, 44):
        return True
    if any(c.isupper() for c in s) and any(c.islower() for c in s) and any(
        c.isdigit() for c in s
    ):
        return True
    return False


def _iter_pids() -> list[int]:
    th32 = ctypes.WinDLL("kernel32", use_last_error=True)
    TH32CS_SNAPPROCESS = 0x00000002

    class PROCESSENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", wt.DWORD),
            ("cntUsage", wt.DWORD),
            ("th32ProcessID", wt.DWORD),
            ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
            ("th32ModuleID", wt.DWORD),
            ("cntThreads", wt.DWORD),
            ("th32ParentProcessID", wt.DWORD),
            ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", wt.DWORD),
            ("szExeFile", ctypes.c_char * 260),
        ]

    snap = th32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap in (None, ctypes.c_void_p(-1 & 0xFFFFFFFFFFFFFFFF), -1):
        import subprocess

        out = subprocess.check_output(
            ["tasklist", "/FI", "IMAGENAME eq terminal64.exe"], text=True
        )
        pids = []
        for line in out.splitlines():
            parts = line.split()
            if parts and parts[0].lower() == "terminal64.exe":
                pids.append(int(parts[1]))
        return pids

    entry = PROCESSENTRY32()
    entry.dwSize = ctypes.sizeof(PROCESSENTRY32)
    pids: list[int] = []
    if th32.Process32First(snap, ctypes.byref(entry)):
        while True:
            name = entry.szExeFile.decode("ascii", "ignore").lower()
            if name == "terminal64.exe":
                pids.append(entry.th32ProcessID)
            if not th32.Process32Next(snap, ctypes.byref(entry)):
                break
    th32.CloseHandle(snap)
    return pids


def _collect_from_bytes(data: bytes, found: list[str], seen: set[str], limit: int) -> None:
    for m in CAND_RE.finditer(data):
        s = m.group(1).decode("ascii", "ignore")
        if _looks_like_key(s) and s not in seen:
            seen.add(s)
            found.append(s)
            if len(found) >= limit:
                return
    # UTF-16LE candidates
    try:
        text = data.decode("utf-16le", "ignore")
    except Exception:
        return
    for m in re.finditer(r"(?<![A-Za-z0-9_-])([A-Za-z0-9_-]{40,64})(?![A-Za-z0-9_-])", text):
        s = m.group(1)
        if _looks_like_key(s) and s not in seen:
            seen.add(s)
            found.append(s)
            if len(found) >= limit:
                return


def scan_memory(max_candidates: int = 400) -> list[str]:
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    pids = _iter_pids()
    if not pids:
        raise RuntimeError("terminal64.exe not running")

    found: list[str] = []
    seen: set[str] = set()
    mbi = MEMORY_BASIC_INFORMATION()
    mbi_len = ctypes.sizeof(mbi)

    for pid in pids:
        h = k32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
        if not h:
            continue
        try:
            addr = 0
            while True:
                rc = k32.VirtualQueryEx(
                    h, ctypes.c_void_p(addr), ctypes.byref(mbi), mbi_len
                )
                if not rc:
                    break
                region_size = mbi.RegionSize
                if (
                    mbi.State == MEM_COMMIT
                    and mbi.Protect not in (PAGE_GUARD, PAGE_NOACCESS)
                    and (mbi.Protect & 0xFF) in READABLE_PROTECT
                    and 0 < region_size <= 64 * 1024 * 1024
                ):
                    buf = (ctypes.c_char * region_size)()
                    n = ctypes.c_size_t(0)
                    ok = k32.ReadProcessMemory(
                        h, ctypes.c_void_p(addr), buf, region_size, ctypes.byref(n)
                    )
                    if ok and n.value:
                        _collect_from_bytes(bytes(buf[: n.value]), found, seen, max_candidates)
                        if len(found) >= max_candidates:
                            return found
                addr = addr + region_size
                if addr >= 0x7FFFFFFFFFFFFFFF:
                    break
        finally:
            k32.CloseHandle(h)
    return found


def _deobfuscate_hex(hx: str) -> list[str]:
    out: list[str] = []
    try:
        raw = bytes.fromhex(hx)
    except ValueError:
        return out
    # raw ascii if printable
    if all(32 <= c < 127 for c in raw):
        out.append(raw.decode("ascii"))
    # utf-16le / be if even length
    if len(raw) % 2 == 0:
        for enc in ("utf-16le", "utf-16be"):
            try:
                s = raw.decode(enc)
                if s.isprintable() and _looks_like_key(s):
                    out.append(s)
            except UnicodeError:
                pass
    # base64url of first 32/48 bytes
    for n in (31, 32, 48, 64):
        if len(raw) >= n:
            s = base64.urlsafe_b64encode(raw[:n]).decode().rstrip("=")
            if _looks_like_key(s):
                out.append(s)
    # single-byte xor then base64
    for k in (0xFF, 0x55, 0xAA, 0x00):
        x = bytes(c ^ k for c in raw[:32]) if len(raw) >= 32 else b""
        if x:
            s = base64.urlsafe_b64encode(x).decode().rstrip("=")
            if _looks_like_key(s):
                out.append(s)
    return out


def config_keys() -> list[str]:
    keys: list[str] = []
    roots = [
        Path(r"C:\Program Files\MetaTrader 5\Config"),
        Path.home() / r"AppData\Roaming\MetaQuotes\Terminal",
        Path.home() / r"AppData\Local\MetaQuotes\Terminal",
    ]
    files: list[Path] = []
    for r in roots:
        if r.is_file():
            files.append(r)
        elif r.is_dir():
            files.extend(r.rglob("assistant.ini"))
    for f in files:
        try:
            raw = f.read_text(encoding="utf-16", errors="ignore")
        except OSError:
            continue
        for m in re.finditer(r"(?im)^\s*ApiKey\s*=\s*([0-9a-fA-F]{32,256})\s*$", raw):
            keys.extend(_deobfuscate_hex(m.group(1)))
        # plaintext ApiKey
        for m in re.finditer(r"(?im)^\s*ApiKey\s*=\s*([A-Za-z0-9_-]{40,64})\s*$", raw):
            keys.append(m.group(1))
    # unique preserve order
    seen: set[str] = set()
    out: list[str] = []
    for k in keys:
        if k not in seen:
            seen.add(k)
            out.append(k)
    return out


def probe(url: str, key: str, timeout: float = 5.0) -> int | None:
    req = urllib.request.Request(
        url,
        data=INIT_BODY,
        method="POST",
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Connection": "close",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:22346/mcp")
    ap.add_argument("--wait", type=int, default=180)
    ap.add_argument("--rescan", type=int, default=8)
    ap.add_argument(
        "--seed-key",
        default="",
        help="known pre-seeded key to try first (never logged)",
    )
    args = ap.parse_args()

    deadline = time.time() + args.wait
    tried: set[str] = set()
    last_status: list[int] = []
    round_i = 0

    if args.seed_key:
        tried.add(args.seed_key)
        st = probe(args.url, args.seed_key)
        if st is not None:
            last_status.append(st)
        if st == 200:
            print(args.seed_key)
            return 0
        print(f"seed probe status={st}", file=sys.stderr)

    while time.time() < deadline:
        round_i += 1
        cands: list[str] = []
        try:
            cands.extend(config_keys())
        except Exception as e:
            print(f"config scan error: {e}", file=sys.stderr)
        try:
            cands.extend(scan_memory())
        except Exception as e:
            print(f"mem scan error: {e}", file=sys.stderr)

        new = [c for c in cands if c not in tried]
        if not new and round_i % 3 == 1:
            print(
                f"round {round_i}: {len(cands)} cand(s), 0 new, waiting...",
                file=sys.stderr,
            )
        for key in new:
            tried.add(key)
            status = probe(args.url, key)
            if status is not None:
                last_status.append(status)
            if status == 200:
                print(key)
                return 0
        if last_status:
            print(
                f"round {round_i}: tried={len(tried)} statuses={sorted(set(last_status))}",
                file=sys.stderr,
            )
        time.sleep(args.rescan)

    print(
        f"fail: tried={len(tried)} statuses={sorted(set(last_status))} after {args.wait}s",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
