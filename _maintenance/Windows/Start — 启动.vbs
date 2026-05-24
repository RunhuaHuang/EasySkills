' ==============================================================================
' Script: Start — 启动.vbs (Windows)
' Purpose: Silent launcher for EasySkills. Double-click to ensure the
'          background services are running and open the WebUI in the
'          default browser. Runs via wscript.exe with NO visible window.
' ==============================================================================
Option Explicit
On Error Resume Next

Dim sh, sa, scriptDir, supervisorPath, watcherPath
Set sh = CreateObject("WScript.Shell")

' Resolve absolute path to ../webui-service.ps1 (used as fallback below).
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
supervisorPath = CreateObject("Scripting.FileSystemObject").GetParentFolderName(scriptDir) & "\webui-service.ps1"
watcherPath    = CreateObject("Scripting.FileSystemObject").GetParentFolderName(scriptDir) & "\watcher-service.ps1"

' Trigger the Scheduled Tasks (idempotent — no-op if already running).
' Window style 0 = hidden, bWaitOnReturn True = wait for schtasks to return.
Dim webuiResult, watcherResult
webuiResult   = sh.Run("schtasks /Run /TN ""EasySkills WebUI""", 0, True)
watcherResult = sh.Run("schtasks /Run /TN ""EasySkills Watcher""", 0, True)

' If the Scheduled Tasks aren't registered (exit code 1), fall back to a
' direct hidden PowerShell launch. This keeps the launcher useful even if
' Task Scheduler is locked down or the install was incomplete.
If webuiResult <> 0 Then
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & supervisorPath & """", 0, False
End If
If watcherResult <> 0 Then
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & watcherPath & """", 0, False
End If

' Brief grace period for the HttpListener to bind to port 6633.
WScript.Sleep 800

' Open the WebUI in the default browser via Shell.Application (no console
' window at all — this is the same code path Windows uses for the Run dialog).
Set sa = CreateObject("Shell.Application")
sa.ShellExecute "http://localhost:6633", "", "", "open", 1
