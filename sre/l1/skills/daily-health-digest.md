# Daily health digest (read-only)

Produce a short report for the last 24 hours (UTC) for resource groups `{{SPOKE_RG}}` and `{{HUB_RG}}`.

1. **Tickets.** List alerts fired in the last 24h (`az rest` → `.../providers/Microsoft.AlertsManagement/alerts?...&timeRange=1d`),
   grouped by severity and state. Highlight tickets still `New` (nobody picked them up) and any `[HUMAN-NEEDED]` notes.
2. **Apps.** For each container app in `{{SPOKE_RG}}`: requests, failure rate, p95 latency (App Insights),
   restarts (`ContainerAppSystemLogs_CL`), and whether the latest revision is ready.
3. **Platform.** ACA environment cores quota, Key Vault availability, Foundry server errors/throttling,
   App Gateway healthy hosts (if deployed), hub firewall health/SNAT (if deployed).
4. **Changes.** Activity Log write operations in `{{SPOKE_RG}}` (who/what), plus new revisions.

Output format:

```
Health digest {{WORKLOAD}}/{{ENV}} – <date>
Status: 🟢 / 🟡 / 🔴  (one line why)
Tickets: Sev0 x · Sev1 x · Sev2 x · Sev3 x · Sev4 x   (open: x, escalated: x, human-needed: x)
Top issues: 1) … 2) … 3) …
Apps needing attention: …
Changes: …
```

Don't change any alert state while producing the digest.
