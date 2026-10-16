# Container app health check (read-only)

Inputs: app name, time window (default: fired time − 60 min … now). Resource group `{{SPOKE_RG}}`.

1. **Configuration and revisions**
   ```bash
   az containerapp show -g {{SPOKE_RG}} -n <app> --query "{image:properties.template.containers[0].image, min:properties.template.scale.minReplicas, max:properties.template.scale.maxReplicas, cpu:properties.template.containers[0].resources.cpu, mem:properties.template.containers[0].resources.memory, latest:properties.latestRevisionName, ready:properties.latestReadyRevisionName}"
   az containerapp revision list -g {{SPOKE_RG}} -n <app> --query "[].{name:name, active:properties.active, traffic:properties.trafficWeight, replicas:properties.replicas, health:properties.healthState, created:properties.createdTime}" -o table
   ```
   `latest != ready` means the newest revision failed to provision; that's a deployment problem.
2. **Platform events.** In Log Analytics workspace `{{LAW_CUSTOMER_ID}}`:
   ```kusto
   ContainerAppSystemLogs_CL
   | where TimeGenerated between (datetime(<start>) .. datetime(<end>)) and ContainerAppName_s == "<app>"
   | summarize count() by Reason_s, RevisionName_s, bin(TimeGenerated, 5m)
   ```
   Look for `BackOff`, `ProbeFailed`, `ContainerTerminated` (OOMKilled shows up in `Log_s`), image pull errors.
3. **App output.** `ContainerAppConsoleLogs_CL` for the same window: the first error after the start of the incident matters most.
4. **Requests and dependencies.** In App Insights (app ID `{{APPI_APP_ID}}`):
   ```kusto
   requests | where timestamp > ago(2h) and cloud_RoleName =~ "<app>"
   | summarize total=count(), failed=countif(success == false), p95=percentile(duration, 95) by bin(timestamp, 5m)
   dependencies | where timestamp > ago(2h) and cloud_RoleName =~ "<app>" and success == false
   | summarize count() by target, resultCode, type
   ```
   Failed dependencies to `*.vault.azure.net`, `*.azurecr.io`, `*.openai.azure.com` or `*.services.ai.azure.com`
   usually point to private DNS or private endpoint problems, so mention it in the escalation.
5. **Metrics.** `Requests` (statusCodeCategory), `CpuPercentage`, `MemoryPercentage`, `Replicas`, `RestartCount` (cumulative; look at the delta).

Summarize as: *symptom → likely cause → evidence → recommended action → confidence*.
