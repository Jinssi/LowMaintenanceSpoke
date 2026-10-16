# Platform context: {{WORKLOAD}} / {{ENV}} Container Apps spoke

A hub-and-spoke landing zone spoke that hosts many small apps on one **internal** Azure Container Apps
environment, with Azure AI Foundry, all PaaS behind private endpoints. Subscription: `{{SUBSCRIPTION_ID}}`.

## Resource groups

| Resource group | Contents |
|---|---|
| `{{SPOKE_RG}}` | Spoke VNet, ACA environment + apps, ACR, Key Vault, Foundry, Log Analytics, App Insights, private DNS zones, alert rules |
| `{{HUB_RG}}` | Test hub (only in lab mode): VNet, Azure Firewall Basic, Bastion, jumpbox. Empty = platform-owned hub (not visible to the agents) |
| `{{SRE_RG}}` | The SRE agents themselves (do not modify) |

## Key resources

| Resource | Name / ID |
|---|---|
| Container Apps environment (internal, workload profiles) | `{{ACA_ENV}}` |
| Apps domain (`<app>.<domain>` resolves to the environment's internal IP via private DNS) | `{{APPS_DOMAIN}}` |
| Container registry (Premium, private endpoint, no admin user) | `{{ACR}}` |
| Key Vault (RBAC, private endpoint) | `{{KEY_VAULT}}` |
| Azure AI Foundry account (AIServices, private endpoint, Entra auth only) | `{{FOUNDRY}}` |
| App Gateway WAF_v2 (wildcard listener, optional) | `{{APP_GATEWAY}}` |
| Hub firewall (test hub only) | `{{FIREWALL}}` |
| Log Analytics workspace | `{{LAW_ID}}` (workspace ID `{{LAW_CUSTOMER_ID}}`) |
| Application Insights (apps) | App ID `{{APPI_APP_ID}}` |

## Network facts

- Spoke VNet `10.1.0.0/22`: `snet-aca` 10.1.0.0/23 (ACA, delegated), `snet-pep` 10.1.2.0/26 (private endpoints),
  `snet-sre-l1` 10.1.2.64/27 and `snet-sre-l2` 10.1.2.96/27 (SRE agents), `snet-agw` 10.1.3.0/24 (App Gateway).
- `0.0.0.0/0` from `snet-aca` and the SRE subnets goes to the hub firewall (UDR). Missing firewall rules are
  the most common cause of image-pull, token or telemetry failures.
- ACR, Key Vault and Foundry have **public network access disabled**: failures to reach them are almost
  always private DNS or private endpoint problems, not service outages.

## How apps are built

- Every app is one Container App from `apps/_shared/container-app.bicep`, with one shared user-assigned identity
  (AcrPull, Key Vault Secrets User, Azure AI User, Cognitive Services OpenAI User).
- Apps scale to zero by default (`minReplicas = 0`): a replica count of 0 alone is **not** an incident.
- Apps get env vars `AZURE_CLIENT_ID`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `KEY_VAULT_URI`,
  `FOUNDRY_PROJECT_ENDPOINT`, `AZURE_OPENAI_ENDPOINT`.
- Every app has three alert rules: `ar-{{WORKLOAD}}-{{ENV}}-app-<name>-http-5xx` (Sev2), `-cpu-high` (Sev3), `-memory-high` (Sev3).
- Changes to images, env vars, secrets and infrastructure go through IaC (`azd provision`, `scripts/deploy-app.ps1`).
  Agents never change them directly; they recommend the change instead.

## Useful queries

```kusto
// Container Apps platform events (restarts, probe failures, scaling)
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, ContainerAppName_s, RevisionName_s, Reason_s, Log_s
| order by TimeGenerated desc

// App stdout/stderr
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h) and ContainerAppName_s == "<app>"
| project TimeGenerated, RevisionName_s, Log_s

// Firewall denies from the spoke (test hub)
AZFWApplicationRule
| union AZFWNetworkRule
| where TimeGenerated > ago(1h) and Action == "Deny"
| summarize count() by SourceIp, Fqdn, DestinationIp, DestinationPort
```
