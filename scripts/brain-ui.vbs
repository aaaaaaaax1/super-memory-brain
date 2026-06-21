Option Explicit

Dim fso, shell, scriptDir, rootDir, logPath, installLogPath, eventsLogPath
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
rootDir = fso.GetParentFolderName(scriptDir)
logPath = rootDir & "\memory\workspace\last-run.log"
installLogPath = rootDir & "\memory\workspace\last-install.log"
eventsLogPath = rootDir & "\memory\workspace\last-install-ui-events.log"
EnsureFolder rootDir & "\memory\workspace"

Dim installer, appModule, appScript, mode, rc
installer = rootDir & "\scripts\windows_install.ps1"
appModule = rootDir & "\scripts\brain_console_app.py"
appScript = rootDir & "\scripts\brain_console.py"

AppendEvent "UI launcher started."

If Not HasPython() Then
  MsgBox "Super Brain needs Python 3.10+ to run." & vbCrLf & vbCrLf & _
         "Please install Python from https://www.python.org/downloads/ and enable 'Add python.exe to PATH', then run brain.bat again.", _
         vbExclamation, "Super Brain Console"
  AppendEvent "Python not found."
  WScript.Quit 10
End If

If Not fso.FileExists(appModule) Or Not fso.FileExists(appScript) Then
  MsgBox "Required application files are missing from the package." & vbCrLf & rootDir, vbCritical, "Super Brain Console"
  AppendEvent "Required application files missing."
  WScript.Quit 11
End If

If NeedsInstall() Then
  Dim answer
  answer = MsgBox("First-time setup is required before Super Brain can start." & vbCrLf & vbCrLf & _
                  "This will create a local virtual environment and install Python packages." & vbCrLf & _
                  "Internet access may be required the first time." & vbCrLf & vbCrLf & _
                  "Continue setup now?", vbQuestion + vbYesNo, "Super Brain Console Setup")
  If answer <> vbYes Then
    AppendEvent "User cancelled setup."
    WScript.Quit 12
  End If

  AppendEvent "Starting dependency setup."
  rc = RunVisible("powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & Q(installer) & " -Root " & Q(rootDir))
  AppendEvent "Dependency setup exited with code " & CStr(rc) & "."

  If rc <> 0 Or NeedsInstall() Then
    ShowFailure "Setup did not complete successfully.", installLogPath
    WScript.Quit 20
  End If

  MsgBox "Setup completed successfully. Super Brain will start now.", vbInformation, "Super Brain Console"
End If

mode = PickMode()
If mode = "" Then
  AppendEvent "User cancelled mode selection."
  WScript.Quit 0
End If

AppendEvent "Starting app with mode: " & mode
rc = RunVisible("powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & Q(rootDir & "\scripts\run_brain_console.ps1") & " -Root " & Q(rootDir) & " -Mode " & mode)
AppendEvent "App exited with code " & CStr(rc) & "."

If rc <> 0 Then
  ShowFailure "Super Brain Console stopped with an error.", logPath
  WScript.Quit rc
End If

WScript.Quit 0

Function NeedsInstall()
  NeedsInstall = True
  If Not fso.FileExists(rootDir & "\.venv\Scripts\python.exe") Then Exit Function
  If Not fso.FileExists(rootDir & "\.venv\.super-brain-install-ok") Then Exit Function
  NeedsInstall = False
End Function

Function HasPython()
  HasPython = False
  If RunHidden("py -3 --version") = 0 Then HasPython = True: Exit Function
  If RunHidden("python --version") = 0 Then HasPython = True: Exit Function
End Function

Function PickMode()
  Dim choice
  choice = InputBox("Choose startup mode:" & vbCrLf & vbCrLf & _
                    "1 = Core mode (recommended, lightweight)" & vbCrLf & _
                    "2 = Full mode (all available capabilities)" & vbCrLf & vbCrLf & _
                    "Press Cancel to exit.", "Super Brain Console", "1")
  choice = Trim(choice)
  If choice = "" Then PickMode = "": Exit Function
  If choice = "2" Then PickMode = "full": Exit Function
  PickMode = "core"
End Function

Sub ShowFailure(message, filePath)
  Dim details
  details = ReadTail(filePath, 3500)
  If details = "" Then details = "No log details were available."
  MsgBox message & vbCrLf & vbCrLf & "Recent log output:" & vbCrLf & details & vbCrLf & vbCrLf & _
         "Full log: " & filePath, vbCritical, "Super Brain Console"
End Sub

Function RunVisible(cmd)
  RunVisible = shell.Run(cmd, 1, True)
End Function

Function RunHidden(cmd)
  On Error Resume Next
  RunHidden = shell.Run(cmd, 0, True)
  If Err.Number <> 0 Then
    Err.Clear
    RunHidden = 1
  End If
  On Error GoTo 0
End Function

Sub AppendEvent(msg)
  On Error Resume Next
  Dim ts
  EnsureFolder fso.GetParentFolderName(eventsLogPath)
  Set ts = fso.OpenTextFile(eventsLogPath, 8, True, -1)
  ts.WriteLine Now & "  " & msg
  ts.Close
  On Error GoTo 0
End Sub

Function ReadTail(filePath, maxChars)
  On Error Resume Next
  ReadTail = ""
  If Not fso.FileExists(filePath) Then Exit Function
  Dim ts, txt, startAt
  Set ts = fso.OpenTextFile(filePath, 1, False, -1)
  txt = ts.ReadAll
  ts.Close
  If Len(txt) > maxChars Then
    startAt = Len(txt) - maxChars + 1
    ReadTail = "..." & Mid(txt, startAt)
  Else
    ReadTail = txt
  End If
  On Error GoTo 0
End Function

Sub EnsureFolder(path)
  If path = "" Then Exit Sub
  If fso.FolderExists(path) Then Exit Sub
  EnsureFolder fso.GetParentFolderName(path)
  On Error Resume Next
  fso.CreateFolder path
  On Error GoTo 0
End Sub

Function Q(s)
  Q = Chr(34) & s & Chr(34)
End Function
