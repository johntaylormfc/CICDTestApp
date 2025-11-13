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

# Optional fallback: pull secret from SecretManagement 'BC_CLIENT_SECRET' if env var not set
if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
  try {
    if (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement) {
      $secret = Get-Secret -Name 'BC_CLIENT_SECRET' -AsPlainText -ErrorAction Stop
      if (-not [string]::IsNullOrWhiteSpace($secret)) {
        $ClientSecret = $secret
      }
    }
  }
  catch {
    # ignore; script will error later if still missing
  }
}

# Validate required inputs without echoing secrets
if ([string]::IsNullOrWhiteSpace($TenantId))        { throw 'TenantId is required. Set -TenantId or $env:BC_TENANT_ID.' }
if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { throw 'EnvironmentName is required. Set -EnvironmentName or $env:BC_ENVIRONMENT.' }
if ([string]::IsNullOrWhiteSpace($ClientId))        { throw 'ClientId is required. Set -ClientId or $env:BC_CLIENT_ID.' }
if ([string]::IsNullOrWhiteSpace($ClientSecret))    { throw 'ClientSecret is required. Set -ClientSecret, $env:BC_CLIENT_SECRET, or SecretManagement secret "BC_CLIENT_SECRET".' }

if (-not (Test-Path $ArtifactsFolder)) { throw "Artifacts folder not found: $ArtifactsFolder" }
$appFiles = Get-ChildItem -Path $ArtifactsFolder -Filter '*.app' | Select-Object -ExpandProperty FullName
if (-not $appFiles) { throw "No .app files found in $ArtifactsFolder" }

$secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
$bcAuthContext = New-BcAuthContext -tenantId $TenantId -clientId $ClientId -clientSecret $secureSecret

# Preflight: verify Automation API access (companies + extensions)
function Invoke-PreflightChecks {
  param(
    [hashtable]$AuthContext,
    [string]$TenantId,
    [string]$EnvironmentName
  )

  $baseApi = "https://api.businesscentral.dynamics.com/v2.0/$TenantId/$EnvironmentName/api/v2.0"
  $headers = @{ Authorization = "Bearer $($AuthContext.AccessToken)" }
  $ok = $true

  Write-Host "Preflight: checking companies endpoint..."
  try {
    $companies = Invoke-RestMethod -Method Get -Uri "$baseApi/companies" -Headers $headers -UseBasicParsing
    $companyCount = ($companies.value | Measure-Object).Count
    Write-Host -ForegroundColor Green "Preflight OK: companies accessible ($companyCount returned)."
  }
  catch {
    Write-Host -ForegroundColor Red "Preflight FAIL: cannot access companies endpoint. Ensure permission set D365 AUTOMATION or equivalent is assigned to the app registration in Business Central."
    $ok = $false
  }

  Write-Host "Preflight: checking extensions endpoint..."
  if ($ok) {
    try {
      $extensions = Invoke-RestMethod -Method Get -Uri "$baseApi/extensions" -Headers $headers -UseBasicParsing
      $extCount = ($extensions.value | Measure-Object).Count
      Write-Host -ForegroundColor Green "Preflight OK: extensions accessible ($extCount entries)."
    }
    catch {
      Write-Host -ForegroundColor Yellow "Preflight WARN: cannot list extensions. Publishing may still fail with 403 if extension management permissions (e.g. D365 EXTENSION MGT) are missing."
    }
  }

  return $ok
}

if (-not (Invoke-PreflightChecks -AuthContext $bcAuthContext -TenantId $TenantId -EnvironmentName $EnvironmentName)) {
  throw "Preflight checks failed. Aborting publish.";
}

Publish-PerTenantExtensionApps `
  -bcAuthContext $bcAuthContext `
  -environment $EnvironmentName `
  -appFiles $appFiles

Write-Host "Deployment completed to environment: $EnvironmentName"