// Internal Container Apps environment (workload profiles) shared by all apps,
// plus the private DNS zone that resolves app FQDNs to the environment's internal load balancer.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param logAnalyticsWorkspaceId string
param infrastructureSubnetResourceId string
param identityResourceId string
param zoneRedundant bool

@description('Custom DNS suffix for all apps, e.g. apps.contoso.com. Empty = use the generated default domain.')
param appsDnsSuffix string

@description('Name of the wildcard certificate (*.appsDnsSuffix) in Key Vault. Required when appsDnsSuffix is set.')
param appsCertificateName string

param keyVaultUri string

@description('VNets that must resolve app FQDNs (spoke + hub).')
param dnsLinkVnetResourceIds array

var useCustomDomain = !empty(appsDnsSuffix) && !empty(appsCertificateName)

module environment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'cae'
  params: {
    name: names.containerAppsEnvironment
    location: location
    tags: tags
    internal: true
    publicNetworkAccess: 'Disabled'
    infrastructureSubnetResourceId: infrastructureSubnetResourceId
    infrastructureResourceGroupName: 'ME_${names.containerAppsEnvironment}'
    zoneRedundant: zoneRedundant
    peerTrafficEncryption: true
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    managedIdentities: {
      userAssignedResourceIds: [identityResourceId]
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceId
    }
    dnsSuffix: useCustomDomain ? appsDnsSuffix : ''
    certificate: useCustomDomain
      ? {
          certificateKeyVaultProperties: {
            identityResourceId: identityResourceId
            keyVaultUrl: '${keyVaultUri}secrets/${appsCertificateName}'
          }
        }
      : null
  }
}

module appsDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'pdz-apps'
  params: {
    name: useCustomDomain ? appsDnsSuffix : environment.outputs.defaultDomain!
    location: 'global'
    tags: tags
    a: [
      {
        name: '*'
        ttl: 300
        aRecords: [{ ipv4Address: environment.outputs.staticIp! }]
      }
      {
        name: '@'
        ttl: 300
        aRecords: [{ ipv4Address: environment.outputs.staticIp! }]
      }
    ]
    virtualNetworkLinks: [
      for vnetId in dnsLinkVnetResourceIds: {
        name: 'link-${last(split(vnetId, '/'))}'
        virtualNetworkResourceId: vnetId
        registrationEnabled: false
      }
    ]
  }
}

output environmentResourceId string = environment.outputs.resourceId
output environmentName string = environment.outputs.name
output staticIp string = environment.outputs.staticIp!
output defaultDomain string = environment.outputs.defaultDomain!
@description('Domain apps are published under: <app>.<appsDomain>.')
output appsDomain string = useCustomDomain ? appsDnsSuffix : environment.outputs.defaultDomain!
