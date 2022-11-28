module.exports = async (context, token, owner, repo, ref, checkRunName, title, summary, text, detailsURL) => {
  const githubApiRequest = require('./github-api-request')
  // is there an existing check-run we can re-use?
  const { check_runs } = await githubApiRequest(
    context,
    token,
    'GET',
    `/repos/${owner}/${repo}/commits/${ref}/check-runs`
  )
  const filtered = check_runs
    .filter(e => e.name === checkRunName && e.conclusion === null).map(e => {
      return {
        id: e.id,
        status: e.status
      }
    })
  if (filtered.length > 0) {
    // ensure that the check_run is set to status "in progress"
    if (filtered[0].status !== 'in_progress') {
      console.log(await githubApiRequest(
        context,
        token,
        'PATCH',
        `/repos/${owner}/${repo}/check-runs/${filtered[0].id}`, {
          status: 'in_progress'
        }
      ))
    }
    process.stderr.write(`Returning existing ${filtered[0].id}`)
    return filtered[0].id
  }

  const { id } = await githubApiRequest(
    context,
    token,
    'POST',
    `/repos/${owner}/${repo}/check-runs`, {
      name: checkRunName,
      head_sha: ref,
      status: 'in_progress',
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
