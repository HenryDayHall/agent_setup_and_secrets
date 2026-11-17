# agentbox: Goose in a sealed Apptainer box on Maxwell

Files for the "Goose in a sealed Apptainer box on Maxwell" tutorial. Copy each one into
`$AB` (`/data/dust/user/$USER/agentbox`) as the tutorial describes; don't symlink, so a
`git pull` never changes a script that handles your keys without you reviewing it.

| File | Copy to | Runs | Tutorial section |
|---|---|---|---|
| `agentbox.def` | `$AB/agentbox.def` | build time | 1.3 image definition |
| `Caddyfile` | `$AB/Caddyfile` | host | 1.4 key proxy config (no secrets) |
| `goose/config.yaml` | `$AB/home/.config/goose/` | box | 1.5 Goose settings |
| `goose/.goosehints` | `$AB/home/.config/goose/` | box | 1.5 global hints: keep tool output short |
| `goose/custom_providers/*.json` | `$AB/home/.config/goose/custom_providers/` | box | 1.5 DESY and Blablador providers |
| `start` | `$AB/start` (755) | box | 1.6 seal check, then Goose |
| `agentbox` | `$AB/agentbox` (755) | host | 1.6 launcher |
| `agentbox-job` | `$AB/agentbox-job` (755) | Slurm job | 4 batch runs; set `<partition>` |
| `netproxy.py` | `$AB/netproxy.py` | host | 5 optional HTTPS allowlist proxy |

The keys themselves are stored with `../secret.sh`.
