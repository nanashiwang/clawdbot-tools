#requires -Version 5.1
$ErrorActionPreference = "Stop"

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$Default
    )
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    $value = $value.Trim().ToLowerInvariant()
    return @("y", "yes").Contains($value)
}

function Resolve-CLI {
    $openclaw = Get-Command "openclaw" -ErrorAction SilentlyContinue
    if ($openclaw) {
        return @{ Name = "openclaw"; Mode = "native" }
    }

    $clawdbot = Get-Command "clawdbot" -ErrorAction SilentlyContinue
    if ($clawdbot) {
        return @{ Name = "clawdbot"; Mode = "native" }
    }

    $wsl = Get-Command "wsl" -ErrorAction SilentlyContinue
    if ($wsl) {
        $useWsl = Read-YesNo -Prompt "未检测到 openclaw/clawdbot，是否通过 WSL 执行" -Default "y"
        if ($useWsl) {
            return @{ Name = "openclaw"; Mode = "wsl" }
        }
    }

    Write-Error "未检测到 openclaw/clawdbot CLI。请先安装或在 WSL 内安装。"
    exit 1
}

function Invoke-CLI {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cli,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args
    )
    if ($Cli.Mode -eq "wsl") {
        & wsl --exec $Cli.Name @Args
    } else {
        & $Cli.Name @Args
    }
    if ($LASTEXITCODE -ne 0) {
        throw "命令执行失败：$($Cli.Name) $($Args -join ' ')"
    }
}

Write-Host "Clawdbot 后台运行配置向导"
Write-Host "该向导会安装/启动 Gateway 服务，使其以守护进程方式稳定运行。"

$cli = Resolve-CLI
Write-Host "使用 CLI：$($cli.Name)（模式：$($cli.Mode)）"

$useWizard = Read-YesNo -Prompt "是否运行 onboarding 并安装守护进程（推荐）" -Default "y"
if ($useWizard) {
    Invoke-CLI $cli "onboard" "--install-daemon"
} else {
    $installSvc = Read-YesNo -Prompt "是否直接安装 Gateway 服务" -Default "y"
    if ($installSvc) {
        Invoke-CLI $cli "gateway" "install"
    } else {
        Write-Host "已取消安装。"
        exit 0
    }
}

$startSvc = Read-YesNo -Prompt "是否立即启动 Gateway 服务" -Default "y"
if ($startSvc) {
    Invoke-CLI $cli "gateway" "start"
}

$showStatus = Read-YesNo -Prompt "是否查看 Gateway 状态" -Default "y"
if ($showStatus) {
    Invoke-CLI $cli "gateway" "status"
}

Write-Host ""
Write-Host "常用命令："
Write-Host "  $($cli.Name) gateway status"
Write-Host "  $($cli.Name) gateway restart"
Write-Host "  $($cli.Name) logs --follow"
Write-Host ""
Write-Host "Linux/WSL2 提示：若退出登录后服务会停止，请执行："
Write-Host "  sudo loginctl enable-linger \$USER"
