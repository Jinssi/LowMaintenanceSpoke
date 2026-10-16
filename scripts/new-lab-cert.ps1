<#
.SYNOPSIS
  LAB ONLY: creates a self-signed wildcard certificate (*.DnsSuffix) in the spoke Key Vault and
  configures the azd environment so the next `azd provision` enables the custom apps domain
  (and App Gateway if -EnableAppGateway). For production, import a CA-issued wildcard cert instead.

.DESCRIPTION
  The Key Vault has public access disabled. This script temporarily allows only your public IP,
  creates the certificate, and locks the vault again.

.EXAMPLE
  ./scripts/new-lab-cert.ps1 -DnsSuffix apps.contoso.com -EnableAppGateway
  azd provision
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DnsSuffix,
    [string] $CertificateName = 'apps-wildcard',
    [switch] $EnableAppGateway
)
$ErrorActionPreference = 'Stop'

$values = azd env get-values --output json | ConvertFrom-Json
if (-not $values.KEY_VAULT_NAME) { throw 'KEY_VAULT_NAME missing from azd environment. Run `azd provision` first.' }
$kv = $values.KEY_VAULT_NAME
if ($values.AZURE_SUBSCRIPTION_ID) { az account set --subscription $values.AZURE_SUBSCRIPTION_ID | Out-Null }

$myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
$policyFile = Join-Path ([IO.Path]::GetTempPath()) "kv-cert-policy-$([guid]::NewGuid()).json"
$cerFile = Join-Path ([IO.Path]::GetTempPath()) "$CertificateName-$([guid]::NewGuid()).cer"

try {
    Write-Host "Temporarily allowing $myIp on Key Vault $kv ..."
    az keyvault update --name $kv --public-network-access Enabled --default-action Deny --output none
    az keyvault network-rule add --name $kv --ip-address "$myIp/32" --output none
    Start-Sleep -Seconds 20 # network rule propagation

    $policy = az keyvault certificate get-default-policy | ConvertFrom-Json
    $policy.x509CertificateProperties.subject = "CN=*.$DnsSuffix"
    $policy.x509CertificateProperties | Add-Member -Force -NotePropertyName subjectAlternativeNames -NotePropertyValue @{ dnsNames = @("*.$DnsSuffix", $DnsSuffix) }
    $policy.x509CertificateProperties.validityInMonths = 12
    $policy | ConvertTo-Json -Depth 10 | Set-Content $policyFile -Encoding utf8

    Write-Host "Creating self-signed certificate '$CertificateName' for *.$DnsSuffix ..."
    az keyvault certificate create --vault-name $kv --name $CertificateName --policy "@$policyFile" --output none
    az keyvault certificate download --vault-name $kv --name $CertificateName --encoding DER --file $cerFile
    $caBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cerFile))
}
finally {
    Write-Host 'Locking Key Vault again ...'
    az keyvault network-rule remove --name $kv --ip-address "$myIp/32" --output none 2>$null
    az keyvault update --name $kv --public-network-access Disabled --output none
    Remove-Item $policyFile, $cerFile -ErrorAction SilentlyContinue
}

azd env set APPS_DNS_SUFFIX $DnsSuffix
azd env set APPS_CERTIFICATE_NAME $CertificateName
azd env set APPS_CA_CERT_BASE64 $caBase64
if ($EnableAppGateway) { azd env set DEPLOY_APP_GATEWAY true }

Write-Host "Done. Run 'azd provision' to apply the custom domain$(if ($EnableAppGateway) { ' and App Gateway' })." -ForegroundColor Green
