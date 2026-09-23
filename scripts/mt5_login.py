"""Force a broker login on the running MT5 terminal via the MetaTrader5 package.

Reads MT5_LOGIN / MT5_PASSWORD / MT5_SERVER from the environment.
Writes a one-line status to stdout:
  LOGIN_OK login=... server=... type=demo balance=...
  LOGIN_FAIL code=... reason=...
Exit 0 on success, 1 on auth fail, 2 on no package/terminal.
Optionally dumps MCP account after login when MCP_TOKEN is set.
"""
from __future__ import annotations

import json
import os
import sys


def main() -> int:
    login = int(os.environ.get("MT5_LOGIN") or "0")
    password = os.environ.get("MT5_PASSWORD") or ""
    server = os.environ.get("MT5_SERVER") or ""
    path = os.environ.get("MT5_PATH") or ""
    if not login or not password or not server:
        print("LOGIN_FAIL code=missing-env reason=MT5_LOGIN/PASSWORD/SERVER required")
        return 2

    try:
        import MetaTrader5 as mt5
    except Exception as e:  # noqa: BLE001
        print(f"LOGIN_FAIL code=no-package reason={e}")
        return 2

    kwargs = {"login": login, "password": password, "server": server, "timeout": 60000}
    if path and os.path.exists(path):
        kwargs["path"] = path
    try:
        ok = mt5.initialize(**kwargs)
    except Exception as e:  # noqa: BLE001
        print(f"LOGIN_FAIL code=exception reason={e}")
        return 1

    if not ok:
        err = mt5.last_error()
        print(f"LOGIN_FAIL code={err[0] if isinstance(err, tuple) else err} reason={err}")
        mt5.shutdown()
        return 1

    # explicit login (initialize may only attach if already authorized)
    try:
        if not mt5.login(login=login, password=password, server=server):
            err = mt5.last_error()
            print(f"LOGIN_FAIL code={err[0] if isinstance(err, tuple) else err} reason={err}")
            mt5.shutdown()
            return 1
    except Exception as e:  # noqa: BLE001
        print(f"LOGIN_FAIL code=login-exception reason={e}")
        mt5.shutdown()
        return 1

    ai = mt5.account_info()
    if ai is None:
        err = mt5.last_error()
        print(f"LOGIN_FAIL code=no-account reason={err}")
        mt5.shutdown()
        return 1

    mode = {0: "demo", 1: "contest", 2: "real"}.get(int(ai.trade_mode), str(ai.trade_mode))
    print(f"LOGIN_OK login={ai.login} server={ai.server} type={mode} balance={ai.balance}")

    # leave terminal logged in; shutdown only detaches the IPC client
    mt5.shutdown()

    # best-effort MCP dump for artifacts
    token = os.environ.get("MCP_TOKEN") or os.environ.get("MT5_MCP_TOKEN") or ""
    if token:
        os.environ["MCP_TOKEN"] = token
        out = os.environ.get("MT5_ACCOUNT_JSON_OUT", "")
        try:
            import subprocess
            script = os.path.join(os.path.dirname(__file__), "dump_mt5_account.py")
            cmd = [sys.executable, script, "--token", token]
            if out:
                cmd += ["--out", out]
            subprocess.run(cmd, timeout=60, check=False)
        except Exception as e:  # noqa: BLE001
            print(f"mcp dump skipped: {e}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
