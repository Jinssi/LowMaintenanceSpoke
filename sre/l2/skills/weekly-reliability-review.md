# Weekly reliability review (L2)

Look back 7 days across `{{SPOKE_RG}}` and `{{HUB_RG}}`.

1. **Incidents.** All Sev0/Sev1 tickets and every `[ESCALATE-L2]` ticket: cause, time to accept, time to mitigate, and whether the fix
   was manual (drift) or IaC.
2. **Recurring causes.** Group by cause (app bug, capacity, dependency, network/DNS, platform). Anything that recurred
   twice or more needs a permanent fix.
3. **Drift.** Compare the scale/size settings of each container app with `apps/<app>/main.bicepparam` defaults.
   List mismatches left behind by manual remediation.
4. **Capacity.** ACA environment cores quota trend, Foundry throttling trend, firewall SNAT trend.
5. **Agent effectiveness.** Tickets closed by L1 vs escalated, escalations that turned out to be noise, and approvals
   that were denied (the agent proposed the wrong action).

Output: top 5 actions, each with owner (app team / platform / SRE), file or parameter to change, and expected benefit.
Read-only: don't change alert states or resources.
