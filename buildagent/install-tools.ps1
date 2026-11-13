<#
.SYNOPSIS
    Installs every tool the build agent needs. Called by postboot.ps1 after Docker.

.DESCRIPTION
    Based on additional-installforbuildagent.ps1 from microsoft/nav-arm-templates (MIT, see
    THIRD-PARTY-NOTICES.md), extended with what the AI worker pipeline needs.

    Every step runs on its own: a step that fails is logged and the rest continue. The result of
    each step is written to C:\B2FSetup\tools-summary.txt.

    Differences from Microsoft's script:
      - PowerShell 7 comes from Microsoft's own installer (install-powershell.ps1 -UseMSI). The
        Chocolatey 'pwsh' package loops forever in its process tree check when run as SYSTEM at
        startup, which blocks the whole setup.
      - The .NET runtimes the AL tools need (8.0, 10.0) are installed explicitly; Chocolatey's
        'dotnet' only brings the newest one.
      - Added: Node.js, Claude Code, BcContainerHelper, Python with the document libraries, jq,
        the AL Language extension, CLAUDE_CODE_GIT_BASH_PATH.
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SetupFolder = 'C:\B2FSetup'
$summaryFile = Join-Path $SetupFolder 'tools-summary.txt'
$choco       = 'C:\ProgramData\chocolatey\bin\choco.exe'
$npmPrefix   = 'C:\ProgramData\npm-global'

# .NET runtimes the AL compiler and altool.exe of the supported AL Language versions run on.
# Add a channel here when a new AL Language version moves to a new .NET major version.
$DotnetRuntimeChannels = @('8.0', '10.0')
$results     = [System.Collections.Generic.List[string]]::new()

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Add-MachinePath([string] $Folder) {
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ((";$path;") -notlike "*;$Folder;*") {
        [Environment]::SetEnvironmentVariable('Path', "$path;$Folder", 'Machine')
    }
    Update-SessionPath
}

function Invoke-Step([string] $Name, [scriptblock] $Action) {
    Write-Host "--- $Name"
    $started = Get-Date
    try {
        & $Action
        $results.Add(('OK      {0,-34} {1,4:n0}s' -f $Name, ((Get-Date) - $started).TotalSeconds))
    }
    catch {
        Write-Host "FAILED: $Name - $($_.Exception.Message)"
        $results.Add(('FAILED  {0,-34} {1}' -f $Name, $_.Exception.Message))
    }
}

# Chocolatey packages; 1641 and 3010 mean "installed, restart needed", which the setup does anyway.
function Install-ChocoPackage([string] $Package, [string[]] $ExtraArgs = @()) {
    & $choco install $Package -y --no-progress @ExtraArgs
    if ($LASTEXITCODE -notin 0, 1641, 3010) { throw "choco install $Package returned $LASTEXITCODE" }
    Update-SessionPath
}

# --- PowerShell modules ---------------------------------------------------------------------------
Invoke-Step 'NuGet provider and PSGallery' {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.208 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}
Invoke-Step 'Az module' { Install-Module Az -Scope AllUsers -Force -AllowClobber }
Invoke-Step 'BcContainerHelper module' { Install-Module BcContainerHelper -Scope AllUsers -Force -AllowClobber }

# --- Chocolatey and packages ----------------------------------------------------------------------
Invoke-Step 'Chocolatey' {
    if (-not (Test-Path $choco)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }
    & $choco feature enable -n allowGlobalConfirmation
    Update-SessionPath
}
Invoke-Step 'Git'                      { Install-ChocoPackage git @('--params', '/NoAutoCrlf') }
Invoke-Step 'Microsoft Edge'           { Install-ChocoPackage microsoft-edge }
Invoke-Step 'Visual Studio Code'       { Install-ChocoPackage vscode }
Invoke-Step '7-Zip'                    { Install-ChocoPackage 7zip }
Invoke-Step 'GitHub CLI'               { Install-ChocoPackage gh }
Invoke-Step 'Visual C++ Redistributable' { Install-ChocoPackage vcredist140 }
Invoke-Step '.NET runtime'             { Install-ChocoPackage dotnet }
Invoke-Step '.NET SDK'                 { Install-ChocoPackage dotnet-sdk }

# The 'dotnet' package above installs only the newest runtime, and .NET does not roll forward to a
# newer major version: the AL tools need their own (altool.exe of AL 18 needs exactly 10.0).
Invoke-Step '.NET runtimes for AL tools' {
    $installer = Join-Path $SetupFolder 'dotnet-install.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
    foreach ($channel in $DotnetRuntimeChannels) {
        & $installer -Channel $channel -Runtime dotnet -InstallDir 'C:\Program Files\dotnet' -NoPath
    }
    $runtimes = & 'C:\Program Files\dotnet\dotnet.exe' --list-runtimes
    foreach ($channel in $DotnetRuntimeChannels) {
        if (-not ($runtimes -match "Microsoft\.NETCore\.App $([regex]::Escape($channel))\.")) { throw ".NET $channel runtime missing after the install" }
    }
}
Invoke-Step 'Node.js LTS'              { Install-ChocoPackage nodejs-lts }
Invoke-Step 'Python 3.12'              { Install-ChocoPackage python312 }
Invoke-Step 'jq'                       { Install-ChocoPackage jq }

# --- PowerShell 7 (not through Chocolatey, see the header) ----------------------------------------
Invoke-Step 'PowerShell 7' {
    $installer = Join-Path $SetupFolder 'install-powershell.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/install-powershell.ps1' -OutFile $installer
    & $installer -UseMSI -Quiet
    if (-not (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe')) { throw 'pwsh.exe not found after the install' }
    Update-SessionPath
}

# --- Configuration --------------------------------------------------------------------------------
Invoke-Step 'nuget.org source for dotnet' {
    $sources = & dotnet nuget list source
    if (-not ($sources | Where-Object { $_.Trim() -eq 'https://api.nuget.org/v3/index.json' })) {
        & dotnet nuget add source https://api.nuget.org/v3/index.json --name nuget.org
    }
}

Invoke-Step 'Python libraries' {
    $python = Get-ChildItem 'C:\Python3*\python.exe', 'C:\Program Files\Python3*\python.exe' -ErrorAction SilentlyContinue |
              Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
    if (-not $python) { throw 'python.exe not found' }
    & $python -m pip install --upgrade pip python-docx openpyxl lxml pypdf
    if ($LASTEXITCODE -ne 0) { throw "pip returned $LASTEXITCODE" }
}

# Invoke-WorkItemAgent.ps1 looks for claude.exe under this prefix first.
Invoke-Step 'Claude Code' {
    & 'C:\Program Files\nodejs\npm.cmd' install -g '@anthropic-ai/claude-code' --prefix $npmPrefix
    if ($LASTEXITCODE -ne 0) { throw "npm returned $LASTEXITCODE" }
    Add-MachinePath $npmPrefix
}

# Claude Code runs its shell commands through Git Bash on Windows.
Invoke-Step 'Git Bash for Claude Code' {
    $bash = 'C:\Program Files\Git\bin\bash.exe'
    if (-not (Test-Path $bash)) { throw "$bash not found" }
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $bash, 'Machine')
}

# Installed for SYSTEM, the account the agents run as; Compile-App.ps1 looks for alc.exe here first.
Invoke-Step 'AL Language extension' {
    & 'C:\Program Files\Microsoft VS Code\bin\code.cmd' --install-extension ms-dynamics-smb.al --force
    if ($LASTEXITCODE -ne 0) { throw "code --install-extension returned $LASTEXITCODE" }
}

# --- Summary --------------------------------------------------------------------------------------
$results | Set-Content -Path $summaryFile -Encoding UTF8
Write-Host '=== Tools summary'
$results | ForEach-Object { Write-Host $_ }
