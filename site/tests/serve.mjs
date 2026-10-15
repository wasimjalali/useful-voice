// A static server for site/public that behaves like the Cloudflare assets Worker in
// wrangler.jsonc: `/privacy/` serves `privacy/index.html`, and an unknown path gets
// 404.html with a 404 status ("not_found_handling": "404-page").
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

async function resolve(pathname) {
  const path = normalize(join(root, decodeURIComponent(pathname)));
  if (!path.startsWith(root)) return null;
  try {
    const info = await stat(path);
    if (info.isFile()) return path;
    if (info.isDirectory()) return (await stat(join(path, "index.html"))).isFile() ? join(path, "index.html") : null;
  } catch {
    return null;
  }
  return null;
}

createServer(async (req, res) => {
  const { pathname } = new URL(req.url, "http://localhost");
  const file = await resolve(pathname);
  const status = file ? 200 : 404;
  const body = await readFile(file ?? join(root, "404.html"));
  res.writeHead(status, { "content-type": types[extname(file ?? ".html")] ?? "application/octet-stream" });
  res.end(body);
}).listen(port, () => console.log(`site on http://localhost:${port}`));
