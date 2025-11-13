param(
    [string]$Country = 'gb',
    [string]$ArtifactType = 'Sandbox',
    [string]$ContainerName = "bcbuild-local",
    [string]$AppProjectPath = (Resolve-Path "$PSScriptRoot\..\").Path,
    [string]$OutputFolder = (Join-Path (Resolve-Path "$PSScriptRoot\..\").Path 'artifacts'),
    [switch]$CleanContainer,
    [switch]$RefreshVsix
)

$ErrorActionPreference = 'Stop'

Write-Host "AppProjectPath: $AppProjectPath"
Write-Host "OutputFolder:     $OutputFolder"

# Ensure output folder
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null

# Quick incremental skip: if no AL/app.json changes and artifact exists, skip compile
$alAndConfigFiles = Get-ChildItem -Path $AppProjectPath -Recurse -Include '*.al','app.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "\\tests\\" }
$hashInput = $alAndConfigFiles | ForEach-Object { "{0}:{1}" -f $_.FullName, ([System.IO.File]::ReadAllText($_.FullName)) } | Out-String
if (-not [string]::IsNullOrEmpty($hashInput)) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
    $hash = -join ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    $hashFile = Join-Path $OutputFolder 'build.hash'
    $outAppCandidate = Join-Path $OutputFolder 'app.app'
    if ((Test-Path $hashFile) -and (Test-Path $outAppCandidate)) {
        $prevHash = Get-Content -Path $hashFile -ErrorAction SilentlyContinue
        if ($prevHash -eq $hash) {
            Write-Host 'No AL changes detected. Skipping build (cached artifact valid).'
            return
        }
    }
}

# Normalize paths (avoid trailing backslashes breaking quoted native args)
$AppProjectPath = $AppProjectPath.TrimEnd('\')
$OutputFolder   = $OutputFolder.TrimEnd('\\')

# Ensure BcContainerHelper
if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Install-Module BcContainerHelper -Scope CurrentUser -Force
}
Import-Module BcContainerHelper -Force
Write-Host "BcContainerHelper version:" (Get-Module BcContainerHelper).Version

# Resolve artifact URL
if (-not $ArtifactUrl) {
    $ArtifactUrl = Get-BCArtifactUrl -type $ArtifactType -select 'Latest' -country $Country
}
Write-Host "ArtifactUrl: $ArtifactUrl"

# Derive artifact version segment for per-version symbol cache
$artifactVersion = ((($ArtifactUrl) -replace '^(?i).*?/(sandbox|onprem)/','') -split '/')[0]
if (-not $artifactVersion -or ($artifactVersion -notmatch '^\d+\.\d+\.\d+\.\d+$')) { $artifactVersion = 'unknown' }

# Create container credentials
$securePwd = ConvertTo-SecureString 'P@ssw0rd1' -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ('admin', $securePwd)

# Create or reuse container (fallback to docker inspect if helper cmdlet unavailable)
$containerExists = $false
try {
    $null = docker container inspect $ContainerName 2>$null
    if ($LASTEXITCODE -eq 0) { $containerExists = $true }
}
catch { $containerExists = $false }
if (-not $containerExists) {
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
    # Symbols: use default .alpackages folder (ensures System.app is available)
    $pkgPath = Join-Path $AppProjectPath '.alpackages'
    $pkgPath = $pkgPath.TrimEnd('\\')
    New-Item -ItemType Directory -Force -Path $pkgPath | Out-Null
    $pkgCount = (Get-ChildItem -Path $pkgPath -Filter '*.app' -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($pkgCount -eq 0) {
        $symbolCmd = @('Download-BcContainerAppSymbols','Get-BcContainerAppSymbols','Download-NavContainerAppSymbols','Get-NavContainerAppSymbols') |
            ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
        if ($symbolCmd) {
            Write-Host "Downloading symbols using: $($symbolCmd.Name)"
            try {
                & $symbolCmd.Name -containerName $ContainerName -appProjectFolder $AppProjectPath -ErrorAction Stop
            } catch {
                Write-Warning "Symbol download failed: $($_.Exception.Message)"
            }
        }

        # Copy any symbols downloaded to default .alpackages into versioned folder
        $defaultPkg = Join-Path $AppProjectPath '.alpackages'
        if (Test-Path $defaultPkg) {
            Get-ChildItem -Path $defaultPkg -Filter '*.app' -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $pkgPath -Force
            }
        }

        # If still no symbols in versioned folder, copy from container as zip
        $pkgCount = (Get-ChildItem -Path $pkgPath -Filter '*.app' -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($pkgCount -eq 0) {
            Write-Host 'No .alpackages found; copying symbols from container applications folder'
            Invoke-ScriptInBCContainer -containerName $ContainerName -scriptBlock {
                $dest = 'C:\tempSymbols'
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                Get-ChildItem -Path 'C:\Applications' -Filter '*.app' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                    Copy-Item -Path $_.FullName -Destination $dest -Force
                }
                $zip = 'C:\tempSymbols.zip'
                if (Test-Path $zip) { Remove-Item $zip -Force }
                Compress-Archive -Path 'C:\tempSymbols\*' -DestinationPath $zip -Force
            }
            $tmpDir = Join-Path $AppProjectPath '_tmp'
            New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
            $zipLocal = Join-Path $tmpDir 'tempSymbols.zip'
            if (Test-Path $zipLocal) { Remove-Item $zipLocal -Force }
            Copy-FileFromBcContainer -containerName $ContainerName -containerPath 'C:\tempSymbols.zip' -localPath $zipLocal
            Expand-Archive -Path $zipLocal -DestinationPath $pkgPath -Force
        }
    }

    # Host compile using cached AL VSIX (outside project path)
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
    $alcPathCached = Join-Path $vsixOut 'extension/bin/alc.exe'
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
    if (-not (Test-Path $alc)) {
        $alcCandidates = Get-ChildItem -Path $vsixOut -Filter 'alc.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        if ($alcCandidates) { $alc = $alcCandidates | Select-Object -First 1 }
    }
    if (-not (Test-Path $alc)) { throw 'alc.exe not found in cached VSIX' }

    # Remove any legacy VSIX extraction inside the project path (could cause template .al files to be compiled)
    $legacyAlDir = Join-Path $AppProjectPath '_al'
    if (Test-Path $legacyAlDir) {
        Write-Host "Removing legacy VSIX folder: $legacyAlDir"
        Remove-Item $legacyAlDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "ALC: $alc"
    # Prepare isolated build source excluding tests project
    $buildSrc = Join-Path $OutputFolder '_buildsrc'
    if (Test-Path $buildSrc) { Remove-Item $buildSrc -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $buildSrc | Out-Null
    $excludeDirs = @('tests','artifacts','_buildsrc','_tmp','.git','.githooks')
    Get-ChildItem -Path $AppProjectPath -Force | ForEach-Object {
        if ($_.PSIsContainer) {
            if ($excludeDirs -contains $_.Name) { return }
            Copy-Item -Path $_.FullName -Destination (Join-Path $buildSrc $_.Name) -Recurse -Force
        } else {
            if ($_.Name -in @('app.json')) { Copy-Item -Path $_.FullName -Destination (Join-Path $buildSrc $_.Name) -Force }
        }
    }
    # Ensure symbol cache present in isolated folder
    $isolatedPkg = Join-Path $buildSrc '.alpackages'
    if (-not (Test-Path $isolatedPkg)) { New-Item -ItemType Directory -Force -Path $isolatedPkg | Out-Null }
    Get-ChildItem -Path $pkgPath -Filter '*.app' -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName -Destination $isolatedPkg -Force }

    $outApp = Join-Path $OutputFolder 'app.app'
    # Build argument array to avoid concatenation issues
    $alcArgs = @(
        "/project:$buildSrc",
        "/packagecachepath:$isolatedPkg",
        "/out:$outApp"
    )
    & $alc $alcArgs
    if ($LASTEXITCODE -ne 0) { throw "ALC failed with exit code $LASTEXITCODE" }

    Write-Host "Built: $outApp"

    # Save hash to mark artifact as valid for next builds
    if ($hash) { Set-Content -Path (Join-Path $OutputFolder 'build.hash') -Value $hash -Encoding ASCII }
}
finally {
    if ($CleanContainer.IsPresent) {
        try { Remove-BcContainer -containerName $ContainerName } catch { Write-Warning $_ }
    }
}
