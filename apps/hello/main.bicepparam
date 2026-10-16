using '../_shared/container-app.bicep'

// Platform identity (set automatically by scripts/deploy-app.ps1 from the azd environment).
param workloadName = readEnvironmentVariable('WORKLOAD_NAME', 'lowmaint')
param environmentName = readEnvironmentVariable('ENVIRONMENT_NAME', 'dev')

// App definition — this is all an app team needs to edit.
param name = 'hello'
param image = 'mcr.microsoft.com/k8se/quickstart:latest'
param targetPort = 80
param cpu = '0.25'
param memory = '0.5Gi'
param minReplicas = 0
param maxReplicas = 2
param exposure = 'vnet'
param useFoundry = true

param env = {
  GREETING: 'Hello from the low-maintenance spoke'
}

// Key Vault secret references: { ENV_VAR: 'secret-name' }
param keyVaultReferences = {}
