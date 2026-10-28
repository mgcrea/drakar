/**
 * Every fact the pages share lives here, and nowhere else.
 *
 * The repo is the authority on all of it. If something here disagrees with the
 * root README, SECURITY.md or apps/apple, the tree is right and this file is
 * stale.
 */

export const SITE_DOMAIN = "drakar.mgcrea.io";
export const SITE_URL = `https://${SITE_DOMAIN}`;

export const APP_NAME = "Drakar";

/** README's first sentence, word for word. */
export const TAGLINE =
  "A native macOS app to drive Claude Code: the conversation, the tool calls, the permission prompts and the diffs, in a window as light as Zed.";

/** The deployment target in apps/apple. */
export const MIN_MACOS = "macOS 26";

export const REPO_URL = "https://github.com/mgcrea/drakar";

export const DOCS = {
  security: `${REPO_URL}/blob/main/SECURITY.md`,
  audit: `${REPO_URL}/blob/main/scripts/audit-network.sh`,
} as const;

/** The vanity paths public/_redirects serves. */
export const DOWNLOAD = {
  zip: "/download",
  checksum: "/checksum",
  releases: "/releases",
  appcast: `${SITE_DOMAIN}/appcast.xml`,
} as const;

export const SUPPORT_EMAIL = "support@mgcrea.io";
export const SUPPORT_EMAIL_HREF = `mailto:${SUPPORT_EMAIL}`;
export const SECURITY_EMAIL = "security@mgcrea.io";
export const SECURITY_EMAIL_HREF = `mailto:${SECURITY_EMAIL}`;
