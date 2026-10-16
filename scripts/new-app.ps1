<#
.SYNOPSIS
  Scaffolds a new app slot: apps/<Name>/main.bicepparam.

.EXAMPLE
  ./scripts/new-app.ps1 -Name orders -Image crlowmaintdevabcde.azurecr.io/orders:1.0.0 -Port 8080
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-z][a-z0-9-]{1,31}$')] [string] $Name,
    [string] $Image = 'mcr.microsoft.com/k8se/quickstart:latest',
    [int] $Port = 80,
    [switch] $NoFoundry
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dir = Join-Path $root "apps/$Name"
if (Test-Path $dir) { throw "apps/$Name already exists." }
New-Item -ItemType Directory -Path $dir | Out-Null

$useFoundry = if ($NoFoundry) { 'false' } else { 'true' }
@"
using '../_shared/container-app.bicep'

// Platform identity (set automatically by scripts/deploy-app.ps1 from the azd environment).
param workloadName = readEnvironmentVariable('WORKLOAD_NAME', 'lowmaint')
param environmentName = readEnvironmentVariable('ENVIRONMENT_NAME', 'dev')

param name = '$Name'
param image = '$Image'
param targetPort = $Port
param cpu = '0.5'
param memory = '1Gi'
param minReplicas = 0
param maxReplicas = 3
param exposure = 'vnet'
param useFoundry = $useFoundry

param env = {}

// Key Vault secret references: { ENV_VAR: 'secret-name' }
param keyVaultReferences = {}
"@ | Set-Content -Path (Join-Path $dir 'main.bicepparam') -Encoding utf8

Write-Host "Created apps/$Name/main.bicepparam. Deploy with: ./scripts/deploy-app.ps1 -Name $Name" -ForegroundColor Green
