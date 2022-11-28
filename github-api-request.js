module.exports = async (context, token, method, requestPath, payload) => {
    const httpsRequest = require('./https-request')
    const headers = token ? { Authorization: `Bearer ${token}` } : null
    const answer = await httpsRequest(context, null, method, requestPath, payload, headers)
    if (answer.error) throw answer.error
    return answer
}