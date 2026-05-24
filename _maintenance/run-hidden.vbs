' ==============================================================================
' Script: run-hidden.vbs
' Purpose: Generic invisible launcher for PowerShell scripts. wscript.exe is
'          a GUI-subsystem app and never creates a console window, so this
'          completely eliminates the PowerShell-5.x window-flash problem that
'          -WindowStyle Hidden can't reliably fix on its own (especially
'          under Task Scheduler with Interactive logon).
'
' Used by Task Scheduler actions:
'   Execute   = C:\Windows\System32\wscript.exe
'   Argument  = "<this-script>" "<target-ps1>"
'   The wscript.exe parent exits immediately; the spawned powershell.exe
'   inherits SW_HIDE and runs invisibly for the rest of its lifetime.
' ==============================================================================
Option Explicit
On Error Resume Next

If WScript.Arguments.Count < 1 Then WScript.Quit 1

Dim sh, target, cmd
Set sh = CreateObject("WScript.Shell")
target = WScript.Arguments(0)

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & target & """"

' Window style 0 = SW_HIDE. False = don't wait — we exit immediately so the
' Scheduled Task action completes quickly; the PowerShell child keeps running
' under the same security context with no visible window.
sh.Run cmd, 0, False
