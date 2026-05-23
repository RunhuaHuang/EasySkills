' ==============================================================================
' Script: watcher-launcher.vbs (Windows)
' Description: Silently launches watcher-service.ps1 in the background (hidden).
# 脚本：watcher-launcher.vbs (Windows)
# 描述：双击启动器 VBS 脚本，完全静默在 Windows 后台唤醒并加载 PowerShell 监听服务（无黑框弹出）。
' ==============================================================================

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Get the directory of the current script / 获取当前脚本所在的绝对路径目录
strPath = WScript.ScriptFullName
Set objFile = objFSO.GetFile(strPath)
strFolder = objFSO.GetParentFolderName(objFile)

' Construct the silent powershell execution command / 构造静默加载 powershell 脚本的命令
strCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & strFolder & "\watcher-service.ps1"""

' Run the command completely hidden (WindowStyle = 0, WaitOnReturn = False) / 完全静默运行 (0 表示窗口完全隐藏)
objShell.Run strCommand, 0, False
