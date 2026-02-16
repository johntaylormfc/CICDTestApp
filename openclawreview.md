# CICDTestApp - OpenClaw Review

## What It Is

A Microsoft Dynamics 365 Business Central AL extension project with local-first CI/CD workflows. Designed to build and deploy BC apps without using GitHub-hosted runners (to save GitHub minutes). Contains a simple "Hello World" customer list extension and PowerShell scripts for local container builds and deployments.

## 5 Main Functions

1. **Local Container Build** - PowerShell script (`build-local.ps1`) that spins up a transient BC container, compiles the AL extension, and produces an `.app` artifact — all locally without GitHub Actions.

2. **Local Deploy to BC** - `deploy-local.ps1` publishes the built app to a Business Central Sandbox or Production environment using Entra ID authentication (TenantId, ClientId, ClientSecret).

3. **Local Test Execution** - `test-local.ps1` runs automated tests inside a BC container for CI validation without cloud runners.

4. **VS Code Integration** - Pre-configured VS Code tasks (`.vscode/tasks.json`) for "AL: Local Container Build" and "AL: Local Deploy" for one-click workflows.

5. **Hello World Extension** - Simple page extension (50100) on Customer List that displays "App published: Hello world" on open — serves as the base test app.

## Suggested Improvements

1. **Add Automated CI Pipeline** - While designed for local-first, adding a minimal GitHub Actions workflow for PR checks would improve confidence. Can use small-hosted runners or trigger local runs via repository dispatch.

2. **Parameterize Credentials** - Deploy script requires hardcoded or prompt credentials. Consider using GitHub Secrets + environment files or Azure Key Vault integration.

3. **Add Error Handling** - Scripts lack robust error handling. Add try/catch blocks, detailed error messages, and exit codes for automation reliability.

4. **Container Caching** - Build script always recreates the container. Implement artifact caching for Docker layers to speed up rebuilds.

5. **Add README CI/CD Section** - Current README is good but could benefit from a visual architecture diagram showing the local build/deploy flow.

6. **Multi-Country Support** - Build script supports country parameters but test coverage for multiple locales is unclear. Add validation for GB/US/other markets.

7. **Git Hooks Utilisation** - `.githooks` directory exists but content unclear. Document or leverage pre-commit hooks for AL validation.
