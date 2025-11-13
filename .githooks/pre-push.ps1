param(
  [switch]$VerboseOutput
)
$ErrorActionPreference = 'Stop'

# Allow opt-out for CI or emergency pushes
if ($env:BC_SKIP_DEPLOY_ON_PUSH -match '^(1|true|yes)$') {
  Write-Host "[pre-push] Skipping deploy due to BC_SKIP_DEPLOY_ON_PUSH=$($env:BC_SKIP_DEPLOY_ON_PUSH)"
  exit 0
}

# Determine repo root from hooks folder
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot

Write-Host "[pre-push] Deploying to sandbox..."
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts/deploy-local.ps1') @() 2>&1 |
  ForEach-Object { if($VerboseOutput){ $_ } }
if ($LASTEXITCODE -ne 0) {
  Write-Host -ForegroundColor Red "[pre-push] Deploy failed. Blocking push. Set BC_SKIP_DEPLOY_ON_PUSH=1 to bypass."
  exit 1
}

Write-Host -ForegroundColor Green "[pre-push] Deploy OK"
