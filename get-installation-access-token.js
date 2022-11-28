module.exports = async (context, appId, privateKey, installation_id) => {
    const gitHubApiRequestAsApp = require('./github-api-request-as-app')
    const answer = await gitHubApiRequestAsApp(
        context,
        appId,
        privateKey,
        'POST',
        `/app/installations/${installation_id}/access_tokens`)
    if (answer.error) throw answer.error
    if (answer.token) return answer.token
    throw new Error(`Unhandled response:\n${JSON.stringify(answer, null, 2)}`)
}