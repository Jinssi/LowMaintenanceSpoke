// OPTIONAL minimal hub for standalone labs. In production, point the spoke at your platform hub instead.
// VNet + Azure Firewall Basic (egress filtering for ACA, rules ported from the upstream accelerator)
// + optional Bastion + optional Linux jumpbox to reach private endpoints.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param logAnalyticsWorkspaceId string

@description('Hub address space (/24 is enough).')
param addressSpace string

@description('Spoke subnets allowed to egress through the firewall.')
param spokeEgressSourcePrefixes array

@description('SRE agent subnets (Azure VNet egress mode). Empty = no SRE egress rules.')
param sreEgressSourcePrefixes array = []

param deployBastion bool

@description('SSH public key for the jumpbox. Empty = no jumpbox.')
@secure()
param jumpboxSshPublicKey string

param jumpboxAdminUsername string = 'azureuser'

var diagnostics = [{ workspaceResourceId: logAnalyticsWorkspaceId }]
var prefixes = {
  firewall: cidrSubnet(addressSpace, 26, 0)
  firewallManagement: cidrSubnet(addressSpace, 26, 1)
  bastion: cidrSubnet(addressSpace, 26, 2)
  jumpbox: cidrSubnet(addressSpace, 27, 6)
}
// Azure Firewall always takes the first usable address of its subnet.
var firewallPrivateIp = cidrHost(prefixes.firewall, 3)
var deployJumpbox = !empty(jumpboxSshPublicKey)
var loginHost = replace(replace(environment().authentication.loginEndpoint, 'https://', ''), '/', '')

module jumpboxRoute 'br/public:avm/res/network/route-table:0.5.0' = if (deployJumpbox) {
  name: 'rt-jumpbox'
  params: {
    name: 'rt-${names.jumpbox}'
    location: location
    tags: tags
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-hub'
  params: {
    name: names.hubVnet
    location: location
    tags: tags
    addressPrefixes: [addressSpace]
    diagnosticSettings: diagnostics
    subnets: concat(
      [
        { name: 'AzureFirewallSubnet', addressPrefix: prefixes.firewall }
        { name: 'AzureFirewallManagementSubnet', addressPrefix: prefixes.firewallManagement }
      ],
      deployBastion ? [{ name: 'AzureBastionSubnet', addressPrefix: prefixes.bastion }] : [],
      deployJumpbox
        ? [
            {
              name: 'snet-jumpbox'
              addressPrefix: prefixes.jumpbox
              routeTableResourceId: jumpboxRoute!.outputs.resourceId
            }
          ]
        : []
    )
  }
}

var https = [{ protocolType: 'Https', port: 443 }]
var httpAndHttps = [{ protocolType: 'Http', port: 80 }, { protocolType: 'Https', port: 443 }]

// Azure SRE Agent in Azure VNet mode: only "your Azure infrastructure" traffic uses the VNet
// (platform/model traffic stays on Microsoft's infra network). https://learn.microsoft.com/azure/sre-agent/network-requirements
var sreRuleCollectionGroups = empty(sreEgressSourcePrefixes)
  ? []
  : [
      {
        name: 'sre-agent-egress'
        priority: 250
        ruleCollections: [
          {
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'sre-network'
            priority: 100
            action: { type: 'Allow' }
            rules: [
              {
                ruleType: 'NetworkRule'
                name: 'azure-control-and-monitor'
                ipProtocols: ['TCP']
                sourceAddresses: sreEgressSourcePrefixes
                destinationAddresses: [
                  'AzureResourceManager'
                  'AzureMonitor'
                  'AzureActiveDirectory'
                ]
                destinationPorts: ['443']
              }
            ]
          }
          {
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'sre-application'
            priority: 200
            action: { type: 'Allow' }
            rules: [
              {
                ruleType: 'ApplicationRule'
                name: 'azure-apis'
                protocols: https
                sourceAddresses: sreEgressSourcePrefixes
                targetFqdns: [
                  replace(replace(environment().resourceManager, 'https://', ''), '/', '')
                  'api.loganalytics.io'
                  'api.loganalytics.azure.com'
                  'api.applicationinsights.io'
                  '*.ods.opinsights.azure.com'
                  '*.monitor.azure.com'
                  loginHost
                  '*.${loginHost}'
                  'graph.microsoft.com'
                ]
              }
            ]
          }
        ]
      }
    ]

module firewallPolicy 'br/public:avm/res/network/firewall-policy:0.3.6' = {
  name: 'afwp'
  params: {
    name: names.firewallPolicy
    location: location
    tags: tags
    tier: 'Basic'
    threatIntelMode: 'Alert'
    ruleCollectionGroups: concat([
      {
        name: 'aca-egress'
        priority: 200
        ruleCollections: [
          {
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'aca-network'
            priority: 100
            action: { type: 'Allow' }
            rules: [
              {
                ruleType: 'NetworkRule'
                name: 'azure-platform'
                ipProtocols: ['TCP']
                sourceAddresses: spokeEgressSourcePrefixes
                destinationAddresses: [
                  'MicrosoftContainerRegistry'
                  'AzureFrontDoor.FirstParty'
                  'AzureContainerRegistry'
                  'AzureActiveDirectory'
                  'AzureMonitor'
                  'AzureKeyVault'
                ]
                destinationPorts: ['443']
              }
              {
                ruleType: 'NetworkRule'
                name: 'ntp'
                ipProtocols: ['UDP']
                sourceAddresses: spokeEgressSourcePrefixes
                destinationAddresses: ['*']
                destinationPorts: ['123']
              }
            ]
          }
          {
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'aca-application'
            priority: 200
            action: { type: 'Allow' }
            rules: [
              {
                ruleType: 'ApplicationRule'
                name: 'container-images'
                protocols: httpAndHttps
                sourceAddresses: spokeEgressSourcePrefixes
                targetFqdns: [
                  'mcr.microsoft.com'
                  '*.data.mcr.microsoft.com'
                  '*.azurecr.io'
                  '*.blob.${environment().suffixes.storage}'
                ]
              }
              {
                ruleType: 'ApplicationRule'
                name: 'identity'
                protocols: https
                sourceAddresses: spokeEgressSourcePrefixes
                targetFqdns: [
                  '*.identity.azure.net'
                  loginHost
                  '*.${loginHost}'
                  'login.microsoft.com'
                  '*.login.microsoft.com'
                ]
              }
              {
                ruleType: 'ApplicationRule'
                name: 'azure-monitor'
                protocols: https
                sourceAddresses: spokeEgressSourcePrefixes
                targetFqdns: [
                  'dc.applicationinsights.azure.com'
                  'dc.applicationinsights.microsoft.com'
                  'dc.services.visualstudio.com'
                  '*.in.applicationinsights.azure.com'
                  'live.applicationinsights.azure.com'
                  'rt.applicationinsights.microsoft.com'
                  'rt.services.visualstudio.com'
                  '*.livediagnostics.monitor.azure.com'
                  '*.monitoring.azure.com'
                  '*.monitor.azure.com'
                ]
              }
              {
                ruleType: 'ApplicationRule'
                name: 'certificates'
                protocols: httpAndHttps
                sourceAddresses: spokeEgressSourcePrefixes
                targetFqdns: [
                  'ctldl.windowsupdate.com'
                  'ocsp.msocsp.com'
                  'oneocsp.microsoft.com'
                  'crl.microsoft.com'
                  'www.microsoft.com'
                  '*.digicert.com'
                ]
              }
            ]
          }
        ]
      }
      {
        name: 'jumpbox-egress'
        priority: 300
        ruleCollections: [
          {
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'jumpbox-web'
            priority: 100
            action: { type: 'Allow' }
            rules: [
              {
                ruleType: 'ApplicationRule'
                name: 'any-web'
                protocols: httpAndHttps
                sourceAddresses: [prefixes.jumpbox]
                targetFqdns: ['*']
              }
            ]
          }
        ]
      }
    ], sreRuleCollectionGroups)
  }
}

module firewall 'br/public:avm/res/network/azure-firewall:0.11.1' = {
  name: 'afw'
  params: {
    name: names.firewall
    location: location
    tags: tags
    azureSkuTier: 'Basic'
    virtualNetworkResourceId: vnet.outputs.resourceId
    firewallPolicyId: firewallPolicy.outputs.resourceId
    availabilityZones: []
    diagnosticSettings: diagnostics
  }
}

module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = if (deployBastion) {
  name: 'bastion'
  params: {
    name: names.bastion
    location: location
    tags: tags
    skuName: 'Basic'
    virtualNetworkResourceId: vnet.outputs.resourceId
    diagnosticSettings: diagnostics
  }
}

module jumpbox 'br/public:avm/res/compute/virtual-machine:0.22.3' = if (deployJumpbox) {
  name: 'jumpbox'
  params: {
    name: names.jumpbox
    location: location
    tags: tags
    osType: 'Linux'
    vmSize: 'Standard_B2s'
    availabilityZone: -1
    adminUsername: jumpboxAdminUsername
    disablePasswordAuthentication: true
    publicKeys: [
      {
        path: '/home/${jumpboxAdminUsername}/.ssh/authorized_keys'
        keyData: jumpboxSshPublicKey
      }
    ]
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: 'latest'
    }
    osDisk: {
      caching: 'ReadWrite'
      diskSizeGB: 64
      managedDisk: { storageAccountType: 'StandardSSD_LRS' }
    }
    nicConfigurations: [
      {
        nicSuffix: '-nic'
        ipConfigurations: [
          {
            name: 'ipconfig1'
            subnetResourceId: vnet.outputs.subnetResourceIds[length(vnet.outputs.subnetResourceIds) - 1]
          }
        ]
      }
    ]
  }
  dependsOn: [firewall]
}

output vnetResourceId string = vnet.outputs.resourceId
output firewallPrivateIp string = firewall.outputs.privateIp
output firewallResourceId string = firewall.outputs.resourceId
