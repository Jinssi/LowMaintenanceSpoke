// Assigns a set of built-in roles to one or more principals at subscription scope.
targetScope = 'subscription'

param principalIds array
param roleDefinitionIds array

@allowed(['ServicePrincipal', 'User', 'Group'])
param principalType string = 'ServicePrincipal'

var assignments = flatten(map(principalIds, p => map(roleDefinitionIds, r => { principalId: p, roleId: r })))

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in assignments: {
    name: guid(subscription().id, a.principalId, a.roleId)
    properties: {
      principalId: a.principalId
      principalType: principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.roleId)
    }
  }
]
