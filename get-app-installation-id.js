module.exports = async (context, appId, privateKey, owner, repo) => {
    const gitHubApiRequestAsApp = require('./github-api-request-as-app')
    const answer = await gitHubApiRequestAsApp(
        context,
        appId,
        privateKey,
        'GET',
        `/repos/${owner}/${repo}/installation`)
    if (answer.error) throw answer.error
    if (answer.id) return answer.id
    throw new Error(`Unhandled response:\n${JSON.stringify(answer, null, 2)}`)
}