# Build agent

A Windows Server 2022 VM that runs Azure DevOps pipelines building Business Central apps with
BcContainerHelper. Several agents share one machine, so it runs that many pipelines in parallel.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Filtererdogan%2FB2F_AzureTemplates%2Fbuildagent-v4%2Fbuildagent%2Fbuildagent.json)

## What gets installed

| Group | Tools |
|---|---|
| Containers | Windows Containers feature, Docker Engine (data root `C:\d`, process isolation) |
| PowerShell | PowerShell 7, Az module, BcContainerHelper module |
| Build tools | Git, .NET runtime and SDK (latest), .NET and ASP.NET Core 8.0 and 10.0 runtimes for the AL tools, Visual C++ Redistributable, 7-Zip, GitHub CLI, jq |
| Editors | Visual Studio Code with the AL Language extension, Microsoft Edge |
| AI worker | Node.js LTS, Claude Code (`C:\ProgramData\npm-global`), Python 3.12 with python-docx, openpyxl, lxml, pypdf; `CLAUDE_CODE_GIT_BASH_PATH` |
| Agents | Latest Azure DevOps agent, `agentCount` times, as services running as SYSTEM |

## Before deploying

- **Quota.** The subscription needs vCPU quota for the size's family in the chosen region, e.g.
  *Standard EASv5 Family vCPUs* >= 8 for `Standard_E8as_v5`, plus *Total Regional vCPUs*.
  Request it under Subscriptions > Usage + quotas.
- **Token.** A personal access token with the scope *Agent Pools (Read & manage)*. It is passed in
  the extension's protected (encrypted) settings and deleted from the VM once the agents are
  registered. It can expire after that; the agents use their own credentials.
- **Same VM name again?** Delete the old resource group first: the DNS label of the public IP must
  be unique in the region. The agents are named `<vmName>-1`, `<vmName>-2`, ... and registered
  with `--replace`, so they take over the old agents of the same name in the pool.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `vmName` | | 3-15 characters |
| `vmSize` | `Standard_E8as_v5` | 8 vCPU / 64 GB fits two parallel BC builds |
| `osDiskSizeGB` | 256 | Docker images and the artifact cache |
| `osDiskType` | `Premium_LRS` | |
| `useHybridBenefit` | `true` | Needs licences with Software Assurance |
| `adminUsername` / `adminPassword` | `vmadmin` / | |
| `remoteDesktopAccess` | `-` | Comma-separated IPs or CIDR ranges for RDP; `-` opens no port; `*` opens it to the whole internet (not recommended) |
| `organization` | | `https://dev.azure.com/<organization>` |
| `pool` | | Agent pool name |
| `token` | | See above |
| `agentCount` | 2 | Parallel pipelines on this VM |
| `agentUrl` | empty | Empty = latest Windows x64 agent of the organization |
| `scriptsBaseUrl` | this repo at the current tag | Change only to test another tag or a fork |

## What happens after the deployment

The deployment finishes in about 10 minutes, but the machine is not ready yet: the setup goes on
across two restarts and takes **45-60 minutes** in total.

| Stage | What runs | Log |
|---|---|---|
| Extension | Enables Containers, downloads the scripts, registers the task, restarts | `C:\B2FSetup\init.log` |
| After restart 1 | Docker, then every tool; restarts | `C:\B2FSetup\postboot.log`, `C:\B2FSetup\tools-summary.txt` |
| After restart 2 | Registers the agents, deletes the token, removes the task | `C:\B2FSetup\postboot.log` |

**The machine is ready when its agents show up as Online in the pool.** They are registered last
on purpose, so no pipeline lands on a half-installed machine.

## When something goes wrong

- `C:\B2FSetup\phase.txt` shows the stage the setup is in: `tools`, `agents` or `done`.
- A stage that fails stays where it is and runs again at the next start of the VM; the reason is
  at the end of `C:\B2FSetup\postboot.log`. Fix the cause and restart the VM.
- A single tool that fails does not stop the setup. `C:\B2FSetup\tools-summary.txt` lists each tool
  as `OK` or `FAILED` with the reason.
- The extension's own output: VM > Extensions + applications > initbuildagent > View detailed
  status.

Without RDP, read the logs with VM > Run command > RunPowerShellScript:

```powershell
Get-Content C:\B2FSetup\phase.txt
Get-Content C:\B2FSetup\tools-summary.txt -ErrorAction SilentlyContinue
Get-Content C:\B2FSetup\postboot.log -Tail 40
```
