#requires -Version 5.1
$ErrorActionPreference = "Stop"

function Read-Default {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$Default
    )
    $input = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
    return $input.Trim()
}

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

function Get-ModelName {
    param([string]$ModelId)
    switch ($ModelId) {
        "gpt-5.2-codex" { return "GPT-5.2 Codex" }
        "gpt-5-codex"   { return "GPT-5 Codex" }
        default         { return $ModelId }
    }
}

function Ensure-Object {
    param(
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $Parent.PSObject.Properties[$Name]) {
        $Parent | Add-Member -NotePropertyName $Name -NotePropertyValue ([ordered]@{})
    }
    return $Parent.$Name
}

function Resolve-ClawdbotConfigPath {
    $candidates = @()
    if ($env:CLAWDBOT_CONFIG_PATH) {
        $candidates += $env:CLAWDBOT_CONFIG_PATH
    }
    if ($env:CLAWDBOT_STATE_DIR) {
        $candidates += (Join-Path $env:CLAWDBOT_STATE_DIR "clawdbot.json")
    }
    $candidates += (Join-Path $env:USERPROFILE ".clawdbot/clawdbot.json")

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

function Resolve-ClawdbotInstallRoot {
    $cmd = Get-Command "clawdbot" -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $binDir = Split-Path $cmd.Source -Parent
        $candidate = Join-Path $binDir "node_modules/clawdbot"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    try {
        $npmRoot = & npm root -g 2>$null
        if ($LASTEXITCODE -eq 0 -and $npmRoot) {
            $candidate = Join-Path $npmRoot "clawdbot"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    } catch {
        # ignore
    }

    $fallback = Join-Path $env:APPDATA "npm/node_modules/clawdbot"
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }
    return $null
}

$configPath = Resolve-ClawdbotConfigPath
if (-not $configPath) {
    Write-Error "未找到配置文件。请先运行 `clawdbot setup` 或 `clawdbot onboard` 初始化。"
    exit 1
}

$cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

$providerId = "openai-codex"
$cfg.models = Ensure-Object -Parent $cfg -Name "models"
$cfg.models.providers = Ensure-Object -Parent $cfg.models -Name "providers"
if (-not $cfg.models.providers.PSObject.Properties[$providerId]) {
    $cfg.models.providers | Add-Member -NotePropertyName $providerId -NotePropertyValue ([ordered]@{})
}
$provider = $cfg.models.providers.$providerId

$cfg.agents = Ensure-Object -Parent $cfg -Name "agents"
$cfg.agents.defaults = Ensure-Object -Parent $cfg.agents -Name "defaults"
$cfg.agents.defaults.models = Ensure-Object -Parent $cfg.agents.defaults -Name "models"
$cfg.agents.defaults.model = Ensure-Object -Parent $cfg.agents.defaults -Name "model"

$defaultBaseUrl = if ($provider.baseUrl) { $provider.baseUrl } else { "https://crss.nanashiwang.com/openai/v1" }
$defaultPrimary = $cfg.agents.defaults.model.primary
$defaultModelId = if ($defaultPrimary -and $defaultPrimary.StartsWith("$providerId/")) {
    $defaultPrimary.Substring($providerId.Length + 1)
} else {
    "gpt-5.2-codex"
}
$defaultAlias = if ($cfg.agents.defaults.models.PSObject.Properties["$providerId/$defaultModelId"]) {
    $cfg.agents.defaults.models."$providerId/$defaultModelId".alias
} else {
    "Codex"
}
$defaultThinking = if ($cfg.agents.defaults.thinkingDefault) { $cfg.agents.defaults.thinkingDefault } else { "off" }

Write-Host "Clawdbot 中转模型配置向导（不修改 Telegram 等通道配置）"

$baseUrl = Read-Default -Prompt "Base URL" -Default $defaultBaseUrl
$baseUrl = $baseUrl.TrimEnd("/")

$modelId = Read-Default -Prompt "模型 ID（例如 gpt-5.2-codex）" -Default $defaultModelId
$alias = Read-Default -Prompt "模型别名" -Default $defaultAlias

$thinkingAllowed = @("off", "minimal", "low", "medium", "high", "xhigh")
do {
    $thinkingDefault = Read-Default -Prompt "默认思考等级（off/minimal/low/medium/high/xhigh）" -Default $defaultThinking
    $thinkingDefault = $thinkingDefault.Trim().ToLowerInvariant()
} while (-not $thinkingAllowed.Contains($thinkingDefault))

$updateKey = Read-YesNo -Prompt "是否更新 API key" -Default "y"
if ($updateKey) {
    $secureKey = Read-Host "请输入 API key" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Error "API key 不能为空。"
        exit 1
    }
    $provider.apiKey = $apiKey
}

# Update provider config
$provider.baseUrl = $baseUrl
$provider.api = "openai-responses"
$provider.auth = "api-key"
$provider.models = @(
    @{
        id    = $modelId
        name  = (Get-ModelName -ModelId $modelId)
        input = @("text")
    }
)

# Update agent defaults
$cfg.agents.defaults.models."$providerId/$modelId" = @{ alias = $alias }
$cfg.agents.defaults.model.primary = "$providerId/$modelId"
$cfg.agents.defaults.thinkingDefault = $thinkingDefault

# Backup
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = "$configPath.bak.$timestamp"
Copy-Item -LiteralPath $configPath -Destination $backupPath -Force | Out-Null

# Save
$cfg | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $configPath -Encoding UTF8

# Optional patch to avoid rs_ replay 404 for openai-responses
$applyPatch = Read-YesNo -Prompt "是否应用 openai-responses 兼容补丁（避免 rs_ 404，推荐）" -Default "y"
if ($applyPatch) {
    $installRoot = Resolve-ClawdbotInstallRoot
    $patchPath = $null
    if ($installRoot) {
        $patchPath = Join-Path $installRoot "node_modules/@mariozechner/pi-ai/dist/providers/transform-messages.js"
    }
    if ($patchPath -and (Test-Path -LiteralPath $patchPath)) {
        $content = Get-Content -LiteralPath $patchPath -Raw
        if ($content -match "model\.api !== \"openai-responses\"") {
            Write-Host "补丁已存在，跳过。"
        } else {
            $patched = $content -replace "if \\(isSameModel && block\\.thinkingSignature\\)", "if (isSameModel && block.thinkingSignature && model.api !== \"openai-responses\")"
            Set-Content -LiteralPath $patchPath -Value $patched -Encoding UTF8
            Write-Host "补丁已应用: $patchPath"
        }
    } else {
        Write-Warning "未找到 Clawdbot 安装路径，已跳过补丁。"
    }
}

Write-Host "配置完成。请重启 Clawdbot：pm2 restart \"clawdbot\""
