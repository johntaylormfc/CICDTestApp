# CICDTestApp (AL / Business Central)

This repository is configured for local-first workflows to build and deploy an AL app without using GitHub-hosted runners.

## Repo layout
- `app.json` and AL sources at the repo root (single-app repo)
- Artifacts: created under `artifacts/` (ignored by git)

## Prerequisites for local workflows
- Windows 10/11 with Hyper-V
- Docker Desktop (Windows containers mode)
- PowerShell 5.1+

## Build locally with Docker (no GitHub minutes)
You can run a full build locally to avoid GitHub-hosted runner costs.

Prerequisites:
- Windows 10/11 with Hyper-V
- Docker Desktop (Windows containers mode)
- PowerShell 5.1+

### VS Code Task
Run the task: `AL: Local Container Build` (added in `.vscode/tasks.json`). It will:
1. Pull/resolve BC artifacts
2. Create a transient container
3. Fetch symbols (or copy from container if cmdlets unavailable)
4. Download AL VSIX, extract `alc.exe`
5. Compile on host to `artifacts\app.app`
6. Remove container (cleanup flag is enabled by default in the task)

### Direct script usage
```powershell
cd <repo-root>
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-local.ps1 -Country gb -ArtifactType Sandbox -ContainerName bcbuild-local -CleanContainer
```

Override parameters as needed (e.g., `-Country us`, different container name, omit `-CleanContainer` to keep container for inspection).

## Deploy locally to your BC environment
You can publish the built app to a Business Central environment from your PC.

### VS Code Task
Run the task: `AL: Local Deploy`. You’ll be prompted for:
- TenantId: Your Entra tenant ID (GUID)
- EnvironmentName: The BC environment name (e.g., Sandbox)
- ClientId / ClientSecret: App registration credentials with BC application permissions

The task publishes any `.app` in the `artifacts` folder.

### Direct script usage
```powershell
cd <repo-root>
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-local.ps1 -TenantId '<tenantGuid>' -EnvironmentName 'Sandbox' -ClientId '<appId>' -ClientSecret '<secret>'
```

Requirements:
- The app registration must have “Dynamics 365 Business Central” application permissions (admin consent granted).
- In BC Admin Center, the app registration must be granted access to the target environment.

## Optional: Local pre-flight build (PowerShell, container compile)
Alternative approach compiling inside the container:

```powershell
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
Install-Module BcContainerHelper -Scope CurrentUser -Force

$artifactUrl = Get-BCArtifactUrl -type 'Sandbox' -select 'Latest' -country 'gb'
$containerName = "bcbuild-local"
New-BcContainer -accept_eula -containerName $containerName -artifactUrl $artifactUrl -auth UserPassword -updateHosts -enableTaskScheduler:$false -Credential (New-Object pscredential('admin',(ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force)))

try {
  Download-BcContainerAppSymbols -containerName $containerName -appProjectFolder "$PWD"
  New-Item -ItemType Directory -Force -Path "$PWD\artifacts" | Out-Null
  Compile-AppInBCContainer -containerName $containerName -appProjectFolder "$PWD" -appOutputFolder "$PWD\artifacts" -EnableCodeCop:$true -EnablePerTenantExtensionCop:$true -failonwarnings:$false
}
finally {
  try { Remove-BcContainer -containerName $containerName } catch { Write-Host $_.Exception.Message }
}
```

## Optional: local git setup
```powershell
# In this folder
git init
git add .
git commit -m "chore: bootstrap AL CI/CD"
# Create an empty GitHub repo, then run (replace URL)
git branch -M main
git remote add origin https://github.com/<your-org>/<your-repo>.git
git push -u origin main
```

## Notes
- This pipeline is intended for Per-Tenant Extensions. For AppSource scenarios or multi-app repos, consider Microsoft AL-Go for GitHub templates/actions.
- Local script compiles on host (faster, avoids container share pitfalls). Switch to container compilation by replacing host ALC call with `Compile-AppInBCContainer` inside the script.
