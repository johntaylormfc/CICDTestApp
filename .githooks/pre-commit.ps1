param(
  [switch]$VerboseOutput
)
$ErrorActionPreference = 'Stop'

# Determine repo root from hooks folder
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot

# Skip build if no relevant staged changes
$changed = git diff --cached --name-only --diff-filter=ACMR | Where-Object { $_ -match '\.(al|json)$' -or $_ -match '^scripts/' }
if (-not $changed) {
  Write-Host "[pre-commit] No relevant staged changes. Skipping build/tests."
  exit 0
}

Write-Host "[pre-commit] Building app..."
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
  & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts/build-local.ps1') @() 2>&1 |
    ForEach-Object { if($VerboseOutput){ $_ } }
} else {
  & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts/build-local.ps1') @() 2>&1 |
    ForEach-Object { if($VerboseOutput){ $_ } }
}
if ($LASTEXITCODE -ne 0) {
  Write-Host -ForegroundColor Red "[pre-commit] Build failed. Aborting commit."
  exit 1
}

# Optional tests if a test runner script exists (skippable via BC_SKIP_TESTS=1)
if ($env:BC_SKIP_TESTS -eq '1') {
  Write-Host '[pre-commit] Skipping tests (BC_SKIP_TESTS=1)'
} else {
  $testScript = Join-Path $repoRoot 'scripts/test-local.ps1'
  if (Test-Path $testScript) {
    Write-Host "[pre-commit] Running tests..."
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
      & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $testScript @() 2>&1 |
        ForEach-Object { if($VerboseOutput){ $_ } }
    } else {
      & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $testScript @() 2>&1 |
        ForEach-Object { if($VerboseOutput){ $_ } }
    }
    if ($LASTEXITCODE -ne 0) {
      Write-Host -ForegroundColor Red "[pre-commit] Tests failed. Aborting commit."
      exit 1
    }
  }
}

Write-Host -ForegroundColor Green "[pre-commit] OK"
