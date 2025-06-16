module.exports = (artifactsString, architecture, allowI686) => {
    const artifacts = artifactsString.split(' ')

    if (artifacts.length < 1) {
        throw new Error('No artifacts provided. Provide in a space-separated string, e.g. "installer portable"')
    }

    const validArtifacts = [
        {
            name: 'mingit',
            filePrefix: 'MinGit',
            fileExtension: 'zip'
        }
    ]

    if (allowI686 || architecture !== 'i686') validArtifacts.unshift({
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
    })

    if (architecture !== 'aarch64') validArtifacts.push({
        name: 'mingit-busybox',
        filePrefix: 'MinGit',
        fileExtension: 'zip'
    })
    
    if (architecture === 'x86_64') validArtifacts.push({
        name: 'nuget',
        filePrefix: 'Git',
        fileExtension: 'nupkg'
    })

    const artifactsToBuild = []
    
    for (const artifact of artifacts) {
        const artifactObject = validArtifacts.find(a => a.name === artifact)
        if (!artifactObject) {
            throw new Error(`${artifact} is not a valid artifact for ${architecture}`)
        }
    
        artifactsToBuild.push(artifactObject)
    }

    return {
        artifact: artifactsToBuild
    }
}
