// Azure AI Foundry: AIServices account (private endpoint only, Entra ID auth only),
// one project and a configurable list of model deployments.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param logAnalyticsWorkspaceId string
param privateEndpointSubnetResourceId string

@description('Private DNS zone IDs: { cognitiveServices, openAi, aiServices }.')
param privateDnsZoneIds object

@description('Principal ID of the shared app identity (gets Azure AI User + Cognitive Services OpenAI User).')
param appIdentityPrincipalId string

@description('Optional principal that gets Azure AI Developer (e.g. the deploying user).')
param adminPrincipalId string

@allowed(['User', 'Group', 'ServicePrincipal'])
param adminPrincipalType string

@description('Model deployments, e.g. [{ name, model: { format, name, version }, sku: { name, capacity } }].')
param modelDeployments array

var roles = {
  azureAiUser: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  azureAiDeveloper: '64702f94-c441-49e6-a78b-ef80e0188fee'
  cognitiveServicesOpenAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
}

module account 'br/public:avm/res/cognitive-services/account:0.19.1' = {
  name: 'foundry'
  params: {
    name: names.foundry
    location: location
    tags: tags
    kind: 'AIServices'
    sku: 'S0'
    customSubDomainName: names.foundry
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    managedIdentities: {
      systemAssigned: true
    }
    deployments: modelDeployments
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
    privateEndpoints: [
      {
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: privateDnsZoneIds.cognitiveServices }
            { privateDnsZoneResourceId: privateDnsZoneIds.openAi }
            { privateDnsZoneResourceId: privateDnsZoneIds.aiServices }
          ]
        }
      }
    ]
    roleAssignments: concat(
      [
        {
          principalId: appIdentityPrincipalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: roles.azureAiUser
        }
        {
          principalId: appIdentityPrincipalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: roles.cognitiveServicesOpenAiUser
        }
      ],
      empty(adminPrincipalId)
        ? []
        : [
            {
              principalId: adminPrincipalId
              principalType: adminPrincipalType
              roleDefinitionIdOrName: roles.azureAiDeveloper
            }
          ]
    )
  }
}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: names.foundry
  dependsOn: [account]
}

// AVM has no project support yet, so the project is a plain child resource.
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundryAccount
  name: names.foundryProject
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: names.foundryProject
    description: 'Default project for apps in this spoke.'
  }
}

output accountName string = account.outputs.name
output accountResourceId string = account.outputs.resourceId
output accountEndpoint string = account.outputs.endpoint
output projectName string = project.name
output projectEndpoint string = 'https://${names.foundry}.services.ai.azure.com/api/projects/${project.name}'
