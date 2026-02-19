const maybeQuote = (arg) =>
  !arg.match(/[ "']/) ? arg : `'${arg.replace(/'/g, "'\\''")}'`
const prettyPrintCommand = (prog, parameters) =>
  `${maybeQuote(prog)} ${parameters.map(maybeQuote).join(' ')}`
const callProg = (prog, parameters, cwd) => {
  const { spawnSync } = require('child_process')
  const child = spawnSync(prog, parameters, {
    stdio: ['ignore', 'pipe', 'inherit'],
    cwd
  })
  const error = (message) => [
    `${prettyPrintCommand(prog, parameters)}: ${message}`,
    `stdout: ${child.stdout}`,
  ].join('\n')
  if (child.error) throw new Error(error(`failed with ${child.error}`), { cause: child.error })
  if (child.status !== 0) throw new Error(error(`failed with status ${child.status}`))
  return child.stdout.toString('utf-8').replace(/\r?\n$/, '')
}

const callGit = (parameters, cwd) => {
  return callProg('git', parameters, cwd)
}

const getWorkflowRunArtifact = async (context, token, owner, repo, workflowRunId, name) => {
  const { getWorkflowRunArtifactsURLs, downloadAndUnZip } = require('./github-release')
  const urls = await getWorkflowRunArtifactsURLs(context, token, owner, repo, workflowRunId)
  context.log(`Downloading ${name}`)
  await downloadAndUnZip(token, urls[name], name)
}

const mergeBundle = (gitDir, worktree, bundlePath, refName) => {
  callGit(['--git-dir', gitDir, 'fetch', bundlePath, refName])
  // If there is nothing to merge, return early
  if (callGit(['--git-dir', gitDir, 'rev-list', '--count', `${refName}..FETCH_HEAD`]) === '0') return

  if (worktree) {
    callGit(['branch', '-M', refName], worktree)
    callGit(['merge', '--no-edit', 'FETCH_HEAD'], worktree)
  } else {
    // If it fast-forwards, we do not need a worktree
    if (callGit(['--git-dir', gitDir, 'rev-list', '--count', `FETCH_HEAD..${refName}`]) === '0') {
      callGit(['--git-dir', gitDir, 'update-ref', `refs/heads/${refName}`, 'FETCH_HEAD'])
    } else {
      // Fine. We need a worktree. But we don't have one. So let's create one.
      worktree = `${gitDir}/tmp-worktree`
      callGit(['--git-dir', gitDir, 'worktree', 'add', '--no-checkout', worktree])
      // No need for a full checkout, it's not as if we want to resolve any merge conflicts...
      callGit(['sparse-checkout', 'set'], worktree)
      callGit(['switch', '-d', refName], worktree)
      // Perform the merge
      callGit(['fetch', bundlePath, refName], worktree)
      callGit(['merge', '--no-edit', 'FETCH_HEAD'], worktree)
      callGit(['update-ref', `refs/heads/${refName}`, 'HEAD'], worktree)
    }
  }
}

const getPushAuthorizationHeader = async (context, setSecret, appId, privateKey, owner, repo) => {
  const getAppInstallationId = require('./get-app-installation-id')
  const installationId = await getAppInstallationId(
    context,
    appId,
    privateKey,
    owner,
    repo
  )

  const getInstallationAccessToken = require('./get-installation-access-token')
  const { token: accessToken } = await getInstallationAccessToken(
    context,
    appId,
    privateKey,
    installationId
  )

  const auth = Buffer.from(`PAT:${accessToken}`).toString('base64')
  if (setSecret) setSecret(auth)

  return `Authorization: Basic ${auth}`
}

const pushRepositoryUpdate = async (context, setSecret, appId, privateKey, owner, repo, refName, bundlePath) => {
  context.log(`Pushing updates to ${owner}/${repo}`)

  // Updates to `build-extra` and `git-for-windows.github.io` need a worktree
  const bare = ['build-extra', 'git-for-windows.github.io'].includes(repo) ? '' : ['--bare']
  const gitDir = `${repo}${bare ? '' : '/.git'}`

  callGit(['clone', ...bare,
    '--single-branch', '--branch', 'main', '--depth', '50',
    `https://github.com/${owner}/${repo}`, repo
  ])

  if (bundlePath) {
    // Allow Git to fetch non-local objects by pretending to be a partial clone
    callGit(['--git-dir', gitDir, 'config', 'remote.origin.promisor', 'true'])
    callGit(['--git-dir', gitDir, 'config', 'remote.origin.partialCloneFilter', 'blob:none'])
    mergeBundle(gitDir, !bare && repo, bundlePath, refName)
  }

  if (repo === 'build-extra') {
    // Add `versions/package-versions-$ver*.txt`
    const fs = require('fs')
    const ver = fs.readFileSync('bundle-artifacts/ver').toString().trim()
    fs.renameSync(
      'installer-x86_64/package-versions.txt',
      `${repo}/versions/package-versions-${ver}.txt`
    )
    fs.renameSync(
      'mingit-x86_64/package-versions.txt',
      `${repo}/versions/package-versions-${ver}-MinGit.txt`
    )
    callGit([
      'add',
      `versions/package-versions-${ver}.txt`,
      `versions/package-versions-${ver}-MinGit.txt`
    ], repo)
    callGit([
      'commit',
      '-s',
      '-m', `versions: add v${ver}`,
      `versions/package-versions-${ver}.txt`,
      `versions/package-versions-${ver}-MinGit.txt`
    ], repo)

    // Update `download-stats.sh`
    callProg('sh', ['./download-stats.sh', '--update'], repo)
    callGit(['commit', '-s', '-m', 'download-stats: new Git for Windows version', './download-stats.sh'], repo)
  } else if (repo === 'git-for-windows.github.io') {
    callGit(['switch', '-C', 'main', 'origin/main'], repo)
    callProg('node', ['bump-version.js', '--auto'], repo)
    callGit(['commit', '-a', '-s', '-m', 'New Git for Windows version'], repo)
  }

  const authorizationHeader = await getPushAuthorizationHeader(context, setSecret, appId, privateKey, owner, repo)
  callGit(['--git-dir', gitDir,
    '-c', `http.extraHeader=${authorizationHeader}`,
    'push', `https://github.com/${owner}/${repo}`, refName
  ])
  context.log(`Done pushing ref ${refName} to ${owner}/${repo}`)

  // For MINGW-packages, also push the MSYS2 sync branch from the bundle
  // See https://github.com/msys2/MINGW-packages/pull/26470
  // Note: This code only runs for non-RC releases (guarded by the action's `if` condition)
  if (repo === 'MINGW-packages' && bundlePath) {
    const fs = require('fs')
    const version = fs.readFileSync('bundle-artifacts/next_version').toString().trim()
    const msys2SyncBranch = `msys2-sync-${version}`

    // The bundle contains a commit based on msys2/master, so we need to fetch
    // the prerequisite commits first. Parse the bundle header to find them
    // (lines starting with `-` before the first blank line).
    // Bundle files are binary (text header followed by packfile data), so we
    // read the first 1024 bytes as raw bytes and search for the \n\n that
    // separates the header from the binary packfile data, to avoid decoding
    // arbitrary binary content as UTF-8.
    const fd = fs.openSync(bundlePath, 'r')
    const buf = Buffer.alloc(1024)
    fs.readSync(fd, buf)
    fs.closeSync(fd)
    const headerEnd = buf.indexOf(Buffer.from([0x0a, 0x0a]))
    const bundleHeader = buf.subarray(0, headerEnd).toString('utf-8')
    const prerequisites = bundleHeader
      .split('\n')
      .filter(line => line.startsWith('-'))
      .map(line => line.slice(1).split(' ')[0])

    if (prerequisites.length > 0) {
      // Check which prerequisites are missing locally using cat-file --batch-check
      const { spawnSync } = require('child_process')
      const catFile = spawnSync('git', ['--git-dir', gitDir, 'cat-file', '--batch-check'], {
        input: prerequisites.join('\n'),
        encoding: 'utf-8'
      })
      const missing = catFile.stdout
        .split('\n')
        .filter(line => line.endsWith(' missing'))
        .map(line => line.split(' ')[0])

      if (missing.length > 0) {
        context.log(`Fetching ${missing.length} prerequisite(s) from msys2/MINGW-packages`)
        callGit(['--git-dir', gitDir, 'fetch', '--depth', '1',
          'https://github.com/msys2/MINGW-packages', ...missing
        ])
      }
    }

    callGit(['--git-dir', gitDir, 'fetch', bundlePath, msys2SyncBranch])
    callGit(['--git-dir', gitDir,
      '-c', `http.extraHeader=${authorizationHeader}`,
      'push', `https://github.com/${owner}/${repo}`, `FETCH_HEAD:refs/heads/${msys2SyncBranch}`
    ])
    context.log(`::notice::Pushed MSYS2 sync branch ${msys2SyncBranch} to ${owner}/${repo}`)
  }
}

const pushGitBranch = async (context, setSecret, appId, privateKey, owner, repo, pushRefSpec) => {
  context.log(`Pushing ${pushRefSpec} to ${owner}/${repo}`)

  callGit(['clone', '--bare', '--filter=blob:none',
    '--single-branch', '--branch', 'main', '--depth', '50',
    `https://github.com/${owner}/${repo}`, repo
  ])

  // Allow Git to fetch non-local objects by pretending to be a partial clone
  callGit(['--git-dir', repo, 'config', 'remote.origin.promisor', 'true'])
  callGit(['--git-dir', repo, 'config', 'remote.origin.partialCloneFilter', 'blob:none'])

  const authorizationHeader = await getPushAuthorizationHeader(context, setSecret, appId, privateKey, owner, repo)

  callGit(['--git-dir', repo,
    '-c', `http.extraHeader=${authorizationHeader}`,
    'push', `https://github.com/${owner}/${repo}`, pushRefSpec
  ])
  context.log(`Done pushing ref ${pushRefSpec} to ${owner}/${repo}`)
}

module.exports = {
  mergeBundle,
  callGit,
  getWorkflowRunArtifact,
  pushRepositoryUpdate,
  pushGitBranch,
  getPushAuthorizationHeader
}
