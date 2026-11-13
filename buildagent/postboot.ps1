<#
.SYNOPSIS
    Runs at startup until the build agent setup is finished (scheduled task B2FBuildAgentSetup).

.DESCRIPTION
    C:\B2FSetup\phase.txt says where the setup is:

        tools    Docker, then every build tool (install-tools.ps1); then reboot so that every
                 service, including the agents registered next, starts with the final PATH
        agents   register the agents (SetupAgents.ps1), delete the stored token, remove the task
        done     nothing left to do

    A phase that fails leaves phase.txt unchanged, so the task tries again at the next startup.
    Docker and the agent registration are fatal; a single tool that fails to install is logged in
    C:\B2FSetup\tools-summary.txt and does not block the agents.
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SetupFolder = 'C:\B2FSetup'
$phaseFile   = Join-Path $SetupFolder 'phase.txt'
Start-Transcript -Path (Join-Path $SetupFolder 'postboot.log') -Append

$phase = if (Test-Path $phaseFile) { (Get-Content $phaseFile -Raw).Trim() } else { 'done' }
Write-Host "Phase: $phase"

try {
    switch ($phase) {
        'tools' {
            Write-Host '=== Docker'
            & (Join-Path $SetupFolder 'InstallOrUpdateDockerEngine.ps1') -Force -envScope 'Machine' -dataRoot 'C:\d'

            Write-Host '=== Build tools'
            & (Join-Path $SetupFolder 'install-tools.ps1')

            Set-Content -Path $phaseFile -Value 'agents'
            Write-Host 'Tools installed. Restarting before the agents are registered.'
            Stop-Transcript
            Restart-Computer -Force
            exit 0
        }
        'agents' {
            Write-Host '=== Agents'
            $settingsFile = Join-Path $SetupFolder 'agent-settings.json'
            & (Join-Path $SetupFolder 'SetupAgents.ps1') -SettingsFile $settingsFile

            Remove-Item -Path $settingsFile -Force
            Set-Content -Path $phaseFile -Value 'done'
            Unregister-ScheduledTask -TaskName 'B2FBuildAgentSetup' -Confirm:$false
            Write-Host 'Build agent setup finished.'
        }
        default {
            Unregister-ScheduledTask -TaskName 'B2FBuildAgentSetup' -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Host "SETUP FAILED in phase '$phase': $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    Write-Host 'The task runs again at the next startup.'
    Stop-Transcript
    exit 1
}
Stop-Transcript
