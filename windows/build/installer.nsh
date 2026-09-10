; Useful Voice — NSIS installer customisation.
;
; Kept deliberately small: electron-builder's defaults already handle the
; per-user install, shortcut creation and uninstaller. This file exists so the
; installer can do the two things specific to a dictation tool.

!macro customInstall
  ; The app is tray-resident, so a finished install should offer to start it.
  ; Not forced: launching a program that immediately sits in the tray is
  ; surprising if the user was only setting it up.
  DetailPrint "Useful Voice installed. Start it from the Start menu, then set your Deepgram API key."
!macroend

!macro customUnInstall
  ; Deliberately do NOT delete the user's data on uninstall.
  ;
  ; The dictionary, notes and dictation history live in %APPDATA%\Useful Voice.
  ; Removing a program must never destroy the words a user taught it, or a
  ; year of transcripts -- and a reinstall would silently come back empty.
  ; The data folder path is shown in Settings so it can be removed by hand.
  DetailPrint "Your dictionary, notes and history have been kept in %APPDATA%\Useful Voice."
!macroend
