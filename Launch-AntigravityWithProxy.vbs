Set shell = CreateObject("WScript.Shell")
Set env = shell.Environment("PROCESS")

' These variables exist only for this launcher and the Antigravity process it starts.
' Replace 7890 with your actual local proxy port (e.g. 7890, 10809, etc.)
env("HTTP_PROXY") = "http://127.0.0.1:7890"
env("HTTPS_PROXY") = "http://127.0.0.1:7890"
env("ALL_PROXY") = "http://127.0.0.1:7890"
env("NO_PROXY") = "localhost,127.0.0.1,::1"

appPath = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe")
shell.Run Chr(34) & appPath & Chr(34), 1, False

