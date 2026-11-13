<#
.SYNOPSIS
    Registers the Azure DevOps agents. Called by postboot.ps1 as the last step of the setup.

.DESCRIPTION
    Based on SetupAgents.ps1 from microsoft/nav-arm-templates (MIT, see THIRD-PARTY-NOTICES.md).
    Azure DevOps only; Microsoft's GitHub runner and agents-inside-Docker paths are not carried over.

    Agents are named <vmName>-<n> and registered with --replace, so redeploying a VM with the same
    name takes over its old agents in the pool instead of leaving offline duplicates behind. An
    agent folder that is already configured is skipped, so the script can safely run again.
#>
param(
    [Parameter(Mandatory = $true)] [string] $SettingsFile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

$settings  = Get-Content -Path $SettingsFile -Raw | ConvertFrom-Json
$authValue = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($settings.token)"))
$headers   = @{ Authorization = "Basic $authValue" }

$agentUrl = $settings.agentUrl
if (-not $agentUrl) {
    Write-Host 'Looking up the latest Windows x64 agent'
    $packages = Invoke-RestMethod -UseBasicParsing -Headers $headers `
                -Uri "$($settings.organization)/_apis/distributedtask/packages/agent?platform=win-x64&`$top=1&api-version=7.1"
    $agentUrl = $packages.value[0].downloadUrl
    if (-not $agentUrl) { throw 'The organization did not return an agent download URL. Check the organization URL and the token.' }
}
Write-Host "Agent package: $agentUrl"

$agentZip = 'C:\B2FSetup\agent.zip'
Invoke-WebRequest -UseBasicParsing -Uri $agentUrl -OutFile $agentZip

foreach ($index in 1..([int] $settings.agentCount)) {
    $agentName   = "$($settings.vmName)-$index"
    $agentFolder = "C:\Agents\A$index"

    if (Test-Path (Join-Path $agentFolder '.agent')) {
        Write-Host "$agentName is already configured in $agentFolder"
        continue
    }

    Write-Host "Registering $agentName in pool '$($settings.pool)'"
    if (Test-Path $agentFolder) { Remove-Item $agentFolder -Recurse -Force }
    New-Item -ItemType Directory -Path $agentFolder -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($agentZip, $agentFolder)

    Push-Location $agentFolder
    try {
        & .\config.cmd --unattended `
            --url $settings.organization `
            --auth PAT --token $settings.token `
            --pool $settings.pool `
            --agent $agentName --replace `
            --work (Join-Path $agentFolder '_work') `
            --runAsService --windowsLogonAccount 'NT AUTHORITY\SYSTEM'
        if ($LASTEXITCODE -ne 0) { throw "config.cmd for $agentName returned $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}

Remove-Item $agentZip -Force -ErrorAction SilentlyContinue
Write-Host "$($settings.agentCount) agent(s) registered."
