# Container Apps remediation (L2, approval required)

Allowed changes (enforced by the guard hook and Container Apps Contributor RBAC on `{{SPOKE_RG}}` only):

| Action | Command | When |
|---|---|---|
| Restart a revision | `az containerapp revision restart -g {{SPOKE_RG}} -n <app> --revision <revision>` | Crash loop or hung replicas with a healthy image |
| Roll back traffic | `az containerapp ingress traffic set -g {{SPOKE_RG}} -n <app> --revision-weight <previousRevision>=100` | New revision is failing and the previous one was healthy (multiple-revision mode) |
| Activate a previous revision | `az containerapp revision activate -g {{SPOKE_RG}} -n <app> --revision <revision>` | Needed before shifting traffic back |
| Deactivate a bad revision | `az containerapp revision deactivate -g {{SPOKE_RG}} -n <app> --revision <revision>` | After traffic is moved away |
| Scale | `az containerapp update -g {{SPOKE_RG}} -n <app> --min-replicas <n> --max-replicas <m>` | Sustained CPU/memory or concurrency saturation at `maxReplicas` |
| Resize | `az containerapp update -g {{SPOKE_RG}} -n <app> --cpu <c> --memory <m>` | OOMKilled or CPU throttling. Use valid pairs only (0.25/0.5Gi, 0.5/1Gi, 1/2Gi, 2/4Gi) |

Rules:
1. Before any change, capture the current state (`az containerapp show`, `revision list`) in the thread.
2. Propose one change at a time with: command, expected effect, risk, and rollback command.
3. Scaling is bounded: never more than 2× the current `maxReplicas` and never above 30. Never set `minReplicas` above 3.
4. Manual changes **drift from IaC**. After mitigation, add `[HUMAN-NEEDED] update apps/<app>/main.bicepparam:
   <param> = <value>`. Otherwise the next `deploy-app.ps1` reverts the fix.
5. Image, env var, secret, registry or ingress changes aren't allowed. Recommend them instead.
6. After the change, verify for 10 minutes and add `[L2-ACTION] <command> → <result>` to the ticket.
