# Escalation sweep (L2)

The queue L1 hands over lives in Azure Monitor. Run this sweep on schedule.

1. List open tickets from the last 24h in `{{SPOKE_RG}}` (and `{{HUB_RG}}` when set):
   ```bash
   az rest --method get --url "https://management.azure.com/subscriptions/{{SUBSCRIPTION_ID}}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&targetResourceGroup={{SPOKE_RG}}&alertState=Acknowledged&timeRange=1d"
   ```
2. For each ticket, read its history (`.../alerts/<alertId>/history?api-version=2019-05-05-preview`).
   It's **yours** when the latest tagged comment is `[ESCALATE-L2]` and there's no later `[L2-ACCEPT]`.
3. Order your tickets by severity, then age. For each one, add `[L2-ACCEPT]` and run the `incident-command` skill.
4. Also flag tickets in state `New` older than 15 minutes, because no agent picked them up (check that response plans
   are enabled), and `[HUMAN-NEEDED]` tickets older than 4 hours without a later note.

If there's nothing to do, reply with one line: `Escalation sweep: no pending escalations.` Don't create noise.
