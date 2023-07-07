const createRelease = async (context, token, owner, repo, tagName, rev, name, body, draft, prerelease) => {
  const githubApiRequest = require('./github-api-request')
  return await githubApiRequest(
    context,
    token,
    'POST',
    `/repos/${owner}/${repo}/releases`, {
      tag_name: tagName,
      target_commitish: rev,
      name,
      body,
      draft: draft === undefined ? true : draft,
      prerelease: prerelease === undefined ? true : prerelease
    }
  )
}

const updateRelease = async (context, token, owner, repo, releaseId, parameters) => {
  const githubApiRequest = require('./github-api-request')
  return await githubApiRequest(
    context,
    token,
    'PATCH',
    `/repos/${owner}/${repo}/releases/${releaseId}`,
    parameters
  )
}

const uploadReleaseAsset = async (context, token, owner, repo, releaseId, name, path) => {
  const httpsRequest = require('./https-request')
  const fs = require('fs')
  const headers = {
    Authorization: `Bearer ${token}`
  }
  const answer = await httpsRequest(
    context,
    'uploads.github.com',
    'POST',
    `/repos/${owner}/${repo}/releases/${releaseId}/assets?name=${name}`,
    fs.createReadStream(path || name),
    headers)
  if (answer.error) throw answer.error
  return answer
}

const getWorkflowRunArtifactsURLs = async (context, token, owner, repo, workflowRunId) => {
  const githubApiRequest = require('./github-api-request')
  const { artifacts } = await githubApiRequest(
    context,
    token,
    'GET',
    `/repos/${owner}/${repo}/actions/runs/${workflowRunId}/artifacts`
  )
  return artifacts.reduce((map, e) => {
    map[e.name] = e.archive_download_url
    return map
  }, {})
}

const downloadAndUnZip = async (token, url, name) => {
  const { spawnSync } = require('child_process')
  const auth = token ? ['-H', `Authorization: Bearer ${token}`] : []
  const tmpFile = `${process.env.RUNNER_TEMP || process.env.TEMP || '/tmp'}/${name}.zip`
  const curl = spawnSync('curl', [...auth, '-Lo', tmpFile, url])
  if (curl.error) throw curl.error
  const { mkdirSync, rmSync } = require('fs')
  await mkdirSync(name, { recursive: true })
  const unzip = spawnSync('unzip', ['-d', name, tmpFile])
  if (unzip.error) throw unzip.error
  rmSync(tmpFile)
}

const architectures = [
  { name: 'x86_64', infix: '-64-bit' },
  { name: 'i686', infix: '-32-bit' }
]

const artifacts = [
  { name: 'installer', prefix: 'Git', ext: '.exe' },
  { name: 'portable', prefix: 'PortableGit', ext: '.7z.exe' },
  { name: 'mingit', prefix: 'MinGit', ext: '.zip' },
  { name: 'mingit-busybox', prefix: 'MinGit', ext: '.zip', infix: '-busybox' },
  { name: 'archive', prefix: 'Git', ext: '.tar.bz2' }
]

const ranked = artifacts
  .map(e => `${e.prefix}${e.infix || ''}${e.ext}`)
  .reverse()

const artifactName2Rank = (name) => {
  let rank = ranked.indexOf(name
    .replace(/-\d+(\.\d+)*(-rc\d+)?/, '')
    .replace(/-(32|64)-bit/, '')
  ) + (name.indexOf('-64-bit') > 0 ? 0.5 : 0)
  return rank
}

const downloadBundleArtifacts = async (context, token, owner, repo, git_artifacts_i686_workflow_run_id, git_artifacts_x86_64_workflow_run_id) => {
  for (const architecture of architectures) {
    const workflowRunId = {
      x86_64: git_artifacts_x86_64_workflow_run_id,
      i686: git_artifacts_i686_workflow_run_id
    }[architecture.name]
    const downloadURLs = await getWorkflowRunArtifactsURLs(context, token, owner, repo, workflowRunId)
    if (architecture.name === 'x86_64') await downloadAndUnZip(token, downloadURLs['bundle-artifacts'], 'bundle-artifacts')
    await downloadAndUnZip(token, downloadURLs['sha256sums'], `${architecture.name}-sha256sums`)
  }

  const fs = require('fs')

  const result = {
    tagName: fs.readFileSync('bundle-artifacts/next_version').toString().trim(),
    displayVersion: fs.readFileSync('bundle-artifacts/next_version').toString().trim(),
    ver: fs.readFileSync('bundle-artifacts/ver').toString().trim(),
    gitCommitOID: fs.readFileSync('bundle-artifacts/git-commit-oid').toString().trim(),
    sha256sums: {}
  }

  for (const architecture of architectures) {
    fs.readFileSync(`${architecture.name}-sha256sums/sha256sums.txt`)
      .toString()
      .split('\n')
      .forEach(line => {
        const pair = line.split(/\s+\*?/)
        if (pair && pair.length === 2) result.sha256sums[pair[1]] = pair[0]
      })
  }

  const artifactNames = Object.keys(result.sha256sums).filter(name => !name.endsWith('.nupkg'))
  artifactNames.sort((a, b) => artifactName2Rank(b) - artifactName2Rank(a))
  const checksums = artifactNames
    .map(name => `${name} | ${result.sha256sums[name]}`)
    .join('\n')

  fs.writeFileSync('bundle-artifacts/sha256sums', checksums)

  // Work around out-of-band versions' announcement file containing parentheses
  const withParens = result.ver.replace(/^(\d+\.\d+\.\d+)\.(\d+)$/, '$1($2)')
  console.log(`withParens: ${withParens}`)
  if (result.ver !== withParens) {
    if (!fs.existsSync(`bundle-artifacts/announce-${result.ver}`)) {
      fs.renameSync(`bundle-artifacts/announce-${withParens}`, `bundle-artifacts/announce-${result.ver}`)
    }
    if (!fs.existsSync(`bundle-artifacts/release-notes-${result.ver}`)) {
      fs.renameSync(`bundle-artifacts/release-notes-${withParens}`, `bundle-artifacts/release-notes-${result.ver}`)
    }
  }

  result.announcement = fs
    .readFileSync(`bundle-artifacts/announce-${result.ver}`)
    .toString()
    .replace('@@CHECKSUMS@@', checksums)
  result.releaseNotes = fs
    .readFileSync(`bundle-artifacts/release-notes-${result.ver}`)
    .toString()
    .replace('@@CHECKSUMS@@', checksums)

  fs.writeFileSync(`bundle-artifacts/announce-${result.ver}`, result.announcement)
  fs.writeFileSync(`bundle-artifacts/release-notes-${result.ver}`, result.releaseNotes)

  return result
}

const getGitArtifacts = async (context, token, owner, repo, git_artifacts_i686_workflow_run_id, git_artifacts_x86_64_workflow_run_id) => {
  const fs = require('fs')
  const result = []
  for (const architecture of architectures) {
    const workflowRunId = {
      x86_64: git_artifacts_x86_64_workflow_run_id,
      i686: git_artifacts_i686_workflow_run_id
    }[architecture.name]

    const urls = await getWorkflowRunArtifactsURLs(context, token, owner, repo, workflowRunId)
    for (const artifact of artifacts) {
      const name = `${artifact.name}-${architecture.name}`
      context.log(`Downloading ${name}`)
      await downloadAndUnZip(token, urls[name], name)

      for (const fileName of fs.readdirSync(name)) {
        if (fileName.endsWith('.exe') || fileName.endsWith('.zip') || fileName.endsWith('.tar.bz2')) {
          result.push({
            name: fileName,
            path: `${name}/${fileName}`
          })
        }
      }
    }
  }
  return result
}

const sha256sumsFromReleaseNotes = (releaseNotes) =>
  releaseNotes
    .split('-------- | -------\n')[1]
    .split('\n')
    .reduce((checksums, line) => {
      const pair = line.split(' | ')
      if (pair && pair.length === 2) checksums[pair[0]] = pair[1]
      return checksums
    }, {})

const calculateSHA256ForFile = async (path) => {
  const crypto = require('crypto')
  const sha256 = crypto.createHash('sha256')

  const handle = (resolve, reject, res) => {
    res.on('error', err => reject(err))
    res.on('data', data => sha256.update(data))
    res.on('end', () => resolve(sha256.digest('hex')))
    res.on('finish', () => resolve(sha256.digest('hex')))
  }

  const fs = require('fs')
  const stream = fs.createReadStream(path)
  return new Promise((resolve, reject) => {
    handle(resolve, reject, stream)
  })
}

const checkSHA256Sums = async (_context, gitArtifacts, sha256sums) => {
  const unchecked = { ...sha256sums }
  for (const gitArtifact of gitArtifacts) {
    if (gitArtifact.name.startsWith('pdbs-for-')) continue // the PDBs file does not get checksummed

    const expected = unchecked[gitArtifact.name]
    if (!expected) throw new Error(`Unexpected file (no SHA-256): '${gitArtifact.name}`)

    const calculated = await calculateSHA256ForFile(gitArtifact.path)
    if (expected !== calculated) throw new Error(`Unexpected SHA-256 for ${gitArtifact.name} (expected ${expected}, got ${calculated})`)

    delete unchecked[gitArtifact.name]
  }

  const missing = Object.keys(unchecked).filter(name => !name.endsWith('.nupkg'))
  if (missing.length > 0) throw new Error(`Missing artifacts: ${missing.join(', ')}`)
}

const uploadGitArtifacts = async (context, token, owner, repo, releaseId, gitArtifacts) => {
  context.log(`Uploading Git artifacts: ${gitArtifacts.map(artifact => artifact.name).join(', ')}`)
  for (const artifact of gitArtifacts) {
    context.log(`Uploading ${artifact.name}`)
    await uploadReleaseAsset(context, token, owner, repo, releaseId, artifact.name, artifact.path)
  }
  context.log('Done uploading Git artifacts')
}

const pushGitTag = (context, setSecret, token, owner, repo, tagName, bundlePath) => {
  context.log(`Pushing Git tag ${tagName}`)
  const { callGit } = require('./repository-updates')
  callGit(['clone',
    '--bare', '--single-branch', '--branch', 'main', '--depth', '50',
    `https://github.com/${owner}/${repo}`, 'git'
  ])

  // Allow Git to fetch non-local objects by pretending to be a partial clone
  callGit(['--git-dir', 'git', 'config', 'remote.origin.promisor', 'true'])
  callGit(['--git-dir', 'git', 'config', 'remote.origin.partialCloneFilter', 'blob:none'])

  callGit(['--git-dir', 'git', 'fetch', bundlePath, `refs/tags/${tagName}:refs/tags/${tagName}`])
  const auth = Buffer.from(`PATH:${token}`).toString('base64')
  if (setSecret) setSecret(auth)
  callGit(['--git-dir', 'git',
    '-c', `http.extraHeader=Authorization: Basic ${auth}`,
    'push', `https://github.com/${owner}/${repo}`, `refs/tags/${tagName}`
  ])
  context.log('Done pushing tag')
}

module.exports = {
  createRelease,
  updateRelease,
  uploadReleaseAsset,
  getWorkflowRunArtifactsURLs,
  downloadAndUnZip,
  downloadBundleArtifacts,
  getGitArtifacts,
  sha256sumsFromReleaseNotes,
  calculateSHA256ForFile,
  checkSHA256Sums,
  uploadGitArtifacts,
  pushGitTag
}