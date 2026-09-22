"""Discover the live MetaTrader5 MCP bearer key from terminal64 memory.

Fresh installs regenerate the key; assistant.ini only holds an obfuscated
hex blob that the MCP server does not accept. The running terminal keeps the
plaintext key for inbound Bearer checks — scan committed readable pages for
base64url-like candidates and probe http://127.0.0.1:22346/mcp until HTTP 200.

Prints the working key to stdout (single line) and exits 0; exits 1 on failure.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import re
import sys
import time
import urllib.error
import urllib.request

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
MEM_COMMIT = 0x1000
PAGE_GUARD = 0x100
PAGE_NOACCESS = 0x01
READABLE_PROTECT = {0x02, 0x04, 0x08, 0x20, 0x40}

CAND_RE = re.compile(rb"(?<![A-Za-z0-9_-])([A-Za-z0-9_-]{40,44})(?![A-Za-z0-9_-])")

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
    if not (40 <= len(s) <= 44):
        return False
    if not any(c.isupper() for c in s):
        return False
    if not any(c.islower() for c in s):
        return False
    if not any(c.isdigit() for c in s):
        return False
    return True


def _iter_pids() -> list[int]:
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    th32 = ctypes.WinDLL("kernel32", use_last_error=True)
    # CreateToolhelp32Snapshot via kernel32
    TH32CS_SNAPPROCESS = 0x00000002
    INVALID = ctypes.c_void_p(-1 & 0xFFFFFFFFFFFFFFFF)

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
    if snap == INVALID or snap is None:
        # fallback: tasklist via os
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


def scan_memory(max_candidates: int = 80) -> list[str]:
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
                    and region_size > 0
                    and region_size <= 64 * 1024 * 1024
                ):
                    buf = (ctypes.c_char * region_size)()
                    n = ctypes.c_size_t(0)
                    ok = k32.ReadProcessMemory(
                        h,
                        ctypes.c_void_p(addr),
                        buf,
                        region_size,
                        ctypes.byref(n),
                    )
                    if ok and n.value:
                        data = bytes(buf[: n.value])
                        for m in CAND_RE.finditer(data):
                            s = m.group(1).decode("ascii", "ignore")
                            if _looks_like_key(s) and s not in seen:
                                seen.add(s)
                                found.append(s)
                                if len(found) >= max_candidates:
                                    return found
                addr = addr + region_size
                if addr >= 0x7FFFFFFFFFFFFFFF:
                    break
        finally:
            k32.CloseHandle(h)
    return found


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
    ap.add_argument("--wait", type=int, default=180, help="seconds to wait for port+auth")
    ap.add_argument("--rescan", type=int, default=8, help="memory rescan interval (s)")
    args = ap.parse_args()

    deadline = time.time() + args.wait
    tried: set[str] = set()
    round_i = 0
    last_status: list[int] = []

    while time.time() < deadline:
        round_i += 1
        try:
            cands = scan_memory()
        except Exception as e:
            print(f"scan error: {e}", file=sys.stderr)
            cands = []

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
            uniq = sorted(set(last_status))
            print(
                f"round {round_i}: tried={len(tried)} statuses={uniq}",
                file=sys.stderr,
            )
        time.sleep(args.rescan)

    print(
        f"fail: tried={len(tried)} statuses={sorted(set(last_status))} "
        f"after {args.wait}s",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
