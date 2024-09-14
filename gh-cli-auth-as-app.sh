#!/bin/sh

node -e '(async () => {
  const [owner, repo] = process.env.GITHUB_REPOSITORY.split("/")
  const getAppInstallationId = require("./get-app-installation-id")
  const installationId = await getAppInstallationId(
    console,
    process.env.GH_APP_ID,
    process.env.GH_APP_PRIVATE_KEY,
    owner,
    repo
  )
  const getInstallationAccessToken = require("./get-installation-access-token")
  const token = await getInstallationAccessToken(
    console,
    process.env.GH_APP_ID,
    process.env.GH_APP_PRIVATE_KEY,
    installationId
  )
  process.stderr.write(`::add-mask::${token.token}\n`)
  process.stdout.write(token.token)
})().catch(e => {
  process.stderr.write(JSON.stringify(e, null, 2))
  process.exit(1)
})' | gh auth login --with-token
