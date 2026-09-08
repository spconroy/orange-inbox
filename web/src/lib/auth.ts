import { headers } from "next/headers";
import { getDb } from "./db";
import { getAccessConfig, verifyAccessEmail } from "./cf-access";

export interface User {
  id: string;
  email: string;
  display_name: string | null;
  is_admin: boolean;
  undo_send_seconds: number;
  // 0 = Sunday (US default), 1 = Monday (ISO). Other ints are reserved
  // (Saturday-first locales) — for now any value besides 1 is treated as 0
  // on the read side.
  week_start_day: number;
}

interface UserRow {
  id: string;
  email: string;
  display_name: string | null;
  is_admin: number;
  undo_send_seconds: number;
  week_start_day: number | null;
}

const ACCESS_EMAIL_HEADER = "cf-access-authenticated-user-email";

// Resolve the current user from the Cloudflare Access JWT verified against
// Cloudflare's JWKS. In `next dev` (no Access in the loop), fall back to
// DEV_USER_EMAIL so local development is usable.
export async function getCurrentUser(): Promise<User | null> {
  const email = await resolveEmail();
  if (!email) return null;

  const db = getDb();
  const existing = await db
    .prepare(
      "SELECT id, email, display_name, is_admin, undo_send_seconds, week_start_day FROM users WHERE email = ?",
    )
    .bind(email)
    .first<UserRow>();
  if (existing) {
    await db.prepare("UPDATE users SET last_seen_at = unixepoch() WHERE id = ?").bind(existing.id).run();
    return rowToUser(existing);
  }

  const id = crypto.randomUUID();
  await db
    .prepare("INSERT INTO users (id, email, last_seen_at) VALUES (?, ?, unixepoch())")
    .bind(id, email)
    .run();
  return {
    id,
    email,
    display_name: null,
    is_admin: false,
    undo_send_seconds: 0,
    week_start_day: 0,
  };
}

export async function requireUser(): Promise<User> {
  const user = await getCurrentUser();
  if (!user) {
    throw new UnauthenticatedError();
  }
  return user;
}

export async function requireAdmin(): Promise<User> {
  const user = await requireUser();
  if (!user.is_admin) {
    throw new ForbiddenError();
  }
  return user;
}

export class UnauthenticatedError extends Error {
  constructor() {
    super("not authenticated");
  }
}

export class ForbiddenError extends Error {
  constructor() {
    super("forbidden");
  }
}

function rowToUser(row: UserRow): User {
  return {
    id: row.id,
    email: row.email,
    display_name: row.display_name,
    is_admin: row.is_admin === 1,
    undo_send_seconds: row.undo_send_seconds ?? 0,
    week_start_day: row.week_start_day === 1 ? 1 : 0,
  };
}

// Resolve the authenticated user's email. The signed Cloudflare Access JWT is
// the source of truth — the plaintext `cf-access-authenticated-user-email`
// header is spoofable (the Worker is reachable at URLs Access does not front)
// and is only used here as a defense-in-depth cross-check, never as the
// authority. Fails closed: any path that can't establish a verified identity
// returns null.
async function resolveEmail(): Promise<string | null> {
  const h = await headers();
  const config = getAccessConfig();

  if (config) {
    // Access is configured: require a valid, verified JWT. Do NOT fall back
    // to the plaintext header.
    const verified = await verifyAccessEmail(h, config);
    if (!verified) return null;

    // Defense-in-depth: if the plaintext header is present it must agree with
    // the verified claim. A mismatch indicates tampering — reject.
    const headerEmail = h.get(ACCESS_EMAIL_HEADER)?.trim().toLowerCase();
    if (headerEmail && headerEmail !== verified) {
      console.error(
        "CF Access: header email does not match verified JWT email",
      );
      return null;
    }
    return verified;
  }

  // No Access config. Local development convenience only.
  if (process.env.NODE_ENV === "development" && process.env.DEV_USER_EMAIL) {
    return process.env.DEV_USER_EMAIL.trim().toLowerCase();
  }

  // Not configured and not development: fail closed. Never trust the
  // plaintext header on its own.
  console.error(
    "CF Access verification is unconfigured (CF_ACCESS_TEAM_DOMAIN / " +
      "CF_ACCESS_AUD missing). Refusing to authenticate from the spoofable " +
      "cf-access-authenticated-user-email header. Set these vars in " +
      "wrangler.jsonc to enable authentication.",
  );
  return null;
}
