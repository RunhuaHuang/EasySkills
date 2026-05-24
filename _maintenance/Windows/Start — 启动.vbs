' ==============================================================================
' Script: Start — 启动.vbs (Windows)
' Purpose: Silent launcher for EasySkills. Runs under wscript.exe so it
'          creates NO console window. Triggers the EasySkills Scheduled
'          Tasks via the Task Scheduler COM API (avoids spawning schtasks.exe
'          which is a console-subsystem program). Falls back to launching
'          run-hidden.vbs directly if the Tasks aren't registered.
' ==============================================================================
Option Explicit
On Error Resume Next

Dim fso, scriptDir, maintDir, runHiddenVbs, supervisorPs1, watcherPs1
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
maintDir  = fso.GetParentFolderName(scriptDir)
runHiddenVbs   = maintDir & "\run-hidden.vbs"
supervisorPs1  = maintDir & "\webui-service.ps1"
watcherPs1     = maintDir & "\watcher-service.ps1"

' --- Trigger the two Scheduled Tasks via the COM API ---------------------
' This avoids spawning schtasks.exe (a console app) which can cause a
' brief window flash even with SW_HIDE on some Windows versions.
Dim ts, rootFolder, task, ranWebUI, ranWatcher
ranWebUI   = False
ranWatcher = False
Set ts = CreateObject("Schedule.Service")
ts.Connect

If Err.Number = 0 Then
    Set rootFolder = ts.GetFolder("\")
    If Err.Number = 0 Then
        Set task = rootFolder.GetTask("EasySkills WebUI")
        If Err.Number = 0 Then
            task.Run(Null)
            ranWebUI = True
        End If
        Err.Clear

        Set task = rootFolder.GetTask("EasySkills Watcher")
        If Err.Number = 0 Then
            task.Run(Null)
            ranWatcher = True
        End If
        Err.Clear
    End If
End If
Err.Clear

' --- Fallback: if a task isn't registered, launch the supervisor directly
'     via run-hidden.vbs (also windowless). -----------------------------
Dim sh
Set sh = CreateObject("WScript.Shell")
If Not ranWebUI And fso.FileExists(runHiddenVbs) And fso.FileExists(supervisorPs1) Then
    sh.Run "wscript.exe """ & runHiddenVbs & """ """ & supervisorPs1 & """", 0, False
End If
If Not ranWatcher And fso.FileExists(runHiddenVbs) And fso.FileExists(watcherPs1) Then
    sh.Run "wscript.exe """ & runHiddenVbs & """ """ & watcherPs1 & """", 0, False
End If

' Brief grace period for the HttpListener to bind to port 6633.
WScript.Sleep 800

' Open the WebUI in the default browser via Shell.Application (the same
' code path Windows uses for the Run dialog — no console window).
Dim sa
Set sa = CreateObject("Shell.Application")
sa.ShellExecute "http://localhost:6633", "", "", "open", 1
