module.exports = async (octokit, owner, repo, workflowRunId, artifactName) => {
    const { data } = workflowRunId
        ? await octokit.rest.actions.listWorkflowRunArtifacts({
            owner,
            repo,
            run_id: Number(workflowRunId)
        }) : await octokit.rest.actions.listArtifactsForRepo({
            owner,
            repo
        })

    const artifacts = data.artifacts.filter(a => a.name === artifactName)

    if (artifacts.length === 0) {
        throw new Error(`No artifacts with name '${artifactName}' found in workflow run ${workflowRunId}`)
    }

    const artifact = artifacts[0]

    console.log(`Getting downloadUrl for artifact ID ${artifact.id}...`)

    // This returns a download URL. The URL expires after 1 minute.
    const generateDownloadUrl = await octokit.rest.actions.downloadArtifact({
        owner,
        repo,
        artifact_id: artifact.id,
        archive_format: 'zip'
    })

    if (!generateDownloadUrl.url) {
        throw new Error(`Could not get download URL for artifact ${artifact.id}. Output: ${JSON.stringify(generateDownloadUrl)}`)
    }

    return generateDownloadUrl.url
}
