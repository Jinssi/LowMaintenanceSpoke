// Spoke VNet: ACA subnet (delegated), private endpoint subnet, optional App Gateway subnet,
// NSGs, egress UDR to the hub firewall and spoke<->hub peering.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param logAnalyticsWorkspaceId string

@description('Spoke VNet address space.')
param addressSpace string

@description('Subnet prefixes: { aca, privateEndpoints, appGateway, sreL1, sreL2 }.')
param subnetPrefixes object

@description('Create the App Gateway subnet.')
param deployAppGatewaySubnet bool

@description('Create the dedicated, delegated subnets used by the SRE agents in Azure VNet egress mode.')
param deploySreSubnets bool

@description('Custom DNS servers for the spoke (e.g. hub DNS resolver / firewall DNS proxy). Empty = Azure DNS.')
param dnsServers array

@description('Hub VNet resource ID. Empty = standalone spoke (no peering).')
param hubVnetResourceId string

@description('Also create the hub->spoke side of the peering (needs Network Contributor on the hub).')
param createHubSidePeering bool

@description('Private IP of the hub firewall/NVA. Empty = no UDR.')
param hubFirewallPrivateIp string

var diagnostics = [{ workspaceResourceId: logAnalyticsWorkspaceId }]

// NSG service tags use 'centralfrance' while the region is 'francecentral'.
var serviceTagRegion = location == 'francecentral' ? 'centralfrance' : location
var acaNsgRules = json(replace(loadTextContent('rules/nsg-aca.json'), '<location>', serviceTagRegion)).securityRules
var agwNsgRules = loadJsonContent('rules/nsg-agw.json').securityRules

module nsgAca 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-aca'
  params: {
    name: names.nsgAca
    location: location
    tags: tags
    securityRules: acaNsgRules
    diagnosticSettings: diagnostics
  }
}

module nsgPep 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-pep'
  params: {
    name: names.nsgPep
    location: location
    tags: tags
    diagnosticSettings: diagnostics
  }
}

module nsgAgw 'br/public:avm/res/network/network-security-group:0.5.3' = if (deployAppGatewaySubnet) {
  name: 'nsg-agw'
  params: {
    name: names.nsgAgw
    location: location
    tags: tags
    securityRules: agwNsgRules
    diagnosticSettings: diagnostics
  }
}

// SRE agents only make outbound calls; the default NSG rules are sufficient and egress is filtered by the hub firewall.
module nsgSre 'br/public:avm/res/network/network-security-group:0.5.3' = if (deploySreSubnets) {
  name: 'nsg-sre'
  params: {
    name: names.nsgSre
    location: location
    tags: tags
    diagnosticSettings: diagnostics
  }
}

module routeTable 'br/public:avm/res/network/route-table:0.5.0' = if (!empty(hubFirewallPrivateIp)) {
  name: 'rt-spoke'
  params: {
    name: names.routeTable
    location: location
    tags: tags
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-hub-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: hubFirewallPrivateIp
        }
      }
    ]
  }
}

var acaSubnet = {
  name: 'snet-aca'
  addressPrefix: subnetPrefixes.aca
  delegation: 'Microsoft.App/environments'
  networkSecurityGroupResourceId: nsgAca.outputs.resourceId
  routeTableResourceId: empty(hubFirewallPrivateIp) ? null : routeTable!.outputs.resourceId
}

var pepSubnet = {
  name: 'snet-pep'
  addressPrefix: subnetPrefixes.privateEndpoints
  networkSecurityGroupResourceId: nsgPep.outputs.resourceId
  privateEndpointNetworkPolicies: 'Enabled'
}

var agwSubnet = {
  name: 'snet-agw'
  addressPrefix: subnetPrefixes.appGateway
  networkSecurityGroupResourceId: deployAppGatewaySubnet ? nsgAgw!.outputs.resourceId : null
}

// One dedicated /27 per SRE agent (requirement for Azure VNet egress mode).
var sreSubnetCommon = {
  delegation: 'Microsoft.App/environments'
  networkSecurityGroupResourceId: deploySreSubnets ? nsgSre!.outputs.resourceId : null
  routeTableResourceId: empty(hubFirewallPrivateIp) ? null : routeTable!.outputs.resourceId
}
var sreSubnets = [
  union(sreSubnetCommon, { name: 'snet-sre-l1', addressPrefix: subnetPrefixes.?sreL1 ?? '' })
  union(sreSubnetCommon, { name: 'snet-sre-l2', addressPrefix: subnetPrefixes.?sreL2 ?? '' })
]

module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-spoke'
  params: {
    name: names.spokeVnet
    location: location
    tags: tags
    addressPrefixes: [addressSpace]
    dnsServers: dnsServers
    subnets: concat(
      [acaSubnet, pepSubnet],
      deployAppGatewaySubnet ? [agwSubnet] : [],
      deploySreSubnets ? sreSubnets : []
    )
    diagnosticSettings: diagnostics
    peerings: empty(hubVnetResourceId)
      ? []
      : [
          {
            name: 'to-hub'
            remoteVirtualNetworkResourceId: hubVnetResourceId
            allowForwardedTraffic: true
            allowVirtualNetworkAccess: true
            useRemoteGateways: false
            remotePeeringEnabled: createHubSidePeering
            remotePeeringName: 'to-${names.spokeVnet}'
            remotePeeringAllowForwardedTraffic: true
            remotePeeringAllowVirtualNetworkAccess: true
          }
        ]
  }
}

var subnetIdPrefix = '${vnet.outputs.resourceId}/subnets'

output vnetResourceId string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name
output acaSubnetResourceId string = '${subnetIdPrefix}/snet-aca'
output privateEndpointSubnetResourceId string = '${subnetIdPrefix}/snet-pep'
output appGatewaySubnetResourceId string = deployAppGatewaySubnet ? '${subnetIdPrefix}/snet-agw' : ''
output sreL1SubnetResourceId string = deploySreSubnets ? '${subnetIdPrefix}/snet-sre-l1' : ''
output sreL2SubnetResourceId string = deploySreSubnets ? '${subnetIdPrefix}/snet-sre-l2' : ''
