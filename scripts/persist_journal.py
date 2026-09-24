"""Persist or restore durable watcher state in the private data-store."""

import argparse
import datetime as dt
import glob
import os
import shutil
import subprocess
import sys

STORE = os.environ.get("STORE_DIR", "../alpha-data-store")
TOKEN = os.environ.get("ALPHA_PERSIST_TOKEN", "")
SRC_FILES = (
    (os.path.join("data-runtime", "platform.db"), "journal/platform_*.db", "platform.db"),
    (os.path.join("data-runtime", "decision_ledger.jsonl"), "journal/ledger_*.jsonl", "decision_ledger.jsonl"),
    (os.path.join("data-runtime", "journal.csv"), "journal/journal_*.csv", "journal.csv"),
    (os.path.join("data-runtime", "cost_samples.json"), "journal/cost_samples_*.json", "cost_samples.json"),
)


def _git(*args, cwd=STORE):
    env = os.environ.copy()
    if TOKEN:
        import base64
        b64 = base64.b64encode(f"JackPro2121:{TOKEN}".encode()).decode()
        env["GIT_HTTP_EXTRAHEADER"] = ""
        args = ("-c", f"http.extraheader=AUTHORIZATION: basic {b64}", *args)
    return subprocess.run(["git", *args], cwd=cwd, env=env,
                          capture_output=True, text=True)


def _latest(pattern: str) -> str | None:
    paths = glob.glob(os.path.join(STORE, pattern))
    return max(paths, key=os.path.basename) if paths else None


def restore() -> int:
    if not os.path.isdir(STORE):
        print("restore failed: data-store missing")
        return 1
    os.makedirs("data-runtime", exist_ok=True)
    restored = []
    for _src, pattern, destination in SRC_FILES:
        source = _latest(pattern)
        if not source:
            continue
        try:
            shutil.copy2(source, os.path.join("data-runtime", destination))
        except OSError as exc:
            print(f"restore failed for {destination}: {exc}")
            return 1
        restored.append(destination)
    print("restored:", ", ".join(restored) if restored else "no prior state")
    return 0


def persist() -> int:
    if not TOKEN or not os.path.isdir(STORE):
        print("persist failed: token/store missing")
        return 1
    os.makedirs(os.path.join(STORE, "journal"), exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    copied = []
    for source, pattern, _destination in SRC_FILES:
        if not os.path.exists(source):
            continue
        suffix = os.path.splitext(source)[1]
        prefix = os.path.basename(source).rsplit(".", 1)[0]
        stored = os.path.join(STORE, "journal", f"{prefix}_{stamp}{suffix}")
        try:
            shutil.copy2(source, stored)
        except OSError as exc:
            print(f"copy failed for {source}: {exc}")
            return 1
        copied.append(os.path.relpath(stored, STORE))
    if not copied:
        print("nothing to persist")
        return 0
    _git("add", "-A")
    _git("config", "user.email", "alpha-demo-trader@users.noreply.github.com")
    _git("config", "user.name", "alpha-demo-trader")
    commit = _git("commit", "-m", f"journal snapshot {stamp}")
    if commit.returncode != 0 and "nothing to commit" not in commit.stdout:
        print("commit failed:", commit.stderr[:200])
        return 1
    push = _git("push", "origin", "main")
    if push.returncode != 0:
        print("push failed:", push.stderr[:200])
        return 1
    print("persisted:", ", ".join(copied))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    return restore() if args.restore else persist()


if __name__ == "__main__":
    sys.exit(main())
