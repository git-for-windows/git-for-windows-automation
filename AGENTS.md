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

## The MSYS2 Runtime and Git Bash

Git for Windows ships a subset of an [MSYS2](https://www.msys2.org/) installation. At the core of that subset is the **msys2-runtime** (`msys-2.0.dll`). The [Cygwin project](https://cygwin.com/) maintains the original POSIX emulation runtime (`cygwin1.dll`). [MSYS2 forks Cygwin's runtime](https://github.com/msys2/msys2-runtime), and [Git for Windows in turn forks MSYS2's fork](https://github.com/git-for-windows/msys2-runtime). There is healthy cross-pollination between all three projects: fixes flow upstream and downstream regularly.

This runtime provides a POSIX emulation layer on top of Win32: it translates POSIX paths, fork/exec semantics, signal handling, and pseudo-terminal I/O into Windows API calls. Programs that are difficult or impractical to port to pure Win32 (like Bash) run on top of this layer.

What users know as "Git Bash" is not Bash itself. It is a launcher that opens [mintty](https://mintty.github.io/) (a terminal emulator), which in turn runs Bash, which links against the msys2-runtime. When users report problems in "Git Bash", the root cause is most often in the msys2-runtime rather than in Bash or mintty. In recent years, the most common class of bugs has been in the **pseudo-console emulation** layer of the msys2-runtime, where insufficient mutex guarding of input events can cause keystroke reordering under fast typing, among other race conditions.

The Git for Windows installer packages this MSYS2 subset (runtime, Bash, coreutils, and other POSIX tools) together with the native Win32 Git executables (which do not depend on the MSYS2 runtime). This way users get a working POSIX shell environment without having to maintain a full MSYS2 installation.

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
| `remove-packages-from-pacman-repository.yml` | Remove named packages from the Pacman repository (replaces `drop-pacman-package.yml` for multi-package removal) |
| `break-pacman-upload-lease.yml` | Handle Azure Blob Storage lease issues |
| `prepare-embargoed-branches.yml` | Prepare embargoed security fix branches |
| `rebase-shears.yml` | Automated merging-rebase of `shears/*` branches onto upstream; runs on a schedule and via `workflow_dispatch` |

## Directory Structure

```
.github/
├── agents/                     # Copilot agent definitions (e.g., conflict-resolver)
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
*.sh                            # Shell helper scripts (rebase, stash, auth, etc.)
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
| `gently.js` | Try/catch wrapper returning a fallback value on failure |
| `get-workflow-run-artifact.js` | Downloads a named artifact from a workflow run via Octokit |

## Key Shell Scripts

| Script | Purpose |
|--------|---------|
| `rebase-branch.sh` | Rebases a `shears/*` branch onto a new upstream base using range-diff correspondence maps |
| `stash-with-conflicts.sh` | Creates a stash-like octopus merge commit preserving full conflict state (unmerged index entries) |
| `apply-stash-with-conflicts.sh` | Restores conflict state from a commit created by `stash-with-conflicts.sh` |
| `gh-cli-auth-as-app.sh` | Authenticates the `gh` CLI as the GitForWindowsHelper GitHub App |
| `prepare-embargoed-branches.sh` | Prepares branches for embargoed security releases |
| `azure-signtool.sh` | Drop-in replacement for build-extra's `signtool.sh`, using Azure Artifact Signing via `dotnet/sign` CLI |

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
| `AZURE_CLIENT_ID` | Azure AD app registration client ID for OIDC code signing |
| `AZURE_TENANT_ID` | Azure AD tenant ID for OIDC code signing |
| `AZURE_SIGNING_OPTS` | Sign tool arguments (endpoint, account, certificate profile) |
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
- **YAML block scalar indentation pitfall**: In `run: |` and `script: |` blocks, every line of content must be indented at least to the block's base indentation level. Lines with *less* indentation (including column 0) terminate the block scalar — YAML silently truncates the step's script at that point. This is especially treacherous for heredoc bodies and multi-line JS template literals whose content naturally starts at column 0. Mitigations: for shell heredocs, indent the body and the delimiter to the YAML block's base indentation; for multi-line JS strings, use `[...].join('\n')` so each array element is a single indented line.

### Release Branch Semantics

The `release-git.yml` workflow expects the `release` branch to fast-forward to `main` when started. It uses composite actions referenced at `@release` (e.g., `.github/actions/github-release@release`). This allows modifying action code and re-running failed jobs without affecting in-flight releases.

## Code Signing

Code signing uses [Azure Artifact Signing](https://learn.microsoft.com/en-us/azure/trusted-signing/overview) (formerly "Trusted Signing") via the [`dotnet/sign`](https://github.com/dotnet/sign) CLI. This replaced the previous `osslsigncode`-based approach in April 2026 when the PKCS#12 certificate expired and renewal became prohibitively expensive (price hike plus mandatory hardware dongle incompatible with cloud CI).

Authentication uses OIDC workload identity federation: `azure/login@v3` obtains a short-lived token from GitHub, exchanges it with Azure AD, and the sign tool picks up the session via `--azure-credential-type azure-cli`. No long-lived credentials are stored in GitHub secrets; Azure only trusts tokens from this specific repository's `main` branch.

The `azure-signtool.sh` wrapper auto-downloads a [pre-built x64 `sign.exe`](https://github.com/dscho/prebuilt-dotnet-sign-tool/releases) (bundled with .NET runtime) on first use. The x64 build runs under emulation on ARM64 runners because `dotnet/sign` lacks native ARM64 support ([dotnet/sign#852](https://github.com/dotnet/sign/issues/852)). The `.sign-tool/` directory is git-ignored.

The `git-artifacts.yml` workflow's `pkg` and `artifacts` jobs declare explicit `permissions: id-token: write` to request the OIDC token.

## Maintainer Development Environment

Git for Windows maintainers work inside a [Git for Windows SDK](https://github.com/git-for-windows/build-extra/releases) (essentially a full MSYS2 installation plus build toolchains). The SDK is typically installed on a [Dev Drive](https://learn.microsoft.com/en-us/windows/dev-drive/) (usually `D:\`) for significantly better I/O performance. Repositories are checked out under `/usr/src/` inside the SDK, e.g. `D:\git-sdk-64\usr\src\git`, `D:\git-sdk-64\usr\src\MINGW-packages`, etc.

The core repositories typically present in `/usr/src/` are:
- `git` (the main Git for Windows fork)
- `MINGW-packages` (MINGW package definitions, including `mingw-w64-git`)
- `MSYS2-packages` (MSYS package definitions, including `msys2-runtime`)
- `build-extra` (installer scripts, release notes, supplementary tools)
- `git-for-windows-automation` (this repository)

Less obviously, maintainers also often have these checked out there:
- `7-Zip` (custom 7-Zip build used by the installer's self-extracting archive)
- `setup-git-for-windows-sdk` (the GitHub Action for CI SDK setup)
- `rss-to-issues` (monitors RSS/Atom feeds to create component-update issues)
- `track-website-changes` (monitors website changes, usually component version updates)
- `MSYS2-packages/msys2-runtime/src/msys2-runtime` (the Cygwin runtime fork, for debugging POSIX layer issues; this nested path is where `sdk cd msys2-runtime` lands, because `makepkg` extracts the source into `src/` inside the package directory)

When an AI agent operates inside a Git SDK, it should expect this layout and can navigate between sibling repositories under `/usr/src/` to cross-reference package definitions, build scripts, and automation workflows.

## Development Tips

1. **Test JavaScript locally**: Most modules can be tested via `node` on the command line before deploying to workflows.

2. **Use the `build_only` flag**: When testing `build-and-deploy.yml`, set `build_only: true` to skip actual deployment.

3. **Check run state**: When debugging check run mirroring issues, the state file at `$RUNNER_TEMP/check-run.state` contains encrypted state.

4. **Setup Git for Windows SDK**: Workflows use [setup-git-for-windows-sdk](https://github.com/git-for-windows/setup-git-for-windows-sdk) action to get the build environment. As of v2, caching is disabled by default due to cache-poisoning risks ([documented rationale](https://adnanthekhan.com/2024/05/06/the-monsters-in-your-build-cache-github-actions-cache-poisoning/)). To mitigate the performance impact for the `build-installers` flavor, the git-sdk-* repositories now provide pre-built `.tar.zst` CI artifacts that are used directly on Windows Server 2025 runners.

## Known Pitfalls

### Sparse checkout and `--no-checkout` worktrees

When a worktree is created with `--no-checkout`, its index starts empty. Even after `sparse-checkout set <cone>` and `checkout <ref> -- <path>`, only the explicitly checked-out paths are staged. A bare `git commit` (without a pathspec) will compare this sparse index against the parent and treat every path outside the cone as a deletion. Always pass a pathspec to `git commit` in such worktrees to limit the commit to the intended paths.

### `git describe` in merging-rebase topologies

In repositories that use merging-rebases (like msys2-runtime), `git describe --match='tag-pattern-*'` can select the wrong tag. The describe algorithm walks first-parent chains and counts depth, which does not correspond to the actual closest ancestor in a rebase-heavy DAG. Prefer `git for-each-ref --format='%(ahead-behind:<rev>)'` sorted by distance when you need the nearest ancestor tag in such topologies.

### Version update scripts

Package-specific version update scripts in `update-scripts/version/` run during the `/open pr` workflow. They can be difficult to debug because they execute in a CI environment with a specific working-tree layout (bare clones, worktrees, alternates files for object sharing). When modifying these scripts, pay attention to which Git directory each command targets (`--git-dir=`, `-C`, alternates) and whether objects fetched into one clone are visible to another. A worktree created from a bare clone shares objects automatically, but an independent `git init` does not unless you set up `.git/objects/info/alternates`.

## Validating Changes

This repository has no local `npm test` or lint scripts. When making changes, validate by:

1. **Workflow filenames**: Check that any renamed workflows are also updated in `gfw-helper-github-app` dispatch logic.

2. **Check-run names/summaries**: Verify that check-run names and summary patterns match what `gfw-helper-github-app` parsers expect.

3. **Artifact names/paths**: Ensure artifact names consumed across jobs and composite actions remain consistent.

4. **Cross-repo changes**: If a change touches slash-command behavior, mirror it in `gfw-helper-github-app` and run `npm run lint` and `npm test` there.

5. **Secret usage**: Do not introduce new secret names without ensuring all calling workflows and environments are updated together.
