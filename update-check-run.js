module.exports = async (context, token, owner, repo, checkRunId, appendText, conclusion, title, summary) => {
  const githubApiRequest = require('./github-api-request')
  let { output } = await githubApiRequest(
    context,
    token,
    'GET',
    `/repos/${owner}/${repo}/check-runs/${checkRunId}`
  )

  if (title) output.title = title
  if (summary) output.summary = summary
  if (appendText) output.text = [output.text, appendText].join('\n')

  const statusUpdate = conclusion ? { status: 'completed', conclusion } : {}

  await githubApiRequest(
    context,
    token,
    'PATCH',
    `/repos/${owner}/${repo}/check-runs/${checkRunId}`, {
      output,
      ...statusUpdate
    }
  )

  return output.text
}