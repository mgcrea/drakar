// The page someone lands on straight after paying.
//
// Rendered here rather than on the marketing site because the key has to come
// from the database, and the site is static assets under a strict CSP that would
// block it fetching anything. One self-contained page, no external requests, so
// it needs no CSP relaxation of its own and cannot break when the site redeploys.
//
// The palette is by hand. It cannot import a design token file: this is a Worker
// bundle, and a build step to inline three hex values would cost more than it
// saves. The one thing to keep true is the accent, which has to be the site's
// --color-accent in apps/website/src/styles/tokens.css, #b9a6ff, taken from the
// icon. Change one, change both. The neutrals are armada's, close to the site's
// without needing to match.

const escapeHtml = (text: string): string =>
  text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

const shell = (title: string, inner: string): string => `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; padding: 48px 24px; background: #0d0d0f; color: #e8e6e3;
    font: 16px/1.6 ui-sans-serif, -apple-system, system-ui, sans-serif; }
  main { max-width: 620px; margin: 0 auto; }
  h1 { font-size: 24px; letter-spacing: -0.02em; margin: 0 0 8px; }
  p { color: #a9a5a0; }
  code { display: block; overflow-wrap: anywhere; background: #17171a;
    border: 1px solid #2a2a2e; border-radius: 10px; padding: 14px;
    font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; color: #e8e6e3; }
  a { color: #b9a6ff; }
</style>
</head><body><main>${inner}</main></body></html>
`;

export const thanksPage = (key: string, email: string): string =>
  shell(
    "Your Drakar licence",
    `<h1>Thank you.</h1>
<p>Your licence key, also sent to ${escapeHtml(email)}:</p>
<code>${escapeHtml(key)}</code>
<p>Open <strong>Drakar ▸ Settings ▸ Licence</strong> and paste it in. One key covers every
1.x release, on every Mac you own, and it does not expire.</p>
<p>Within 30 days, for any reason, reply to the email and you get your money back in full.</p>`,
  );

/**
 * The same URL, a week later.
 *
 * A checkout session id lands in browser history, in the Referer of the link
 * this page carries, and in support screenshots, and it never expires on
 * Stripe's side. Showing the key against it forever turns each of those into a
 * copy of the licence. After a week the buyer has long since read the mail, so
 * the page says where the key went instead of what it is.
 */
export const sentPage = (email: string): string =>
  shell(
    "Your Drakar licence",
    `<h1>Already sent.</h1>
<p>Your licence key was emailed to ${escapeHtml(email)} when you bought it. This page
stops showing it after a week.</p>
<p>Can't find the message? Reply to your Stripe receipt and we'll send it again.</p>`,
  );

/**
 * Stripe redirects the moment payment succeeds, which can outrun the webhook.
 * This is that gap, and it says so rather than showing an error for a purchase
 * that went through perfectly.
 */
export const pendingPage = (): string =>
  shell(
    "Your Drakar licence",
    `<h1>Payment received.</h1>
<p>Your key is being issued and will arrive by email in a moment. Refresh this page
shortly and it will show here too.</p>
<p>If nothing arrives within a few minutes, reply to your Stripe receipt and it
will be sorted out by hand.</p>`,
  );

/**
 * A licence that was refunded or lost to a dispute, at the URL that showed it.
 *
 * No key, and no address either. The page answers anyone holding the session
 * id, and what it owes them is that the licence has ended and where to ask.
 * Checked before the one-week window, so a revoked licence never gets the
 * "Already sent" page, whose last line invites asking for the dead key again.
 */
export const revokedPage = (): string =>
  shell(
    "Your Drakar licence",
    `<h1>This licence has been revoked.</h1>
<p>The payment for it was refunded or disputed, so the key is no longer valid and
is not shown here.</p>
<p>If you have any questions, reply to your Stripe receipt.</p>`,
  );

/**
 * `site` comes from the SITE_URL binding, so a move of the marketing site is a
 * change to wrangler.jsonc rather than a hunt through the page templates.
 *
 * Escaped although it is configuration rather than input. It is still text put
 * into markup, inside an attribute where a stray quote ends the `href`, and
 * escaping it costs nothing next to finding out which value someone typed.
 */
export const notFoundPage = (site = "https://drakar.mgcrea.io"): string =>
  shell(
    "Not found",
    `<h1>Not found.</h1><p><a href="${escapeHtml(site)}">${escapeHtml(site.replace(/^https?:\/\//, ""))}</a></p>`,
  );
