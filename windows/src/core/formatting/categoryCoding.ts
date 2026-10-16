import { chars, isAlnum, isDigit, isUpper, isWS } from './categoryText.js';

/**
 * Coding category rules. Mirrors `Sources/UsefulVoiceCore/Formatting/CategoryCoding.swift`
 * rule for rule.
 *
 * What it does: curly quotes become straight, spoken file names become real ones
 * ("index dot ts" is `index.ts`), "at" or "tag" before one makes a mention (`@index.ts`)
 * and spoken symbols ("slash", "underscore", "dot", "dash dash") become the symbol.
 *
 * What it never does: add or remove sentence punctuation, change capitals, or touch a
 * spoken symbol that is not between code-like words. "a dot on the map" and "look at
 * the docs" come out exactly as dictated.
 */

const EXTENSIONS = new Set([
  'ts', 'tsx', 'js', 'jsx', 'json', 'md', 'py', 'swift', 'rs', 'go', 'rb', 'java', 'kt', 'c', 'h',
  'cpp', 'cs', 'css', 'html', 'yml', 'yaml', 'toml', 'sh', 'txt', 'lock', 'sql',
]);

/**
 * Extensions that are also everyday words or letters. "red dot go" is prose; "main dot go"
 * is a file. These convert only after a name that looks like a file name.
 */
const AMBIGUOUS_EXTENSIONS = new Set(['go', 'c', 'h', 'lock']);

/** Plain words that are common file names, so "main dot go" converts. Code-like words qualify anyway. */
const COMMON_BASENAMES = new Set([
  'main', 'index', 'mod', 'server', 'client', 'util', 'cargo', 'yarn', 'package', 'pipfile',
  'poetry', 'composer', 'hello', 'foo', 'bar', 'baz', 'run', 'setup', 'handler', 'router',
  'types', 'model', 'models', 'api', 'db', 'cli', 'cmd', 'parser', 'helper', 'helpers', 'common',
  'init', 'start', 'example', 'sample', 'demo', 'script', 'readme', 'license', 'makefile',
]);

/**
 * A path made only of "~", "." and ".." parts ("~", "..", "../.."). Not a word, but it
 * joins a spoken slash: "cd ~ slash projects" is `cd ~/projects`.
 */
function isPathRoot(t: Tok): boolean {
  const parts = t.core.split('/');
  return parts.every(
    (p, i) => p === '.' || p === '..' || (p === '~' && i === 0) || (p === '' && i > 0 && i === parts.length - 1),
  );
}

/**
 * Names that are a dot file when spoken alone: "dot gitignore" is `.gitignore`. They are
 * not in EXTENSIONS: "copy dot env" is "copy .env", never `copy.env`.
 */
const DOTFILES = new Set([
  'env', 'gitignore', 'gitattributes', 'npmrc', 'nvmrc', 'eslintrc', 'prettierrc', 'editorconfig',
  'dockerignore', 'babelrc', 'zshrc', 'bashrc',
]);

/** Words that are never a code name next to a spoken symbol: articles, pronouns, shell verbs. */
const NOT_NAMES = new Set([
  'a', 'an', 'the', 'this', 'that', 'these', 'those', 'my', 'your', 'his', 'her', 'its', 'our',
  'their', 'of', 'in', 'on', 'at', 'to', 'for', 'and', 'or', 'but', 'is', 'it', 'with', 'as', 'by',
  'from', 'i', 'we', 'you', 'he', 'she', 'they', 'be', 'are', 'was', 'were', 'am', 'been', 'have',
  'has', 'had', 'do', 'does', 'did', 'can', 'could', 'would', 'should', 'will', 'not', 'no', 'yes',
  'if', 'so', 'than', 'then', 'when', 'while', 'where', 'what', 'who', 'which', 'why', 'how', 'about',
  'into', 'over', 'under', 'after', 'before', 'between', 'up', 'down', 'out', 'off', 'them', 'him',
  'me', 'us', 'there', 'here', 'now', 'just', 'also', 'only', 'very', 'more', 'most', 'some', 'any',
  'all', 'each', 'every', 'other', 'such',
  'cd', 'ls', 'cat', 'rm', 'mv', 'cp', 'mkdir', 'touch', 'open', 'edit', 'use', 'type', 'press',
  'add', 'insert', 'put', 'say',
]);

/** Plain lower-case folder names that mark a word as part of a path. */
const PATH_WORDS = new Set([
  'src', 'lib', 'app', 'bin', 'usr', 'etc', 'var', 'tmp', 'home', 'dist', 'build', 'docs', 'test',
  'tests', 'public', 'packages', 'scripts', 'utils', 'config', 'node_modules', 'components', 'pages',
  'sources', 'tools', 'assets', 'users', 'opt', 'mnt', 'library', 'documents', 'downloads',
  'applications', 'volumes', 'projects', 'repos', 'workspace',
]);

const SYMBOL_TEXT: Record<string, string> = { dot: '.', slash: '/', underscore: '_' };

const LEAD_CHARS = new Set(['"', "'", '(', '[', '{', '`', '<']);
const TRAIL_CHARS = new Set(['.', ',', ';', ':', '!', '?', ')', ']', '}', '"', "'", '`', '>', '…']);
const NAME_PUNCT = new Set(['_', '-', '/', '.', '~', '@']);

/** One whitespace-separated word, split into the punctuation around it and its core. */
interface Tok {
  /** The whitespace before the word. */
  sep: string;
  lead: string;
  core: string;
  trail: string;
  /** True when the word is, or ends in, a file name this pass built. */
  file: boolean;
}

export function straightenQuotes(text: string): string {
  return text
    .replaceAll('‘', "'")
    .replaceAll('’', "'")
    .replaceAll('“', '"')
    .replaceAll('”', '"');
}

function isNameCore(core: string): boolean {
  const cs = chars(core);
  if (cs.length === 0) return false;
  let alnum = false;
  for (const c of cs) {
    if (isAlnum(c)) alnum = true;
    else if (!NAME_PUNCT.has(c)) return false;
  }
  return alnum;
}

function tokenizeLine(line: string): { toks: Tok[]; tail: string } {
  const cs = chars(line);
  const toks: Tok[] = [];
  let i = 0;
  let sep = '';
  while (i < cs.length) {
    if (isWS(cs[i] as string)) {
      sep += cs[i] as string;
      i++;
      continue;
    }
    let j = i;
    while (j < cs.length && !isWS(cs[j] as string)) j++;
    const run = cs.slice(i, j);
    let a = 0;
    let b = run.length;
    while (a < b && LEAD_CHARS.has(run[a] as string)) a++;
    while (b > a && TRAIL_CHARS.has(run[b - 1] as string)) b--;
    if (a === b) {
      toks.push({ sep, lead: '', core: run.join(''), trail: '', file: false });
    } else {
      toks.push({
        sep,
        lead: run.slice(0, a).join(''),
        core: run.slice(a, b).join(''),
        trail: run.slice(b).join(''),
        file: false,
      });
    }
    sep = '';
    i = j;
  }
  return { toks, tail: sep };
}

function symbolWord(t: Tok): string | null {
  if (t.lead !== '' || t.trail !== '') return null;
  const word = t.core.toLowerCase();
  return word === 'dot' || word === 'slash' || word === 'underscore' ? word : null;
}

function isDash(t: Tok): boolean {
  return t.lead === '' && t.trail === '' && t.core.toLowerCase() === 'dash';
}

function isSpokenSymbol(t: Tok): boolean {
  return symbolWord(t) !== null || isDash(t);
}

/** A word that can sit next to a spoken symbol: a name core that is not an article, verb or symbol. */
function isNameWord(t: Tok): boolean {
  return isNameCore(t.core) && !NOT_NAMES.has(t.core.toLowerCase()) && !isSpokenSymbol(t);
}

function isCodeLike(t: Tok): boolean {
  if (t.file) return true;
  const cs = chars(t.core);
  for (let i = 0; i < cs.length; i++) {
    const c = cs[i] as string;
    if (c === '_' || c === '/' || c === '.' || c === '~' || c === '@') return true;
    if (isDigit(c)) return true;
    if (i > 0 && isUpper(c)) return true;
  }
  return PATH_WORDS.has(t.core.toLowerCase());
}

const IDENTIFIER_PUNCT = new Set(['_', '-']);

/** ASCII letters, digits, "_" and "-" only: the shape of a variable, function or flag name. */
function isIdentifierShaped(t: Tok): boolean {
  const cs = chars(t.core);
  return (
    cs.length > 0 &&
    cs.every((c) => (c.length === 1 && c < '\u0080' && isAlnum(c)) || IDENTIFIER_PUNCT.has(c))
  );
}

/** Whether a word can be part of a path. Bare numbers cannot: "slash 20 percent" is prose. */
function isPathish(t: Tok): boolean {
  if (t.file) return true;
  const cs = chars(t.core);
  if (cs.some((c) => c === '/' || c === '.' || c === '_' || c === '~' || c === '@')) return true;
  if (PATH_WORDS.has(t.core.toLowerCase())) return true;
  return cs.some((c) => !isDigit(c) && isAlnum(c));
}

/** Whether a name can stand in front of an ambiguous extension such as ".go". */
function isFileBase(t: Tok): boolean {
  return isCodeLike(t) || COMMON_BASENAMES.has(t.core.toLowerCase());
}

/** "index.ts", "src/app.tsx": a name that already ends in a known extension. */
function looksLikeFileName(core: string): boolean {
  const cs = chars(core);
  const dot = cs.lastIndexOf('.');
  if (dot <= 0 || cs[0] === '@') return false;
  return EXTENSIONS.has(cs.slice(dot + 1).join('').toLowerCase()) && cs[dot - 1] !== '/';
}

/** "index dot ts" and "foo dot test dot ts" become `index.ts` and `foo.test.ts`. */
function convertFileNames(toks: Tok[]): Tok[] {
  const out: Tok[] = [];
  let i = 0;
  while (i < toks.length) {
    const first = toks[i] as Tok;
    let e = i;
    if (isNameWord(first) && first.trail === '' && i + 2 < toks.length) {
      // Walk "name dot name dot name ...", stopping at a word that carries trailing punctuation.
      while (
        e + 2 < toks.length &&
        (toks[e] as Tok).trail === '' &&
        symbolWord(toks[e + 1] as Tok) === 'dot' &&
        isNameWord(toks[e + 2] as Tok) &&
        (toks[e + 2] as Tok).lead === ''
      ) {
        e += 2;
      }
    }
    if (e === i) {
      out.push(first);
      i += 1;
      continue;
    }
    const extension = (toks[e] as Tok).core.toLowerCase();
    const valid =
      EXTENSIONS.has(extension) &&
      (!AMBIGUOUS_EXTENSIONS.has(extension) || isFileBase(toks[e - 2] as Tok));
    if (!valid) {
      // Every shorter chain ends at the same word, so it fails the same way: skip them all.
      for (let k = i; k <= e; k++) out.push(toks[k] as Tok);
      i = e + 1;
      continue;
    }
    const parts: string[] = [];
    for (let k = i; k <= e; k += 2) parts.push((toks[k] as Tok).core);
    parts[parts.length - 1] = extension;
    out.push({
      sep: first.sep,
      lead: first.lead,
      core: parts.join('.'),
      trail: (toks[e] as Tok).trail,
      file: true,
    });
    i = e + 1;
  }
  return out;
}

/** "dash dash help" becomes `--help`. */
function convertFlags(toks: Tok[]): Tok[] {
  const out: Tok[] = [];
  let i = 0;
  while (i < toks.length) {
    const first = toks[i] as Tok;
    const second = toks[i + 1];
    const third = toks[i + 2];
    if (
      isDash(first) &&
      second !== undefined &&
      isDash(second) &&
      third !== undefined &&
      isNameWord(third) &&
      third.lead === ''
    ) {
      out.push({ sep: first.sep, lead: '', core: `--${third.core}`, trail: third.trail, file: false });
      i += 3;
    } else {
      out.push(first);
      i += 1;
    }
  }
  return out;
}

/** "src slash app", "foo underscore bar", "dot slash src", "dot env". */
function convertSymbols(toks: Tok[]): Tok[] {
  const out: Tok[] = [];
  let i = 0;
  while (i < toks.length) {
    const tok = toks[i] as Tok;
    if (symbolWord(tok) === null) {
      out.push(tok);
      i += 1;
      continue;
    }
    let j = i;
    let text = '';
    let dots = 0;
    let slashes = 0;
    let underscores = 0;
    while (j < toks.length && symbolWord(toks[j] as Tok) !== null) {
      const word = symbolWord(toks[j] as Tok) as string;
      text += SYMBOL_TEXT[word] as string;
      if (word === 'dot') dots++;
      else if (word === 'slash') slashes++;
      else underscores++;
      j++;
    }
    const lastOut = out[out.length - 1];
    let left: Tok | null =
      lastOut !== undefined &&
      lastOut.trail === '' &&
      (isNameWord(lastOut) || (slashes > 0 && isPathRoot(lastOut)))
        ? lastOut
        : null;
    const nextTok = toks[j];
    let right: Tok | null =
      nextTok !== undefined &&
      nextTok.lead === '' &&
      (isNameWord(nextTok) || (slashes > 0 && isPathRoot(nextTok)))
        ? nextTok
        : null;
    const runLength = j - i;

    // Around a slash, only path-like words join: "slash 20 percent" is prose.
    if (slashes > 0) {
      if (left !== null && !isPathish(left)) left = null;
      if (right !== null && !isPathish(right)) right = null;
    }
    // "copy dot env": a dot file on its own, not joined to the word before it.
    const dotFile =
      dots === 1 &&
      runLength === 1 &&
      right !== null &&
      DOTFILES.has(right.core.toLowerCase()) &&
      (left === null || !isCodeLike(left));
    if (dotFile) left = null;

    let allowed = false;
    if (underscores === runLength) {
      // Both sides must look like identifiers: "the underscore key" is prose.
      const identifiers =
        (left === null || isIdentifierShaped(left)) && (right === null || isIdentifierShaped(right));
      allowed =
        identifiers &&
        ((left !== null && right !== null) || (runLength >= 2 && (left !== null || right !== null)));
    } else if (dots > 0 && slashes > 0) {
      allowed = true;
    } else if (dotFile) {
      allowed = true;
    } else if (left !== null && right !== null) {
      allowed = isCodeLike(left) || isCodeLike(right);
    } else if (slashes === runLength && left === null && right !== null) {
      allowed = isCodeLike(right);
    }

    if (!allowed) {
      for (let k = i; k < j; k++) out.push(toks[k] as Tok);
      i = j;
      continue;
    }
    if (left !== null) out.pop();
    const base = left ?? { sep: tok.sep, lead: '', core: '', trail: '', file: false };
    out.push({
      sep: base.sep,
      lead: base.lead,
      core: base.core + text + (right !== null ? right.core : ''),
      trail: right !== null ? right.trail : '',
      file: right !== null ? right.file : false,
    });
    i = right !== null ? j + 1 : j;
  }
  return out;
}

/** "at index.ts" and "tag index.ts" become `@index.ts`, only before a file name. */
function convertMentions(toks: Tok[]): Tok[] {
  const out: Tok[] = [];
  let i = 0;
  while (i < toks.length) {
    const tok = toks[i] as Tok;
    const next = toks[i + 1];
    const word = tok.core.toLowerCase();
    if (
      tok.lead === '' &&
      tok.trail === '' &&
      (word === 'at' || word === 'tag') &&
      next !== undefined &&
      (next.file || looksLikeFileName(next.core)) &&
      next.lead === ''
    ) {
      out.push({ sep: tok.sep, lead: '', core: `@${next.core}`, trail: next.trail, file: true });
      i += 2;
    } else {
      out.push(tok);
      i += 1;
    }
  }
  return out;
}

function renderLine(toks: Tok[], tail: string): string {
  return toks.map((t) => t.sep + t.lead + t.core + t.trail).join('') + tail;
}

/** Applies every Coding rule. Line breaks and spacing are kept as dictated. */
export function formatCoding(text: string): string {
  const lines = straightenQuotes(text).split('\n');
  return lines
    .map((line) => {
      const { toks, tail } = tokenizeLine(line);
      const converted = convertMentions(convertSymbols(convertFlags(convertFileNames(toks))));
      return renderLine(converted, tail);
    })
    .join('\n');
}
