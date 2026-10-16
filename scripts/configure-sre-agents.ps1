<#
.SYNOPSIS
  Applies the data-plane configuration of the L1 and L2 Azure SRE Agents from the sre/ folder.

.DESCRIPTION
  ARM (infra/main.bicep) creates the agents, identities, RBAC, connectors and the Azure Monitor incident platform.
  Everything else lives in the agent's data plane and is applied here, idempotently:
    knowledge (operating model, platform context) -> skills -> custom agents (with skill-level guard hooks)
    -> response plans (incident filters by severity) -> scheduled tasks.

  Runs automatically as the azd `postprovision` hook. Values come from the azd environment
  (outputs of infra/main.bicep). Re-run any time after editing files under sre/.

  Data-plane calls need a token for https://azuresre.dev. If that fails, run:
    az login --scope "https://azuresre.dev/.default"

.PARAMETER DryRun
  Render every payload to -OutputPath without calling Azure. Useful for reviews and CI.

.EXAMPLE
  ./scripts/configure-sre-agents.ps1
  ./scripts/configure-sre-agents.ps1 -Tier l2
  ./scripts/configure-sre-agents.ps1 -DryRun -OutputPath ./.sre-preview
#>
[CmdletBinding()]
param(
    [ValidateSet('l1', 'l2', 'all')] [string] $Tier = 'all',
    [switch] $DryRun,
    [string] $OutputPath = (Join-Path ([IO.Path]::GetTempPath()) 'sre-preview')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sreRoot = Join-Path $root 'sre'
$armApi = '2025-05-01-preview'
$dataPlaneAudience = 'https://azuresre.dev'

# ---------------------------------------------------------------------------
# Environment (azd injects values into hooks; fall back to `azd env get-values` when run by hand)
# ---------------------------------------------------------------------------
if (-not $env:SRE_RESOURCE_GROUP -and -not $DryRun) {
    try {
        $values = azd env get-values --output json 2>$null | ConvertFrom-Json
        $values.PSObject.Properties | ForEach-Object { Set-Item -Path "env:$($_.Name)" -Value $_.Value }
    } catch { }
}

if (-not $DryRun -and $env:DEPLOY_SRE_AGENTS -and $env:DEPLOY_SRE_AGENTS -ne 'true') {
    Write-Host 'DEPLOY_SRE_AGENTS is false: nothing to configure.'
    return
}
if (-not $DryRun -and -not $env:SRE_RESOURCE_GROUP) {
    Write-Warning 'SRE_RESOURCE_GROUP not found. Run `azd provision` first (or deploy with DEPLOY_SRE_AGENTS=true).'
    return
}

function Get-EnvOr([string] $Name, [string] $Default) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v }
}

$tokens = [ordered]@{
    SUBSCRIPTION_ID = Get-EnvOr 'AZURE_SUBSCRIPTION_ID' '<subscription-id>'
    WORKLOAD        = Get-EnvOr 'WORKLOAD_NAME' 'lowmaint'
    ENV             = Get-EnvOr 'ENVIRONMENT_NAME' 'dev'
    SPOKE_RG        = Get-EnvOr 'SPOKE_RESOURCE_GROUP' 'rg-lowmaint-spoke-dev'
    HUB_RG          = Get-EnvOr 'HUB_RESOURCE_GROUP' '(platform-owned hub, not managed by these agents)'
    SRE_RG          = Get-EnvOr 'SRE_RESOURCE_GROUP' 'rg-lowmaint-sre-dev'
    ACA_ENV         = Get-EnvOr 'CONTAINER_APPS_ENVIRONMENT_NAME' 'cae-lowmaint-dev'
    APPS_DOMAIN     = Get-EnvOr 'APPS_DOMAIN' '<apps-domain>'
    ACR             = (Get-EnvOr 'AZURE_CONTAINER_REGISTRY_ENDPOINT' '<acr>').Split('.')[0]
    KEY_VAULT       = Get-EnvOr 'KEY_VAULT_NAME' '<key-vault>'
    FOUNDRY         = Get-EnvOr 'FOUNDRY_ACCOUNT_NAME' '(not deployed)'
    APP_GATEWAY     = Get-EnvOr 'APP_GATEWAY_NAME' '(not deployed)'
    FIREWALL        = Get-EnvOr 'FIREWALL_NAME' '(platform-owned hub firewall)'
    LAW_ID          = Get-EnvOr 'LOG_ANALYTICS_WORKSPACE_ID' '<log-analytics-resource-id>'
    LAW_CUSTOMER_ID = Get-EnvOr 'LOG_ANALYTICS_CUSTOMER_ID' '<log-analytics-workspace-id>'
    APPI_APP_ID     = Get-EnvOr 'APP_INSIGHTS_APP_ID' '<app-insights-app-id>'
    L1_AGENT        = Get-EnvOr 'SRE_L1_AGENT_NAME' 'sre-lowmaint-l1-dev'
    L2_AGENT        = Get-EnvOr 'SRE_L2_AGENT_NAME' 'sre-lowmaint-l2-dev'
    ACTION_GROUP    = (Get-EnvOr 'ACTION_GROUP_ID' 'ag-oncall').Split('/')[-1]
}

function Expand-Template([string] $Text) {
    foreach ($k in $tokens.Keys) { $Text = $Text.Replace("{{$k}}", [string]$tokens[$k]) }
    $left = [regex]::Matches($Text, '\{\{[A-Z_]+\}\}') | ForEach-Object Value | Select-Object -Unique
    if ($left) { throw "Unresolved template tokens: $($left -join ', ')" }
    return $Text
}

$groundRules = Expand-Template (Get-Content (Join-Path $sreRoot 'shared/ground-rules.md') -Raw)
$guardTemplate = Get-Content (Join-Path $sreRoot 'hooks/skill-level-guard.py') -Raw

function Read-SreFile([string] $TierDir, [string] $RelativePath) {
    $text = Get-Content (Join-Path $TierDir $RelativePath) -Raw
    return Expand-Template ($text.Replace('{{GROUND_RULES}}', $groundRules))
}

# ---------------------------------------------------------------------------
# Payload builders (shapes follow https://github.com/microsoft/sre-agent sreagent-templates)
# ---------------------------------------------------------------------------
function New-Payloads([string] $TierKey) {
    $tierDir = Join-Path $sreRoot $TierKey
    $manifest = Get-Content (Join-Path $tierDir 'manifest.json') -Raw | ConvertFrom-Json
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($k in $manifest.knowledge) {
        $content = Read-SreFile $tierDir $k.file
        $items.Add([pscustomobject]@{
            Kind = 'knowledge'; Name = $k.name; Method = 'PUT'; Path = "/api/v2/extendedAgent/connectors/$($k.name)"
            Body = [ordered]@{
                name = $k.name; type = 'KnowledgeItem'; tags = @()
                properties = [ordered]@{
                    dataConnectorType  = 'KnowledgeFile'
                    dataSource         = $k.name
                    extendedProperties = [ordered]@{
                        displayName = "$($k.name).md"
                        fileName    = "$($k.name).md"
                        fileContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
                        contentType = 'text/markdown'
                    }
                }
            }
        })
    }

    foreach ($s in $manifest.skills) {
        $items.Add([pscustomobject]@{
            Kind = 'skill'; Name = $s.name; Method = 'PUT'; Path = "/api/v2/extendedAgent/skills/$($s.name)"
            Body = [ordered]@{
                name = $s.name; type = 'Skill'; tags = @()
                properties = [ordered]@{
                    name            = $s.name
                    description     = $s.description
                    tools           = @($s.tools)
                    skillContent    = Read-SreFile $tierDir $s.file
                    additionalFiles = @()
                }
            }
        })
    }

    foreach ($a in $manifest.agents) {
        $guard = $guardTemplate.Replace('__POLICY__', $a.guardPolicy)
        $items.Add([pscustomobject]@{
            Kind = 'custom-agent'; Name = $a.name; Method = 'PUT'; Path = "/api/v2/extendedAgent/agents/$($a.name)"
            Body = [ordered]@{
                name = $a.name; type = 'ExtendedAgent'; tags = @()
                properties = [ordered]@{
                    instructions       = Read-SreFile $tierDir $a.file
                    handoffDescription = $a.handoffDescription
                    handoffs           = @($a.handoffs | Where-Object { $_ })
                    tools              = @($a.tools)
                    enableSkills       = $true
                    allowedSkills      = @($a.allowedSkills)
                    hooks              = [ordered]@{
                        PreToolUse = @(
                            [ordered]@{ type = 'command'; matcher = '*'; timeout = 30; failMode = 'block'; script = $guard }
                        )
                    }
                }
            }
        })
    }

    # The quickstart plan created by the portal wizard would double-route incidents.
    $items.Add([pscustomobject]@{ Kind = 'response-plan'; Name = 'quickstart_handler'; Method = 'DELETE'; Path = '/api/v2/extendedAgent/incidentFilters/quickstart_handler'; Body = $null })

    foreach ($p in $manifest.responsePlans) {
        $items.Add([pscustomobject]@{
            Kind = 'response-plan'; Name = $p.name; Method = 'PUT'; Path = "/api/v2/extendedAgent/incidentFilters/$($p.name)"
            Body = [ordered]@{
                name = $p.name; type = 'IncidentFilter'; tags = @()
                properties = [ordered]@{
                    incidentPlatform                  = 'AzMonitor'
                    impactedService                   = ''
                    priorities                        = @($p.priorities)
                    incidentType                      = ''
                    alertId                           = ''
                    titleContains                     = ''
                    titleContainsAll                  = @()
                    titleContainsAny                  = @()
                    titleNotContains                  = @()
                    agentMode                         = $p.agentMode
                    handlingAgent                     = $p.handlingAgent
                    handlingAgents                    = $null
                    owningTeamId                      = ''
                    owningTeamIds                     = @()
                    maxAutomatedInvestigationAttempts = $p.maxAutomatedInvestigationAttempts
                    mergeEnabled                      = $true
                    mergeWindowHours                  = 3
                    isEnabled                         = $true
                    icmFilterSettings                 = $null
                    azMonitorFilterSettings           = [ordered]@{ targetResourceType = ''; targetResource = '' }
                }
            }
        })
    }

    foreach ($t in $manifest.scheduledTasks) {
        $items.Add([pscustomobject]@{
            Kind = 'scheduled-task'; Name = $t.name; Method = 'PUT'; Path = "/api/v2/extendedAgent/scheduledtasks/$($t.name)"
            Body = [ordered]@{
                name = $t.name; type = 'ScheduledTask'; tags = @()
                properties = [ordered]@{
                    name           = $t.name
                    description    = $t.description
                    cronExpression = $t.cron
                    agentPrompt    = Expand-Template $t.prompt
                    agent          = $t.agent
                    agentMode      = $t.mode
                    isEnabled      = $true
                }
            }
        })
    }
    return $items
}

# ---------------------------------------------------------------------------
# Azure calls
# ---------------------------------------------------------------------------
function Get-DataPlaneToken {
    $t = az account get-access-token --resource $dataPlaneAudience --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $t) {
        throw "No data-plane token for $dataPlaneAudience. Run: az login --scope `"$dataPlaneAudience/.default`" and re-run this script."
    }
    return $t
}

function Invoke-DataPlane([string] $Endpoint, [object] $Item) {
    $uri = "$($Endpoint.TrimEnd('/'))$($Item.Path)"
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $headers = @{ Authorization = "Bearer $(Get-DataPlaneToken)" }
            if ($Item.Method -eq 'DELETE') {
                $null = Invoke-RestMethod -Uri $uri -Method Delete -Headers $headers -TimeoutSec 60
            } else {
                $json = $Item.Body | ConvertTo-Json -Depth 30 -Compress
                $null = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $json -ContentType 'application/json' -TimeoutSec 60
            }
            Write-Host "    ok   $($Item.Kind)/$($Item.Name)"
            return $true
        } catch {
            $status = [int]($_.Exception.Response.StatusCode ?? 0)
            if ($Item.Method -eq 'DELETE' -and $status -eq 404) { Write-Host "    skip $($Item.Kind)/$($Item.Name) (not present)"; return $true }
            if ($status -in 400, 401, 403, 404, 405 -or $attempt -eq 4) {
                Write-Warning "    FAIL $($Item.Kind)/$($Item.Name): HTTP $status $($_.ErrorDetails.Message)"
                return $false
            }
            Start-Sleep -Seconds (15 * $attempt)
        }
    }
}

function Get-Agent([string] $Name) {
    $url = "https://management.azure.com/subscriptions/$($tokens.SUBSCRIPTION_ID)/resourceGroups/$($tokens.SRE_RG)/providers/Microsoft.App/agents/$Name`?api-version=$armApi"
    for ($i = 0; $i -lt 30; $i++) {
        $agent = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json
        if ($agent.properties.agentEndpoint) { return @{ Url = $url; Agent = $agent } }
        Write-Host "  waiting for $Name to finish provisioning ..."
        Start-Sleep -Seconds 20
    }
    throw "Agent $Name has no data-plane endpoint after 10 minutes."
}

function Confirm-IncidentPlatform([hashtable] $Ctx) {
    if ($Ctx.Agent.properties.incidentManagementConfiguration.type -ne 'AzMonitor') {
        Write-Host '  setting incident platform: Azure Monitor'
        $body = @{ properties = @{ incidentManagementConfiguration = @{ type = 'AzMonitor'; connectionName = 'azmonitor' } } } | ConvertTo-Json -Depth 5 -Compress
        $tmp = New-TemporaryFile
        Set-Content $tmp $body -NoNewline
        az rest --method patch --url $Ctx.Url --body "@$tmp" --headers 'Content-Type=application/json' -o none
        Remove-Item $tmp
    }
    $endpoint = $Ctx.Agent.properties.agentEndpoint.TrimEnd('/')
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $r = Invoke-RestMethod -Uri "$endpoint/api/v1/incidentplayground/incidentPlatformType" -Headers @{ Authorization = "Bearer $(Get-DataPlaneToken)" } -TimeoutSec 30
            if ($r.incidentPlatformType -eq 'AzMonitor') { Write-Host '  incident platform: Azure Monitor (synced)'; return }
        } catch { }
        Start-Sleep -Seconds 10
    }
    Write-Warning '  incident platform not reported as AzMonitor yet; response plans may fail. Re-run this script in a few minutes.'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$tiers = if ($Tier -eq 'all') { @('l1', 'l2') } else { @($Tier) }
$failures = 0

foreach ($t in $tiers) {
    $agentName = $tokens["$($t.ToUpper())_AGENT"]
    Write-Host "`n== $($t.ToUpper()) agent: $agentName" -ForegroundColor Cyan
    $items = New-Payloads $t

    if ($DryRun) {
        $dir = Join-Path $OutputPath $t
        New-Item -ItemType Directory -Force $dir | Out-Null
        $i = 0
        foreach ($item in $items) {
            $i++
            $file = Join-Path $dir ('{0:d2}-{1}-{2}.json' -f $i, $item.Kind, $item.Name)
            [ordered]@{ method = $item.Method; path = $item.Path; body = $item.Body } | ConvertTo-Json -Depth 30 | Set-Content $file
            Write-Host "  rendered $($item.Method) $($item.Path)"
        }
        continue
    }

    $ctx = Get-Agent $agentName
    $endpoint = $ctx.Agent.properties.agentEndpoint
    Write-Host "  endpoint: $endpoint"
    Confirm-IncidentPlatform $ctx
    foreach ($item in $items) {
        if (-not (Invoke-DataPlane $endpoint $item)) { $failures++ }
    }
}

if ($DryRun) { Write-Host "`nDry run complete. Payloads in $OutputPath" -ForegroundColor Green; return }

Write-Host ''
if ($failures -gt 0) {
    Write-Warning "$failures item(s) failed. Fix the cause and re-run ./scripts/configure-sre-agents.ps1 (it is idempotent)."
    exit 1
}
Write-Host 'SRE agents configured.' -ForegroundColor Green
if ($env:SRE_L1_PORTAL_URL) { Write-Host "  L1 triage:    $($env:SRE_L1_PORTAL_URL)" }
if ($env:SRE_L2_PORTAL_URL) { Write-Host "  L2 responder: $($env:SRE_L2_PORTAL_URL)" }
