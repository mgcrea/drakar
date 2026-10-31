// Copies a button's `data-copy` to the clipboard and says so on the button. Used
// by the "Share this release" box on /changelog/<version>/.
//
// A file here rather than an inline <script>, and that is not taste. The CSP in
// astro.config.mjs is hash-based: Astro appends a sha256 to `script-src` for each
// script it bundles, and nothing for an `is:inline` one, so an inline copy would
// be refused, in the build only, since the dev server emits no policy. A file
// under public/ is covered by `script-src 'self'`.
for (const button of document.querySelectorAll("[data-copy]")) {
  button.addEventListener("click", async () => {
    const label = button.textContent;
    try {
      await navigator.clipboard.writeText(button.dataset.copy ?? "");
      button.textContent = "Copied";
    } catch {
      // Refused, as a clipboard write can be outside a secure context or without
      // a user gesture the browser trusts. Said rather than swallowed.
      button.textContent = "Copy failed";
    }
    setTimeout(() => {
      button.textContent = label;
    }, 1600);
  });
}
