/**
 * Server-side Entra callback URL resolution.
 *
 * This lives in shared code so the OAuth connect flow, the setup metadata, and
 * the diagnostics report all compute the same expected redirect URI. The
 * precedence (runtime application URL, then public build URL, then localhost)
 * matches the historical connect action; diagnostics only ever read it.
 */

export interface AppSecretReader {
  getAppSecret(key: string): Promise<string | undefined | null>;
}

export function computeEntraCallbackUrl(baseUrl: string): string {
  const trimmed = (baseUrl || '').trim() || 'http://localhost:3000';
  return `${trimmed.replace(/\/+$/, '')}/api/auth/microsoft/entra/callback`;
}

/**
 * Resolve the deployment base URL without letting a build-time NEXT_PUBLIC_*
 * value override a runtime deployment URL. Never writes.
 */
export async function resolveEntraDeploymentBaseUrl(
  secretProvider: AppSecretReader
): Promise<string> {
  const base =
    process.env.APPLICATION_URL ||
    (await secretProvider.getAppSecret('APPLICATION_URL')) ||
    process.env.NEXTAUTH_URL ||
    (await secretProvider.getAppSecret('NEXTAUTH_URL')) ||
    process.env.NEXT_PUBLIC_BASE_URL ||
    (await secretProvider.getAppSecret('NEXT_PUBLIC_BASE_URL')) ||
    'http://localhost:3000';

  return (base || 'http://localhost:3000').trim();
}

export async function resolveEntraCallbackUrl(
  secretProvider: AppSecretReader
): Promise<string> {
  // Unlike NEXT_PUBLIC_BASE_URL, this is not inlined by Next.js at build time.
  // It lets a container deployment pin the Entra callback independently of the
  // build environment.
  const explicit =
    process.env.ENTRA_REDIRECT_URI ||
    await secretProvider.getAppSecret('ENTRA_REDIRECT_URI');
  if (explicit?.trim()) {
    return explicit.trim();
  }
  return computeEntraCallbackUrl(await resolveEntraDeploymentBaseUrl(secretProvider));
}
