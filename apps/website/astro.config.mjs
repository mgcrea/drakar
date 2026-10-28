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
        // The beacon POSTs its measurement here (no `static.` prefix). Miss it and
        // the script loads, runs, and every report stays empty.
        //
        // DIVERGES from armada, which also names https://feedback.mgcrea.io for
        // its /feedback/ form. This site has no form and posts nothing, so the
        // origin would be an allowance with nothing behind it. When a feedback
        // page arrives, the origin comes back with it, or its Send button is
        // refused by the browser with no build error.
        "connect-src 'self' https://cloudflareinsights.com",
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
      // computed widths. Nothing here carries one, so `style-src` stays strict.
    },
  },
  vite: { plugins: [tailwindcss()] },
});
