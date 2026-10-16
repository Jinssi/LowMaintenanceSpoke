// Creates Private DNS zones and links them to the given VNets.
targetScope = 'resourceGroup'

param tags object

@description('Map of logical key -> zone name, e.g. { acr: \'privatelink.azurecr.io\' }.')
param zones object

@description('VNet resource IDs to link every zone to (spoke and, if present, hub).')
param vnetResourceIds array

var zoneList = items(zones)

module zone 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for z in zoneList: {
    name: 'pdz-${z.key}'
    params: {
      name: z.value
      location: 'global'
      tags: tags
      virtualNetworkLinks: [
        for (vnetId, i) in vnetResourceIds: {
          name: 'link-${last(split(vnetId, '/'))}'
          virtualNetworkResourceId: vnetId
          registrationEnabled: false
        }
      ]
    }
  }
]

@description('Logical key + private DNS zone resource ID for every zone.')
output zones array = [
  for (z, i) in zoneList: {
    key: z.key
    id: zone[i].outputs.resourceId
  }
]
