################################################################################
# MIT License
#
# © 2021, Microsoft Corporation. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Filename: CheckMsiOverride.ps1
# Version: 1.0.2110.2101
# Description: Script to check for and applies Teams msiOverride updates
# Owner: Teams Client Tools Support <tctsupport@microsoft.com>
#################################################################################

#Requires -RunAsAdministrator

Param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Share','CDN','Package')]
    #[string] $Type = "Share",
    [string] $Type = "CDN",
    [Parameter(Mandatory=$false)]
    [Switch] $PreviewRing = $false,
    [Parameter(Mandatory=$false)]
    [string] $BaseShare = "",
    [Parameter(Mandatory=$false)]
    [string] $OverrideVersion = "",
    [Parameter(Mandatory=$false)]
    [string] $MsiFileName = "",
    [Parameter(Mandatory=$false)]
    [Switch] $AllowInstallOvertopExisting = $false,
    [Parameter(Mandatory=$false)]
    [Switch] $OverwritePolicyKey = $false,
    [Parameter(Mandatory=$false)]
    [Switch] $FixRunKey = $false,
    [Parameter(Mandatory=$false)]
    [Switch] $Uninstall32Bit = $false
    )

$ScriptName  = "Microsoft Teams MsiOverride Checker"
$Version     = "1.0.2110.2101"

# Trace functions
function InitTracing([string]$traceName, [string]$tracePath = $env:TEMP)
{
    $script:TracePath = Join-Path $tracePath $traceName
    WriteTrace("")
    WriteTrace("Start Trace $(Get-Date)")
}

function WriteTrace([string]$line, [string]$function = "")
{
    $output = $line
    if($function -ne "")
    {
        $output = "[$function] " + $output
    }
    Write-Verbose $output
    $output | Out-File $script:TracePath -Append
}

function WriteInfo([string]$line, [string]$function = "")
{
    $output = $line
    if($function -ne "")
    {
        $output = "[$function] " + $output
    }
    Write-Host $output
    $output | Out-File $script:TracePath -Append
}

function WriteWarning([string]$line)
{
    Write-Host $line -ForegroundColor DarkYellow
    $line | Out-File $script:TracePath -Append
}

function WriteError([string]$line)
{
    Write-Host $line  -ForegroundColor Red
    $line | Out-File $script:TracePath -Append
}

function WriteSuccess([string]$line)
{
    Write-Host $line  -ForegroundColor Green
    $line | Out-File $script:TracePath -Append
}

# Removes temp folder
function Cleanup
{
    WriteTrace "Removing temp folder $TempPath"
    Remove-Item $TempPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}

# Runs cleanup and exits
function CleanExit($code = 0)
{
    Cleanup
    WriteTrace("End Trace $(Get-Date)")
    Exit $code
}

function ErrorExit($line, $code)
{
    WriteError($line)
    Write-EventLog -LogName Application -Source $EventLogSource -Category 0 -EntryType Error -EventId ([Math]::Abs($code)) -Message $line
    CleanExit($code)
}

function IsRunningUnderSystem
{
    if(($env:COMPUTERNAME + "$") -eq $env:USERNAME)
    {
        return $true
    }
    return $false
}

function GetFileVersionString($Path)
{
    if (Test-Path $Path)
    {
        $item = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($item)
        {
            return $item.FileVersion
        }
    }
    return ""
}

function HasReg($Path, $Name)
{
    if (Test-Path $Path)
    {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($item -ne $null)
        {
            return $true
        }
    }
    return $false
}

function GetReg($Path, $Name, $DefaultValue)
{
    if (HasReg -Path $Path -Name $Name)
    {
        $item = Get-ItemProperty -Path $Path -Name $Name
        return $item.$Name
    }
    return $DefaultValue
}

function SetDwordReg($Path, $Name, $Value)
{
    if (!(Test-Path $Path))
    {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWORD
}

function SetExpandStringReg($Path, $Name, $Value)
{
    if (!(Test-Path $Path))
    {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type ExpandString
}

function GetInstallerVersion
{
    return (GetFileVersionString -Path (GetInstallerPath))
}

function GetInstallerPath
{
    if($([Environment]::Is64BitOperatingSystem))
    {
        return (${env:ProgramFiles(x86)} + "\Teams Installer\Teams.exe")
    }
    else
    {
        return ($env:ProgramFiles + "\Teams Installer\Teams.exe")
    }
}

function GetTargetVersion
{
    $versionFile = Join-Path $BaseShare "Version.txt"
    $fileVersion = Get-Content $versionFile -ErrorAction SilentlyContinue
    return (VerifyVersion($fileVersion))
}

function VerifyVersion($Version)
{
    if($Version -match $versionRegex)
    {
        return $Matches.version
    }
    return $null
}

function GetUninstallKey
{
    $UninstallReg1 = Get-ChildItem -Path HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall -ErrorAction SilentlyContinue  | Get-ItemProperty | Where-Object { $_ -match 'Teams Machine-Wide Installer' }
    $UninstallReg2 = Get-ChildItem -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_ -match 'Teams Machine-Wide Installer' }

    WriteTrace("UninstallReg1: $($UninstallReg1.PSChildName)")
    WriteTrace("UninstallReg2: $($UninstallReg2.PSChildName)")

    if($UninstallReg1) { return $UninstallReg1 }
    elseif($UninstallReg2) { return $UninstallReg2 }
    return $null
}

function GetProductsKey
{
    $ProductsRegLM = Get-ChildItem -Path HKLM:\SOFTWARE\Classes\Installer\Products -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_ -match 'Teams Machine-Wide Installer' } # ALLUSERS Install
    $ProductsRegCU = Get-ChildItem -Path HKCU:\SOFTWARE\Microsoft\Installer\Products -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_ -match 'Teams Machine-Wide Installer' } # Local User Install

    WriteTrace("ProductsRegLM: $($ProductsRegLM.PSChildName)")
    WriteTrace("ProductsRegCU: $($ProductsRegCU.PSChildName)")

    if($ProductsRegLM) { return $ProductsRegLM }
    elseif($ProductsRegCU) { return $ProductsRegCU }
    return $null
}

function GetPackageKey()
{
    $msiKey = GetProductsKey
    if($msiKey)
    {
        $msiPkgReg = (Get-ChildItem -Path $msiKey.PSPath -Recurse | Get-ItemProperty | Where-Object { $_ -match 'PackageName' })

        if ($msiPkgReg.PackageName)
        {
            WriteTrace("PackageName: $($msiPkgReg.PackageName)")
            return $msiPkgReg
        }
    }
    return $null
}

function GetInstallBitnessFromUninstall()
{
    $uninstallReg = GetUninstallKey
    if($uninstallReg)
    {
        if ($uninstallReg.PSPath | Select-String -Pattern $MsiPkg64Guid)
        {
            return "x64"
        }
        elseif ($uninstallReg.PSPath | Select-String -Pattern $MsiPkg32Guid)
        {
            return "x86"
        }
    }
    return $null
}

function GetInstallBitnessFromSource()
{
    $msiPkgReg = GetPackageKey
    if($msiPkgReg)
    {
        WriteTrace("LastUsedSource: $($msiPkgReg.LastUsedSource)")
        if ($msiPkgReg.LastUsedSource | Select-String -Pattern ${env:ProgramFiles(x86)})
        {
            return "x86"
        }
        elseif ($msiPkgReg.LastUsedSource | Select-String -Pattern $env:ProgramFiles)
        {
            if($([Environment]::Is64BitOperatingSystem))
            {
                return "x64"
            }
            else
            {
                return "x86"
            }
        }
    }
    return $null
}

function GetInstallBitnessForOS()
{
    if($([Environment]::Is64BitOperatingSystem))
    {
        return "x64"
    }
    else
    {
        return "x86"
    }
}

function GetInstallBitness([ref]$outMode, [ref]$outFileName)
{
    $installBitness = GetInstallBitnessFromUninstall
    $packageKey = GetPackageKey
    # Determine the install bitness and mode
    if($installBitness)
    {
        # Uninstall key existed and we matched to known GUID
        if($packageKey)
        {
            # Update Scenario, Package key existed (meaning MSI was installed by this user, or as ALLUSERS).
            $mode = "update"
        }
        else
        {
            # Install Scenario, Package key did not exist (meaning MSI is installed, but not by this user and not as ALLUSERS).
            $mode = "installovertop"
        }
    }
    else
    {
        # Uninstall key did not exist or we did not match a known GUID
        if($packageKey)
        {
            # Update Scenario, we do have a package key, so we must not have matched a known GUID, so try to read LastUsedSource path (Office installation scenario).
            $mode = "update"
            $installBitness = GetInstallBitnessFromSource
            if(-not $installBitness)
            {
                # Fall back to OS bitness as a last resort.
                $installBitness = GetInstallBitnessForOS
            }
        }
        else
        {
            # Install Scenario, Neither Uninstall key or Package key existed, so it will be a fresh install
            $mode = "install"
            $installBitness = GetInstallBitnessForOS
        }
    }

    $outMode.Value = $mode
    $outFileName.Value = $packageKey.PackageName

    return $installBitness
}

function DeleteFile($path)
{
    if(Test-Path $path)
    {
        Remove-Item -Path $path -Force | Out-Null
        if(Test-Path $path)
        {
            Write-Host "Unable to delete $path" -ForegroundColor Red
            ErrorExit "Failed to delete existing file $path" -8
        }
    }
}

function SetParametersWithCDN([ref]$outVersion, [ref]$outPath)
{
    WriteInfo "Using CDN to check for an update and aquire the new MSI..."
    $updateCheckUrl = "https://teams.microsoft.com/package/desktopclient/update/{0}/windows/{1}?ring={2}"
    $downloadFormat32 = "https://statics.teams.microsoft.com/production-windows/{0}/Teams_windows.msi"
    $downloadFormat64 = "https://statics.teams.microsoft.com/production-windows-x64/{0}/Teams_windows_x64.msi"
    $bitness = $installBitness.Replace("x86", "x32")

    # Add TLS 1.2 for older OSs
    if (([Net.ServicePointManager]::SecurityProtocol -ne 'SystemDefault') -and 
        !(([Net.ServicePointManager]::SecurityProtocol -band 'Tls12') -eq 'Tls12'))
    {
        WriteTrace "Adding TLS 1.2 protocol"
        [Net.ServicePointManager]::SecurityProtocol += [Net.SecurityProtocolType]::Tls12
    }

    $downloadPath = ""
    $fileName = ""
    if($bitness -eq "x32")
    {
        $fileName = $FileName32
    }
    else
    {
        $fileName = $FileName64
    }
    if($outVersion.Value -eq "")
    {
        $ring = "general"
        if($PreviewRing)
        {
            $ring = "ring3"
        }

        $url = $updateCheckUrl -f $currentVersion,$bitness,$ring

        WriteInfo "Sending request to $url"
        $updateCheckResponse = Invoke-WebRequest -Uri $url -UseBasicParsing
        $updateCheckJson = $updateCheckResponse | ConvertFrom-Json

        if($updateCheckJson.isUpdateAvailable)
        {
            $downloadPath = $updateCheckJson.releasesPath.Replace("RELEASES", $fileName)
        }
        else
        {
            $outVersion.Value = $currentVersion
            return
        }
    }
    else
    {
        if($bitness -eq "x32")
        {
            $downloadPath = $downloadFormat32 -f $outVersion.Value
        }
        else
        {
            $downloadPath = $downloadFormat64 -f $outVersion.Value
        }
    }
    WriteInfo "Download path: $downloadPath"

    # Extract new version number from URL
    $newVersion = ""
    if($downloadPath -match $versionRegex)
    {
        $newVersion = $Matches.version
        WriteInfo "New version $newVersion"
    }

    # If we have a new version number and the download path, proceed
    if($newVersion -ne "" -and $downloadPath -ne "")
    {
        $localPath = Join-Path $TempPath "CDN"
        New-Item -ItemType Directory -Path $localPath | Out-Null
        $localPath = Join-Path $localPath $fileName
        WriteInfo "Downloading $downloadPath"
        DeleteFile $localPath
        $oldProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadPath -OutFile $localPath
        $ProgressPreference = $oldProgressPreference
        WriteInfo "Download complete."
        if(Test-Path $localPath)
        {
            WriteInfo "Successfully downloaded new installer to $localPath"
            $outVersion.Value = $newVersion
            $outPath.Value = $localPath
            return
        }
    }
    ErrorExit "Failed to check for or retrieve the update from the CDN!" -9
}

function SetParametersAsPackage([ref]$outVersion, [ref]$outPath)
{
    WriteInfo "Using working directory to aquire the new MSI..."
    if($outVersion.Value -eq "")
    {
        ErrorExit "Target version should already be provided by OverrideVersion parameter"
    }

    $workingDirectory = Get-Location

    WriteInfo "Working Directory: $workingDirectory"

    # Select MSI based on the bitness
    if ($installBitness -eq "x86") 
    {
        WriteInfo "Using 32-bit MSI from working directory"
        $fromMsi = Join-Path $workingDirectory $FileName32 # x86 MSI
    }
    else
    {
        WriteInfo "Using 64-bit MSI from working directory"
        $fromMsi = Join-Path $workingDirectory $FileName64 # x64 MSI
    }
    $outPath.Value = $fromMsi
}

function SetParametersWithShare([ref]$outVersion, [ref]$outPath)
{
    WriteInfo "Using the BaseShare check for an update and aquire the new MSI..."
    if($outVersion.Value -eq "")
    {
        # Get the target Teams Machine Installer version from the share
        $targetVersion = GetTargetVersion
        $outVersion.Value = $targetVersion
    }

    # Select MSI based on the bitness
    if ($installBitness -eq "x86") 
    {
        WriteInfo "Using 32-bit MSI from BaseShare"
        $fromMsi = "$BaseShare\$targetVersion\$FileName32" # x86 MSI
    }
    else
    {
        WriteInfo "Using 64-bit MSI from BaseShare"
        $fromMsi = "$BaseShare\$targetVersion\$FileName64" # x64 MSI
    }
    $outPath.Value = $fromMsi
}

function GetMsiExecFlags()
{
    $msiExecFlags = ""
    # Set msiExec flags based on our mode
    if ($mode -eq "install")
    {
        WriteInfo "This will be an install"
        $msiExecFlags = "/i" # new install flag
    }
    elseif ($mode -eq "update")
    {
        WriteInfo "This will be an override update"
        $msiExecFlags = "/fav" # override flag
    }
    elseif ($mode -eq "installovertop")
    {
        if($AllowInstallOvertopExisting)
        {
            WriteInfo "This will be an install overtop an existing install"
            $msiExecFlags = "/i" # new install flag
        }
        else
        {
            ErrorExit "ERROR: Existing Teams Machine-Wide Installer is present but it was not installed by the current user or as an ALLUSERS=1 install" -4
        }
    }
    else 
    {
        ErrorExit "UNEXPECTED ERROR! Unknown mode" -5
    }
    return $msiExecFlags
}

function CheckPolicyKey()
{
    # Set AllowMsiOverride key if needed
    $AllowMsiExists = (HasReg -Path $AllowMsiRegPath -Name $AllowMsiRegName)
    if ((-not $AllowMsiExists) -or $OverwritePolicyKey)
    {
        WriteInfo "The policy key AllowMsiOverride is not set, setting $AllowMsiRegPath\$AllowMsiRegName to 1..."
        SetDwordReg -Path $AllowMsiRegPath -Name $AllowMsiRegName -Value 1 | Out-Null
    }
    $AllowMsiValue = !!(GetReg -Path $AllowMsiRegPath -Name $AllowMsiRegName -DefaultValue 0)
    WriteInfo "AllowMsiOverride policy is set to $AllowMsiValue"

    if(-not $AllowMsiValue)
    {
        ErrorExit "ERROR: AllowMsiOverride is not enabled by policy!" -1
    }
}

function CheckParameters()
{
    if( $Type -eq "Share" -and $BaseShare -eq "" )
    {
        ErrorExit "ERROR: BaseShare must be provided"
    }
    if( $Type -ne "Share" -and $BaseShare -ne "" )
    {
        ErrorExit "ERROR: BaseShare should only be provided with Share type"
    }
    if( $Type -eq "Package" -and $OverrideVersion -eq "")
    {
        ErrorExit "ERROR: You must provide an OverrideVersion with Package type"
    }
}

# ----- Constants -----

$versionRegex = "(?<version>\d+\.\d+\.\d+\.\d+)"

$AllowMsiRegPath = "HKLM:\Software\Policies\Microsoft\Office\16.0\Teams"
$AllowMsiRegName = "AllowMsiOverride"

$RunKeyPath32 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$RunKeyPath64 = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"

$MsiPkg32Guid = "{39AF0813-FA7B-4860-ADBE-93B9B214B914}"
$MsiPkg64Guid = "{731F6BAA-A986-45A4-8936-7C3AAAAA760B}"

$FileName32 = "Teams_windows.msi"
$FileName64 = "Teams_windows_x64.msi"

$TempPath     = Join-Path $env:TEMP "TeamsMsiOverrideCheck"

$EventLogSource = "TeamsMsiOverride"

#----- Main Script -----

# Set the default error action preference
$ErrorActionPreference = "Continue"

InitTracing("TeamsMsiOverrideTrace.txt")

WriteTrace("Script Version $Version")
WriteTrace("Parameters Type: $Type, PreviewRing: $PreviewRing, BaseShare: $BaseShare, OverrideVersion: $OverrideVersion, MsiFileName: $MsiFileName, AllowInstallOvertopExisting: $AllowInstallOvertopExisting, OverwritePolicyKey: $OverwritePolicyKey, FixRunKey: $FixRunKey")
WriteTrace("Environment IsSystemAccount: $(IsRunningUnderSystem), IsOS64Bit: $([Environment]::Is64BitOperatingSystem)")

# Create event log source
New-EventLog -LogName Application -Source $EventLogSource -ErrorAction SilentlyContinue

# Delete the temp directory
Cleanup

# Validate parameters passed in
CheckParameters

# Check and set AllowMsiOverride key
CheckPolicyKey

# Check if we have both 32 bit and 64 bit versions of the MSI installed.  This will be an issue.
$productsKey = GetProductsKey
if($productsKey -is [array])
{
    # If switch is passed, uninstall the 32 bit MSI before we perform the upgrade on 64 bit.
    if($Uninstall32Bit)
    {
        $msiExecUninstallArgs = "/X $MsiPkg32Guid /quiet /l*v $env:TEMP\msiOverrideCheck_msiexecUninstall.log"

        WriteInfo "About to uninstall 32-bit MSI using this msiexec command:"
        WriteInfo " msiexec.exe $msiExecUninstallArgs"

        $res = Start-Process "msiexec.exe" -ArgumentList $msiExecUninstallArgs -Wait -PassThru -WindowStyle Hidden
        if ($res.ExitCode -eq 0)
        {
            WriteInfo "MsiExec completed successfully."
        }
        else
        {
            ErrorExit "ERROR: MsiExec failed with exit code $($res.ExitCode)" $res.ExitCode
        }
    }
    else
    {
        ErrorExit "It appears you have both 32 and 64 bit versions of the machine-wide installer present.  Please uninstall them and reinstall the correct one, or use the Uninstall32Bit switch to attempt to uninstall the 32 bit version." -16
    }
}

# Get the existing Teams Machine Installer version
$currentVersion = GetInstallerVersion
if($currentVersion)
{
    WriteInfo "Current Teams Machine-Wide Installer version is $currentVersion"
}
else
{
    WriteInfo "Teams Machine-Wide Installer was not found."
    $currentVersion = "1.3.00.00000"
}

$fromMsi = ""
$mode = ""
$packageFileName = ""
$installBitness = GetInstallBitness ([ref]$mode) ([ref]$packageFileName)

if($packageFileName -is [array])
{
    ErrorExit "Two or more package file names were found, indicating the machine-wide installer may be installed multiple times! Unable to continue." -17
}

$targetVersion = ""
if($OverrideVersion -ne "")
{
    $targetVersion = VerifyVersion $OverrideVersion
    if($targetVersion -eq $null)
    {
        ErrorExit "Specified OverrideVersion is not the correct format.  Please ensure it follows a format similar to 1.2.00.34567"  -10
    }

    if($currentVersion -eq $targetVersion)
    {
        WriteSuccess "Version specified in OverrideVersion is already installed!"
        CleanExit
    }
}

# Set the parameters either using CDN or file share
if($Type -eq "CDN")
{
    SetParametersWithCDN ([ref]$targetVersion) ([ref]$fromMsi)
}
elseif($Type -eq "Package")
{
    SetParametersAsPackage ([ref]$targetVersion) ([ref]$fromMsi)
}
else
{
    SetParametersWithShare([ref]$targetVersion) ([ref]$fromMsi)
}

# Confirm we have the target version
if($targetVersion)
{
    WriteInfo "Target Teams Machine-Wide Installer version is $targetVersion"
}
else
{
    ErrorExit "ERROR: TargetVersion is invalid!" -2
}

# Confirm we don't already have the target version installed
if($currentVersion -eq $targetVersion)
{
    WriteSuccess "Target version already installed!"
    CleanExit
}

# Get our MSIExec flags
$msiExecFlags = GetMsiExecFlags

# Check that we can reach the MSI file
if (-not (Test-Path $fromMsi))
{
    ErrorExit "ERROR: Unable to access the MSI at $fromMsi" -6
}

# Get the new MSI file name (must match the original for an in place repair operation)
if($MsiFileName -ne "")
{
    $msiName = $MsiFileName
}
else
{
    $msiName = $packageFileName
}

if (-not $msiName)
{
    # If this is a new install, or we don't know the MSI name, use the original MSI name
    $msiName = Split-Path $fromMsi -Leaf
}

# Rename (for CDN based) or copy from the share with the new name (for share based)
if($Type -eq "CDN")
{
    WriteInfo "Renaming $fromMsi to $msiName..."
    $toMsi = (Rename-Item -Path $fromMsi -NewName $msiName -PassThru).FullName
}
else
{
    # Copy MSI to our temp folder
    $toMsi = Join-Path $TempPath $msiName
    WriteInfo "Copying $fromMsi to $toMsi..."
    New-Item -ItemType File -Path $toMsi -Force | Out-Null
    Copy-Item -Path $fromMsi -Destination $toMsi | Out-Null
}

#Construct our full MsiExec arg statement
$msiExecArgs = "$msiExecFlags `"$toMsi`" /quiet ALLUSERS=1 /l*v $env:TEMP\msiOverrideCheck_msiexec.log"

# Output our action
WriteInfo "About to perform deployment using this msiexec command:"
WriteInfo " msiexec.exe $msiExecArgs"

# Do the install or upgrade
$res = Start-Process "msiexec.exe" -ArgumentList $msiExecArgs -Wait -PassThru -WindowStyle Hidden
if ($res.ExitCode -eq 0)
{
    WriteInfo "MsiExec completed successfully."
}
else
{
    ErrorExit "ERROR: MsiExec failed with exit code $($res.ExitCode)" $res.ExitCode
}

# Fixup the HKLM Run key if option is set
if($FixRunKey)
{
    $installer = GetInstallerPath
    $keyValue = "`"$installer`" --checkInstall --source=default"
    WriteInfo "Rewriting the HKLM Run key with $keyValue"
    if($([Environment]::Is64BitOperatingSystem))
    {
        SetExpandStringReg $RunKeyPath64 "TeamsMachineInstaller" $keyValue
    }
    else
    {
        SetExpandStringReg $RunKeyPath32 "TeamsMachineInstaller" $keyValue
    }
}

# Get final confirmation we actually did update the installer
$currentVersion = GetInstallerVersion
if($currentVersion)
{
    WriteInfo "New Teams Machine Installer version is $currentVersion"
}
if($currentVersion -eq $targetVersion)
{
    WriteSuccess "Deployment successful, installer is now at target version!"
    Write-EventLog -LogName Application -Source $EventLogSource -Category 0 -EntryType Information -EventId 0 -Message "Successfully updated Teams Machine-Wide Installer to $targetVersion"
    CleanExit
}
else
{
    ErrorExit "ERROR: Script completed, however the Teams Machine-Wide Installer is still not at the target version!" -7
}

# SIG # Begin signature block
# MIIjkgYJKoZIhvcNAQcCoIIjgzCCI38CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCgnFbiHRYSD05Q
# zEYcVqAKlbVjdQlwNcHdGKIpUui+J6CCDYEwggX/MIID56ADAgECAhMzAAAB32vw
# LpKnSrTQAAAAAAHfMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjAxMjE1MjEzMTQ1WhcNMjExMjAyMjEzMTQ1WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQC2uxlZEACjqfHkuFyoCwfL25ofI9DZWKt4wEj3JBQ48GPt1UsDv834CcoUUPMn
# s/6CtPoaQ4Thy/kbOOg/zJAnrJeiMQqRe2Lsdb/NSI2gXXX9lad1/yPUDOXo4GNw
# PjXq1JZi+HZV91bUr6ZjzePj1g+bepsqd/HC1XScj0fT3aAxLRykJSzExEBmU9eS
# yuOwUuq+CriudQtWGMdJU650v/KmzfM46Y6lo/MCnnpvz3zEL7PMdUdwqj/nYhGG
# 3UVILxX7tAdMbz7LN+6WOIpT1A41rwaoOVnv+8Ua94HwhjZmu1S73yeV7RZZNxoh
# EegJi9YYssXa7UZUUkCCA+KnAgMBAAGjggF+MIIBejAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUOPbML8IdkNGtCfMmVPtvI6VZ8+Mw
# UAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRpb25zIFB1
# ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzAwMTIrNDYzMDA5MB8GA1UdIwQYMBaAFEhu
# ZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0w
# Ny0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAnnqH
# tDyYUFaVAkvAK0eqq6nhoL95SZQu3RnpZ7tdQ89QR3++7A+4hrr7V4xxmkB5BObS
# 0YK+MALE02atjwWgPdpYQ68WdLGroJZHkbZdgERG+7tETFl3aKF4KpoSaGOskZXp
# TPnCaMo2PXoAMVMGpsQEQswimZq3IQ3nRQfBlJ0PoMMcN/+Pks8ZTL1BoPYsJpok
# t6cql59q6CypZYIwgyJ892HpttybHKg1ZtQLUlSXccRMlugPgEcNZJagPEgPYni4
# b11snjRAgf0dyQ0zI9aLXqTxWUU5pCIFiPT0b2wsxzRqCtyGqpkGM8P9GazO8eao
# mVItCYBcJSByBx/pS0cSYwBBHAZxJODUqxSXoSGDvmTfqUJXntnWkL4okok1FiCD
# Z4jpyXOQunb6egIXvkgQ7jb2uO26Ow0m8RwleDvhOMrnHsupiOPbozKroSa6paFt
# VSh89abUSooR8QdZciemmoFhcWkEwFg4spzvYNP4nIs193261WyTaRMZoceGun7G
# CT2Rl653uUj+F+g94c63AhzSq4khdL4HlFIP2ePv29smfUnHtGq6yYFDLnT0q/Y+
# Di3jwloF8EWkkHRtSuXlFUbTmwr/lDDgbpZiKhLS7CBTDj32I0L5i532+uHczw82
# oZDmYmYmIUSMbZOgS65h797rj5JJ6OkeEUJoAVwwggd6MIIFYqADAgECAgphDpDS
# AAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDla
# MH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMT
# H01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgG
# OBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S
# 35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jz
# y23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/7
# 4ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2u
# M1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33
# X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIl
# XdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP
# 6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLB
# l4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGF
# RInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiM
# CwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQ
# BdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1Ud
# DwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO
# 4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNw
# cy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkA
# XwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY
# 4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj
# 82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUd
# d5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJ
# Yx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYf
# wzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJ
# aG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1j
# NpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9B
# xw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96
# eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7
# r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5I
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVZzCCFWMCAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAd9r8C6Sp0q00AAAAAAB3zAN
# BglghkgBZQMEAgEFAKCBrjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgvxXag+8l
# 0KHT9EYzlE1tp0mYc191I6azDxyfHLQGFu0wQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQBnn0vErtaH2m48vRff0YuremL5Dncu5sBEbARwRnBE
# 4k+Vat7g/HCDyCmzLVN/PNeyzIhnS8AbQ/jyRJsEZyY7WQ+/loeiKMkf+stiSeFt
# T1mK06eXT0qSmv4LvkzoKXd5zIBIfOtBPbF7lO+aidee85e2wX/EwdU4vYngzWVQ
# Dklb4I+Ver4fOZdE1loEX8E5Z2VqMJgIRchuNF+NLvlQQpICxjFDPNgYjsVpLXoD
# r7CluojCoVm8p0sgCXLjV54JBWW1Ql3Z75mZsmXtkS//b3bwzZpq4aH8B+xH/lsS
# tc81zIz6xS7HzaipjRrkc5DXjQ/Qv8B9Oam7RTSCtKBHoYIS8TCCEu0GCisGAQQB
# gjcDAwExghLdMIIS2QYJKoZIhvcNAQcCoIISyjCCEsYCAQMxDzANBglghkgBZQME
# AgEFADCCAVUGCyqGSIb3DQEJEAEEoIIBRASCAUAwggE8AgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEICHC/UB7EfoMfSAnLt0GFH/ynXbdomZHQVZZivwi
# hbe5AgZhb3W06l4YEzIwMjExMDIxMTk1ODU5LjIwN1owBIACAfSggdSkgdEwgc4x
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKTAnBgNVBAsTIE1p
# Y3Jvc29mdCBPcGVyYXRpb25zIFB1ZXJ0byBSaWNvMSYwJAYDVQQLEx1UaGFsZXMg
# VFNTIEVTTjowQTU2LUUzMjktNEQ0RDElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZaCCDkQwggT1MIID3aADAgECAhMzAAABW3ywujRnN8GnAAAA
# AAFbMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEw
# MB4XDTIxMDExNDE5MDIxNloXDTIyMDQxMTE5MDIxNlowgc4xCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVy
# YXRpb25zIFB1ZXJ0byBSaWNvMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjowQTU2
# LUUzMjktNEQ0RDElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vydmlj
# ZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMgkf6Xs9dqhesumLltn
# l6lwjiD1jh+Ipz/6j5q5CQzSnbaVuo4KiCiSpr5WtqqVlD7nT/3WX6V6vcpNQV5c
# dtVVwafNpLn3yF+fRNoUWh1Q9u8XGiSX8YzVS8q68JPFiRO4HMzMpLCaSjcfQZId
# 6CiukyLQruKnSFwdGhMxE7GCayaQ8ZDyEPHs/C2x4AAYMFsVOssSdR8jb8fzAek3
# SNlZtVKd0Kb8io+3XkQ54MvUXV9cVL1/eDdXVVBBqOhHzoJsy+c2y/s3W+gEX8Qb
# 9O/bjBkR6hIaOwEAw7Nu40/TMVfwXJ7g5R/HNXCt7c4IajNN4W+CugeysLnYbqRm
# W+kCAwEAAaOCARswggEXMB0GA1UdDgQWBBRl5y01iG23UyBdTH/15TnJmLqrLjAf
# BgNVHSMEGDAWgBTVYzpcijGQ80N7fEYbxTNoWoVtVTBWBgNVHR8ETzBNMEugSaBH
# hkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNU
# aW1TdGFQQ0FfMjAxMC0wNy0wMS5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUF
# BzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1RpbVN0
# YVBDQV8yMDEwLTA3LTAxLmNydDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsG
# AQUFBwMIMA0GCSqGSIb3DQEBCwUAA4IBAQCnM2s7phMamc4QdVolrO1ZXRiDMUVd
# gu9/yq8g7kIVl+fklUV2Vlout6+fpOqAGnewMtwenFtagVhVJ8Hau8Nwk+IAhB0B
# 04DobNDw7v4KETARf8KN8gTH6B7RjHhreMDWg7icV0Dsoj8MIA8AirWlwf4nr8pK
# H0n2rETseBJDWc3dbU0ITJEH1RzFhGkW7IzNPQCO165Tp7NLnXp4maZzoVx8PyiO
# NO6fyDZr0yqVuh9OqWH+fPZYQ/YYFyhxy+hHWOuqYpc83Phn1vA0Ae1+Wn4bne6Z
# GjPxRI6sxsMIkdBXD0HJLyN7YfSrbOVAYwjYWOHresGZuvoEaEgDRWUrMIIGcTCC
# BFmgAwIBAgIKYQmBKgAAAAAAAjANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJv
# b3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAwHhcNMTAwNzAxMjEzNjU1WhcN
# MjUwNzAxMjE0NjU1WjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCCASIw
# DQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKkdDbx3EYo6IOz8E5f1+n9plGt0
# VBDVpQoAgoX77XxoSyxfxcPlYcJ2tz5mK1vwFVMnBDEfQRsalR3OCROOfGEwWbEw
# RA/xYIiEVEMM1024OAizQt2TrNZzMFcmgqNFDdDq9UeBzb8kYDJYYEbyWEeGMoQe
# dGFnkV+BVLHPk0ySwcSmXdFhE24oxhr5hoC732H8RsEnHSRnEnIaIYqvS2SJUGKx
# Xf13Hz3wV3WsvYpCTUBR0Q+cBj5nf/VmwAOWRH7v0Ev9buWayrGo8noqCjHw2k4G
# kbaICDXoeByw6ZnNPOcvRLqn9NxkvaQBwSAJk3jN/LzAyURdXhacAQVPIk0CAwEA
# AaOCAeYwggHiMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBTVYzpcijGQ80N7
# fEYbxTNoWoVtVTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMC
# AYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvX
# zpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20v
# cGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYI
# KwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDCBoAYDVR0g
# AQH/BIGVMIGSMIGPBgkrBgEEAYI3LgMwgYEwPQYIKwYBBQUHAgEWMWh0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS9QS0kvZG9jcy9DUFMvZGVmYXVsdC5odG0wQAYIKwYB
# BQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AUABvAGwAaQBjAHkAXwBTAHQAYQB0AGUA
# bQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAAfmiFEN4sbgmD+BcQM9naOh
# IW+z66bM9TG+zwXiqf76V20ZMLPCxWbJat/15/B4vceoniXj+bzta1RXCCtRgkQS
# +7lTjMz0YBKKdsxAQEGb3FwX/1z5Xhc1mCRWS3TvQhDIr79/xn/yN31aPxzymXlK
# kVIArzgPF/UveYFl2am1a+THzvbKegBvSzBEJCI8z+0DpZaPWSm8tv0E4XCfMkon
# /VWvL/625Y4zu2JfmttXQOnxzplmkIz/amJ/3cVKC5Em4jnsGUpxY517IW3DnKOi
# PPp/fZZqkHimbdLhnPkd/DjYlPTGpQqWhqS9nhquBEKDuLWAmyI4ILUl5WTs9/S/
# fmNZJQ96LjlXdqJxqgaKD4kWumGnEcua2A5HmoDF0M2n0O99g/DhO3EJ3110mCII
# YdqwUB5vvfHhAN/nMQekkzr3ZUd46PioSKv33nJ+YWtvd6mBy6cJrDm77MbL2IK0
# cs0d9LiFAR6A+xuJKlQ5slvayA1VmXqHczsI5pgt6o3gMy4SKfXAL1QnIffIrE7a
# KLixqduWsqdCosnPGUFN4Ib5KpqjEWYw07t0MkvfY3v1mYovG8chr1m1rtxEPJdQ
# cdeh0sVV42neV8HR3jDA/czmTfsNv11P6Z0eGTgvvM9YBS7vDaBQNdrvCScc1bN+
# NR4Iuto229Nfj950iEkSoYIC0jCCAjsCAQEwgfyhgdSkgdEwgc4xCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKTAnBgNVBAsTIE1pY3Jvc29mdCBP
# cGVyYXRpb25zIFB1ZXJ0byBSaWNvMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjow
# QTU2LUUzMjktNEQ0RDElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUACrtBbqYy0r+YGLtUaFVRW/Yh7qaggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQUFAAIF
# AOUb7lMwIhgPMjAyMTEwMjExNzQ5MDdaGA8yMDIxMTAyMjE3NDkwN1owdzA9Bgor
# BgEEAYRZCgQBMS8wLTAKAgUA5RvuUwIBADAKAgEAAgIXBwIB/zAHAgEAAgIRWTAK
# AgUA5R0/0wIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIB
# AAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBBQUAA4GBAA5YSyPCFOdstcFy
# vq4NB4hsfVEewLsTALjyKWLD5cIoJZ6sTtXVjiI6wSBmKAOHaMVv+GGdAC5iSr1v
# NkizlCMe9qHLw6vRDMHf7bOY67u/r4b6V/6Tjj1P9NrGLpn5lbQPc/wwa+gH+gim
# +vlrrLLltTsor3z3Kqr6kDQdQn0rMYIDDTCCAwkCAQEwgZMwfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAFbfLC6NGc3wacAAAAAAVswDQYJYIZIAWUD
# BAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0B
# CQQxIgQgalbdmygYpTtjeGDb0ke0Okt947reNptyyjVarEMbfRMwgfoGCyqGSIb3
# DQEJEAIvMYHqMIHnMIHkMIG9BCDJIuCpKGMRh4lCGucGPHCNJ7jq9MTbe3mQ2FtS
# ZLCFGTCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAAB
# W3ywujRnN8GnAAAAAAFbMCIEIF90K4uFxf5/LD54NVpgUke5l80RRHi3brLe8LUi
# u8KwMA0GCSqGSIb3DQEBCwUABIIBAHZEahsKj4BpQSltklo4hk4NM25RW+tGiSd+
# Z+Ar9SeNzFOWnFa17j8i8GlMTX0MM7BgUH3vdZdwJbRgE19GUZRYL9HgJbDDkkIS
# kh0uQBZPVCuRssR02nf7Xj7bDqzGBP4352y60T7NwxZOFoc+alL1qdajPS1qpaWH
# VAKAq0CvQlQcHVHA1BCdNkqbzBTNX4F8ytSXiudT6Gn3Djc9r6HetuvI9WjYP7fh
# bhQ0wwhi19NcK/+aZ+ir7FXi5axZ9B3D3NsZr03W4bmfHrj0SpHv4I91PgMa4fkA
# 5P/AkoB7VS+TEx1IpEbPZuXaY7LPM4R6B0pLc0EKZ2oI4y1KPMk=
# SIG # End signature block
