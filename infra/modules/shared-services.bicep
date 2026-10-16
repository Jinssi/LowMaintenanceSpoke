// Shared services for all apps: one user-assigned identity, ACR and Key Vault (private endpoints only).
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param logAnalyticsWorkspaceId string
param privateEndpointSubnetResourceId string

@description('Private DNS zone IDs: { acr, keyVault }.')
param privateDnsZoneIds object

@description('Optional principal (user/group/SP) that gets Key Vault Administrator and AcrPush, e.g. the deploying user.')
param adminPrincipalId string

@allowed(['User', 'Group', 'ServicePrincipal'])
param adminPrincipalType string

param zoneRedundant bool

var diagnostics = [{ workspaceResourceId: logAnalyticsWorkspaceId }]

var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  acrPush: '8311e382-0749-4cb8-b61a-304f252e45ec'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultAdministrator: '00482a5a-887f-4fb3-b363-3b7fe8e74483'
}

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'id-apps'
  params: {
    name: names.identity
    location: location
    tags: tags
  }
}

module registry 'br/public:avm/res/container-registry/registry:0.13.1' = {
  name: 'acr'
  params: {
    name: names.containerRegistry
    location: location
    tags: tags
    acrSku: 'Premium' // required for private endpoints
    acrAdminUserEnabled: false
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'AzureServices'
    zoneRedundancy: zoneRedundant ? 'Enabled' : 'Disabled'
    diagnosticSettings: diagnostics
    privateEndpoints: [
      {
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: privateDnsZoneIds.acr }]
        }
      }
    ]
    roleAssignments: concat(
      [
        {
          principalId: identity.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: roles.acrPull
        }
      ],
      empty(adminPrincipalId)
        ? []
        : [
            {
              principalId: adminPrincipalId
              principalType: adminPrincipalType
              roleDefinitionIdOrName: roles.acrPush
            }
          ]
    )
  }
}

module vault 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: 'kv'
  params: {
    name: names.keyVault
    location: location
    tags: tags
    sku: 'standard'
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 30
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    diagnosticSettings: diagnostics
    privateEndpoints: [
      {
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: privateDnsZoneIds.keyVault }]
        }
      }
    ]
    roleAssignments: concat(
      [
        {
          principalId: identity.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: roles.keyVaultSecretsUser
        }
      ],
      empty(adminPrincipalId)
        ? []
        : [
            {
              principalId: adminPrincipalId
              principalType: adminPrincipalType
              roleDefinitionIdOrName: roles.keyVaultAdministrator
            }
          ]
    )
  }
}

output identityResourceId string = identity.outputs.resourceId
output identityPrincipalId string = identity.outputs.principalId
output identityClientId string = identity.outputs.clientId
output containerRegistryName string = registry.outputs.name
output containerRegistryLoginServer string = registry.outputs.loginServer
output keyVaultName string = vault.outputs.name
output keyVaultResourceId string = vault.outputs.resourceId
output keyVaultUri string = vault.outputs.uri
