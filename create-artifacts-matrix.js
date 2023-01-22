module.exports = (core, artifactsString, architecture) => {
    const artifacts = artifactsString.split(' ')

    if (artifacts.length < 1) {
        core.setFailed('No artifacts provided. Provide in a space-separated string, e.g. "installer portable"')
        return
    }

    const validArtifacts = [
        {
            name: 'installer',
            filePrefix: 'Git',
            fileExtension: 'exe'
        },
        {
            name: 'portable',
            filePrefix: 'PortableGit',
            fileExtension: 'exe'
        },
        {
            name: 'archive',
            filePrefix: 'Git',
            fileExtension: 'tar.bz2'
        },
        {
            name: 'mingit',
            filePrefix: 'MinGit',
            fileExtension: 'zip'
        },
        architecture !== 'aarch64' && {
            name: 'mingit-busybox',
            filePrefix: 'MinGit',
            fileExtension: 'zip'
        }
    ]
    
    const artifactsToBuild = []
    
    for (const artifact of artifacts) {
        const artifactObject = validArtifacts.find(a => a.name === artifact)
        if (!artifactObject) {
            core.setFailed(`${artifact} is not a valid artifact for ${architecture}`)
            return
        }
    
        artifactsToBuild.push(artifactObject)
    }

    const output = {artifact: artifactsToBuild}

    core.info(`Will be using the following matrix: ${JSON.stringify(output)}`)
    core.setOutput('matrix', output)
}
