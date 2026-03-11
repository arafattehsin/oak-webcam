' Launches a PowerShell script with no visible window.
' Usage: wscript.exe launch-hidden.vbs <script.ps1> [args...]
'
' Task Scheduler + pwsh -WindowStyle Hidden still flashes a console
' because the console host is created before PowerShell processes the flag.
' WScript.Shell.Run with window-style 0 avoids this entirely.

If WScript.Arguments.Count = 0 Then
    WScript.Echo "Usage: wscript.exe launch-hidden.vbs <script.ps1> [args...]"
    WScript.Quit 1
End If

Dim fso, scriptPath, args, cmd, i
Set fso = CreateObject("Scripting.FileSystemObject")

scriptPath = WScript.Arguments(0)
If Not fso.FileExists(scriptPath) Then
    ' Try resolving relative to this VBS file's directory
    scriptPath = fso.BuildPath(fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName)), WScript.Arguments(0))
End If

args = ""
For i = 1 To WScript.Arguments.Count - 1
    args = args & " " & WScript.Arguments(i)
Next

cmd = "pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """" & args

Set WshShell = CreateObject("WScript.Shell")
' 0 = hidden window, False = don't wait for completion
WshShell.Run cmd, 0, False
