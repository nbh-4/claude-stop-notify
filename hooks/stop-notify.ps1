# Claude Code Stop Hook
# stdin 읽기 → 대화 분석 → Calendar 소리 + WinRT 토스트

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

try {
    $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $rawInput = $reader.ReadToEnd()
    $hookData = $rawInput | ConvertFrom-Json
} catch { exit 0 }

if ($hookData.stop_hook_active -eq $true) { exit 0 }

# ── 설정 로드 ──
$configPath = Join-Path $PSScriptRoot 'config.json'
$cfg = @{ sound = 'C:\Windows\Media\Windows Notify Calendar.wav'; appName = 'Claude Code'; toastDuration = 'long'; maxSummaryLength = 2000; title = '🦀 Clawd' }
if (Test-Path $configPath) {
    try {
        $userCfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $userCfg.PSObject.Properties) { $cfg[$prop.Name] = $prop.Value }
    } catch {}
}

$project = Split-Path -Leaf $hookData.cwd

# ── 대화 기록 분석 ──
$summary = "작업이 완료되었습니다!"
$stats = ""
$tokenInfo = ""
$timeInfo = ""

try {
    $tp = $hookData.transcript_path
    if ($tp -and (Test-Path $tp)) {
        $lines = Get-Content $tp -Encoding UTF8
        $allText = $lines -join "`n"

        # 도구 횟수
        $editCount = ([regex]::Matches($allText, '"name"\s*:\s*"Edit"')).Count
        $writeCount = ([regex]::Matches($allText, '"name"\s*:\s*"Write"')).Count
        $bashCount = ([regex]::Matches($allText, '"name"\s*:\s*"Bash"')).Count
        $readCount = ([regex]::Matches($allText, '"name"\s*:\s*"Read"')).Count
        $searchCount = ([regex]::Matches($allText, '"name"\s*:\s*"(Grep|Glob|WebSearch)"')).Count

        $sp = @()
        if ($editCount -gt 0) { $sp += "수정 $editCount" }
        if ($writeCount -gt 0) { $sp += "생성 $writeCount" }
        if ($bashCount -gt 0) { $sp += "명령 $bashCount" }
        if ($readCount -gt 0) { $sp += "읽기 $readCount" }
        if ($searchCount -gt 0) { $sp += "검색 $searchCount" }
        if ($sp.Count -gt 0) { $stats = $sp -join " | " }

        # 토큰 (마지막 응답만)
        $totalTokens = 0
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '"type"\s*:\s*"assistant"') {
                try {
                    $obj = $lines[$i] | ConvertFrom-Json
                    if ($obj.message.usage) {
                        $u = $obj.message.usage
                        $totalTokens = [int]$u.input_tokens + [int]$u.output_tokens + [int]$u.cache_read_input_tokens
                    }
                } catch {}
                break
            }
        }
        if ($totalTokens -ge 1000000) { $tokenInfo = "$([math]::Round($totalTokens/1000000,1))M tokens" }
        elseif ($totalTokens -ge 1000) { $tokenInfo = "$([math]::Round($totalTokens/1000,1))K tokens" }
        elseif ($totalTokens -gt 0) { $tokenInfo = "${totalTokens} tokens" }

        # 시간 (전체 세션 + 마지막 요청)
        $firstTs = $null; $lastTs = $null; $lastHumanTs = $null
        foreach ($line in $lines) {
            try {
                $obj = $line | ConvertFrom-Json
                if ($obj.timestamp) {
                    if (-not $firstTs) { $firstTs = [datetime]$obj.timestamp }
                    $lastTs = [datetime]$obj.timestamp
                    if ($obj.type -eq 'user' -and $line -notmatch '"tool_result"') { $lastHumanTs = [datetime]$obj.timestamp }
                }
            } catch {}
        }
        function FmtDur($d) {
            if ($d.TotalHours -ge 1) { "$([math]::Floor($d.TotalHours))시간 $($d.Minutes)분" }
            elseif ($d.TotalMinutes -ge 1) { if ($d.Seconds -gt 0) { "$([math]::Floor($d.TotalMinutes))분 $($d.Seconds)초" } else { "$([math]::Floor($d.TotalMinutes))분" } }
            else { "$([math]::Floor($d.TotalSeconds))초" }
        }
        if ($firstTs -and $lastTs) {
            $totalStr = FmtDur ($lastTs - $firstTs)
            if ($lastHumanTs -and $lastTs -gt $lastHumanTs) {
                $reqStr = FmtDur ($lastTs - $lastHumanTs)
                $timeInfo = "$totalStr (요청 $reqStr)"
            } else {
                $timeInfo = $totalStr
            }
        }

        # 마지막 Claude 응답 텍스트 (자연어 요약)
        $lastAssistantText = ""
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '"type"\s*:\s*"assistant"') {
                try {
                    $obj = $lines[$i] | ConvertFrom-Json
                    $textBlocks = $obj.message.content | Where-Object { $_.type -eq "text" }
                    if ($textBlocks) {
                        $combined = ($textBlocks | ForEach-Object { $_.text }) -join "`n"
                        if ($combined.Length -gt 0) {
                            $lastAssistantText = $combined
                            break
                        }
                    }
                } catch {}
            }
        }

        # 요약 조합
        if ($lastAssistantText) {
            # 마크다운 문법 제거
            $clean = $lastAssistantText -replace '\*\*', '' -replace '`([^`]*)`', '$1' -replace '#{1,6}\s*', '' -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
            if ($clean.Length -gt $cfg.maxSummaryLength) {
                $summary = $clean.Substring(0, $cfg.maxSummaryLength - 3) + "..."
            } else {
                $summary = $clean
            }
        }
    }
} catch {}

# ── XML 이스케이프 ──
function Esc($s) { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'","&apos;" -replace "`r","" -replace "`n","&#xA;" }

$safeProject = Esc $project
# attribution: 항상 하단 고정 (2줄)
$metaParts = @()
if ($tokenInfo) { $metaParts += $tokenInfo }
if ($timeInfo) { $metaParts += $timeInfo }
$line1 = if ($metaParts.Count -gt 0) { Esc ($metaParts -join " · ") } else { "" }
$line2 = if ($stats) { Esc $stats } else { "" }

$safeAttr = if ($line1 -and $line2) { "$line1&#xA;$line2" }
            elseif ($line1) { $line1 }
            elseif ($line2) { $line2 }
            else { "" }

$safeSummary = Esc $summary

$safeTitle = Esc $cfg.title
$toastXml = "<toast duration=`"$($cfg.toastDuration)`"><visual><binding template=`"ToastGeneric`"><text>$safeTitle — $safeProject</text><text hint-wrap=`"true`" hint-maxLines=`"50`">$safeSummary</text><text placement=`"attribution`">$safeAttr</text></binding></visual><audio silent=`"true`"/></toast>"

# ── 알림 소리 (별도 프로세스 — 훅 컨텍스트에서 오디오 접근 불가) ──
if ($cfg.sound) {
    Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"(New-Object System.Media.SoundPlayer '$($cfg.sound)').PlaySync()`"" -WindowStyle Hidden
}

# ── WinRT 토스트 ──
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
    $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $xml.LoadXml($toastXml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($cfg.appName).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
} catch {}

exit 0
