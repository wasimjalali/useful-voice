// Runs before the stylesheet applies. A classic script, not part of the bundle: the page
// is a file:// URL under a strict CSP, and a module would be deferred past first paint.
// The main process passes the resolved theme as ?theme=light|dark; components/theme.ts
// keeps it correct afterwards.
document.documentElement.dataset.theme =
  new URLSearchParams(window.location.search).get('theme') === 'dark' ? 'dark' : 'light';
