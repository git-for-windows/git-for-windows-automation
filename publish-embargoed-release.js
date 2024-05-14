const publishEmbargoedRelease = async (source, target, tag) => {
  const getAppInstallationToken = async (context) => {
    if (context.token) return context.token

    const getAppInstallationId = require('./get-app-installation-id')
    const installationId = await getAppInstallationId(
      console,
      context.appId,
      context.privateKey,
      context.repoOwner,
      context.repoName
    )

    const getInstallationAccessToken = require('./get-installation-access-token')
    const { token: accessToken } = await getInstallationAccessToken(
      console,
      context.appId,
      context.privateKey,
      installationId
    )

    context.token = accessToken
    return accessToken
  }

  const getRelease = async (context, tag) => {
    if (context.release) return context.release

    const githubApiRequest = require('./github-api-request')
    context.release = await githubApiRequest(
      console,
      await getAppInstallationToken(context),
      'GET',
      `/repos/${context.repoOwner}/${context.repoName}/releases/tags/${tag}`
    )

    return context.release
  }

  const getReleaseAssets = async (context, tag) => {
    context.directory = `assets-${tag}`
    const zips = `${context.directory}/zips`
    context.unpackedPath = `${context.directory}/unpacked`

    const { mkdirSync, existsSync, openSync } = require('fs')
    await mkdirSync(zips, { recursive: true })
    await mkdirSync(context.unpackedPath, { recursive: true })

    const release = await getRelease(context, tag)
    if (!context.assets) context.assets = []

    const { spawnSync } = require('child_process')
    for (const asset of release.assets) {
      const zipPath = `${zips}/${asset.name}`
      if (!existsSync(zipPath)) {
        console.log(`Downloading ${asset.name}`)
        const url = asset.url
        const accept = ['-H', 'Accept: application/octet-stream']
        const auth = ['-H', `Authorization: token ${await getAppInstallationToken(context)}`]
        const curl = spawnSync('curl', [...accept, ...auth, '-fLo', zipPath, url])
        if (curl.error) throw curl.error
      }
      if (asset.name.startsWith('all-')) {
        for (const bundle of [`git.bundle`]) {
          const bundlePath = `${context.unpackedPath}/${bundle}`
          if (existsSync(bundlePath)) continue
          const directoryInZip = 'bundle-artifacts-x86_64'
          console.log(`Extracting ${bundle} from ${asset.name}`)
          const unzip = spawnSync('unzip', ['-p', zipPath, `${directoryInZip}/${bundle}`], {
            stdio: ['ignore', openSync(`${context.unpackedPath}/${bundle}`, 'w'), 'inherit'],
          })
          if (unzip.error) throw unzip.error
          if (!existsSync(bundlePath)) {
            throw new Error(`Failed to extract ${bundle} from ${zipPath}`)
          }
        }
      } else if (!asset.name.startsWith('release-notes-')) {
        context.assets.push({
          name: asset.name,
          path: zipPath,
        })
      }
    }
  }

  const mirrorRelease = async (source, target, tag) => {
    const setSecret = typeof core === 'undefined' ? null : core.setSecret

    await getReleaseAssets(source, tag)
    const isLatest = !source.release.prerelease

    const { createRelease, updateRelease, uploadReleaseAsset, pushGitTag } = require('./github-release')
    console.log(`Pushing tag ${tag} to ${target.repoOwner}/${target.repoName}`)
    await pushGitTag(
      console,
      setSecret,
      await getAppInstallationToken(target),
      target.repoOwner,
      target.repoName,
      tag,
      `${source.unpackedPath}/git.bundle`
    )
    console.log(`Creating release for ${target.repoOwner}/${target.repoName} with tag ${tag}`)
    target.release = await createRelease(
      console,
      await getAppInstallationToken(target),
      target.repoOwner,
      target.repoName,
      tag,
      source.release.target_commitish,
      source.release.name,
      source.release.body,
      true, // draft
      true // prerelease
    )
    for (const asset of source.assets) {
      console.log(`Uploading ${asset.name} to ${target.repoOwner}/${target.repoName} release ${target.release.id}`)
      await uploadReleaseAsset(
        console,
        await getAppInstallationToken(target),
        target.repoOwner,
        target.repoName,
        target.release.id,
        asset.name,
        asset.path
      )
    }
    console.log(`Publishing release ${source.release.name}`)
    await updateRelease(
      console,
      await getAppInstallationToken(target),
      target.repoOwner,
      target.repoName,
      target.release.id,
      {
        draft: false,
        prerelease: !isLatest,
        make_latest: isLatest,
      }
    )
    console.log(`Release ${source.release.name} mirrored to ${target.repoOwner}/${target.repoName}`)
  }

  await mirrorRelease(source, target, tag)
}

module.exports = {
  publishEmbargoedRelease,
}
