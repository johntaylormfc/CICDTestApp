param(
    [Parameter(Mandatory=$true)][string]$TenantId,
    [Parameter(Mandatory=$true)][string]$EnvironmentName,
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ClientSecret,
    [string]$ArtifactsFolder = (Join-Path (Resolve-Path "$PSScriptRoot\..\").Path 'artifacts')
)

$ErrorActionPreference = 'Stop'

# Ensure BcContainerHelper
if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Install-Module BcContainerHelper -Scope CurrentUser -Force
}
Import-Module BcContainerHelper -Force

if (-not (Test-Path $ArtifactsFolder)) { throw "Artifacts folder not found: $ArtifactsFolder" }
$appFiles = Get-ChildItem -Path $ArtifactsFolder -Filter '*.app' | Select-Object -ExpandProperty FullName
if (-not $appFiles) { throw "No .app files found in $ArtifactsFolder" }

$secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
$bcAuthContext = New-BcAuthContext -tenantId $TenantId -clientId $ClientId -clientSecret $secureSecret

Publish-PerTenantExtensionApps `
  -bcAuthContext $bcAuthContext `
  -environment $EnvironmentName `
  -appFiles $appFiles `
  -skipVerification:$true `
  -doNotInstallApps:$false `
  -InstallPublishedApps:$true

Write-Host "Deployment completed to environment: $EnvironmentName"