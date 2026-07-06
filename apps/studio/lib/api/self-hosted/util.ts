import crypto from 'crypto-js'
import type { NextApiRequest } from 'next'

import {
  ENCRYPTION_KEY,
  POSTGRES_DATABASE,
  POSTGRES_HOST,
  POSTGRES_PASSWORD,
  POSTGRES_PORT,
  POSTGRES_USER_READ_ONLY,
  POSTGRES_USER_READ_WRITE,
} from './constants'
import { getProjectByRef } from './manifest'
import { IS_PLATFORM } from '@/lib/constants'

/**
 * Asserts that the current environment is self-hosted.
 */
export function assertSelfHosted() {
  if (IS_PLATFORM) {
    throw new Error('This function can only be called in self-hosted environments')
  }
}

export function encryptString(stringToEncrypt: string): string {
  return crypto.AES.encrypt(stringToEncrypt, ENCRYPTION_KEY).toString()
}

export function getConnectionString({
  ref,
  readOnly,
}: {
  ref?: string | string[]
  readOnly: boolean
}) {
  const postgresUser = readOnly ? POSTGRES_USER_READ_ONLY : POSTGRES_USER_READ_WRITE
  const project = getProjectByRef(ref)
  const database = project?.db ?? POSTGRES_DATABASE

  return `postgresql://${postgresUser}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${database}`
}

/**
 * Adds an `x-connection-encrypted` header carrying a per-project connection
 * string so pg-meta queries the correct DB for the current `[ref]` route.
 * Falls back to the env-configured DB when no SuperBase² manifest is present.
 */
export function withConnectionHeader(req: NextApiRequest, headers: Record<string, any>) {
  const connectionString = getConnectionString({ ref: req.query.ref, readOnly: false })
  return { ...headers, 'x-connection-encrypted': encryptString(connectionString) }
}
