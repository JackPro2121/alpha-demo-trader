"""Commit the watcher journal DB + decision ledger to the private
data-store repo so decisions survive runner restarts (6h job cap).

Runs inside the workflow; env STORE_DIR points at the checked-out
alpha-data-store clone. Fail-soft: a persistence hiccup must never
affect trading (trades live at the broker anyway).
"""

import datetime as dt
import os
import subprocess
import sys

STORE = os.environ.get("STORE_DIR", "../alpha-data-store")
TOKEN = os.environ.get("ALPHA_PERSIST_TOKEN", "")
SRC_DB = os.path.join("data-runtime", "platform.db")
SRC_LEDGER = os.path.join("data-runtime", "decision_ledger.jsonl")


def _git(*args, cwd=STORE):
    env = os.environ.copy()
    if TOKEN:
        b64 = __import__("base64").b64encode(
            f"JackPro2121:{TOKEN}".encode()).decode()
        env["GIT_HTTP_EXTRAHEADER"] = ""
        args = ("-c", f"http.extraheader=AUTHORIZATION: basic {b64}", *args)
    return subprocess.run(["git", *args], cwd=cwd, env=env,
                          capture_output=True, text=True)


def main() -> int:
    if not TOKEN or not os.path.isdir(STORE):
        print("persist skipped (no token/store)")
        return 0
    os.makedirs(os.path.join(STORE, "journal"), exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    copied = []
    for src, dst in ((SRC_DB, f"journal/platform_{stamp}.db"),
                     (SRC_LEDGER, f"journal/ledger_{stamp}.jsonl")):
        if os.path.exists(src):
            import shutil
            shutil.copy2(src, os.path.join(STORE, dst))
            copied.append(dst)
    if not copied:
        print("nothing to persist")
        return 0
    _git("add", "-A")
    commit = _git("commit", "-m", f"journal snapshot {stamp}")
    if commit.returncode != 0 and "nothing to commit" not in commit.stdout:
        print("commit failed:", commit.stderr[:200])
        return 0
    push = _git("push", "origin", "main")
    print("pushed" if push.returncode == 0
          else f"push failed: {push.stderr[:200]}")
    print("persisted:", ", ".join(copied))
    return 0


if __name__ == "__main__":
    sys.exit(main())
