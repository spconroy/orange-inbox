import type { NextConfig } from "next";
import { PHASE_DEVELOPMENT_SERVER } from "next/constants";

const nextConfig: NextConfig = {
  experimental: {
    // Client Router Cache tuning. These bottom-nav routes (Calendar, Contacts,
    // Settings, Help) and the mailbox views are all dynamically rendered —
    // they read the auth cookie — so the App Router can't fully prefetch them
    // and, with the default `dynamic: 0`, every single click re-runs the
    // layout's multi-query fetch plus the page's own queries over the wire.
    // That's why navigation felt slow/flaky rather than "cached and instant."
    //
    // Giving `dynamic` a non-zero window lets a just-visited segment be reused
    // from the client cache on re-navigation (e.g. flipping Calendar → Mail →
    // Calendar) without another server round-trip. 30s matches Next's own
    // pre-15 default — long enough to make back-and-forth instant, short
    // enough that the inbox list doesn't show meaningfully stale mail.
    staleTimes: {
      dynamic: 30,
      static: 180,
    },
  },
};

export default async function config(phase: string): Promise<NextConfig> {
  // Only next dev needs the local Workers runtime and its persisted SQLite state.
  if (phase === PHASE_DEVELOPMENT_SERVER) {
    const { initOpenNextCloudflareForDev } = await import("@opennextjs/cloudflare");
    await initOpenNextCloudflareForDev();
  }
  return nextConfig;
}
