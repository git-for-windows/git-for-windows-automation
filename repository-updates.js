const callProg = (prog, parameters, cwd) => {
  const { spawnSync } = require('child_process')
  const child = spawnSync(prog, parameters, {
    stdio: ['ignore', 'pipe', 'inherit'],
    cwd
  })
  if (child.error) throw error
  if (child.status !== 0) throw new Error(`${prog} ${parameters.join(' ')} failed with status ${child.status}`)
  return child.stdout.toString('utf-8')
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

const pushRepositoryUpdate = async (context, setSecret, appId, privateKey, owner, repo, refName, bundlePath) => {
  context.log(`Pushing updates to ${owner}/${repo}`)

  const bare = ['build-extra', 'git-for-windows.github.io'].includes(repo) ? '' : ['--bare']
  const gitDir = `${repo}${bare ? '' : '/.git'}`

  callGit(['clone', ...bare,
    '--single-branch', '--branch', 'main', '--depth', '50',
    `https://github.com/${owner}/${repo}`, repo
  ])

  if (bundlePath) {
    callGit(['--git-dir', gitDir, 'fetch', bundlePath, refName])
  }

  if (repo === 'build-extra') {
    callGit(['switch', '-f', '-c', refName, 'FETCH_HEAD'], repo)
    callProg('./download-stats.sh', ['--update'], repo)
    callGit(['commit', '-s', '-m', 'download-stats: new Git for Windows version', './download-stats.sh'], repo)
  } else if (repo === 'git-for-windows.github.io') {
    callGit(['switch', '-C', 'main', 'origin/main'], repo)
    callProg('node', ['bump-version.js', '--auto'], repo)
    callGit(['commit', '-a', '-s', '-m', 'New Git for Windows version'], repo)
  }

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

  callGit(['--git-dir', gitDir,
    '-c', `http.extraHeader=Authorization: Basic ${auth}`,
    'push', `https://github.com/${owner}/${repo}`, refName
  ])
  context.log(`Done pushing ref ${refName} to ${owner}/${repo}`)
}

module.exports = {
  callGit,
  getWorkflowRunArtifact,
  pushRepositoryUpdate
}
