// Optional single entry point: App Gateway WAF_v2 with ONE wildcard listener (*.appsDnsSuffix)
// forwarding to the internal Container Apps environment. The original Host header is preserved,
// so new apps are reachable without touching the gateway.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param logAnalyticsWorkspaceId string
param subnetResourceId string
param identityResourceId string
param keyVaultUri string

@description('Wildcard DNS suffix served by the gateway (same as the ACA environment custom DNS suffix).')
param appsDnsSuffix string

@description('Key Vault certificate name holding *.appsDnsSuffix.')
param certificateName string

@description('Base64 (DER/.cer) root certificate for backends signed by a private/self-signed CA. Empty = public CA.')
param backendTrustedRootCertificate string

@description('Expose the listener on the public IP or on a private IP in the App Gateway subnet.')
@allowed(['Public', 'Private'])
param frontend string

@description('Static private frontend IP (inside the App Gateway subnet).')
param privateFrontendIp string

@description('Internal IP of the Container Apps environment.')
param backendIp string

@allowed(['Detection', 'Prevention'])
param wafMode string

param zoneRedundant bool

var zones = zoneRedundant ? [1, 2, 3] : []
var agwId = resourceId('Microsoft.Network/applicationGateways', names.appGateway)
var frontendIpName = frontend == 'Public' ? 'fe-public' : 'fe-private'
var useTrustedRoot = !empty(backendTrustedRootCertificate)

module wafPolicy 'br/public:avm/res/network/application-gateway-web-application-firewall-policy:0.3.0' = {
  name: 'waf-policy'
  params: {
    name: names.appGatewayWafPolicy
    location: location
    tags: tags
    policySettings: {
      state: 'Enabled'
      mode: wafMode
      requestBodyCheck: true
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.1'
        }
      ]
    }
  }
}

// App Gateway v2 always needs a public IP, even when the listener is private.
module publicIp 'br/public:avm/res/network/public-ip-address:0.13.0' = {
  name: 'pip-agw'
  params: {
    name: names.appGatewayPip
    location: location
    tags: tags
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
    availabilityZones: zones
  }
}

module appGateway 'br/public:avm/res/network/application-gateway:0.10.0' = {
  name: 'agw'
  params: {
    name: names.appGateway
    location: location
    tags: tags
    sku: 'WAF_v2'
    autoscaleMinCapacity: 0
    autoscaleMaxCapacity: 3
    availabilityZones: zones
    enableHttp2: true
    firewallPolicyResourceId: wafPolicy.outputs.resourceId
    managedIdentities: {
      userAssignedResourceIds: [identityResourceId]
    }
    sslPolicyType: 'Predefined'
    sslPolicyName: 'AppGwSslPolicy20220101'
    gatewayIPConfigurations: [
      {
        name: 'gw-ipconfig'
        properties: { subnet: { id: subnetResourceId } }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'fe-public'
        properties: { publicIPAddress: { id: publicIp.outputs.resourceId } }
      }
      {
        name: 'fe-private'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateFrontendIp
          subnet: { id: subnetResourceId }
        }
      }
    ]
    frontendPorts: [
      { name: 'port-80', properties: { port: 80 } }
      { name: 'port-443', properties: { port: 443 } }
    ]
    sslCertificates: [
      {
        name: 'apps-wildcard'
        properties: { keyVaultSecretId: '${keyVaultUri}secrets/${certificateName}' }
      }
    ]
    trustedRootCertificates: useTrustedRoot
      ? [
          {
            name: 'backend-root'
            properties: { data: backendTrustedRootCertificate }
          }
        ]
      : []
    backendAddressPools: [
      {
        name: 'aca-environment'
        properties: { backendAddresses: [{ ipAddress: backendIp }] }
      }
    ]
    probes: [
      {
        name: 'aca-environment'
        properties: {
          protocol: 'Https'
          host: 'healthprobe.${appsDnsSuffix}'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          // Unknown hosts return 404 from the environment; any HTTP answer means it is up.
          match: { statusCodes: ['200-499'] }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'aca-https'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 60
          // No host override: the client's Host header (<app>.<suffix>) selects the container app.
          pickHostNameFromBackendAddress: false
          probe: { id: '${agwId}/probes/aca-environment' }
          trustedRootCertificates: useTrustedRoot ? [{ id: '${agwId}/trustedRootCertificates/backend-root' }] : []
        }
      }
    ]
    httpListeners: [
      {
        name: 'apps-https'
        properties: {
          frontendIPConfiguration: { id: '${agwId}/frontendIPConfigurations/${frontendIpName}' }
          frontendPort: { id: '${agwId}/frontendPorts/port-443' }
          protocol: 'Https'
          sslCertificate: { id: '${agwId}/sslCertificates/apps-wildcard' }
          hostNames: ['*.${appsDnsSuffix}']
          requireServerNameIndication: true
        }
      }
      {
        name: 'apps-http'
        properties: {
          frontendIPConfiguration: { id: '${agwId}/frontendIPConfigurations/${frontendIpName}' }
          frontendPort: { id: '${agwId}/frontendPorts/port-80' }
          protocol: 'Http'
          hostNames: ['*.${appsDnsSuffix}']
        }
      }
    ]
    redirectConfigurations: [
      {
        name: 'http-to-https'
        properties: {
          redirectType: 'Permanent'
          targetListener: { id: '${agwId}/httpListeners/apps-https' }
          includePath: true
          includeQueryString: true
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'apps-https'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: { id: '${agwId}/httpListeners/apps-https' }
          backendAddressPool: { id: '${agwId}/backendAddressPools/aca-environment' }
          backendHttpSettings: { id: '${agwId}/backendHttpSettingsCollection/aca-https' }
        }
      }
      {
        name: 'apps-http-redirect'
        properties: {
          ruleType: 'Basic'
          priority: 200
          httpListener: { id: '${agwId}/httpListeners/apps-http' }
          redirectConfiguration: { id: '${agwId}/redirectConfigurations/http-to-https' }
        }
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

output resourceId string = appGateway.outputs.resourceId
output publicIpAddress string = publicIp.outputs.ipAddress
output privateIpAddress string = privateFrontendIp
output listenerIp string = frontend == 'Public' ? publicIp.outputs.ipAddress : privateFrontendIp
