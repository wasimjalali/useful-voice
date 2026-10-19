Three high-severity findings remain.

```json
[
  {
    "finding": "Fallback paths overwrite a newer clipboard copy.",
    "severity": "high",
    "file": "windows/src/core/delivery/pasteFlow.ts",
    "line": 162,
    "scenario": "While the keystroke waits, the user copies something else. If the delivery timeout then fires, stopBeforePaste writes the dictation unconditionally (line 98). If Useful Voice also comes forward, canSend checks ownership before clipboard contents and copyBecauseOwnWindow overwrites the newer copy (line 118). Both paths bypass clipboardChanged and report 'Press Ctrl+V'. Preserve the newer clipboard and return clipboardChanged once the initial dictation write has happened."
  },
  {
    "finding": "Editable-field permission remains valid after focus changes.",
    "severity": "high",
    "file": "windows/src/core/delivery/pasteFlow.ts",
    "line": 141,
    "scenario": "A dictation starts in Useful Voice and delivery confirms an editable field. While PowerShell starts or another request runs, the user focuses a password box, button or another Useful Voice window. ownFieldChecked remains true, so canSend permits the request. allowOwnWindow also disables the script's own-process guard. The dictation can enter an excluded field or disappear while being reported pasted. Revalidate the current window and editable focus after queueing."
  },
  {
    "finding": "The script uses foreground identity captured before clipboard work.",
    "severity": "high",
    "file": "windows/src/main/keystroke.ts",
    "line": 61,
    "scenario": "An external-start dictation passes beforeWrite. The script captures that external foreground process, then runs Get-Clipboard and hashes the result. If Useful Voice comes forward during that work, the later guard still uses the old procId and sends Ctrl+V into Useful Voice. Clipboard contention or cold command initialization widens this interval. Read the foreground process after clipboard hashing, immediately before the final guard and SendKeys."
  }
]
```

**DISMISSED**

- **Double paste through fallback:** `runHosted` retries only errors explicitly marked unsent. Written requests that time out, exit or throw become indeterminate without another keystroke attempt.
- **Cancellation restoring the clipboard after a possible send:** `sent` and `indeterminate` take precedence over the abort signal. They remain delivered and proceed to history.
- **PowerShell injection:** PID validation permits only positive safe integers. Hash validation permits exactly 64 lowercase hexadecimal characters. The boolean produces fixed PowerShell literals. Transcript text never enters the script.
- **Universal hash mismatch:** no encoding or newline discrepancy found. Both hash UTF-8 bytes after CRLF-to-LF normalization. [`Get-Clipboard -Raw`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-clipboard?view=powershell-5.1) returns one multiline string, and [Chromium’s clipboard implementation](https://raw.githubusercontent.com/chromium/chromium/main/ui/base/clipboard/clipboard_win.cc) stores Unicode text.
- **Late picker reveal:** the reveal callback rechecks both state and sequence. Delivery’s picker wait is bounded.
- **Written request exceeding grace:** the five-second grace exceeds the 2.5-second written-request timeout.

Validation: in-memory probes reproduced both clipboard-overwrite scenarios and the stale editable-focus scenario. The foreground-ordering finding follows from the script. Windows/PowerShell execution and full verification weren’t run. Files remain unchanged.