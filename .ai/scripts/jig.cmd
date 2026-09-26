@echo off
setlocal
rem LF-only on purpose: `jig upgrade` hashes a framework source file as raw
rem bytes while it hashes the installed copy through the project's
rem .gitattributes, so a CRLF source here would read as changed forever;
rem cmd.exe only misparses LF-only batch files around labels/goto, and this
rem file has neither.
rem PowerShell (native Codex on Windows) cannot execute ".ai/scripts/jig"
rem itself -- a shebang script with no extension -- but it does find this
rem sibling jig.cmd for "jig status" / "jig.cmd version" (CI probe,
rem 2026-09-14) and passes the exit code through.
rem PATH's "bash" can resolve to C:\Windows\system32\bash.exe, the WSL
rem launcher, not a usable bash for this repo. Git for Windows carries its
rem own Bash relative to its own exec path, so ask git rather than PATH.
for /f "delims=" %%G in ('git --exec-path') do set "JIG_GIT_EXEC=%%G"
set "JIG_BASH=%JIG_GIT_EXEC%\..\..\..\bin\bash.exe"
if not exist "%JIG_BASH%" (echo jig: Git Bash not found next to git 1>&2 & exit /b 127)
rem Bash wants forward slashes; the dispatcher lives next to this file.
set "JIG_SELF=%~dp0jig"
set "JIG_SELF=%JIG_SELF:\=/%"
rem Known limitation (CI probe): cmd.exe's quoting drops inner double
rem quotes from these arguments; spaces, &, |, and % survive intact.
"%JIG_BASH%" "%JIG_SELF%" %*
exit /b %ERRORLEVEL%
