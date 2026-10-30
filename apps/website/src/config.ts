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

/**
 * Whether /buy resolves to a live payment link.
 *
 * The website's mirror of `LicenceLinks.isSelling` in apps/apple: the two move
 * together, in the release that opens the store. It gates the price and the Buy
 * button on the home page and the prose that says whether anything is on sale, on
 * /terms and /privacy.
 */
export const SELLING = true;

/**
 * The evaluation window: started from a button, never armed on its own, and held
 * in memory rather than written to disk (`Trial.duration` in apps/apple).
 */
export const TRIAL = { minutes: 30 } as const;

/**
 * The price, as it is charged. Two currencies, both set explicitly on the Stripe
 * price via `currency_options`, never one converted from the other, the way
 * armada, bastion and cupertino sell. The USD figure is quoted tax-exclusive and
 * the EUR figure VAT-inclusive, the ordinary convention on each side, so the page
 * shows both rather than picking one.
 */
export const PRICING = {
  price: "$14.99",
  eur: "€14.99",
  /** The stable vanity URL: a 302 in public/_redirects to the live Stripe payment link. */
  buy: "/buy",
  /** Written as a fragment, so a call site capitalises it where a sentence starts. */
  covers: "every 1.x release, on every Mac you own",
  refundDays: 30,
} as const;
