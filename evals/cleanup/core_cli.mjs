// JSON in on stdin, JSON out on stdout. Usage: node core_cli.mjs <bundle.mjs> <op>
//   rules    [text]                      -> [text]            (English cleanup rules)
//   control  [{category, style}]         -> [control line]
//   guard    [{rules, output, limits?}]         -> [{accepted, reason?, text?}]
//   prompt   null                        -> the S1-mini system prompt
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [bundle, op] = process.argv.slice(2);
const core = await import(pathToFileURL(bundle).href);
const items = JSON.parse(readFileSync(0, 'utf8'));
let out;
if (op === 'rules') out = items.map((t) => core.applyCleanupRules(t, 'en'));
else if (op === 'control') out = items.map((i) => core.s1ControlLine(i.category, i.style));
else if (op === 'guard') out = items.map((i) => core.evaluateCleanupOutput(i.rules, i.output, i.limits ?? undefined));
else if (op === 'prompt') out = core.S1_MINI_SYSTEM_PROMPT;
else throw new Error(`unknown op ${op}`);
process.stdout.write(JSON.stringify(out));
