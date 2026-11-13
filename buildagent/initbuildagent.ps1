<#
.SYNOPSIS
    First stage of the build agent setup. Runs once, inside the Custom Script Extension, as SYSTEM.

.DESCRIPTION
    Based on initbuildagent.ps1 from microsoft/nav-arm-templates (MIT, see THIRD-PARTY-NOTICES.md).

    The setup is split across reboots because Docker needs the Windows Containers feature, and that
    feature only becomes active after a restart:

        this script     enable Containers, download the setup scripts, store the agent settings,
                        register the B2FBuildAgentSetup task, schedule a reboot
        reboot 1        postboot.ps1 (phase "tools"): Docker, then every build tool; reboot
        reboot 2        postboot.ps1 (phase "agents"): register the agents, delete the token, done

    The agents are registered last on purpose: they start only on a machine that already has every
    tool, and their services start with the final PATH.

    Logs: C:\B2FSetup\init.log, then C:\B2FSetup\postboot.log.
#>
param(
    [Parameter(Mandatory = $true)] [string] $ScriptsBaseUrl,
    [Parameter(Mandatory = $true)] [string] $Organization,
    [Parameter(Mandatory = $true)] [string] $Pool,
    [Parameter(Mandatory = $true)] [string] $Token,
    [Parameter(Mandatory = $true)] [int]    $AgentCount,
    [string] $AgentUrl = '',
    [Parameter(Mandatory = $true)] [string] $VmName
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SetupFolder = 'C:\B2FSetup'
New-Item -ItemType Directory -Path $SetupFolder -Force | Out-Null
Start-Transcript -Path (Join-Path $SetupFolder 'init.log') -Append

if (-not $ScriptsBaseUrl.EndsWith('/')) { $ScriptsBaseUrl += '/' }

# The folder holds the PAT until the agents are registered: SYSTEM and Administrators only.
& icacls.exe $SetupFolder /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null

Write-Host "Downloading setup scripts from $ScriptsBaseUrl"
$scripts = @{
    'postboot.ps1'                    = 'buildagent/postboot.ps1'
    'install-tools.ps1'               = 'buildagent/install-tools.ps1'
    'SetupAgents.ps1'                 = 'buildagent/SetupAgents.ps1'
    'InstallOrUpdateDockerEngine.ps1' = 'shared/InstallOrUpdateDockerEngine.ps1'
}
foreach ($name in $scripts.Keys) {
    $target = Join-Path $SetupFolder $name
    Invoke-WebRequest -UseBasicParsing -Uri ($ScriptsBaseUrl + $scripts[$name]) -OutFile $target
}

Write-Host 'Storing agent settings'
[ordered]@{
    organization = $Organization.TrimEnd('/')
    pool         = $Pool
    token        = $Token
    agentCount   = $AgentCount
    agentUrl     = $AgentUrl
    vmName       = $VmName
} | ConvertTo-Json | Set-Content -Path (Join-Path $SetupFolder 'agent-settings.json') -Encoding UTF8

Write-Host 'Enabling the Windows Containers feature'
Install-WindowsFeature -Name Containers | Out-Null

Write-Host 'Extending the OS partition to the full disk'
$partition = Get-Partition -DriveLetter C
$maxSize = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
if ($partition.Size -lt $maxSize) { Resize-Partition -DriveLetter C -Size $maxSize }

Write-Host 'Registering the B2FBuildAgentSetup task'
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Unrestricted -File `"$SetupFolder\postboot.ps1`""
$trigger  = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT1M'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
Register-ScheduledTask -TaskName 'B2FBuildAgentSetup' -Action $action -Trigger $trigger -Settings $settings `
                       -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null

Set-Content -Path (Join-Path $SetupFolder 'phase.txt') -Value 'tools'

# A delayed restart lets the extension report success before the machine goes down.
Write-Host 'Restarting in 60 seconds to activate the Containers feature'
Stop-Transcript
& shutdown.exe /r /t 60 /c 'B2F build agent setup' /d p:4:2
exit 0
