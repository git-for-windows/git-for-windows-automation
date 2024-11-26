#Requires -RunAsAdministrator

param (
    # https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners
    [Parameter(Mandatory = $true, HelpMessage = "GitHub Actions Runner registration token. Note that these tokens are only valid for one hour after creation, so we always expect the user to provide one.")]
    [string]$GitHubActionsRunnerToken,

    # GitHub Actions Runner repository. E.g. "https://github.com/MY_ORG" (org-level) or "https://github.com/MY_ORG/MY_REPO" (repo-level)
    # https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners
    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -like "https://*" })]
    [string]$GithubActionsRunnerRegistrationUrl,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the runner. Needs to be unique in the org/repo")]
    [ValidateNotNullOrEmpty()]
    [string]$GithubActionsRunnerName,

    [Parameter(Mandatory = $false, HelpMessage = "Stop Service immediately (useful for spinning up runners preemptively)")]
    [ValidateSet('true', 'false')]
    [string]$StopService = 'true',

    [Parameter(Mandatory = $true, HelpMessage = "Path to the Actions Runner. Keep this path short to prevent Long Path issues, e.g. D:\a")]
    [ValidateNotNullOrEmpty()]
    [string]$GitHubActionsRunnerPath
)

Write-Output "Starting post-deployment script."

# =================================
# TOOL VERSIONS AND OTHER VARIABLES
# =================================
#
# This header is used for both Git for Windows and GitHub Actions Runner
[hashtable]$GithubHeaders = @{
    "Accept"               = "application/vnd.github.v3+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# =================================
# Get download and hash information for the latest release of Git for Windows
# =================================
#
# This will return the latest release of Git for Windows download link, hash and the name of the outfile
# Everything will be saved in the object $GitHubGit
#
# url for Github API to get the latest release
[string]$GitHubUrl = "https://api.github.com/repos/git-for-windows/git/releases/latest"
#
# Name of the exe file that should be verified and downloaded
[string]$GithubExeName = "Git-.*-arm64.exe"

try {
    [System.Object]$GithubRestData = Invoke-RestMethod -Uri $GitHubUrl -Method Get -Headers $GithubHeaders -TimeoutSec 10 | Select-Object -Property assets, body
    [System.Object]$GitHubAsset = $GithubRestData.assets | Where-Object { $_.name -match $GithubExeName }
    $AssetNameEscaped = [Regex]::Escape($GitHubAsset.name)
    if ($GithubRestData.body -match "\b${AssetNameEscaped}.*?\|.*?([a-zA-Z0-9]{64})" -eq $True) {
        [System.Object]$GitHubGit = [PSCustomObject]@{
            DownloadUrl = [string]$GitHubAsset.browser_download_url
            Hash        = [string]$Matches[1].ToUpper()
            OutFile     = "./git-for-windows-installer.exe"
        }
    }
    else {
        Write-Error "Could not find hash for $GithubExeName"
        exit 1
    }
}
catch {
    Write-Error @"
   "Message: "$($_.Exception.Message)`n
   "Error Line: "$($_.InvocationInfo.Line)`n
   "Line Number: "$($_.InvocationInfo.ScriptLineNumber)`n
"@
    exit 1
}

# =================================
# Obtain the latest GitHub Actions Runner and other GitHub Actions information
# =================================
#
# Note that the GitHub Actions Runner auto-updates itself by default, but do try to reference a relatively new version here.
#
# This will return the latest release of GitHub Actions Runner download link, hash, Tag, RunnerArch, RunnerLabels and the name of the outfile.
# Everything will be saved in the object $GitHubAction
#
# url for Github API to get the latest release of actions runner
[string]$GitHubActionUrl = "https://api.github.com/repos/actions/runner/releases/latest"

try {
    [System.Object]$GithubActionRestData = Invoke-RestMethod -Uri $GitHubActionUrl -Method Get -Headers $GithubHeaders -TimeoutSec 10 | Select-Object -Property assets, body, tag_name
    if ($GithubActionRestData.body -match "<!-- BEGIN SHA win-arm64 -->(.*)<!-- END SHA win-arm64 -->" -eq $True) {
        [string]$ActionZipName = "actions-runner-win-arm64-" + [string]$($GithubActionRestData.tag_name.Substring(1)) + ".zip"

        [System.Object]$GitHubAction = [PSCustomObject]@{
            Tag          = $GithubActionRestData.tag_name.Substring(1)
            Hash         = $Matches[1].ToUpper()
            RunnerArch   = "arm64"
            RunnerLabels = "self-hosted,Windows,ARM64"
            DownloadUrl  = $GithubActionRestData.assets | where-object { $_.name -match $ActionZipName } | Select-Object -ExpandProperty browser_download_url
            OutFile      = "$($GitHubActionsRunnerPath)\$($ActionZipName)"
        }
    }
    else {
        Write-Error "Error: Could not find hash for Github Actions Runner"
        exit 1
    }
}
catch {
    Write-Error @"
   "Message: "$($_.Exception.Message)`n
   "Error Line: "$($_.InvocationInfo.Line)`n
   "Line Number: "$($_.InvocationInfo.ScriptLineNumber)`n
"@
    exit 1
}

# =================================
# Obtain the latest pwsh binary and other pwsh information
# =================================
#
# This will install pwsh on the machine, because it's not installed by default.
# It contains a bunch of new features compared to "powershell" and is sometimes more stable as well.
#
# url for Github API to get the latest release of pwsh
[string]$PwshUrl = "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"

# Name of the MSI file that should be verified and downloaded
[string]$PwshMsiName = "PowerShell-.*-win-arm64.msi"

try {
    [System.Object]$PwshRestData = Invoke-RestMethod -Uri $PwshUrl -Method Get -Headers $GithubHeaders -TimeoutSec 10 | Select-Object -Property assets, body
    [System.Object]$PwshAsset = $PwshRestData.assets | Where-Object { $_.name -match $PwshMsiName }
    if ($PwshRestData.body -match "\b$([Regex]::Escape($PwshAsset.name))\r\n.*?([a-zA-Z0-9]{64})" -eq $True) {
        [System.Object]$GitHubPwsh = [PSCustomObject]@{
            DownloadUrl = [string]$PwshAsset.browser_download_url
            Hash        = [string]$Matches[1].ToUpper()
            OutFile     = "./pwsh-installer.msi"
        }
    }
    else {
        Write-Error "Could not find hash for $PwshMsiName"
        exit 1
    }
}
catch {
    Write-Error @"
   "Message: "$($_.Exception.Message)`n
   "Error Line: "$($_.InvocationInfo.Line)`n
   "Line Number: "$($_.InvocationInfo.ScriptLineNumber)`n
"@
    exit 1
}

# ======================
# WINDOWS DEVELOPER MODE
# ======================

# Needed for symlink support
Write-Output "Enabling Windows Developer Mode..."
Start-Process -Wait "reg" 'add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d "1"'
Write-Output "Enabled Windows developer mode."

# =============================
# MICROSOFT DEFENDER EXCLUSIONS
# =============================

Write-Output "Adding Microsoft Defender Exclusions..."
Add-MpPreference -ExclusionPath "C:\"
Write-Output "Finished adding Microsoft Defender Exclusions."

# ======================
# GIT FOR WINDOWS
# ======================

Write-Output "Downloading Git for Windows..."
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -UseBasicParsing -Uri $GitHubGit.DownloadUrl -OutFile $GitHubGit.OutFile
$ProgressPreference = 'Continue'

if ((Get-FileHash -Path $GitHubGit.OutFile -Algorithm SHA256).Hash.ToUpper() -ne $GitHubGit.Hash) {
    Write-Error "Computed checksum for $($GitHubGit.OutFile) did not match $($GitHubGit.Hash)"
    exit 1
}

Write-Output "Installing Git for Windows..."
@"
[Setup]
Lang=default
Dir=C:\Program Files\Git
Group=Git
NoIcons=0
SetupType=default
Components=gitlfs,windowsterminal
Tasks=
EditorOption=VIM
CustomEditorPath=
DefaultBranchOption= 
PathOption=CmdTools
SSHOption=OpenSSH
TortoiseOption=false
CURLOption=WinSSL
CRLFOption=CRLFAlways
BashTerminalOption=ConHost
GitPullBehaviorOption=FFOnly
UseCredentialManager=Core
PerformanceTweaksFSCache=Enabled
EnableSymlinks=Disabled
EnablePseudoConsoleSupport=Disabled
EnableFSMonitor=Disabled
"@ | Out-File -FilePath "./git-installer-config.inf"

Start-Process -Wait $GitHubGit.OutFile '/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /LOADINF="./git-installer-config.inf"'

Write-Output "Finished installing Git for Windows."

# ======================
# PWSH (PowerShell)
# ======================

Write-Output "Downloading pwsh..."

$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -UseBasicParsing -Uri $GitHubPwsh.DownloadUrl -OutFile $GitHubPwsh.OutFile
$ProgressPreference = 'Continue'

if ((Get-FileHash -Path $GitHubPwsh.OutFile -Algorithm SHA256).Hash.ToUpper() -ne $GitHubPwsh.Hash) {
    Write-Error "Computed checksum for $($GitHubPwsh.OutFile) did not match $($GitHubPwsh.Hash)"
    exit 1
}

Write-Output "Installing pwsh..."

# Get the full path to the MSI in the current working directory
$MsiPath = Resolve-Path $GitHubPwsh.OutFile

# Define arguments for silent installation
$MsiArguments = "/qn /i  `"$MsiPath`" ADD_PATH=1"

# Install pwsh using msiexec
Start-Process msiexec.exe -Wait -ArgumentList $MsiArguments

Write-Output "Finished installing pwsh."

# ======================
# GITHUB ACTIONS RUNNER
# ======================

Write-Output "Downloading GitHub Actions runner..."

mkdir $GitHubActionsRunnerPath | Out-Null
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -UseBasicParsing -Uri $GitHubAction.DownloadUrl -OutFile $GitHubAction.OutFile
$ProgressPreference = 'Continue'

if ((Get-FileHash -Path $GitHubAction.OutFile -Algorithm SHA256).Hash.ToUpper() -ne $GitHubAction.hash) {
    Write-Error "Computed checksum for $($GitHubAction.OutFile) did not match $($GitHubAction.hash)"
    exit 1
}

Write-Output "Installing GitHub Actions runner $($GitHubAction.Tag) as a Windows service with labels $($GitHubAction.RunnerLabels)..."

Add-Type -AssemblyName System.IO.Compression.FileSystem ; [System.IO.Compression.ZipFile]::ExtractToDirectory($GitHubAction.OutFile, $GitHubActionsRunnerPath)

Write-Output "Configuring the runner to shut down automatically after running"
Set-Content -Path "${GitHubActionsRunnerPath}\shut-down.ps1" -Value "shutdown -s -t 60 -d p:4:0 -c `"workflow job is done`""
[System.Environment]::SetEnvironmentVariable("ACTIONS_RUNNER_HOOK_JOB_COMPLETED", "${GitHubActionsRunnerPath}\shut-down.ps1", [System.EnvironmentVariableTarget]::Machine)

Write-Output "Configuring the runner"
cmd.exe /c "${GitHubActionsRunnerPath}\config.cmd" --unattended --ephemeral --name ${GithubActionsRunnerName} --runasservice --labels $($GitHubAction.RunnerLabels) --url ${GithubActionsRunnerRegistrationUrl} --token ${GitHubActionsRunnerToken}

# Ensure that the service was created. If not, exit with error code.
if ($null -eq (Get-Service -Name "actions.runner.*")) {
    Write-Output "Could not find service actions.runner.*, making three more attempts with a 3 second delay in between each attempt..."

    [int]$RetryCountService = 0
    do {
        Write-Output "Attempt $($RetryCountService) of 3: Looking for service actions.runner.*..."
        $RetryCountService++
        Start-Sleep -Seconds 3
    }
    while ($null -eq (Get-Service -Name "actions.runner.*") -or $RetryCountService -gt 3)

    if ($RetryCountService -gt 3) {
        Write-Error "GitHub Actions service not found (should start with actions.runner). Check the logs in ${GitHubActionsRunnerPath}\_diag for more details."
        exit 1
    }
    else {
        Write-Output "Found service actions.runner.*"
    }
}

# Immediately stop the service as we want to leave the VM in a deallocated state for later use. The service will automatically be started when Windows starts.
if ($StopService -eq 'true') {
    #Collects all running services named actions.runner.*
    $GetActionRunnerServices = Get-Service -Name "actions.runner.*" | Where-Object { $_.Status -eq 'Running' } | Select-Object -ExpandProperty Name

    # Loops trough all services and stopping them one by one
    foreach ($Service in $GetActionRunnerServices) {
        Write-Output "Stopping service $Service"
        Stop-Service -Name $Service

        # Making sure that all of the services has been stopped before moving forward
        [int]$RetryCount = 0
        do {
            Write-Output "Attempt: $($RetryCount) of 5: Waiting for service $Service to stop..."
            $RetryCount++
            Start-Sleep -Seconds 5
        }
        while ((Get-Service -Name $Service).Status -eq 'running' -or $RetryCount -gt 5)

        if ($RetryCount -gt 5) {
            Write-Error "Service $Service failed to stop"
            exit 1
        }
        else {
            Write-Output "Service $Service has been stopped"
        }
    }
}

Write-Output "Finished installing GitHub Actions runner."
