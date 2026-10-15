// Serves a release folder on 127.0.0.1 the way GitHub serves release assets: every file
// as application/octet-stream, nothing else. Used by the release-windows workflow to
// run install.ps1 and electron-updater against real build output without publishing.
//
// Usage: node e2e/installer/serve.mjs <dir> <port> [log file]
import { appendFileSync, createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import path from 'node:path';

const [dir, port, logFile] = process.argv.slice(2);
if (!dir || !port) {
  process.stderr.write('usage: serve.mjs <dir> <port> [log file]\n');
  process.exit(2);
}
const root = path.resolve(dir);

createServer((req, res) => {
  const name = decodeURIComponent(new URL(req.url ?? '/', 'http://127.0.0.1').pathname).replace(/^\/+/, '');
  const file = path.join(root, name);
  const ok = name.length > 0 && !name.includes('/') && !name.includes('\\') && existsSync(file) && statSync(file).isFile();
  if (logFile) appendFileSync(logFile, `${new Date().toISOString()} ${req.method} /${name} ${ok ? 200 : 404}\n`);
  if (!ok) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': statSync(file).size });
  if (req.method === 'HEAD') res.end();
  else createReadStream(file).pipe(res);
}).listen(Number(port), '127.0.0.1', () => process.stdout.write(`serving ${root} on 127.0.0.1:${port}\n`));
