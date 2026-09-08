import { createRemoteJWKSet, jwtVerify } from "jose";
import { getEnv } from "./db";

// Cloudflare Access JWT verification.
//
// Cloudflare Access sits in front of the custom domain and issues a signed
// JWT (the `Cf-Access-Jwt-Assertion` header / `CF_Authorization` cookie) on
// every authenticated request. The plaintext `cf-access-authenticated-user-email`
// header is NOT trustworthy on its own: the worker is also reachable at URLs
// Access does not front, so an attacker can spoof that header. We must verify
// the signed JWT and derive the user's identity from its claims.

const JWT_HEADER = "cf-access-jwt-assertion";
const JWT_COOKIE = "CF_Authorization";

interface AccessConfig {
  teamDomain: string;
  aud: string;
}

// Cache the JWKS per team domain. `createRemoteJWKSet` itself caches the
// fetched keys; we just avoid rebuilding the set object on every request.
let cachedJwks:
  | { teamDomain: string; jwks: ReturnType<typeof createRemoteJWKSet> }
  | null = null;

function getJwks(teamDomain: string): ReturnType<typeof createRemoteJWKSet> {
  if (cachedJwks && cachedJwks.teamDomain === teamDomain) {
    return cachedJwks.jwks;
  }
  const jwks = createRemoteJWKSet(
    new URL(`${teamDomain}/cdn-cgi/access/certs`),
  );
  cachedJwks = { teamDomain, jwks };
  return jwks;
}

// Read CF_ACCESS_TEAM_DOMAIN / CF_ACCESS_AUD from the Worker env. These are
// plain config vars (not secrets) declared in wrangler.jsonc. Returns null
// when either is missing/blank so callers can fail closed.
export function getAccessConfig(): AccessConfig | null {
  let env: Record<string, unknown>;
  try {
    env = getEnv() as unknown as Record<string, unknown>;
  } catch {
    // No Cloudflare context (e.g. `next dev`): not configured here.
    return null;
  }
  const rawDomain =
    typeof env.CF_ACCESS_TEAM_DOMAIN === "string"
      ? env.CF_ACCESS_TEAM_DOMAIN.trim()
      : "";
  const aud = typeof env.CF_ACCESS_AUD === "string" ? env.CF_ACCESS_AUD.trim() : "";
  if (!rawDomain || !aud) return null;

  // Normalize to an https origin with no trailing slash. Accept either a bare
  // team name ("acme") or a full domain ("acme.cloudflareaccess.com" / URL).
  let teamDomain = rawDomain;
  if (!/^https?:\/\//i.test(teamDomain)) {
    if (!teamDomain.includes(".")) {
      teamDomain = `${teamDomain}.cloudflareaccess.com`;
    }
    teamDomain = `https://${teamDomain}`;
  }
  teamDomain = teamDomain.replace(/\/+$/, "");

  return { teamDomain, aud };
}

// Extract the Access JWT from request headers: prefer the dedicated assertion
// header, fall back to the CF_Authorization cookie.
function extractToken(h: Headers): string | null {
  const headerToken = h.get(JWT_HEADER);
  if (headerToken && headerToken.trim()) return headerToken.trim();

  const cookie = h.get("cookie");
  if (cookie) {
    for (const part of cookie.split(";")) {
      const eq = part.indexOf("=");
      if (eq === -1) continue;
      const name = part.slice(0, eq).trim();
      if (name === JWT_COOKIE) {
        const value = part.slice(eq + 1).trim();
        if (value) return decodeURIComponent(value);
      }
    }
  }
  return null;
}

// Verify the Cloudflare Access JWT present in the given request headers and
// return the verified email claim. Returns null when Access is configured but
// the request carries no valid token (fail closed).
//
// `config` must come from getAccessConfig(); callers check for null config
// themselves so they can apply dev-fallback semantics.
export async function verifyAccessEmail(
  h: Headers,
  config: AccessConfig,
): Promise<string | null> {
  const token = extractToken(h);
  if (!token) return null;

  try {
    const { payload } = await jwtVerify(token, getJwks(config.teamDomain), {
      issuer: config.teamDomain,
      audience: config.aud,
    });
    const email = payload.email;
    if (typeof email !== "string" || !email.trim()) {
      console.error("CF Access: verified JWT has no email claim");
      return null;
    }
    return email.trim().toLowerCase();
  } catch (err) {
    console.error(
      "CF Access: JWT verification failed:",
      err instanceof Error ? err.message : String(err),
    );
    return null;
  }
}
