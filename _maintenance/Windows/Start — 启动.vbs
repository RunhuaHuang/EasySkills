' ==============================================================================
' Script: Start — 启动.vbs (Windows)
' Purpose: Silent launcher for EasySkills. Double-click to ensure the
'          background services are running and open the WebUI in the
'          default browser. Runs via wscript.exe with NO visible window.
' ==============================================================================
Option Explicit
On Error Resume Next

Dim sh, sa

Set sh = CreateObject("WScript.Shell")

' Trigger the Scheduled Tasks (idempotent — no-op if already running).
' Window style 0 = hidden, bWaitOnReturn True = wait for schtasks to return.
sh.Run "schtasks /Run /TN ""EasySkills WebUI""", 0, True
sh.Run "schtasks /Run /TN ""EasySkills Watcher""", 0, True

' Brief grace period for the HttpListener to bind to port 6633.
WScript.Sleep 800

' Open the WebUI in the default browser via Shell.Application (no console
' window at all — this is the same code path Windows uses for the Run dialog).
Set sa = CreateObject("Shell.Application")
sa.ShellExecute "http://localhost:6633", "", "", "open", 1
