# Known noise and threshold guidance

Use this to decide whether an alert is noise, and to feed the weekly noise review.

| Alert | Usually noise when | Usually real when |
|---|---|---|
| `app-*-http-5xx` | A single burst under 2 minutes during a revision rollout, and later requests succeed | It persists across two 5-minute windows, or failures share one dependency |
| `app-*-cpu-high` / `memory-high` | A scheduled batch or cold start; `Replicas` scales out and the metric drops | Memory grows steadily (leak), or CPU stays high at `maxReplicas` |
| `kv-saturation` | Short spikes during deployments that read many secrets | Sustained above 75% with 429s in App Insights dependencies |
| `foundry-throttling` | Isolated bursts; clients retry and succeed | Sustained 429s that cause user-facing errors, so the deployment needs more capacity (IaC change: `foundryModelDeployments[].sku.capacity`) |
| `resource-health` | `Degraded` that ends within 5 minutes with an Azure-initiated reason | `Unavailable`, or several resources at once |
| `aca-env-cores-quota` | Brief during a mass scale-out | Above 80% for more than an hour. Then request a quota increase or reduce `maxReplicas` |

Thresholds live in IaC:
- Platform rules: `infra/modules/alerts.bicep`
- Per-app rules: `apps/_shared/container-app.bicep` (`http5xxThreshold` can be set per app in `apps/<name>/main.bicepparam`)

Never edit alert rules directly. Propose the change in the weekly noise review instead.
