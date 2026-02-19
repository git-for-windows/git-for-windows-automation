# AGENTS.md

This file provides guidance for AI agents and developers working with the `git-for-windows-automation` repository.

## Repository Purpose

This repository contains GitHub workflows and support scripts to automate the day-to-day maintenance tasks of the [Git for Windows](https://github.com/git-for-windows/git) project. It works in tandem with the [GitForWindowsHelper GitHub App](https://github.com/git-for-windows/gfw-helper-github-app), which handles "slash commands" (commands issued via comments in GitHub Issues or Pull Requests).

The core purpose is twofold:
1. **Document knowledge** about "how things are done" in the Git for Windows project
2. **Offload repetitive tasks** to machines to reduce maintenance burden

## Architecture Overview

```
Slash command (e.g., /deploy) → GitForWindowsHelper (Azure Function)
                                        ↓
                              Triggers workflow here (git-for-windows-automation)
                                        ↓
                              Workflow runs, optionally "mirrors back" check runs
                              to the source PR in another repository
```

This "mirror back" technique allows versioning source code independently of workflow definitions.

## Critical Contracts with GitForWindowsHelper

The GitForWindowsHelper GitHub App dispatches workflows **by filename**. Renaming any of these workflows requires a coordinated change in `gfw-helper-github-app`:

- `open-pr.yml`
- `updpkgsums.yml`
- `build-and-deploy.yml`
- `tag-git.yml`
- `git-artifacts.yml`
- `release-git.yml`
- `upload-snapshot.yml`

The helper app also parses check-run names and summaries to drive cascading behavior. These patterns must remain stable:

- Check-run names: `tag-git`, `git-artifacts-x86_64`, `git-artifacts-i686`, `git-artifacts-aarch64`, `deploy`, `build`
- Summary patterns like `Tag Git <version> @<sha>` and `Build Git <version> artifacts from commit <sha>`
- Artifact names: `bundle-artifacts`, `pkg-<arch>`, `sha256sums`, `<artifact>-<arch>` (e.g., `installer-x86_64`)

Changing any of these without updating `gfw-helper-github-app` will break the automation.

## Key Workflows

### Component Updates

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `open-pr.yml` | `/open pr` command on `component-update` issues | Creates PRs in MINGW-packages/MSYS2-packages/build-extra to update component versions |
| `build-and-deploy.yml` | `/deploy` command on PRs | Builds Pacman packages and deploys to Azure Blob Storage |
| `updpkgsums.yml` | `/updpkgsums` command on PRs | Updates checksums in PKGBUILD files |

### Git for Windows Releases

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `tag-git.yml` | `/git-artifacts` command (via GitForWindowsHelper) | Tags a Git commit, generates release notes and bundle artifacts |
| `git-artifacts.yml` | Cascading trigger after `tag-git` completes | Builds release artifacts: installer, Portable Git, MinGit, archive, NuGet |
| `release-git.yml` | `/release` command | Publishes artifacts as GitHub release, deploys Pacman packages, updates website |

The release flow has cascading triggers: `/git-artifacts` → `tag-git.yml` → (on success) `git-artifacts.yml` for each architecture → (optionally) `upload-snapshot.yml` for snapshot builds.

### Other Workflows

| Workflow | Purpose |
|----------|---------|
| `upload-snapshot.yml` | Upload snapshot builds |
| `drop-pacman-package.yml` | Remove packages from Pacman repository |
| `break-pacman-upload-lease.yml` | Handle Azure Blob Storage lease issues |
| `prepare-embargoed-branches.yml` | Prepare embargoed security fix branches |

## Directory Structure

```
.github/
├── actions/                    # Composite actions
│   ├── check-run-action/       # Creates/updates check runs in other repos
│   ├── github-release/         # Handles GitHub release creation
│   ├── gitforwindows.org/      # Updates Git for Windows website
│   ├── init-g4w-sdk-for-pacman/ # Initializes SDK for Pacman operations
│   ├── mail-announcement/      # Sends release announcement emails
│   ├── nuget-packages/         # Publishes NuGet packages
│   ├── pacman-packages/        # Deploys Pacman packages
│   └── repository-updates/     # Updates build-extra, MINGW-packages, etc.
└── workflows/                  # GitHub Actions workflow definitions

update-scripts/
├── version/                    # Package-specific version update scripts
├── checksums/                  # Package-specific checksum update scripts
├── tag-git.sh                  # Creates Git tags with release notes
└── ensure-not-yet-deployed.sh  # Prevents duplicate deployments

*.js                            # Node.js modules for GitHub API operations
```

## Key JavaScript Modules

| Module | Purpose |
|--------|---------|
| `github-api-request.js` | Generic GitHub API requests with Bearer token auth |
| `github-api-request-as-app.js` | GitHub API requests authenticated as a GitHub App (JWT) |
| `get-app-installation-id.js` | Retrieves GitHub App installation ID for a repository |
| `get-installation-access-token.js` | Gets an access token for a GitHub App installation |
| `check-runs.js` | Creates and updates check runs in other repositories |
| `workflow-runs.js` | Waits for workflow runs to complete |
| `github-release.js` | Creates releases, uploads assets, downloads artifacts |
| `repository-updates.js` | Pushes updates to Git for Windows repositories |
| `create-artifacts-matrix.js` | Generates build matrix for artifact builds |
| `https-request.js` | Low-level HTTPS request wrapper |

## Check Run Mirroring

A key pattern in this repository is "mirroring" check runs from workflow runs here back to PRs in other repositories (e.g., `git-for-windows/MINGW-packages`). This is done via the `check-run-action` composite action:

```yaml
- uses: ./.github/actions/check-run-action
  with:
    app-id: ${{ secrets.GH_APP_ID }}
    private-key: ${{ secrets.GH_APP_PRIVATE_KEY }}
    owner: git-for-windows
    repo: MINGW-packages  # Target repository
    rev: ${{ env.REF }}   # Target commit
    check-run-name: "deploy"
    title: "Build and deploy package"
```

The check run state is encrypted and stored between job steps using the GitHub App's private key.

## Secrets Required

| Secret | Purpose |
|--------|---------|
| `GH_APP_ID` | GitHub App ID for GitForWindowsHelper |
| `GH_APP_PRIVATE_KEY` | Private key for the GitHub App |
| `GPGKEY` | GPG key ID for signing packages |
| `PRIVGPGKEY` | Private GPG key (newlines replaced with `%`) |
| `CODESIGN_P12` | Code signing certificate (base64, newlines replaced with `%`) |
| `CODESIGN_PASS` | Password for code signing certificate |
| `AZURE_BLOBS_TOKEN` | Token for Azure Blob Storage (Pacman repository) |
| `NUGET_API_KEY` | API key for NuGet package publishing |

## Working with Package Updates

### Version Update Scripts

Package-specific version update scripts live in `update-scripts/version/`. If a script exists for a package, `open-pr.yml` uses it instead of the default `sed`-based PKGBUILD modification. These scripts handle special cases like:
- Downloading and extracting version information
- Updating multiple files beyond just `PKGBUILD`
- Transforming version strings

### Checksum Update Scripts

Similarly, package-specific checksum update scripts in `update-scripts/checksums/` handle cases where the default `updpkgsums` command doesn't suffice.

## Supported Architectures

Git for Windows builds for three architectures:
- `x86_64` (64-bit) - Full support: installer, portable, archive, MinGit, NuGet
- `i686` (32-bit) - MinGit only
- `aarch64` (ARM64) - All artifacts except MinGit-BusyBox

## Relationship with Other Repositories

Workflows in this repository intentionally push updates to these external repositories:

| Repository | What gets pushed |
|------------|------------------|
| [git-for-windows/git](https://github.com/git-for-windows/git) | Release tags, check-run status |
| [git-for-windows/build-extra](https://github.com/git-for-windows/build-extra) | Release notes, package versions, MINGW-packages bundle |
| [git-for-windows/MINGW-packages](https://github.com/git-for-windows/MINGW-packages) | Package update PRs, PKGBUILD updates |
| [git-for-windows/MSYS2-packages](https://github.com/git-for-windows/MSYS2-packages) | Package update PRs |
| [git-for-windows/pacman-repo](https://github.com/git-for-windows/pacman-repo) | Package deployment metadata |
| [git-for-windows/git-for-windows.github.io](https://github.com/git-for-windows/git-for-windows.github.io) | Website version updates |
| [git-for-windows/git-snapshots](https://github.com/git-for-windows/git-snapshots) | Snapshot release artifacts |
| git-sdk-32, git-sdk-64, git-sdk-arm64 | SDK synchronization triggers |

Additionally, [git-for-windows/gfw-helper-github-app](https://github.com/git-for-windows/gfw-helper-github-app) is the Azure Function that receives slash commands and triggers workflows here.

Treat these cross-repository updates as API contracts: changing refs, artifact names, or bundle contents can break downstream jobs.

## Coding Conventions

Preserve these conventions when editing:

### JavaScript
- Reuse existing root modules from `actions/github-script` instead of duplicating API/auth logic
- All modules use CommonJS (`module.exports` / `require()`)
- Async/await for asynchronous operations
- Modules are designed to be usable both from GitHub Actions and command line
- Error handling via thrown exceptions
- Context parameter (typically `console`) passed for logging

### Shell Scripts
- POSIX-compatible shell (except where Bash features are explicitly needed)
- Use `die()` function for fatal errors
- Quote all variable expansions
- Chain commands with `&&` for early failure

### Workflows
- Use `workflow_dispatch` for manual/API triggering
- Pass parameters via `inputs`
- Use composite actions for reusable functionality
- Always include `if: github.event.repository.owner.login == 'git-for-windows'` to prevent forks from accidentally running workflows
- Keep GitHub App auth flow consistent (`GH_APP_ID` + `GH_APP_PRIVATE_KEY`, installation token exchange)
- Preserve mirrored check-run behavior in workflows that act on other repositories

### Release Branch Semantics

The `release-git.yml` workflow expects the `release` branch to fast-forward to `main` when started. It uses composite actions referenced at `@release` (e.g., `.github/actions/github-release@release`). This allows modifying action code and re-running failed jobs without affecting in-flight releases.

## Development Tips

1. **Test JavaScript locally**: Most modules can be tested via `node` on the command line before deploying to workflows.

2. **Use the `build_only` flag**: When testing `build-and-deploy.yml`, set `build_only: true` to skip actual deployment.

3. **Check run state**: When debugging check run mirroring issues, the state file at `$RUNNER_TEMP/check-run.state` contains encrypted state.

4. **Setup Git for Windows SDK**: Workflows use [setup-git-for-windows-sdk](https://github.com/git-for-windows/setup-git-for-windows-sdk) action to get the build environment.

## Validating Changes

This repository has no local `npm test` or lint scripts. When making changes, validate by:

1. **Workflow filenames**: Check that any renamed workflows are also updated in `gfw-helper-github-app` dispatch logic.

2. **Check-run names/summaries**: Verify that check-run names and summary patterns match what `gfw-helper-github-app` parsers expect.

3. **Artifact names/paths**: Ensure artifact names consumed across jobs and composite actions remain consistent.

4. **Cross-repo changes**: If a change touches slash-command behavior, mirror it in `gfw-helper-github-app` and run `npm run lint` and `npm test` there.

5. **Secret usage**: Do not introduce new secret names without ensuring all calling workflows and environments are updated together.
