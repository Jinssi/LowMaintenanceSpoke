# Spoke network diagnostics (read-only)

Typical symptoms: several apps failing together, dependency timeouts to Key Vault/ACR/Foundry, image pull errors,
token acquisition failures, App Gateway unhealthy backends, firewall health or SNAT alerts.

Work from the inside out:

1. **Private endpoints.** ACR, Key Vault and Foundry have public access disabled.
   ```bash
   az network private-endpoint list -g {{SPOKE_RG}} --query "[].{name:name, state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status, ip:customDnsConfigs[0].ipAddresses[0], fqdn:customDnsConfigs[0].fqdn}" -o table
   ```
   Every connection must be `Approved`.
2. **Private DNS.** Each `privatelink.*` zone (and the apps domain zone `{{APPS_DOMAIN}}`) must be linked to the spoke VNet
   (and the hub VNet when hub resolvers are used), with A records that match the private endpoint IPs.
   ```bash
   az network private-dns zone list -g {{SPOKE_RG}} -o table
   az network private-dns link vnet list -g {{SPOKE_RG}} -z <zone> -o table
   az network private-dns record-set a list -g {{SPOKE_RG}} -z <zone> -o table
   ```
3. **Routing.** `snet-aca` and the SRE subnets use route table `rt-*-spoke-*` with `0.0.0.0/0 → hub firewall`.
   Check `az network vnet subnet show` for the route table and NSG association, and the peering state:
   `az network vnet peering list -g {{SPOKE_RG}} --vnet-name <spoke vnet> -o table` (must be `Connected`).
4. **Firewall (test hub `{{FIREWALL}}`).** Query denies for the spoke subnets (`AZFWApplicationRule`, `AZFWNetworkRule`
   with `Action == "Deny"`). A new FQDN that an app or the platform needs shows up here first. For a platform-owned hub
   you can't see the firewall, so list the denied FQDN as `[HUMAN-NEEDED]` for the platform team.
5. **App Gateway (`{{APP_GATEWAY}}`).** `az network application-gateway show-backend-health -g {{SPOKE_RG}} -n {{APP_GATEWAY}}`.
   The probe uses `healthprobe.{{APPS_DOMAIN}}` and accepts 200–499, so *unhealthy* means TLS or connectivity to the
   environment's static IP failed (certificate expired or mismatched, NSG, environment down).
6. **Container Apps environment.** `az containerapp env show -g {{SPOKE_RG}} -n {{ACA_ENV}} --query "properties.{state:provisioningState, ip:staticIp, domain:defaultDomain}"`.

Report as: failing hop → evidence → required change (file/parameter) → owner (spoke IaC or platform team).
You never change network resources.
