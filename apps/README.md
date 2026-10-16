# App slots

Every app in the spoke is one small `main.bicepparam` file that uses the shared module
[`_shared/container-app.bicep`](./_shared/container-app.bicep). Apps are deployed independently of the
platform and of each other.

## Add an app in 3 steps

```powershell
./scripts/new-app.ps1 -Name orders -Image <acr>.azurecr.io/orders:1.0.0 -Port 8080   # 1. scaffold
code apps/orders/main.bicepparam                                                      # 2. adjust (optional)
./scripts/deploy-app.ps1 -Name orders                                                  # 3. deploy
```

The app becomes reachable at `https://orders.<APPS_DOMAIN>` from the spoke, the hub (via the linked private DNS
zone) and, if enabled, through the App Gateway wildcard listener. You don't need to change the gateway.

## What every app gets automatically

| Feature | How |
|---|---|
| Image pull from the spoke ACR | Shared user-assigned identity (`AcrPull`) |
| Secrets | `keyVaultReferences = { DB_PASSWORD: 'db-password' }` → Key Vault reference, no secret values in code |
| Foundry access | `FOUNDRY_PROJECT_ENDPOINT`, `AZURE_OPENAI_ENDPOINT` + identity roles `Azure AI User` / `Cognitive Services OpenAI User` |
| Telemetry | `APPLICATIONINSIGHTS_CONNECTION_STRING` |
| Identity for SDKs | `AZURE_CLIENT_ID` (use `DefaultAzureCredential` / `ManagedIdentityCredential`) |
| Scale to zero | `minReplicas = 0`, HTTP concurrency scaling |
| Alerts (worked by the SRE agents) | `http-5xx` (Sev2, `http5xxThreshold`), `cpu-high` and `memory-high` (Sev3); disable with `enableAlerts = false` |

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `name` | – | DNS label, 2–32 chars |
| `image` | – | `mcr.microsoft.com/...` or `<acr>.azurecr.io/...` |
| `targetPort` | `80` | Container port |
| `cpu` / `memory` | `0.5` / `1Gi` | Valid pairs: 0.25/0.5Gi, 0.5/1Gi, 1/2Gi, 2/4Gi |
| `minReplicas` / `maxReplicas` | `0` / `3` | |
| `exposure` | `vnet` | `environment` = only other apps can call it |
| `healthPath` | `''` | Adds liveness/readiness probes |
| `env` | `{}` | Plain env vars |
| `keyVaultReferences` | `{}` | `{ ENV_VAR: 'kv-secret-name' }` |
| `useFoundry` | `true` | Inject Foundry endpoints |

## Pushing images to the private ACR

The registry has no public access. Push from a build agent in the hub or spoke VNet (or the test hub jumpbox):

```bash
az acr login --name <acr-name>
docker push <acr-name>.azurecr.io/orders:1.0.0
```
