// Locate the git-artifacts run for the UCRT64 variant that is built alongside
// MINGW64 during the migration, and that will replace it as the official Intel
// 64-bit build (returning '' while no such transitional run exists yet).

const findUCRT64GitArtifactsRun = async (context, token, owner, repo, sha) => {
  const githubApiRequest = require('./github-api-request')

  // The git-artifacts workflow mirrors a `git-artifacts-ucrt64` check-run onto
  // the tagged commit in git-for-windows/git, whose details URL points back at
  // the run in the git-for-windows-automation repository.
  const { check_runs } = await githubApiRequest(
    context,
    token,
    'GET',
    `/repos/${owner}/${repo}/commits/${sha}/check-runs?check_name=git-artifacts-ucrt64`
  )

  // Prefer the most recently started successful run, falling back to the most
  // recent run of any conclusion (e.g. while it is still in progress).
  const candidates = check_runs
    .filter(c => /\/actions\/runs\/\d+/.test(c.details_url || ''))
    .sort((a, b) => Date.parse(b.started_at || 0) - Date.parse(a.started_at || 0))
  const match = candidates.find(c => c.conclusion === 'success') || candidates[0]
  if (!match) {
    context.log(`No UCRT64 git-artifacts run found for ${owner}/${repo}@${sha}`)
    return ''
  }

  const runId = match.details_url.match(/\/actions\/runs\/(\d+)/)[1]
  context.log(`Found UCRT64 git-artifacts run ${runId} (check-run ${match.id}, conclusion: ${match.conclusion || 'pending'})`)
  return runId
}

module.exports = findUCRT64GitArtifactsRun

if (require.main === module) {
  const [owner, repo, sha] = process.argv.slice(2)
  if (!owner || !repo || !sha) {
    console.error(`Usage: ${process.argv[1]} <owner> <repo> <commit-ish>`)
    process.exit(1)
  }

  const token = process.env.GITHUB_TOKEN
  if (!token) {
    console.error('Need GITHUB_TOKEN in the environment')
    process.exit(1)
  }

  findUCRT64GitArtifactsRun(console, token, owner, repo, sha)
    .then(runId => process.stdout.write(`${runId}\n`))
    .catch(err => { console.error(err); process.exit(1) })
}
