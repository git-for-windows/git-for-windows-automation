const gently = require('./gently')

module.exports = async (context, hostname, method, requestPath, body, headers) => {
    headers = {
        'User-Agent': 'GitForWindowsHelperApp/0.0',
        Accept: 'application/json',
        ...headers || {}
    }
    if (body) {
        if (typeof body === 'object') body = JSON.stringify(body)
        headers['Content-Type'] = 'application/json'
        headers['Content-Length'] = body.length
    }
    const options = {
        port: 443,
        hostname: hostname || 'api.github.com',
        method: method || 'GET',
        path: requestPath,
        headers
    }
    return new Promise((resolve, reject) => {
        try {
            const https = require('https')
            const handler = res => {
                if (res.statusCode === 204) {
                    resolve({
                        statusCode: res.statusCode,
                        statusMessage: res.statusMessage,
                        headers: res.headers
                    })
                    return
                }

                res.on('error', e => reject(e))

                const chunks = []
                res.on('data', data => chunks.push(data))
                res.on('end', () => {
                    const json = Buffer.concat(chunks).toString('utf-8')
                    if (res.statusCode > 299) {
                        context.log('FAILED GitHub REST API call!')
                        context.log(options)
                        reject({
                            statusCode: res.statusCode,
                            statusMessage: res.statusMessage,
                            body: json,
                            json: gently(() => JSON.parse(json))
                        })
                        return
                    }
                    try {
                        resolve(JSON.parse(json))
                    } catch (e) {
                        reject(`Invalid JSON: ${json}`)
                    }
                })
            }

            const req = https.request(options, res => {
                if (res.statusCode === 301 || res.statusCode === 302) {
                    const url = res.headers.location
                    const match = url.match(/^https:\/\/([^/]+)(.*)$/)
                    if (!match) throw new Error(`Unsupported redirect URL: ${url}`)

                    const options = {
                        port: 443,
                        hostname: match[1],
                        method: 'GET',
                        path: match[2],
                        headers
                    }

                    const portNumberMatch = options.hostname.match(/^(.*):(\d+)$/)
                    if (portNumberMatch) {
                        options.port = Number(portNumberMatch[2])
                        options.hostname = portNumberMatch[1]
                    }

                    const req = https.request(options, handler)
                    req.on('error', err => reject(err))
                    req.end()
                } else handler(res)
            })

            req.on('error', err => reject(err))
            if (body) req.write(body)
            req.end()
        } catch (e) {
            reject(e)
        }
    })
}
