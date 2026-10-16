// Low-maintenance Container Apps spoke.
// Simplified from https://github.com/Azure/ACA-Landing-Zone-Accelerator (scenario aca-internal).
targetScope = 'subscription'

import { resourceNames, uniqueToken } from 'naming.bicep'

// ---------------------------------------------------------------------------
// Basics
// ---------------------------------------------------------------------------
@description('Short workload name used in every resource name (lowercase, letters/numbers/hyphens).')
@minLength(2)
@maxLength(10)
param workloadName string

@description('Environment name, e.g. dev, test, prod.')
@minLength(2)
@maxLength(6)
param environmentName string

param location string = deployment().location
param tags object = {}

@description('Optional principal (e.g. the deploying user) that gets admin access to Key Vault, ACR push and Foundry.')
param adminPrincipalId string = ''

@allowed(['User', 'Group', 'ServicePrincipal'])
param adminPrincipalType string = 'User'

@description('Zone-redundant ACA environment, ACR and App Gateway (region must support AZs).')
param zoneRedundant bool = false

// ---------------------------------------------------------------------------
// Hub connectivity
// ---------------------------------------------------------------------------
@description('Existing platform hub VNet resource ID. Ignored when deployTestHub = true. Empty = standalone spoke.')
param hubVnetResourceId string = ''

@description('Private IP of the hub firewall/NVA used for egress (0.0.0.0/0 UDR). Ignored when deployTestHub = true.')
param hubFirewallPrivateIp string = ''

@description('Also create the hub->spoke peering (requires Network Contributor on the hub VNet).')
param createHubSidePeering bool = true

@description('Custom DNS servers for the spoke VNet (e.g. hub DNS Private Resolver). Empty = Azure DNS.')
param spokeDnsServers array = []

@description('Deploy a minimal hub (VNet, Azure Firewall Basic, optional Bastion/jumpbox) for standalone labs.')
param deployTestHub bool = false

param testHubAddressSpace string = '10.0.0.0/24'
param testHubDeployBastion bool = true

@description('SSH public key for a Linux jumpbox in the test hub. Empty = no jumpbox.')
@secure()
param testHubJumpboxSshPublicKey string = ''

// ---------------------------------------------------------------------------
// Spoke network
// ---------------------------------------------------------------------------
param spokeAddressSpace string = '10.1.0.0/22'

@description('Subnet prefixes inside spokeAddressSpace (sreL1/sreL2 are dedicated /27s for the SRE agents).')
param spokeSubnets object = {
  aca: '10.1.0.0/23'
  privateEndpoints: '10.1.2.0/26'
  sreL1: '10.1.2.64/27'
  sreL2: '10.1.2.96/27'
  appGateway: '10.1.3.0/24'
}

// ---------------------------------------------------------------------------
// Private DNS
// ---------------------------------------------------------------------------
@description('Create = spoke owns the privatelink zones. Existing = use central zones from existingPrivateDnsZoneIds.')
@allowed(['Create', 'Existing'])
param privateDnsZoneMode string = 'Create'

@description('Only for Existing mode: { acr, keyVault, cognitiveServices, openAi, aiServices } -> zone resource IDs.')
param existingPrivateDnsZoneIds object = {}

@description('Also link spoke-owned zones to the hub VNet. Disable if the hub already links zones with the same names.')
param linkPrivateDnsZonesToHub bool = true

// ---------------------------------------------------------------------------
// Apps hosting
// ---------------------------------------------------------------------------
@description('Custom DNS suffix for apps (apps become <app>.<suffix>). Requires appsCertificateName. Empty = default ACA domain.')
param appsDnsSuffix string = ''

@description('Key Vault certificate name holding *.<appsDnsSuffix>. Upload it after the first deployment (see scripts/new-lab-cert.ps1).')
param appsCertificateName string = ''

param logRetentionInDays int = 30

// ---------------------------------------------------------------------------
// Foundry
// ---------------------------------------------------------------------------
param deployFoundry bool = true

@description('Foundry model deployments. Check model/region availability: https://learn.microsoft.com/azure/ai-foundry/foundry-models/concepts/models-sold-directly-by-azure')
param foundryModelDeployments array = [
  {
    name: 'gpt-5-mini'
    model: { format: 'OpenAI', name: 'gpt-5-mini', version: '2025-08-07' }
    sku: { name: 'GlobalStandard', capacity: 10 }
  }
]

// ---------------------------------------------------------------------------
// Ingress
// ---------------------------------------------------------------------------
@description('Deploy App Gateway WAF_v2 as the single entry point. Requires appsDnsSuffix + appsCertificateName.')
param deployAppGateway bool = false

@allowed(['Public', 'Private'])
param appGatewayFrontend string = 'Public'

@allowed(['Detection', 'Prevention'])
param appGatewayWafMode string = 'Prevention'

@description('Base64 .cer of the CA that signed the apps certificate, only needed for private/self-signed CAs.')
param appGatewayBackendTrustedRootCertificate string = ''

// ---------------------------------------------------------------------------
// Operations: Azure Monitor alerting + SRE agents
// ---------------------------------------------------------------------------
@description('E-mail addresses notified for Sev0/Sev1 alerts, Resource Health and Service Health.')
param alertEmailAddresses array = []

@description('Deploy the L1 (triage) and L2 (responder) Azure SRE Agents. Each agent has an always-on cost (see README).')
param deploySreAgents bool = true

@description('AzureVNet = agents egress through dedicated spoke subnets (reach private endpoints, filtered by the hub firewall). Unrestricted = no VNet integration.')
@allowed(['AzureVNet', 'Unrestricted'])
param sreAgentNetworkMode string = 'AzureVNet'

@description('Entra group that may chat with the agents and request actions (SRE Agent Standard User). Approvals stay with adminPrincipalId.')
param sreOperatorsGroupId string = ''

@description('Model provider for the agents, e.g. MicrosoftFoundry, Anthropic.')
param sreDefaultModelProvider string = 'MicrosoftFoundry'

param sreDefaultModelName string = 'Automatic'

@description('Monthly active-flow AAU allocation limit per agent.')
param sreMonthlyAgentUnitLimits object = {
  l1: 3000
  l2: 5000
}

@allowed(['Stable', 'Preview'])
param sreUpgradeChannel string = 'Stable'

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------
var names = resourceNames(workloadName, environmentName, uniqueToken(subscription().subscriptionId, workloadName, environmentName))
var allTags = union({ workload: workloadName, environment: environmentName, 'managed-by': 'bicep-avm' }, tags)
var useCustomDomain = !empty(appsDnsSuffix) && !empty(appsCertificateName)
var deployAgw = deployAppGateway && useCustomDomain
var deploySreSubnets = deploySreAgents && sreAgentNetworkMode == 'AzureVNet'

var privatelinkZones = union(
  {
    acr: 'privatelink.azurecr.io'
    keyVault: 'privatelink.vaultcore.azure.net'
  },
  deployFoundry
    ? {
        cognitiveServices: 'privatelink.cognitiveservices.azure.com'
        openAi: 'privatelink.openai.azure.com'
        aiServices: 'privatelink.services.ai.azure.com'
      }
    : {}
)

// ---------------------------------------------------------------------------
// Resource groups
// ---------------------------------------------------------------------------
resource spokeRg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: names.spokeResourceGroup
  location: location
  tags: allTags
}

resource hubRg 'Microsoft.Resources/resourceGroups@2025-04-01' = if (deployTestHub) {
  name: names.hubResourceGroup
  location: location
  tags: allTags
}

resource sreRg 'Microsoft.Resources/resourceGroups@2025-04-01' = if (deploySreAgents) {
  name: names.sreResourceGroup
  location: location
  tags: allTags
}

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------
module monitoring 'modules/monitoring.bicep' = {
  scope: spokeRg
  name: 'monitoring'
  params: {
    location: location
    tags: allTags
    names: names
    retentionInDays: logRetentionInDays
  }
}

module testHub 'modules/test-hub.bicep' = if (deployTestHub) {
  scope: hubRg
  name: 'test-hub'
  params: {
    location: location
    tags: allTags
    names: names
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    addressSpace: testHubAddressSpace
    spokeEgressSourcePrefixes: [spokeSubnets.aca]
    sreEgressSourcePrefixes: deploySreSubnets ? [spokeSubnets.sreL1, spokeSubnets.sreL2] : []
    deployBastion: testHubDeployBastion
    jumpboxSshPublicKey: testHubJumpboxSshPublicKey
  }
}

var effectiveHubVnetId = deployTestHub ? testHub!.outputs.vnetResourceId : hubVnetResourceId
var effectiveFirewallIp = deployTestHub ? testHub!.outputs.firewallPrivateIp : hubFirewallPrivateIp

module network 'modules/spoke-network.bicep' = {
  scope: spokeRg
  name: 'spoke-network'
  params: {
    location: location
    tags: allTags
    names: names
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    addressSpace: spokeAddressSpace
    subnetPrefixes: spokeSubnets
    deployAppGatewaySubnet: deployAgw
    deploySreSubnets: deploySreSubnets
    dnsServers: spokeDnsServers
    hubVnetResourceId: effectiveHubVnetId
    createHubSidePeering: deployTestHub ? true : createHubSidePeering
    hubFirewallPrivateIp: effectiveFirewallIp
  }
}

var linkHub = !empty(effectiveHubVnetId) && (deployTestHub || linkPrivateDnsZonesToHub)
var dnsLinkVnets = concat([network.outputs.vnetResourceId], linkHub ? [effectiveHubVnetId] : [])

module privateDns 'modules/private-dns.bicep' = if (privateDnsZoneMode == 'Create') {
  scope: spokeRg
  name: 'private-dns'
  params: {
    tags: allTags
    zones: privatelinkZones
    vnetResourceIds: dnsLinkVnets
  }
}

var zoneIds = privateDnsZoneMode == 'Create'
  ? toObject(privateDns!.outputs.zones, z => z.key, z => z.id)
  : existingPrivateDnsZoneIds

module shared 'modules/shared-services.bicep' = {
  scope: spokeRg
  name: 'shared-services'
  params: {
    location: location
    tags: allTags
    names: names
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneIds: zoneIds
    adminPrincipalId: adminPrincipalId
    adminPrincipalType: adminPrincipalType
    zoneRedundant: zoneRedundant
  }
}

module acaEnvironment 'modules/aca-environment.bicep' = {
  scope: spokeRg
  name: 'aca-environment'
  params: {
    location: location
    tags: allTags
    names: names
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    infrastructureSubnetResourceId: network.outputs.acaSubnetResourceId
    identityResourceId: shared.outputs.identityResourceId
    zoneRedundant: zoneRedundant
    appsDnsSuffix: appsDnsSuffix
    appsCertificateName: appsCertificateName
    keyVaultUri: shared.outputs.keyVaultUri
    dnsLinkVnetResourceIds: dnsLinkVnets
  }
}

module foundry 'modules/foundry.bicep' = if (deployFoundry) {
  scope: spokeRg
  name: 'foundry'
  params: {
    location: location
    tags: allTags
    names: names
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneIds: zoneIds
    appIdentityPrincipalId: shared.outputs.identityPrincipalId
    adminPrincipalId: adminPrincipalId
    adminPrincipalType: adminPrincipalType
    modelDeployments: foundryModelDeployments
  }
}

module appGateway 'modules/app-gateway.bicep' = if (deployAgw) {
  scope: spokeRg
  name: 'app-gateway'
  params: {
    location: location
    tags: allTags
    names: names
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    subnetResourceId: network.outputs.appGatewaySubnetResourceId
    identityResourceId: shared.outputs.identityResourceId
    keyVaultUri: shared.outputs.keyVaultUri
    appsDnsSuffix: appsDnsSuffix
    certificateName: appsCertificateName
    backendTrustedRootCertificate: appGatewayBackendTrustedRootCertificate
    frontend: appGatewayFrontend
    privateFrontendIp: cidrHost(spokeSubnets.appGateway, 9)
    backendIp: acaEnvironment.outputs.staticIp
    wafMode: appGatewayWafMode
    zoneRedundant: zoneRedundant
  }
}

module alerts 'modules/alerts.bicep' = {
  scope: spokeRg
  name: 'alerts'
  params: {
    location: location
    tags: allTags
    names: names
    alertEmailAddresses: alertEmailAddresses
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    appInsightsResourceId: monitoring.outputs.appInsightsResourceId
    containerAppsEnvironmentId: acaEnvironment.outputs.environmentResourceId
    keyVaultId: shared.outputs.keyVaultResourceId
    foundryAccountId: deployFoundry ? foundry!.outputs.accountResourceId : ''
    appGatewayId: deployAgw ? appGateway!.outputs.resourceId : ''
    firewallId: deployTestHub ? testHub!.outputs.firewallResourceId : ''
    resourceHealthScopes: concat([spokeRg.id], deployTestHub ? [hubRg.id] : [])
  }
}

var sreManagedResourceGroups = concat([spokeRg.name], deployTestHub ? [hubRg.name] : [])

module sre 'modules/sre-operations.bicep' = if (deploySreAgents) {
  scope: sreRg
  name: 'sre-operations'
  params: {
    location: location
    tags: allTags
    names: names
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    workloadAppInsightsResourceId: monitoring.outputs.appInsightsResourceId
    workloadAppInsightsAppId: monitoring.outputs.appInsightsAppId
    managedResourceGroupNames: sreManagedResourceGroups
    spokeResourceGroupName: spokeRg.name
    subnetResourceIds: {
      l1: network.outputs.sreL1SubnetResourceId
      l2: network.outputs.sreL2SubnetResourceId
    }
    defaultModelProvider: sreDefaultModelProvider
    defaultModelName: sreDefaultModelName
    monthlyAgentUnitLimits: sreMonthlyAgentUnitLimits
    upgradeChannel: sreUpgradeChannel
    adminPrincipalId: adminPrincipalId
    adminPrincipalType: adminPrincipalType
    operatorsGroupId: sreOperatorsGroupId
  }
  dependsOn: [alerts]
}

// ---------------------------------------------------------------------------
// Outputs (UPPER_CASE so azd stores them as environment values for scripts/apps)
// ---------------------------------------------------------------------------
output WORKLOAD_NAME string = workloadName
output ENVIRONMENT_NAME string = environmentName
output AZURE_LOCATION string = location
output SPOKE_RESOURCE_GROUP string = spokeRg.name
output SPOKE_VNET_ID string = network.outputs.vnetResourceId
output HUB_VNET_ID string = effectiveHubVnetId
output CONTAINER_APPS_ENVIRONMENT_NAME string = acaEnvironment.outputs.environmentName
output CONTAINER_APPS_ENVIRONMENT_STATIC_IP string = acaEnvironment.outputs.staticIp
output APPS_DOMAIN string = acaEnvironment.outputs.appsDomain
output APPS_IDENTITY_CLIENT_ID string = shared.outputs.identityClientId
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = shared.outputs.containerRegistryLoginServer
output KEY_VAULT_NAME string = shared.outputs.keyVaultName
output FOUNDRY_ACCOUNT_NAME string = deployFoundry ? foundry!.outputs.accountName : ''
output FOUNDRY_PROJECT_ENDPOINT string = deployFoundry ? foundry!.outputs.projectEndpoint : ''
output APP_GATEWAY_IP string = deployAgw ? appGateway!.outputs.listenerIp : ''

// Operations (consumed by scripts/configure-sre-agents.ps1)
output AZURE_SUBSCRIPTION_ID string = subscription().subscriptionId
output HUB_RESOURCE_GROUP string = deployTestHub ? hubRg.name : ''
output LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.logAnalyticsWorkspaceId
output LOG_ANALYTICS_CUSTOMER_ID string = monitoring.outputs.logAnalyticsCustomerId
output APP_INSIGHTS_APP_ID string = monitoring.outputs.appInsightsAppId
output APP_GATEWAY_NAME string = deployAgw ? names.appGateway : ''
output FIREWALL_NAME string = deployTestHub ? names.firewall : ''
output ACTION_GROUP_ID string = alerts.outputs.actionGroupResourceId
output DEPLOY_SRE_AGENTS bool = deploySreAgents
output SRE_RESOURCE_GROUP string = deploySreAgents ? sreRg.name : ''
output SRE_L1_AGENT_NAME string = deploySreAgents ? sre!.outputs.l1AgentName : ''
output SRE_L2_AGENT_NAME string = deploySreAgents ? sre!.outputs.l2AgentName : ''
output SRE_L1_PORTAL_URL string = deploySreAgents ? sre!.outputs.l1PortalUrl : ''
output SRE_L2_PORTAL_URL string = deploySreAgents ? sre!.outputs.l2PortalUrl : ''
