const getOrCreateCheckRun = async (context, token, owner, repo, ref, checkRunName, title, summary, text, detailsURL) => {
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
        status: e.status,
        output: e.output
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
          status: 'in_progress',
          details_url: detailsURL,
          output: {
            ...filtered[0].output,
            title: title || filtered[0].output.title,
            summary: summary || filtered[0].output.summary,
            text: text || filtered[0].output.text
          }
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

const updateCheckRun = async (context, token, owner, repo, checkRunId, appendText, conclusion, title, summary) => {
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

const crypto = require('crypto')

const getPublicKey = (privateKey) => crypto.createPublicKey(privateKey)

const decryptChunk = (encrypted, privateKey) => crypto.privateDecrypt(privateKey, Buffer.from(encrypted, 'base64url')).toString('utf-8')

const decrypt = (encrypted, privateKey) => {
    return JSON.parse(encrypted
        .split('/')
        .map(e => decryptChunk(e, privateKey))
        .join(''))
}

const encryptChunk = (chunk, publicKey) => crypto.publicEncrypt(publicKey, chunk).toString('base64url')

const maxChunkLength = 200
const encrypt = (data, publicKey) => {
    const json = JSON.stringify(data)
    const chunked = []
    let i = 0
    while (i < json.length) {
        const i2 = i + maxChunkLength
        if (i2 < json.length) chunked.push(json.substring(i, i2))
        else chunked.push(json.substring(i))
        i = i2
    }
    return chunked
        .map(e => encryptChunk(e, publicKey))
        .join('/')
}

const initCheckRunState =  async (context, setSecret, appId, privateKey, owner, repo) => {
  const fs = require('fs')

  const stateFile = `${process.env.RUNNER_TEMP || process.env.TEMP || '/tmp'}/check-run.state`
  const state = fs.existsSync(stateFile)
    ? JSON.parse(decrypt(fs.readFileSync(stateFile).toString(), privateKey))
    : {}

  if (!state.owner) state.owner = owner
  else if (owner && state.owner !== owner) throw new Error(`Expected owner ${state.owner}, got ${owner}`)
  if (!state.repo) state.repo = repo
  else if (repo && state.repo !== repo) throw new Error(`Expected repo ${state.repo}, got ${repo}`)

  state.store = () => {
    fs.writeFileSync(stateFile, encrypt(JSON.stringify(state), getPublicKey(privateKey)))
  }

  state.refreshToken = async () => {
    if (state.expiresAt
      && Date.parse(state.expiresAt) - Date.now() > 5 * 60 * 1000) return

    const getAppInstallationId = require('./get-app-installation-id')
    const installationId = await getAppInstallationId(
      context,
      appId,
      privateKey,
      owner,
      repo
    )

    const getInstallationAccessToken = require('./get-installation-access-token')
    const { expiresAt, token: accessToken } = await getInstallationAccessToken(
      context,
      appId,
      privateKey,
      installationId
    )

    if (setSecret) setSecret(accessToken)

    state.expiresAt = expiresAt
    state.accessToken = accessToken
    state.store()
  }

  state.get = async (ref, checkRunName, title, summary, text, detailsURL) => {
    await state.refreshToken()

    state.id = await(getOrCreateCheckRun(
      context,
      state.accessToken,
      owner || state.owner,
      repo || state.repo,
      ref,
      checkRunName,
      title,
      summary,
      text,
      detailsURL
    ))
    state.ref = ref
    state.checkRunName = checkRunName
    state.title = title
    state.summary = summary
    state.text = text
    state.detailsURL = detailsURL
    state.store()
  }

  state.update = async (appendText, conclusion, title, summary) => {
    if (!state.id) throw new Error('Need to `get()` Check Run before calling `update()`')

    await state.refreshToken()

    state.text = await updateCheckRun(
      context,
      state.accessToken,
      owner || state.owner,
      repo || state.repo,
      state.id,
      appendText,
      conclusion,
      title,
      summary
    )
    state.conclusion = conclusion
  }

  state.store()
  return state
}

module.exports = {
  getOrCreateCheckRun,
  updateCheckRun,
  initCheckRunState
}