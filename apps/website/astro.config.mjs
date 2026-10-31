import sitemap from "@astrojs/sitemap";
import tailwindcss from "@tailwindcss/vite";
// @ts-check
import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://drakar.mgcrea.io",
  integrations: [sitemap()],
  // Astro 7 defaults to 'jsx', which drops whitespace between inline elements:
  // "contact us at <a>support@…</a>" renders welded together.
  compressHTML: true,
  // Every page here is `.astro`; there is no markdown to highlight. Left at its
  // `shiki` default, Astro warns on every start that the highlighter's inline
  // styles fight the CSP below, whether or not any code block exists.
  markdown: { syntaxHighlight: false },
  security: {
    csp: {
      directives: [
        "default-src 'self'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        // The beacon POSTs its measurement to the first (no `static.` prefix).
        // Miss it and the script loads, runs, and every report stays empty.
        //
        // The second is the feedback Worker `/feedback/` posts to. Miss that and
        // the form renders, the user types a report, presses Send, and the
        // browser refuses the fetch: no build error, one console line nobody
        // reads. `pnpm feedback:check` asserts it survives into the policy.
        "connect-src 'self' https://cloudflareinsights.com https://feedback.mgcrea.io",
        "base-uri 'self'",
        "form-action 'self'",
        "object-src 'none'",
      ],
      /*
       * The Cloudflare Web Analytics beacon is injected at the edge for the whole
       * mgcrea.io zone, so the browser has to be allowed to fetch it from a
       * third-party origin. Astro fills `script-src` with `'self'` plus a sha256 per
       * inline script and nothing else, and hashes only ever match inline scripts: an
       * external URL needs a host source or it is refused silently.
       *
       * `resources` REPLACES Astro's default source list rather than extending it, so
       * `'self'` has to be repeated here. The per-script hashes are still appended.
       */
      scriptDirective: {
        resources: ["'self'", "https://static.cloudflareinsights.com"],
      },
      // DIVERGES from armada, which allows `style` attributes for its drawings'
      // computed widths and glows. Nothing here carries one (the glows are
      // classes in global.css), so `style-src` stays strict. A `style=` added to a
      // page is refused in the build only, since the dev server sends no policy.
    },
  },
  vite: { plugins: [tailwindcss()] },
});
