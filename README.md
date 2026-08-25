# alpha-demo-trader

**24/7 demo trading pump on GitHub Actions (Windows runners, public repo =
free unlimited minutes).** Trades execute on the Exness **DEMO** account
via the MetaTrader5 python package (credentials auto-login, no GUI needed).

## Architecture

```
schedule (5x/day) or manual dispatch
  -> windows runner: install MT5 (silent) + python deps
  -> clone ALPHA engine (private repo, PAT) + this repo's scripts
  -> watcher loop ~5.25h: 7 pairs H1 analysis -> committee -> risk gates
     -> REAL demo orders -> position manage -> Slack alerts
  -> journal DB + decision ledger committed to private alpha-data-store
  (job ends under 6h cap; next scheduled run resumes; broker-side SL/TP
   protect positions in between; reconciliation re-syncs on start)
```

## Required repo secrets (Settings -> Secrets -> Actions)

| Secret | Value |
|---|---|
| `MT5_LOGIN` | demo login (e.g. 198721722) |
| `MT5_PASSWORD` | demo password |
| `MT5_SERVER` | `Exness-MT5Trial11` |
| `ALFA_REPO_TOKEN` | classic PAT with `repo` scope that can READ the private ALPHAFOREX repo (JackPro2121 must be a collaborator on it) |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook (alerts) — optional but recommended |

## Run

Actions -> `demo-trader` -> Run workflow:
- first ever run: `once = true` (probe: install + login + one cycle)
- then full runs: `once = false`

## Honest limits

- Demo only. The engine's own research verdicts are REJECT so far — this
  runner exists to test MACHINERY and accumulate proof-clock evidence,
  not to claim profits.
- 6h job cap -> jobs chain via schedule; positions are protected by
  broker-side SL/TP between jobs and re-synced on start.
- Runner IPs rotate; Exness demo tolerates this, live would not.
