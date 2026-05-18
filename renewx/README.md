# shell

One-shot management scripts for Linux servers. Run as `root`.

## renewx.sh — MS365 E5 RenewX deployer

One-shot deploy of `gladtbam/ms365_e5_renewx`. `Config.xml` is embedded in the script — no extra files needed.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Leovikii/shell/main/renewx/renewx.sh)
```

Requires Docker (install via `sm.sh` first). Choose menu **[1]** to deploy — you'll be prompted to set the admin password interactively (no default password is shipped).

Data lives at `/opt/renewx/`. Container listens on `127.0.0.1:1066` — put a reverse proxy in front for external access (remember to forward `Host` and `X-Forwarded-Proto` headers).
