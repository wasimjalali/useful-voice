// A static server for site/public that follows the Cloudflare assets Worker in
// wrangler.jsonc closely enough for the checks: `/privacy/` serves `privacy/index.html`,
// `/privacy` redirects to `/privacy/` and `/index.html` to `/` (the default
// html_handling "auto-trailing-slash"), `_headers` is config and never served, and an
// unknown path gets 404.html with a 404 status ("not_found_handling": "404-page").
// It does not apply the headers in `_headers`.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../public/", import.meta.url));
const port = Number(process.env.PORT || 4510);
const types = {
  ".html": "text/html; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png",
  ".woff2": "font/woff2", ".xml": "application/xml", ".txt": "text/plain; charset=utf-8",
};

async function isFile(path) {
  try { return (await stat(path)).isFile(); } catch { return false; }
}

async function isDir(path) {
  try { return (await stat(path)).isDirectory(); } catch { return false; }
}

// Returns { file } to serve, { redirect } to send, or {} for a 404.
async function resolve(pathname) {
  let decoded;
  try { decoded = decodeURIComponent(pathname); } catch { return {}; }
  const path = normalize(join(root, decoded));
  if (!path.startsWith(root) || path === join(root, "_headers")) return {};
  if (pathname.endsWith("/index.html") && await isFile(path)) return { redirect: pathname.slice(0, -"index.html".length) };
  if (await isDir(path)) {
    if (!(await isFile(join(path, "index.html")))) return {};
    return pathname.endsWith("/") ? { file: join(path, "index.html") } : { redirect: `${pathname}/` };
  }
  return (await isFile(path)) ? { file: path } : {};
}

createServer(async (req, res) => {
  const { pathname } = new URL(req.url, "http://localhost");
  const { file, redirect } = await resolve(pathname);
  if (redirect) {
    res.writeHead(307, { location: redirect });
    res.end();
    return;
  }
  const served = file ?? join(root, "404.html");
  res.writeHead(file ? 200 : 404, { "content-type": types[extname(served)] ?? "application/octet-stream" });
  res.end(await readFile(served));
}).listen(port, () => console.log(`site on http://localhost:${port}`));
