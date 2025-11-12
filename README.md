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

## Changing regions/versions
Edit `.github/workflows/bc-ci-cd.yml` and change the `country` in `Get-BCArtifactUrl` (e.g., `us`, `gb`, `dk`) or pin a specific version/build if desired.

## Troubleshooting
- Container creation fails: Ensure the runner is `windows-latest` and Docker is available (GitHub-hosted Windows runners support Windows containers).
- Compilation errors: Open the raw workflow logs to see CodeCop warnings and ALC compiler errors. Fix AL code or dependencies.
- Symbols: The pipeline runs `Download-BcContainerAppSymbols` automatically; verify your `app.json` dependencies are correct.
- Deployment failures: Verify secrets and that the app registration has access to the BC environment and admin consent was granted.

## Optional: Local pre-flight build (PowerShell)
Use this to validate your app compiles inside a container locally before pushing. Requires Docker Desktop (Windows containers) and PowerShell:

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
