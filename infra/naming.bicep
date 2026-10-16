// Single source of truth for resource names.
// Imported by infra/main.bicep (platform) and apps/_shared/container-app.bicep (apps),
// so app deployments can find platform resources without passing outputs around.

@export()
@description('Short unique token derived from subscription, workload and environment. Used for globally unique names.')
func uniqueToken(subscriptionId string, workload string, env string) string =>
  take(uniqueString(subscriptionId, workload, env), 5)

@export()
@description('All resource names for a given workload/environment.')
func resourceNames(workload string, env string, token string) object => {
  hubResourceGroup: 'rg-${workload}-hub-${env}'
  spokeResourceGroup: 'rg-${workload}-spoke-${env}'

  // test hub
  hubVnet: 'vnet-${workload}-hub-${env}'
  firewall: 'afw-${workload}-hub-${env}'
  firewallPolicy: 'afwp-${workload}-hub-${env}'
  bastion: 'bas-${workload}-hub-${env}'
  jumpbox: 'vm-${workload}-jump-${env}'

  // spoke network
  spokeVnet: 'vnet-${workload}-spoke-${env}'
  nsgAca: 'nsg-${workload}-aca-${env}'
  nsgPep: 'nsg-${workload}-pep-${env}'
  nsgAgw: 'nsg-${workload}-agw-${env}'
  routeTable: 'rt-${workload}-spoke-${env}'

  // shared services
  logAnalytics: 'log-${workload}-${env}'
  appInsights: 'appi-${workload}-${env}'
  identity: 'id-${workload}-apps-${env}'
  containerRegistry: 'cr${replace(workload, '-', '')}${env}${token}'
  keyVault: 'kv${replace(workload, '-', '')}${env}${token}'

  // workload hosting
  containerAppsEnvironment: 'cae-${workload}-${env}'
  foundry: 'aif-${workload}-${env}-${token}'
  foundryProject: 'proj-${workload}-${env}'
  appGateway: 'agw-${workload}-${env}'
  appGatewayPip: 'pip-${workload}-agw-${env}'
  appGatewayWafPolicy: 'waf-${workload}-${env}'

  // operations (Azure Monitor + SRE agents)
  sreResourceGroup: 'rg-${workload}-sre-${env}'
  nsgSre: 'nsg-${workload}-sre-${env}'
  actionGroup: 'ag-${workload}-oncall-${env}'
  alertRulePrefix: 'ar-${workload}-${env}'
  sreAppInsights: 'appi-${workload}-sre-${env}'
  sreAgentL1: 'sre-${workload}-l1-${env}'
  sreAgentL2: 'sre-${workload}-l2-${env}'
  sreIdentityL1: 'id-${workload}-sre-l1-${env}'
  sreIdentityL2: 'id-${workload}-sre-l2-${env}'
}
