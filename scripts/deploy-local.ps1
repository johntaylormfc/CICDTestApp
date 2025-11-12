param(
  [string]$TenantId,
  [string]$EnvironmentName,
  [string]$ClientId,
  [string]$ClientSecret,
  [string]$ArtifactsFolder = (Join-Path (Resolve-Path "$PSScriptRoot\..\").Path 'artifacts')
)

$ErrorActionPreference = 'Stop'

# Ensure BcContainerHelper
if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Install-Module BcContainerHelper -Scope CurrentUser -Force
}
Import-Module BcContainerHelper -Force

# Prefer environment variables if parameters were not supplied
$TenantId        = if ([string]::IsNullOrWhiteSpace($TenantId))        { $env:BC_TENANT_ID }        else { $TenantId }
$EnvironmentName = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { $env:BC_ENVIRONMENT }      else { $EnvironmentName }
$ClientId        = if ([string]::IsNullOrWhiteSpace($ClientId))        { $env:BC_CLIENT_ID }        else { $ClientId }
$ClientSecret    = if ([string]::IsNullOrWhiteSpace($ClientSecret))    { $env:BC_CLIENT_SECRET }    else { $ClientSecret }

# Validate required inputs without echoing secrets
if ([string]::IsNullOrWhiteSpace($TenantId))        { throw 'TenantId is required. Set -TenantId or $env:BC_TENANT_ID.' }
if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { throw 'EnvironmentName is required. Set -EnvironmentName or $env:BC_ENVIRONMENT.' }
if ([string]::IsNullOrWhiteSpace($ClientId))        { throw 'ClientId is required. Set -ClientId or $env:BC_CLIENT_ID.' }
if ([string]::IsNullOrWhiteSpace($ClientSecret))    { throw 'ClientSecret is required. Set -ClientSecret or $env:BC_CLIENT_SECRET.' }

if (-not (Test-Path $ArtifactsFolder)) { throw "Artifacts folder not found: $ArtifactsFolder" }
$appFiles = Get-ChildItem -Path $ArtifactsFolder -Filter '*.app' | Select-Object -ExpandProperty FullName
if (-not $appFiles) { throw "No .app files found in $ArtifactsFolder" }

$secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
$bcAuthContext = New-BcAuthContext -tenantId $TenantId -clientId $ClientId -clientSecret $secureSecret

Publish-PerTenantExtensionApps `
  -bcAuthContext $bcAuthContext `
  -environment $EnvironmentName `
  -appFiles $appFiles

Write-Host "Deployment completed to environment: $EnvironmentName"