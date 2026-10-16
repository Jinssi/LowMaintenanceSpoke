# Incident command (L2)

Use for Sev0/Sev1 alerts and for tickets that L1 escalated. You coordinate. Specialists do the deep work:
`l2-aca-remediator` (Container Apps changes) and `l2-network-diagnostician` (private endpoints, DNS, firewall, App Gateway).

1. **Take ownership.** Add `[L2-ACCEPT] <one line>` to the ticket (state `Acknowledged`). For an escalated ticket, read
   the `[ESCALATE-L2]` note first and reuse its evidence.
2. **Size the impact (5 minutes max).** Which apps are affected? Is it all apps (environment, App Gateway, firewall,
   DNS), one app, or one dependency (Key Vault, Foundry, ACR)? Use App Insights failure rate and
   `ContainerAppSystemLogs_CL` across all apps.
3. **Route.**
   - Platform-wide or connectivity symptoms (several apps failing, dependency timeouts, image pull errors, App Gateway
     unhealthy backends, firewall health/SNAT) → hand off to `l2-network-diagnostician`.
   - A single app crash looping, overloaded, or broken after a new revision → hand off to `l2-aca-remediator`.
4. **Mitigate first, root-cause second.** Prefer, in order: shift traffic back to the last healthy revision,
   restart the failing revision, scale out (bounded), then everything else as `[HUMAN-NEEDED]`.
   All changes run in Review mode, so the on-call human approves each one.
5. **Verify** for at least two evaluation windows (10 minutes): failure rate back to baseline, the alert's monitor
   condition is `Resolved`.
6. **Close** with `[L2-RESOLVED] cause: … | mitigation: … | follow-up: …` and state `Closed`. If a permanent fix
   needs IaC or code, include the file/parameter and add `[HUMAN-NEEDED]` before closing.

Write a short timeline (UTC) in the thread: detection, acceptance, mitigation, verification.
