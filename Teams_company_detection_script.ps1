If([String](Get-Item -Path "$Env:ProgramFiles\Teams Installer\Teams.exe","${Env:ProgramFiles(x86)}\Teams Installer\Teams.exe" -ErrorAction SilentlyContinue).VersionInfo.FileVersion -ge "1"){
write-host (Get-Command "C:\Program Files (x86)\Teams Installer\Teams.exe").FileVersionInfo.FileVersion 
exit 1
}