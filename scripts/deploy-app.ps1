<#
.SYNOPSIS
  Deploys (or updates) one app slot from apps/<Name>/main.bicepparam into the spoke.

.DESCRIPTION
  Loads platform values from the current azd environment (written by `azd provision`)
  and deploys the app into the spoke resource group. Apps are independent: deploying one
  never touches the platform or other apps.

.EXAMPLE
  ./scripts/deploy-app.ps1 -Name hello
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$paramFile = Join-Path $root "apps/$Name/main.bicepparam"
if (-not (Test-Path $paramFile)) { throw "App '$Name' not found: $paramFile (create it with scripts/new-app.ps1)" }

# Export azd environment values (WORKLOAD_NAME, ENVIRONMENT_NAME, SPOKE_RESOURCE_GROUP, ...) for readEnvironmentVariable().
$values = azd env get-values --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the azd environment. Run `azd provision` first.' }
$values.PSObject.Properties | ForEach-Object { Set-Item -Path "env:$($_.Name)" -Value $_.Value }

if (-not $env:SPOKE_RESOURCE_GROUP) { throw 'SPOKE_RESOURCE_GROUP missing from azd environment. Run `azd provision` first.' }
if ($env:AZURE_SUBSCRIPTION_ID) { az account set --subscription $env:AZURE_SUBSCRIPTION_ID | Out-Null }

Write-Host "Deploying app '$Name' to $env:SPOKE_RESOURCE_GROUP ..."
$fqdn = az deployment group create `
    --resource-group $env:SPOKE_RESOURCE_GROUP `
    --name "app-$Name" `
    --parameters $paramFile `
    --query properties.outputs.fqdn.value --output tsv
if ($LASTEXITCODE -ne 0) { throw "Deployment of '$Name' failed." }

Write-Host "App '$Name' deployed: https://$fqdn" -ForegroundColor Green
if ($env:APP_GATEWAY_IP) { Write-Host "Via App Gateway: point $Name.$env:APPS_DOMAIN at $env:APP_GATEWAY_IP" }
