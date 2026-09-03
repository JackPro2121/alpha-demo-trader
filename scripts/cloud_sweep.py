"""Cloud parity sweep driver for GitHub Actions.

Runs full 72-combo grid, walk-forward screen, and out-of-sample holdout gate
in the cloud VM. Writes rich Markdown to $GITHUB_STEP_SUMMARY.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Cloud Parity Sweep")
    parser.add_argument("--symbol", default="GBPUSD")
    parser.add_argument("--timeframe", default="H1")
    parser.add_argument("--holdout", default="2025-06-01")
    parser.add_argument("--dual-mode", default="true")
    args = parser.parse_args()

    symbol = args.symbol.strip().upper()
    timeframe = args.timeframe.strip()
    holdout_date = args.holdout.strip()
    use_dm = str(args.dual_mode).lower() in ("true", "1", "yes")

    t0 = time.time()
    print("=" * 70, flush=True)
    print(f"CLOUD PARITY SWEEP: {symbol} {timeframe} (Dual-Mode: {use_dm})", flush=True)
    print(f"Holdout boundary: {holdout_date}", flush=True)
    print("=" * 70, flush=True)

    import forexgpt3
    from forexgpt3.config import load_config
    from forexgpt2.data.market import MarketData
    from forexgpt3.services.parity import edge_sweep_parity

    cfg = load_config()
    v2 = dataclasses.replace(
        cfg.v2,
        universe=dataclasses.replace(cfg.v2.universe, target=symbol, timeframe=timeframe),
        technical=dataclasses.replace(cfg.v2.technical, dual_mode=use_dm)
    )
    cfg_run = dataclasses.replace(cfg, v2=v2)

    print(f"Fetching market data for {symbol} {timeframe}...", flush=True)
    df = MarketData(v2).target()
    print(f"Loaded {len(df)} bars ({df.index[0]} to {df.index[-1]})", flush=True)

    # Attach measured spread profile if available
    profile_path = Path("../../alpha-data-store") / f"profile_{symbol}.json"
    if profile_path.is_file():
        try:
            with open(profile_path, encoding="utf-8") as f:
                prof_data = json.load(f)
            hourly_spread = prof_data.get("hourly_median_spread", {})
            if hourly_spread:
                arr = [float(hourly_spread[str(h)]) for h in range(24)]
                cfg_run = dataclasses.replace(
                    cfg_run,
                    v2=dataclasses.replace(
                        cfg_run.v2,
                        backtest=dataclasses.replace(cfg_run.v2.backtest, spread_by_hour=arr)
                    )
                )
                print(f"Attached measured hourly spread profile from {profile_path}", flush=True)
        except Exception as exc:
            print(f"Could not load spread profile: {exc}", flush=True)

    # Step 1: Run 72-combo grid on train set
    print("\n[Stage 1/2] Computing parity grid on train set...", flush=True)
    res_grid = edge_sweep_parity(df, cfg_run, holdout_date=holdout_date, stage="grid")
    rows = res_grid.get("rows", [])
    pos_combos = sum(1 for r in rows if r["pnl"] > 0)
    best = rows[0] if rows else {}
    print(f"Grid finished! Best train PnL: ${best.get('pnl', 0):.2f} (PF {best.get('pf', 0):.3f}, {best.get('trades', 0)} trades)", flush=True)
    print(f"Positive combos: {pos_combos} / {len(rows)}", flush=True)

    # Step 2: Finalize (WF screening + Holdout Gate)
    print("\n[Stage 2/2] Running Walk-Forward screening and Holdout Gate...", flush=True)
    res = edge_sweep_parity(df, cfg_run, holdout_date=holdout_date, stage="finalize")

    promoted = res.get("promoted", [])
    screened = res.get("screened", [])
    elapsed = time.time() - t0

    print("\n" + "=" * 70, flush=True)
    print(f"SWEEP COMPLETE in {elapsed:.1f}s — Promoted: {len(promoted)}", flush=True)
    print("=" * 70, flush=True)

    # Build Markdown Summary for GitHub Step Summary
    md_lines = [
        f"## 📊 Alpha Parity Sweep Results: {symbol} ({timeframe})",
        f"- **Dual-Mode Technical:** `{use_dm}`",
        f"- **Data Range:** `{df.index[0].strftime('%Y-%m-%d')}` to `{df.index[-1].strftime('%Y-%m-%d')}` ({len(df)} bars)",
        f"- **Holdout Boundary:** `{holdout_date}`",
        f"- **Execution Time:** `{elapsed:.1f}s`",
        f"- **Verdict:** `{'🟢 PROMOTED' if promoted else '🔴 REJECT'}`",
        "",
        "### 🎯 In-Train Grid Summary",
        f"- **Best Train PnL:** `${best.get('pnl', 0):.2f}` (PF: `{best.get('pf', 0):.3f}`, `{best.get('trades', 0)}` trades, WR: `{best.get('win_rate', 0)*100:.1f}%`)",
        f"- **Positive Parameter Combos:** `{pos_combos} / {len(rows)}` ({pos_combos / max(1, len(rows))*100:.1f}%)",
        "",
        "### 🔍 Top Screened Geometries (Walk-Forward + Untouched Holdout)",
        "| # | Parameters (Thresh/ADX/SL/TP/Regime) | Train PnL | WF Screen | Holdout PnL | Holdout Trades | Holdout WR | Wilson LB vs BE | DSR | Status |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]

    for idx, r in enumerate(screened):
        p = r.get("params", {})
        param_str = f"T{p.get('threshold')}/ADX{int(p.get('adx_min', 0))}/SL{p.get('atr_sl')}/TP{p.get('atr_tp')}/R{p.get('regime_gate')}"
        train_pnl = f"${r.get('pnl', 0):.2f}"
        wf_str = f"{r.get('wf_pos', 0)}/{r.get('wf_wins', 0)} (${r.get('wf_pnl', 0):.0f})"
        ho_pnl = f"${r.get('ho_pnl', 0):.2f}"
        ho_trades = f"{r.get('ho_trades', 0)}"
        ho_wr = f"{r.get('ho_win_rate', 0)*100:.1f}%" if r.get('ho_win_rate') is not None else "N/A"
        wilson = f"{r.get('ho_wilson_lower', 0):.3f} vs {r.get('ho_breakeven', 0):.3f}" if r.get('ho_wilson_lower') is not None else "N/A"
        dsr = f"{r.get('ho_dsr', 0):.4f}"
        status = "✅ PROMOTED" if r.get("ho_passes") else "❌ REJECT"
        md_lines.append(f"| {idx+1} | `{param_str}` | {train_pnl} | {wf_str} | {ho_pnl} | {ho_trades} | {ho_wr} | {wilson} | {dsr} | {status} |")

    md_content = "\n".join(md_lines)
    print("\n" + md_content)

    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        try:
            with open(step_summary, "a", encoding="utf-8") as f:
                f.write(md_content + "\n")
            print("\nWrote summary to $GITHUB_STEP_SUMMARY")
        except Exception as exc:
            print(f"Failed to write GITHUB_STEP_SUMMARY: {exc}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
