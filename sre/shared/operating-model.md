# Operating model: Azure Monitor is the ticketing system

This spoke uses **Azure Monitor alerts as tickets**. There is no other ticketing tool.

| Ticket concept | Azure Monitor equivalent |
|---|---|
| Ticket | Fired alert instance (`Microsoft.AlertsManagement/alerts/<alertId>`) |
| Priority | Alert severity (Sev0 critical … Sev4 verbose) |
| Status | Alert state: `New` (unowned) → `Acknowledged` (owned / in progress) → `Closed` (resolved) |
| Work notes | Comment attached to every state change (visible in the alert's *History* tab) |
| Assignment | Severity-based response plan: Sev0–Sev1 → **L2 responder**, Sev2–Sev4 → **L1 triage** |
| Escalation | L1 adds an `[ESCALATE-L2]` note; the L2 escalation sweep picks it up |

## Who owns what

| Agent | Agent name | Owns | Can change |
|---|---|---|---|
| L1 triage | `{{L1_AGENT}}` | Sev2, Sev3, Sev4 | Alert state + notes only |
| L2 responder | `{{L2_AGENT}}` | Sev0, Sev1, and anything L1 escalates | Container Apps (restart, scale, traffic) after human approval, alert state + notes |
| Humans (on-call) | action group `{{ACTION_GROUP}}` | Approvals, Sev0/Sev1 e-mail, anything the agents cannot fix | Everything |

## Note tags (always start a comment with exactly one tag)

| Tag | Used by | Meaning |
|---|---|---|
| `[L1-TRIAGE]` | L1 | Investigation summary, ticket stays open |
| `[L1-CLOSE]` | L1 | Resolved, self-healed or false positive; ticket closed |
| `[ESCALATE-L2]` | L1 | Needs a change or deeper investigation; leave Acknowledged |
| `[L2-ACCEPT]` | L2 | L2 took ownership of an escalated ticket |
| `[L2-ACTION]` | L2 | A change was proposed or executed (include the exact command) |
| `[L2-RESOLVED]` | L2 | Mitigated and verified; ticket closed |
| `[HUMAN-NEEDED]` | L1/L2 | Out of the agent's authority; on-call must act |

## How to change state with a note

```bash
az rest --method post \
  --url "https://management.azure.com/subscriptions/{{SUBSCRIPTION_ID}}/providers/Microsoft.AlertsManagement/alerts/<alertId>/changestate?api-version=2019-05-05-preview&newState=Acknowledged" \
  --body '{"comments": "[ESCALATE-L2] <one-line summary> | evidence: <query/metric> | suggested action: <action>"}'
```

`newState` is one of `New`, `Acknowledged`, `Closed`. Keep comments under 1,000 characters, without secrets or connection strings.

## How to read the queue

```bash
# Open tickets in the spoke (add &severity=Sev2 etc. to filter)
az rest --method get --url "https://management.azure.com/subscriptions/{{SUBSCRIPTION_ID}}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&targetResourceGroup={{SPOKE_RG}}&alertState=Acknowledged&timeRange=1d"

# Notes / state history of one ticket
az rest --method get --url "https://management.azure.com/subscriptions/{{SUBSCRIPTION_ID}}/providers/Microsoft.AlertsManagement/alerts/<alertId>/history?api-version=2019-05-05-preview"
```
