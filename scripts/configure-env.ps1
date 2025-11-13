param(
  [string]$TenantId,
  [string]$EnvironmentName,
  [string]$ClientId,
  [securestring]$ClientSecret,
  [switch]$UseSecretStore
)

$ErrorActionPreference = 'Stop'

function Ensure-SecretStore {
  if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement)) {
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Install-Module Microsoft.PowerShell.SecretManagement -Scope CurrentUser -Force
  }
  if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretStore)) {
    Install-Module Microsoft.PowerShell.SecretStore -Scope CurrentUser -Force
  }
  Import-Module Microsoft.PowerShell.SecretManagement -Force
  Import-Module Microsoft.PowerShell.SecretStore -Force
  if (-not (Get-SecretVault -Name 'LocalSecretStore' -ErrorAction SilentlyContinue)) {
    Register-SecretVault -Name 'LocalSecretStore' -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
  }
}

# Prompt for missing inputs
if ([string]::IsNullOrWhiteSpace($TenantId))        { $TenantId = Read-Host 'Tenant ID (GUID)' }
if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { $EnvironmentName = Read-Host 'Environment Name (e.g. Sandbox)' }
if ([string]::IsNullOrWhiteSpace($ClientId))        { $ClientId = Read-Host 'Client ID (App Registration)' }
if (-not $ClientSecret)                             { $ClientSecret = Read-Host 'Client Secret' -AsSecureString }

# Persist non-secret values as User environment variables
[Environment]::SetEnvironmentVariable('BC_TENANT_ID', $TenantId, 'User')
[Environment]::SetEnvironmentVariable('BC_ENVIRONMENT', $EnvironmentName, 'User')
[Environment]::SetEnvironmentVariable('BC_CLIENT_ID', $ClientId, 'User')

# Persist secret either in SecretStore (recommended) or as env var (not recommended)
if ($UseSecretStore) {
  Ensure-SecretStore
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret))
  try {
    Set-Secret -Name 'BC_CLIENT_SECRET' -Secret $plain -Vault 'LocalSecretStore'
    Write-Host -ForegroundColor Green 'Stored BC_CLIENT_SECRET in SecretStore (LocalSecretStore).'
  }
  finally {
    if ($plain) { [System.Array]::Clear([char[]]$plain, 0, $plain.Length) }
  }
}
else {
  # WARNING: This stores the secret in plaintext in your user env variables
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret))
  [Environment]::SetEnvironmentVariable('BC_CLIENT_SECRET', $plain, 'User')
  Write-Host -ForegroundColor Yellow 'Stored BC_CLIENT_SECRET as a user environment variable (plaintext). Consider -UseSecretStore.'
}

# Update current session so you can use it immediately
$env:BC_TENANT_ID   = [Environment]::GetEnvironmentVariable('BC_TENANT_ID', 'User')
$env:BC_ENVIRONMENT = [Environment]::GetEnvironmentVariable('BC_ENVIRONMENT', 'User')
$env:BC_CLIENT_ID   = [Environment]::GetEnvironmentVariable('BC_CLIENT_ID', 'User')
if (-not $UseSecretStore) {
  $env:BC_CLIENT_SECRET = [Environment]::GetEnvironmentVariable('BC_CLIENT_SECRET', 'User')
}

Write-Host -ForegroundColor Green 'Configuration saved. New terminals will inherit these values.'
