# Triage an Azure Monitor alert (L1)

Use this for every Sev2–Sev4 alert routed to you. Target: decision within 15 minutes.

1. **Read the ticket.** Alert rule, severity, fired time (UTC), target resource, monitor condition (Fired/Resolved),
   and the ticket history (`operating-model` → "How to read the queue"). If an `[L1-TRIAGE]` note from the last
   hour already exists for the same rule and resource, add to it rather than starting over.
2. **Classify the signal.**
   - `ar-*-app-<name>-http-5xx`, `-cpu-high`, `-memory-high` → use `container-app-health-check` for `<name>`.
   - `ar-*-aca-replica-crashloop` (Sev1 normally; L2 owns it) – only touch it if L2 escalated it back to you.
   - `ar-*-kv-*`, `ar-*-foundry-*` → check the service metrics plus caller errors in App Insights dependencies.
   - `ar-*-agw-backend-5xx` → find which host (`<app>.{{APPS_DOMAIN}}`) produces the 5xx, then treat it as that app.
   - `ar-*-afw-snat`, `ar-*-aca-env-cores-quota` → capacity: report current value, trend over 24h, and the top consumers.
   - `ar-*-resource-health`, `ar-*-service-health` → read the Resource/Service Health event and identify impacted apps.
3. **Correlate.** Look for changes in the 2 hours before the fire time: new revisions
   (`az containerapp revision list -g {{SPOKE_RG}} -n <app> -o table`), Activity Log writes, and other alerts that fired at the same time.
4. **Decide one outcome.**

   | Situation | Action |
   |---|---|
   | Monitor condition is Resolved, metrics are back to baseline, no user impact | Close with `[L1-CLOSE] self-healed: <evidence>` |
   | Known noise or a threshold that is too tight (see `known-noise-and-thresholds`) | Close with `[L1-CLOSE] noise: <why>`, add to the weekly noise review |
   | Real issue, no change needed yet (degradation is stable and low impact) | Keep Acknowledged with `[L1-TRIAGE] <summary>` |
   | Needs a restart, scale, traffic shift or rollback | Keep Acknowledged with `[ESCALATE-L2] <summary> \| evidence \| suggested action` |
   | Needs IaC, network, RBAC, secret or image change | `[HUMAN-NEEDED] <what and where>` and also `[ESCALATE-L2]` if users are impacted |

5. **Write the note** using the alert state command in `operating-model`. One tag per comment. No secrets.
