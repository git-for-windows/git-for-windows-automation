module.exports = async (context, token, owner, repo, checkRunId, appendText, conclusion) => {
  const githubApiRequest = require('./github-api-request')
  let { output: { title, summary, text } } = await githubApiRequest(
    context,
    token,
    'GET',
    `/repos/${owner}/${repo}/check-runs/${checkRunId}`
  )

  if (!text) text = appendText
  else if (appendText) text = [text, appendText].join('\n')

  const statusUpdate = conclusion ? { status: 'completed', conclusion } : {}

  await githubApiRequest(
    context,
    token,
    'PATCH',
    `/repos/${owner}/${repo}/check-runs/${checkRunId}`, {
      output: { title, summary, text },
      ...statusUpdate
    }
  )

  return text
}