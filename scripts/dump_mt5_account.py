"""Dump full MCP get_trading_account_info for runner diagnostics.

Prints one JSON object to stdout (and optionally writes --out).
Exit 0 always if MCP reachable; exit 2 if MCP unreachable.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

INIT = json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"protocolVersion": "2025-06-18", "capabilities": {},
               "clientInfo": {"name": "acct-dump", "version": "1"}},
}).encode()


def _http(url: str, body: bytes, headers: dict, timeout: float = 10.0):
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
    except Exception as e:  # noqa: BLE001
        return None, {}, str(e).encode()


def mcp_call(url: str, token: str, name: str, args: dict | None = None) -> dict:
    h = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {token}",
    }
    st, hdrs, _ = _http(url, INIT, h)
    if st != 200:
        return {"error": f"initialize status={st}"}
    sid = hdrs.get("Mcp-Session-Id") or hdrs.get("mcp-session-id")
    if sid:
        h["Mcp-Session-Id"] = sid
    _http(url, json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}).encode(), h)
    body = json.dumps({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": name, "arguments": args or {}},
    }).encode()
    st, _, raw = _http(url, body, h, timeout=20.0)
    if st != 200:
        return {"error": f"tools/call status={st}", "raw": raw[:500].decode("utf-8", "replace")}
    try:
        data = json.loads(raw)
    except Exception:
        return {"error": "bad json", "raw": raw[:500].decode("utf-8", "replace")}
    texts = []
    for c in data.get("result", {}).get("content", []) or []:
        if c.get("type") == "text":
            texts.append(c.get("text", ""))
        elif c.get("type") == "json":
            texts.append(json.dumps(c.get("json")))
    joined = "\n".join(texts)
    try:
        return json.loads(joined)
    except Exception:
        return {"text": joined[:4000], "isError": data.get("result", {}).get("isError")}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:22346/mcp")
    ap.add_argument("--token", default=os.environ.get("MCP_TOKEN") or os.environ.get("MT5_MCP_TOKEN", ""))
    ap.add_argument("--out", default="")
    ap.add_argument("--wait", type=int, default=0, help="seconds to wait for MCP up")
    ap.add_argument("--expect-login", default=os.environ.get("MT5_LOGIN", ""))
    ap.add_argument("--expect-server", default=os.environ.get("MT5_SERVER", ""))
    args = ap.parse_args()

    token = (args.token or "").strip()
    if not token:
        print(json.dumps({"error": "no token", "env_has_mcp": bool(os.environ.get("MCP_TOKEN")),
                          "env_has_secret": bool(os.environ.get("MT5_MCP_TOKEN"))}))
        return 2

    deadline = time.time() + max(0, args.wait)
    result = {"error": "not attempted"}
    while True:
        result = mcp_call(args.url, token, "get_trading_account_info", {})
        if "error" not in result or result.get("text") or result.get("account"):
            break
        if time.time() >= deadline:
            break
        time.sleep(2)

    # normalize nested account
    acct = result.get("account") if isinstance(result.get("account"), dict) else result
    summary = {
        "login": acct.get("login") if isinstance(acct, dict) else None,
        "server": acct.get("server") if isinstance(acct, dict) else None,
        "type": acct.get("type") if isinstance(acct, dict) else None,
        "balance": acct.get("balance") if isinstance(acct, dict) else None,
        "name": acct.get("name") if isinstance(acct, dict) else None,
        "server_connected": (result.get("terminal") or {}).get("server_connected")
            if isinstance(result.get("terminal"), dict) else None,
        "mcp_trade_allowed": (result.get("terminal") or {}).get("mcp_trade_allowed")
            if isinstance(result.get("terminal"), dict) else None,
        "error": result.get("error"),
    }
    expect_login = str(args.expect_login).strip()
    expect_server = str(args.expect_server).strip()
    login_ok = (not expect_login) or (str(summary.get("login")) == expect_login)
    server_ok = (not expect_server) or (str(summary.get("server")) == expect_server)
    type_raw = str(summary.get("type") or "").lower()
    type_ok = any(k in type_raw for k in ("demo", "trial", "contest", "practice"))
    connected_raw = summary.get("server_connected")
    trade_allowed_raw = summary.get("mcp_trade_allowed")
    connected_ok = connected_raw is True or str(connected_raw).lower() in {"true", "1"}
    trade_allowed_ok = trade_allowed_raw is True or str(trade_allowed_raw).lower() in {"true", "1"}
    summary["login_ok"] = login_ok
    summary["server_ok"] = server_ok
    summary["type_ok"] = type_ok
    summary["connected_ok"] = connected_ok
    summary["trade_allowed_ok"] = trade_allowed_ok
    summary["ready_for_demo_trading"] = bool(
        login_ok and server_ok and type_ok and connected_ok and trade_allowed_ok
    )

    payload = {"summary": summary, "raw": result}
    text = json.dumps(payload, indent=2, default=str)
    print(text)
    if args.out:
        try:
            os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
            with open(args.out, "w", encoding="utf-8") as f:
                f.write(text)
        except OSError as e:
            print(f"write out failed: {e}", file=sys.stderr)

    if result.get("error") and not summary.get("login"):
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
