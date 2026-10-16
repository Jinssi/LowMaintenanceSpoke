// Operations layer: two Azure SRE Agents at fixed skill levels sharing one telemetry sink.
//   L1 (Triage)    - Reader access, owns Sev2-Sev4 alerts, may only change alert state (acknowledge/close/escalate).
//   L2 (Responder) - Container Apps Contributor on the spoke, owns Sev0-Sev1 alerts and L1 escalations, acts after approval.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param logAnalyticsWorkspaceId string
param workloadAppInsightsResourceId string
param workloadAppInsightsAppId string

@description('Resource groups both agents watch and can read (spoke, and the test hub when deployed).')
param managedResourceGroupNames array

@description('Spoke resource group where L2 may act.')
param spokeResourceGroupName string

@description('Delegated subnets for Azure VNet egress mode: { l1, l2 }. Empty strings = Unrestricted egress.')
param subnetResourceIds object

param defaultModelProvider string
param defaultModelName string

@description('Monthly Azure Agent Unit (AAU) allocation limits: { l1, l2 }.')
param monthlyAgentUnitLimits object

@allowed(['Stable', 'Preview'])
param upgradeChannel string

param adminPrincipalId string

@allowed(['User', 'Group', 'ServicePrincipal'])
param adminPrincipalType string

param operatorsGroupId string

var roles = {
  containerAppsContributor: '358470bc-b998-42bd-ab17-a7e34c199c0f'
  monitoringContributor: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
}

var tiers = [
  {
    key: 'l1'
    agentName: names.sreAgentL1
    identityName: names.sreIdentityL1
    accessLevel: 'Low'
    writeResourceGroupName: ''
    writeRoleDefinitionIds: []
  }
  {
    key: 'l2'
    agentName: names.sreAgentL2
    identityName: names.sreIdentityL2
    accessLevel: 'High'
    writeResourceGroupName: spokeResourceGroupName
    writeRoleDefinitionIds: [roles.containerAppsContributor, roles.monitoringContributor]
  }
]

module agentTelemetry 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'appi-sre'
  params: {
    name: names.sreAppInsights
    location: location
    tags: tags
    applicationType: 'web'
    kind: 'web'
    requestSource: 'SreAgent'
    workspaceResourceId: logAnalyticsWorkspaceId
  }
}

@batchSize(1)
module agent 'sre-agent.bicep' = [
  for t in tiers: {
    name: 'sre-agent-${t.key}'
    params: {
      location: location
      tags: union(tags, { 'sre-tier': t.key })
      agentName: t.agentName
      identityName: t.identityName
      accessLevel: t.accessLevel
      managedResourceGroupNames: managedResourceGroupNames
      writeResourceGroupName: t.writeResourceGroupName
      writeRoleDefinitionIds: t.writeRoleDefinitionIds
      subnetResourceId: subnetResourceIds[t.key]
      agentAppInsightsAppId: agentTelemetry.outputs.applicationId
      agentAppInsightsConnectionString: agentTelemetry.outputs.connectionString
      workloadAppInsightsResourceId: workloadAppInsightsResourceId
      workloadAppInsightsAppId: workloadAppInsightsAppId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      defaultModelProvider: defaultModelProvider
      defaultModelName: defaultModelName
      monthlyAgentUnitLimit: monthlyAgentUnitLimits[t.key]
      upgradeChannel: upgradeChannel
      adminPrincipalId: adminPrincipalId
      adminPrincipalType: adminPrincipalType
      operatorsGroupId: operatorsGroupId
    }
  }
]

output l1AgentName string = agent[0].outputs.name
output l2AgentName string = agent[1].outputs.name
output l1PortalUrl string = agent[0].outputs.portalUrl
output l2PortalUrl string = agent[1].outputs.portalUrl
