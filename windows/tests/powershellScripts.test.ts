import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import {
  CSHARP_BLOCKS,
  browserAddressScript,
  cueScript,
  foregroundScript,
  pasteScript,
  reactivateScript,
  restoreForegroundScript,
  typeScript,
} from '../src/main/powershellScripts.js';

/**
 * Every PowerShell script the app runs, handed to PowerShell's own parser, and every C#
 * block compiled with Add-Type. A syntax error in a script fails silently on a user's
 * machine (the paste just never happens), so it has to fail here.
 *
 * Runs on Windows (CI's windows job), or anywhere `UV_POWERSHELL` names a PowerShell.
 */
const shell = process.env.UV_POWERSHELL ?? (process.platform === 'win32' ? 'powershell.exe' : undefined);

function runPowerShell(script: string, input: string): string {
  return execFileSync(shell!, ['-NoProfile', '-NonInteractive', '-Command', script], {
    input,
    encoding: 'utf8',
    timeout: 60_000,
    windowsHide: true,
  });
}

const PARSE = `
$src = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd().Trim()))
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Output ("parse error: " + $_.Message) }; exit 0 }
Write-Output "parsed"
`;

const COMPILE = `
$src = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd().Trim()))
try { Add-Type -TypeDefinition $src; Write-Output "compiled" } catch { Write-Output ("compile error: " + $_.Exception.Message) }
`;

const deadline = Date.now() + 5000;
const scripts: Record<string, string> = {
  'paste, guarded': pasteScript(0x1234, deadline),
  'type out': typeScript(0x1234, deadline),
  foreground: foregroundScript(),
  reactivate: reactivateScript(0x1234, 0x99),
  'reactivate, no focus child': reactivateScript(0x1234, undefined),
  'address bar, chromium': browserAddressScript(0x1234, 'chromium'),
  'address bar, firefox': browserAddressScript(0x1234, 'firefox'),
  'restore foreground, guarded': restoreForegroundScript(0x1234, 0x55),
  'restore foreground': restoreForegroundScript(0x1234, undefined),
  cue: cueScript("C:\\Temp\\it's a cue.wav"),
};

describe.skipIf(!shell)('PowerShell scripts', () => {
  for (const [name, script] of Object.entries(scripts)) {
    it(`parses: ${name}`, () => {
      const out = runPowerShell(PARSE, Buffer.from(script, 'utf8').toString('base64')).trim();
      expect(out).toBe('parsed');
    });
  }

  for (const [name, source] of Object.entries(CSHARP_BLOCKS)) {
    it(`compiles: ${name}`, () => {
      const out = runPowerShell(COMPILE, Buffer.from(source, 'utf8').toString('base64')).trim();
      expect(out).toBe('compiled');
    });
  }
});

describe('PowerShell script guards', () => {
  it('fails closed: every script that acts stops on the first error', () => {
    for (const script of [
      scripts['paste, guarded']!,
      scripts['type out']!,
      scripts.reactivate!,
      scripts['restore foreground']!,
    ]) {
      expect(script).toContain("$ErrorActionPreference = 'Stop'");
      expect(script).toMatch(/\} catch \{\s*Write-Output "(failed|failed:\$typed|refused)"/);
    }
  });

  it('checks the deadline and the foreground before Ctrl+V', () => {
    const script = scripts['paste, guarded']!;
    const keystroke = script.indexOf('SendKeys');
    expect(script.indexOf('GetForegroundWindow() -ne [IntPtr]4660')).toBeGreaterThan(-1);
    expect(script.indexOf('GetForegroundWindow() -ne [IntPtr]4660')).toBeLessThan(keystroke);
    expect(script.indexOf('[DateTime]::UtcNow -ge $deadline')).toBeLessThan(keystroke);
    expect(script).toContain(`FromUnixTimeMilliseconds(${deadline})`);
  });

  it('checks the deadline, the foreground and the password field before every batch', () => {
    const script = scripts['type out']!;
    const loop = script.slice(script.indexOf('foreach ($line in $batches)'));
    const send = loop.indexOf('[UvType]::Send');
    expect(loop.indexOf('-ge $deadline')).toBeLessThan(send);
    expect(loop.indexOf('GetForegroundWindow() -ne $expected')).toBeLessThan(send);
    expect(loop.indexOf('IsPassword')).toBeLessThan(send);
    // A UI Automation error counts as a password field.
    expect(loop).toMatch(/catch \{\s*\$secure = \$true/);
  });

  it('reads only the real address bar', () => {
    expect(scripts['address bar, chromium']).toContain("'OmniboxViewViews'");
    expect(scripts['address bar, firefox']).toContain("'urlbar-input'");
    for (const script of [scripts['address bar, chromium']!, scripts['address bar, firefox']!]) {
      expect(script).toContain('AndCondition($isEdit, $isBar)');
    }
  });

  it('refuses anything but a plain handle', () => {
    expect(() => typeScript(0, deadline)).toThrow();
    expect(() => typeScript(1.5, deadline)).toThrow();
    expect(() => reactivateScript(-1, undefined)).toThrow();
    expect(() => browserAddressScript(Number.NaN, 'chromium')).toThrow();
    expect(() => restoreForegroundScript(5, 0)).toThrow();
    expect(() => pasteScript(Number.MAX_SAFE_INTEGER + 2, deadline)).toThrow();
  });
});
