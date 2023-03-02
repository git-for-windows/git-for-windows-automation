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

module.exports =  async (context, setSecret, appId, privateKey, owner, repo) => {
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

    const get = require('./get-check-run-id')
    state.id = await(get(
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

    const update = require('./update-check-run')
    state.text = await update(
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
