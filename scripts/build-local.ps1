param(
    [string]$Country = 'gb',
    [string]$ArtifactType = 'Sandbox',
    [string]$ContainerName = "bcbuild-local",
    [string]$AppProjectPath = (Resolve-Path "$PSScriptRoot\..\").Path,
    [string]$OutputFolder = (Join-Path (Resolve-Path "$PSScriptRoot\..\").Path 'artifacts'),
    [switch]$CleanContainer
)

$ErrorActionPreference = 'Stop'

Write-Host "AppProjectPath: $AppProjectPath"
Write-Host "OutputFolder:     $OutputFolder"

# Ensure output folder
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null

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

# Create container credentials
$securePwd = ConvertTo-SecureString 'P@ssw0rd1' -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ('admin', $securePwd)

# Create container
New-BcContainer `
  -accept_eula `
  -containerName $ContainerName `
  -artifactUrl $ArtifactUrl `
  -auth UserPassword `
  -Credential $credential `
  -updateHosts `
  -enableTaskScheduler:$false

try {
    # Symbols: download to host .alpackages
    $pkgPath = Join-Path $AppProjectPath '.alpackages'
    $pkgPath = $pkgPath.TrimEnd('\\')
    New-Item -ItemType Directory -Force -Path $pkgPath | Out-Null
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

    # If still no symbols, copy from container as zip
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

    # Host compile using AL VSIX (extract outside project path to avoid picking up template .al files)
    $alDir = Join-Path ([System.IO.Path]::GetTempPath()) ('alvsix_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $alDir | Out-Null
    $vsix = Join-Path $alDir 'al.vsix'
    $vsixOut = Join-Path $alDir 'vsix'
    if (-not (Test-Path $vsix)) {
        Write-Host 'Downloading AL Language VSIX (latest)'
        Invoke-WebRequest -Uri 'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-dynamics-smb/vsextensions/al/latest/vspackage' -OutFile $vsix
    }
    if (Test-Path $vsixOut) { Remove-Item $vsixOut -Recurse -Force }
    $vsixZip = Join-Path $alDir 'al.vsix.zip'
    if (Test-Path $vsixZip) { Remove-Item $vsixZip -Force }
    Copy-Item -Path $vsix -Destination $vsixZip -Force
    Expand-Archive -Path $vsixZip -DestinationPath $vsixOut -Force
    Remove-Item $vsixZip -Force
    $alcCandidates = Get-ChildItem -Path $vsixOut -Filter 'alc.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    if (-not $alcCandidates) { throw 'alc.exe not found in downloaded VSIX' }
    $alc = $alcCandidates | Where-Object { $_ -match '\\extension\\bin\\' } | Select-Object -First 1
    if (-not $alc) { $alc = $alcCandidates | Select-Object -First 1 }

    # Remove any legacy VSIX extraction inside the project path (could cause template .al files to be compiled)
    $legacyAlDir = Join-Path $AppProjectPath '_al'
    if (Test-Path $legacyAlDir) {
        Write-Host "Removing legacy VSIX folder: $legacyAlDir"
        Remove-Item $legacyAlDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "ALC: $alc"
    $outApp = Join-Path $OutputFolder 'app.app'
    # Build argument array to avoid concatenation issues
    $alcArgs = @(
        "/project:$AppProjectPath",
        "/packagecachepath:$pkgPath",
        "/out:$outApp"
    )
    & $alc $alcArgs
    if ($LASTEXITCODE -ne 0) { throw "ALC failed with exit code $LASTEXITCODE" }

    Write-Host "Built: $outApp"
}
finally {
    if ($CleanContainer.IsPresent) {
        try { Remove-BcContainer -containerName $ContainerName } catch { Write-Warning $_ }
    }
}
