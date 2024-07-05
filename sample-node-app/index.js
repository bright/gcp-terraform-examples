const express = require('express')
const asyncHandler = require('express-async-handler')
const { SecretManagerServiceClient } = require('@google-cloud/secret-manager')
const app = express()

function deployEnv () {
  const env = process.env.DEPLOY_ENV
  if (!env) {
    throw new Error('Missing DEPLOY_ENV environment variable')
  }
  return env
}

app.get('/', (req, res) => {

  res.status(200).json({
    message: 'Welcome to my API',
    GAE_MODULE_NAME: process.env.GAE_MODULE_NAME ?? Object.keys(process.env).toString(),
  })
})

const secretClient = new SecretManagerServiceClient()

function projectId () {
  const id = process.env.GOOGLE_CLOUD_PROJECT
  if (!id) {
    throw new Error('Missing GOOGLE_CLOUD_PROJECT environment variable')
  }
  return id
}

async function getSecretValue (secretKey) {
  const [version] = await secretClient.accessSecretVersion({
    name: `projects/${projectId()}/secrets/${secretKey}/versions/latest`,
  })

  const payload = version.payload.data.toString('utf8')
  return payload
}

app.get('/secrets', asyncHandler(async (req, res) => {
  const [first, second, third, forth] = await Promise.all([
    await getSecretValue(`${deployEnv()}-first-api-key`),
    await getSecretValue(`${deployEnv()}-second-api-key`),
    await getSecretValue(`${deployEnv()}-third-api-key`),
    await getSecretValue(`${deployEnv()}-forth-api-key`),
  ])

  res.status(200).json({
    first,second,third,forth
  })
}))

// Start the server
const PORT = process.env.PORT || 8080
app.listen(PORT, () => {
  console.log(`App listening on port ${PORT}`)
  console.log('Press Ctrl+C to quit.')
})
