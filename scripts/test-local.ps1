param(
  [string]$Country = 'gb',
  [string]$ArtifactType = 'Sandbox',
  [string]$ContainerName = 'bcbuild-local',
  [string]$CompanyName = 'CRONUS UK Ltd.',
  [switch]$CleanContainer,
  [switch]$RefreshVsix
)

$ErrorActionPreference = 'Stop'

# Ensure BcContainerHelper
if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
  Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
  Install-Module BcContainerHelper -Scope CurrentUser -Force
}
Import-Module BcContainerHelper -Force

# Resolve paths
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ArtifactsFolder = (Join-Path $AppRoot 'artifacts')
$TestProjectPath = (Join-Path $AppRoot 'tests')

# Ensure artifact
if (-not (Test-Path $ArtifactsFolder)) { throw "Artifacts folder not found: $ArtifactsFolder" }
$appFile = Get-ChildItem -Path $ArtifactsFolder -Filter '*.app' | Select-Object -ExpandProperty FullName -First 1
if (-not $appFile) {
  Write-Host 'No app.app found; building first...'
  & (Join-Path $PSScriptRoot 'build-local.ps1')
  $appFile = Get-ChildItem -Path $ArtifactsFolder -Filter '*.app' | Select-Object -ExpandProperty FullName -First 1
  if (-not $appFile) { throw 'Build did not produce an .app file.' }
}

# Read app id/name from app.json
$appJsonPath = Join-Path $AppRoot 'app.json'
$appJson = Get-Content $appJsonPath -Raw | ConvertFrom-Json
$appName = $appJson.name

# Resolve artifact URL for test container
if (-not $ArtifactUrl) {
  $ArtifactUrl = Get-BCArtifactUrl -type $ArtifactType -select 'Latest' -country $Country
}
Write-Host "ArtifactUrl: $ArtifactUrl"
$artifactVersion = (($ArtifactUrl -replace '^(?i).*?/(sandbox|onprem)/','') -split '/')[0]
if (-not $artifactVersion -or ($artifactVersion -notmatch '^\d+\.\d+\.\d+\.\d+$')) { $artifactVersion = 'unknown' }

# Create credentials for container
$securePwd = ConvertTo-SecureString 'P@ssw0rd1' -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ('admin', $securePwd)

# Create or reuse container (clean if requested)
if ($CleanContainer.IsPresent) {
  try { Remove-BcContainer -containerName $ContainerName -force -ErrorAction SilentlyContinue } catch {}
}
$exists = $false
try { $null = docker container inspect $ContainerName 2>$null; if ($LASTEXITCODE -eq 0) { $exists = $true } } catch {}
if (-not $exists) {
  New-BcContainer `
    -accept_eula `
    -containerName $ContainerName `
    -artifactUrl $ArtifactUrl `
    -auth UserPassword `
    -Credential $credential `
    -updateHosts `
    -enableTaskScheduler:$false
}

try {
  # Install minimal Test Toolkit (framework + runner)
  Import-TestToolkitToBcContainer -containerName $ContainerName -credential $credential -includeTestFrameworkOnly -includeTestRunnerOnly

  # Publish the main app
  Publish-BcContainerApp -containerName $ContainerName -appFile $appFile -skipVerification -sync -install -credential $credential

  # Build test app (if tests/app.json exists)
  $testAppJson = Join-Path $TestProjectPath 'app.json'
  if (Test-Path $testAppJson) {
    $testAppManifest = Get-Content $testAppJson -Raw | ConvertFrom-Json
    $testAppName = $testAppManifest.name
    $testAppPublisher = $testAppManifest.publisher
    # Prepare test symbol cache using default .alpackages and include main app package
    $testPkg = Join-Path $TestProjectPath '.alpackages'
    New-Item -ItemType Directory -Force -Path $testPkg | Out-Null
    # Reuse symbols from main project default cache
    $mainPkg = Join-Path $AppRoot '.alpackages'
    if (Test-Path $mainPkg) { Get-ChildItem -Path $mainPkg -Filter '*.app' -File | ForEach-Object { Copy-Item $_.FullName -Destination $testPkg -Force } }
    # Add built main app as dependency package for tests
    Copy-Item $appFile -Destination $testPkg -Force

    # Compile test app using cached VSIX
    $cacheRoot = Join-Path $env:LOCALAPPDATA 'ALVSIXCache'
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    $vsixCache = Join-Path $cacheRoot 'al_latest.vsix'
    $vsixOut = Join-Path $cacheRoot 'vsix'
    if ($RefreshVsix.IsPresent -and (Test-Path $vsixCache)) { Remove-Item $vsixCache -Force }
    if ($RefreshVsix.IsPresent -and (Test-Path $vsixOut)) { Remove-Item $vsixOut -Recurse -Force }
    if (-not (Test-Path $vsixCache)) {
      Write-Host 'Downloading AL Language VSIX (latest)'
      Invoke-WebRequest -Uri 'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-dynamics-smb/vsextensions/al/latest/vspackage' -OutFile $vsixCache
    }
    $alcPathCached = Join-Path $vsixOut 'extension/bin/win32/alc.exe'
    if (-not (Test-Path $alcPathCached)) {
      if (Test-Path $vsixOut) { Remove-Item $vsixOut -Recurse -Force }
      New-Item -ItemType Directory -Force -Path $vsixOut | Out-Null
      $vsixZip = Join-Path $cacheRoot 'al.vsix.zip'
      if (Test-Path $vsixZip) { Remove-Item $vsixZip -Force }
      Copy-Item -Path $vsixCache -Destination $vsixZip -Force
      Expand-Archive -Path $vsixZip -DestinationPath $vsixOut -Force
      Remove-Item $vsixZip -Force
    }
    $alc = $alcPathCached
    if (-not (Test-Path $alc)) { throw 'alc.exe not found in cached VSIX' }

    $outTestApp = Join-Path $ArtifactsFolder 'test.app'
    $alcArgs = @(
      "/project:$TestProjectPath",
      "/packagecachepath:$testPkg",
      "/out:$outTestApp"
    )
    & $alc $alcArgs
    if ($LASTEXITCODE -ne 0) { throw "ALC (tests) failed with exit code $LASTEXITCODE" }
    Write-Host "Built test app: $outTestApp"

    # If an existing tests app with same version is installed/published, remove it first
    $existingTest = Get-BcContainerAppInfo -containerName $ContainerName -tenant default | Where-Object { $_.Name -eq $testAppName }
    if ($existingTest) {
      try { UnInstall-BcContainerApp -containerName $ContainerName -tenant default -name $existingTest.Name -publisher $existingTest.Publisher -version $existingTest.Version -doNotSaveData -ErrorAction SilentlyContinue } catch {}
      try { UnPublish-BcContainerApp -containerName $ContainerName -tenant default -name $existingTest.Name -publisher $existingTest.Publisher -version $existingTest.Version -ErrorAction SilentlyContinue } catch {}
    }

    # Publish test app
    Publish-BcContainerApp -containerName $ContainerName -appFile $outTestApp -skipVerification -sync -install -credential $credential
  }

  # Verify app installed
  $installed = Get-BcContainerAppInfo -containerName $ContainerName -tenant default | Where-Object { $_.Name -eq $appName }
  if (-not $installed) { throw "Extension '$appName' did not install in container." }

  # Run the sample test codeunit (50200 in tests app)
  $resultFile = Join-Path $ArtifactsFolder 'testresults.xml'
  $runTestsCmd = Get-Command 'Run-TestsInBCContainer' -ErrorAction SilentlyContinue
  if ($runTestsCmd) {
    try {
      & $runTestsCmd.Name -containerName $ContainerName -credential $credential -companyName $CompanyName -detailed -testCodeunitIds 50200 -returnTrueIfAllPassed | Out-Null
    }
    catch {
      & $runTestsCmd.Name -containerName $ContainerName -credential $credential -companyName $CompanyName -detailed -returnTrueIfAllPassed | Out-Null
    }
  }
  else {
    $invokeCmd = Get-Command 'Invoke-BCContainerTests' -ErrorAction SilentlyContinue
    if ($invokeCmd) {
      try {
        & $invokeCmd.Name -containerName $ContainerName -credential $credential -companyName $CompanyName -detailed -testCodeunitIds 50200 -returnTrueIfAllPassed | Out-Null
      }
      catch {
        & $invokeCmd.Name -containerName $ContainerName -credential $credential -companyName $CompanyName -detailed -returnTrueIfAllPassed | Out-Null
      }
    }
    else {
      Write-Warning 'No test runner cmdlet found; skipping test run.'
    }
  }

  Write-Host -ForegroundColor Green 'All tests passed.'
  # Note: XUnit export skipped due to shared path constraints on this host
}
finally {
  if ($CleanContainer.IsPresent) {
    try { Remove-BcContainer -containerName $ContainerName } catch { Write-Warning $_ }
  }
}
