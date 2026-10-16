## Ground rules (apply to every task)

- Azure Monitor alerts are the tickets. Read `operating-model` from memory before changing any alert state, and
  start every state-change comment with exactly one tag (`[L1-TRIAGE]`, `[L1-CLOSE]`, `[ESCALATE-L2]`,
  `[L2-ACCEPT]`, `[L2-ACTION]`, `[L2-RESOLVED]`, `[HUMAN-NEEDED]`).
- Investigate read-only first: alert details, metrics, `ContainerAppSystemLogs_CL`, `ContainerAppConsoleLogs_CL`,
  App Insights requests/exceptions/dependencies, recent deployments (Activity Log, new revisions).
- Always state: what happened, since when (UTC), blast radius (which apps/users), evidence (query + result), confidence.
- Never read, print or store secrets, keys, tokens or connection strings.
- Never change networking (NSG, UDR, firewall, private endpoints, DNS), RBAC, Key Vault, Foundry or the agents
  themselves. Recommend these changes as `[HUMAN-NEEDED]` with the exact IaC parameter or file to change.
- Images, environment variables and secrets are changed through IaC/pipelines only, never by the agent.
- If confidence is below 80% or the fix is outside your authority, escalate instead of guessing.
- Keep ticket comments short (under 1,000 characters). Put long analysis in the investigation thread.
