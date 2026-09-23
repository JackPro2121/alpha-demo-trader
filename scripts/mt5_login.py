"""Authenticate the configured MT5 account through the Python integration.

Exit 0 only for the expected account on an allowed virtual-account mode.
"""
from __future__ import annotations

import os
import sys
import time


def _error_code(error: object) -> object:
    if isinstance(error, (tuple, list)) and error:
        return error[0]
    return error


def _initialize(mt5, path: str, login: int, password: str, server: str, portable: bool):
    common = {"timeout": 60000}
    if path and os.path.exists(path):
        common["path"] = path
    if portable:
        common["portable"] = True
    first_error = None
    try:
        if mt5.initialize(**common):
            return True, None
        first_error = mt5.last_error()
    except Exception as exc:
        first_error = exc
    try:
        mt5.shutdown()
    except Exception:
        pass
    time.sleep(2)
    direct = dict(common)
    direct.update({"login": login, "password": password, "server": server, "timeout": 120000})
    try:
        if mt5.initialize(**direct):
            return True, first_error
    except Exception as exc:
        first_error = exc
    return False, mt5.last_error() if first_error is None else first_error


def main() -> int:
    raw_login = os.environ.get("MT5_LOGIN") or ""
    try:
        login = int(raw_login)
    except ValueError:
        print("LOGIN_FAIL code=invalid-login reason=MT5_LOGIN must be numeric")
        return 2
    password = os.environ.get("MT5_PASSWORD") or ""
    server = (os.environ.get("MT5_SERVER") or "").strip()
    path = os.environ.get("MT5_PATH") or ""
    portable = (os.environ.get("MT5_PORTABLE") or "true").lower() not in {"0", "false", "no", "off"}
    if not login or not password or not server:
        print("LOGIN_FAIL code=missing-env reason=MT5_LOGIN/PASSWORD/SERVER required")
        return 2

    try:
        import MetaTrader5 as mt5
    except Exception as exc:
        print(f"LOGIN_FAIL code=no-package reason={exc}")
        return 2

    initialized, error = _initialize(mt5, path, login, password, server, portable)
    if not initialized:
        print(f"LOGIN_FAIL code={_error_code(error)} reason={error}")
        try:
            mt5.shutdown()
        except Exception:
            pass
        return 1

    try:
        if not mt5.login(login=login, password=password, server=server, timeout=60000):
            error = mt5.last_error()
            print(f"LOGIN_FAIL code={_error_code(error)} reason={error}")
            return 1
    except Exception as exc:
        print(f"LOGIN_FAIL code=login-exception reason={exc}")
        return 1

    account = mt5.account_info()
    if account is None:
        error = mt5.last_error()
        print(f"LOGIN_FAIL code=no-account reason={error}")
        return 1

    actual_login = getattr(account, "login", None)
    actual_server = str(getattr(account, "server", "") or "").strip()
    trade_mode = getattr(account, "trade_mode", None)
    mode = {0: "demo", 1: "contest", 2: "real"}.get(trade_mode, str(trade_mode))
    if str(actual_login) != str(login):
        print(f"LOGIN_FAIL code=wrong-login reason=expected configured account, got {actual_login}")
        return 1
    if actual_server != server:
        print(f"LOGIN_FAIL code=wrong-server reason=expected configured server, got {actual_server}")
        return 1
    if mode not in {"demo", "contest"}:
        print(f"LOGIN_FAIL code=unsafe-type reason=trade_mode={mode}")
        return 1

    print(f"LOGIN_OK login=verified server={actual_server} type={mode} balance={getattr(account, 'balance', 'unknown')}")
    try:
        mt5.shutdown()
    except Exception:
        pass

    token = os.environ.get("MCP_TOKEN") or os.environ.get("MT5_MCP_TOKEN") or ""
    if token:
        os.environ["MCP_TOKEN"] = token
        output = os.environ.get("MT5_ACCOUNT_JSON_OUT", "")
        try:
            import subprocess
            script = os.path.join(os.path.dirname(__file__), "dump_mt5_account.py")
            command = [sys.executable, script, "--out", output] if output else [sys.executable, script]
            subprocess.run(command, timeout=60, check=False)
        except Exception as exc:
            print(f"mcp dump skipped: {exc}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
