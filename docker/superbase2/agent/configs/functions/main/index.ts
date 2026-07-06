import * as jose from 'https://deno.land/x/jose@v4.14.4/index.ts'

console.log('main function started')

const JWT_SECRET = Deno.env.get('JWT_SECRET')
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')
const VERIFY_JWT = Deno.env.get('VERIFY_JWT') === 'true'

let SUPABASE_JWT_KEYS: ReturnType<typeof jose.createRemoteJWKSet> | null = null
if (SUPABASE_URL) {
  try {
    SUPABASE_JWT_KEYS = jose.createRemoteJWKSet(
      new URL('/auth/v1/.well-known/jwks.json', SUPABASE_URL)
    )
  } catch (e) {
    console.error('Failed to fetch JWKS from SUPABASE_URL:', e)
  }
}

function getAuthToken(req: Request) {
  const authHeader = req.headers.get('authorization')
  if (!authHeader) {
    throw new Error('Missing authorization header')
  }
  const [bearer, token] = authHeader.split(' ')
  if (bearer !== 'Bearer') {
    throw new Error(`Auth header is not 'Bearer {token}'`)
  }
  return token
}

async function isValidLegacyJWT(jwt: string): Promise<boolean> {
  if (!JWT_SECRET) return false
  try {
    await jose.jwtVerify(jwt, new TextEncoder().encode(JWT_SECRET))
  } catch (_e) {
    return false
  }
  return true
}

async function isValidJWT(jwt: string): Promise<boolean> {
  if (!SUPABASE_JWT_KEYS) return false
  try {
    await jose.jwtVerify(jwt, SUPABASE_JWT_KEYS)
  } catch (_e) {
    return false
  }
  return true
}

async function isValidHybridJWT(jwt: string): Promise<boolean> {
  const { alg } = jose.decodeProtectedHeader(jwt)
  if (alg === 'HS256') return await isValidLegacyJWT(jwt)
  if (alg === 'ES256' || alg === 'RS256') return await isValidJWT(jwt)
  return false
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'OPTIONS' && VERIFY_JWT) {
    try {
      const token = getAuthToken(req)
      if (!(await isValidHybridJWT(token))) {
        return new Response(JSON.stringify({ msg: 'Invalid JWT' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        })
      }
    } catch (e) {
      return new Response(JSON.stringify({ msg: e.toString() }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      })
    }
  }

  const url = new URL(req.url)
  const { pathname } = url
  const service_name = pathname.split('/')[1]

  if (!service_name || service_name === '') {
    return new Response(JSON.stringify({ msg: 'missing function name in request' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const servicePath = `/home/deno/functions/${service_name}`
  const envVarsObj = Deno.env.toObject()
  const envVars = Object.keys(envVarsObj).map((k) => [k, envVarsObj[k]])

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath,
      memoryLimitMb: 150,
      workerTimeoutMs: 60000,
      noModuleCache: false,
      importMapPath: null,
      envVars,
    })
    return await worker.fetch(req)
  } catch (e) {
    return new Response(JSON.stringify({ msg: e.toString() }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})
