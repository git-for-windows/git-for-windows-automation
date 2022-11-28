module.exports = async (context, token, owner, repo, ref, checkRunName, title, summary, text, detailsURL) => {
  const githubApiRequest = require('./github-api-request')
  const { check_runs } = await githubApiRequest(
    context,
    token,
    'GET',
    `/repos/${owner}/${repo}/commits/${ref}/check-runs`
  )
  const check_run_ids = check_runs.filter(e => e.name === checkRunName).map(e => e.id)
  if (check_run_ids.length > 0) return check_run_ids[0]

  const { id } = await githubApiRequest(
    context,
    token,
    'POST',
    `/repos/${owner}/${repo}/check-runs`, {
      name: checkRunName,
      head_sha: ref,
      details_url: detailsURL,
      output: {
        title,
        summary,
        text
      }
    }
  )
  return id
}
