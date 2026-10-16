using './main.bicep'

// Values read from the azd environment fall back to sensible defaults when deploying with plain az CLI.
param workloadName = readEnvironmentVariable('WORKLOAD_NAME', 'lowmaint')
param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'dev')
param location = readEnvironmentVariable('AZURE_LOCATION', 'swedencentral')
param adminPrincipalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')

param tags = {
  owner: 'platform-team'
}

// --- Hub -------------------------------------------------------------------
// Production: set hubVnetResourceId + hubFirewallPrivateIp and keep deployTestHub = false.
param deployTestHub = bool(readEnvironmentVariable('DEPLOY_TEST_HUB', 'false'))
param hubVnetResourceId = readEnvironmentVariable('HUB_VNET_RESOURCE_ID', '')
param hubFirewallPrivateIp = readEnvironmentVariable('HUB_FIREWALL_PRIVATE_IP', '')
param testHubJumpboxSshPublicKey = readEnvironmentVariable('JUMPBOX_SSH_PUBLIC_KEY', '')

// --- Spoke network -----------------------------------------------------------
param spokeAddressSpace = '10.1.0.0/22'
param spokeSubnets = {
  aca: '10.1.0.0/23'
  privateEndpoints: '10.1.2.0/26'
  sreL1: '10.1.2.64/27'
  sreL2: '10.1.2.96/27'
  appGateway: '10.1.3.0/24'
}

// --- Private DNS -------------------------------------------------------------
param privateDnsZoneMode = 'Create'

// --- Apps --------------------------------------------------------------------
// Phase 2 (optional): after uploading a wildcard cert to Key Vault, set both and re-run `azd provision`.
param appsDnsSuffix = readEnvironmentVariable('APPS_DNS_SUFFIX', '')
param appsCertificateName = readEnvironmentVariable('APPS_CERTIFICATE_NAME', '')

// --- Foundry -----------------------------------------------------------------
param deployFoundry = true

// --- Ingress -----------------------------------------------------------------
param deployAppGateway = bool(readEnvironmentVariable('DEPLOY_APP_GATEWAY', 'false'))
param appGatewayBackendTrustedRootCertificate = readEnvironmentVariable('APPS_CA_CERT_BASE64', '')

// --- Operations: Azure Monitor alerts + SRE agents ------------------------------
// ALERT_EMAILS is a comma-separated list, e.g. "oncall@contoso.com,sre@contoso.com".
param alertEmailAddresses = map(filter(split(readEnvironmentVariable('ALERT_EMAILS', ''), ','), e => !empty(trim(e))), e => trim(e))
param deploySreAgents = bool(readEnvironmentVariable('DEPLOY_SRE_AGENTS', 'true'))
param sreAgentNetworkMode = readEnvironmentVariable('SRE_AGENT_NETWORK_MODE', 'AzureVNet')
param sreOperatorsGroupId = readEnvironmentVariable('SRE_OPERATORS_GROUP_ID', '')
param sreMonthlyAgentUnitLimits = {
  l1: 3000
  l2: 5000
}
