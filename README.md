# CICDTestApp (AL / Business Central)

[![BC CI/CD](https://github.com/johntaylormfc/CICDTestApp/actions/workflows/bc-ci-cd.yml/badge.svg)](https://github.com/johntaylormfc/CICDTestApp/actions/workflows/bc-ci-cd.yml)

This repository is configured for a simple CI/CD workflow on GitHub Actions:
- CI: Builds the AL app in a Business Central container and uploads the .app as an artifact.
- CD (manual): Deploys the built .app to a target Business Central environment using Entra ID app credentials.

## Repo layout
- `app.json` and AL sources at the repo root (single-app repo)
- Workflow: `.github/workflows/bc-ci-cd.yml`
- Artifacts: created under `artifacts/` (ignored by git)

## Prerequisites
- GitHub repository (create one and push this folder)
- GitHub Actions enabled
- For deployment (CD), set the following repository secrets:
  - `BC_TENANT_ID` — Your Entra ID tenant ID (GUID)
  - `BC_CLIENT_ID` — Your Entra ID app registration (client) ID
  - `BC_CLIENT_SECRET` — A client secret created on the app registration

Permissions for the app registration:
- Add the API permission “Dynamics 365 Business Central” (Delegated not needed; use Application permission via `.default` scope). Grant admin consent.
- The app must be granted access to the target BC environment (Admin Center > Environment > App registrations).

## How it works
The workflow uses PowerShell and BcContainerHelper to:
1. Resolve the latest Sandbox artifacts (W1 by default)
2. Spin up a short-lived BC build container
3. Download symbols and compile your app
4. Upload the resulting `.app` as a workflow artifact
5. If triggered manually with deploy=true, authenticate to BC and publish/install the app into the selected environment

## Run CI
- Push or open a PR against `main` (or `master`).
- The “BC CI/CD” workflow will build and produce a `.app` artifact.

### Other ways to trigger CI
- Manually dispatch: Go to Actions > BC CI/CD > Run workflow and leave "deploy" unchecked.
- Any commit to `main`/`master` or a PR targeting those branches will also trigger the build job.

## Run CD (manual deploy)
- Go to Actions > “BC CI/CD” > Run workflow
- Enable the `deploy` checkbox and set `environment` (defaults to `Sandbox`)
- The job will download the artifact from this run and publish it to the specified environment.

Tip: If you only want to build (no deploy), run the workflow without checking `deploy`.

### Manual deploy checklist
1) Create repo secrets (Settings > Secrets and variables > Actions):
  - `BC_TENANT_ID` — Entra tenant ID (GUID)
  - `BC_CLIENT_ID` — App registration (client) ID
  - `BC_CLIENT_SECRET` — App registration client secret
2) Grant app access in BC Admin Center: Environment > App registrations > Add your app.
3) Admin consent for “Dynamics 365 Business Central” application permissions in Entra.
4) Run Actions > BC CI/CD > Run workflow with `deploy = true` and choose the `environment`.
5) Inspect the “Authenticate and deploy” step for publish/install output.

## Changing regions/versions
Edit `.github/workflows/bc-ci-cd.yml` and change the `country` in `Get-BCArtifactUrl` (e.g., `us`, `gb`, `dk`) or pin a specific version/build if desired.

## Troubleshooting
- Container creation fails: Ensure the runner is `windows-latest` and Docker is available (GitHub-hosted Windows runners support Windows containers).
- Compilation errors: Open the raw workflow logs to see CodeCop warnings and ALC compiler errors. Fix AL code or dependencies.
- Symbols: The pipeline runs `Download-BcContainerAppSymbols` automatically; verify your `app.json` dependencies are correct.
- Deployment failures: Verify secrets and that the app registration has access to the BC environment and admin consent was granted.

### Known pipeline hiccups and fixes
- Container auth required: `New-BcContainer` with `-auth UserPassword` needs a credential. The workflow generates one per run and passes `-Credential`.
- Cleanup parameter: Some versions don’t support `Remove-BcContainer -Force`; we call `Remove-BcContainer` without `-Force` and ignore cleanup errors.
- Host share error: “appProjectFolder is not shared with the container” is fixed by compiling with `-CopyAppToContainer`.
- Symbols cmdlet name differences: If `Download-BcContainerAppSymbols` isn’t available, the workflow falls back to `Get-BcContainerAppSymbols`. If neither is found, compile may still work if symbols are already resolved.
- Slow first run: BcContainerHelper and `.alpackages` are cached. Subsequent runs are faster (cache hits will be shown in logs).

### Where to look in logs
- “Build in ephemeral BC container” for container creation, symbol download, compile, and ALC version.
- “List built artifacts before upload” and the artifact itself to confirm the `.app` output.

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
