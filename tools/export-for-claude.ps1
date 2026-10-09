#requires -Version 5.1
<#
  把「點歌」專案匯出成 txt，給 Claude 分析用。

  用法（在 PowerShell 裡執行）：
    powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Downloads\export-for-claude.ps1"

  可選參數：
    -Root "G:\點歌"        專案資料夾（預設 G:\點歌）
    -OutDir "D:\輸出"      輸出資料夾（預設 桌面\點歌分析）
    -MaxFileKB 400        單一檔案超過這個大小就不收錄內容
    -PartMB 4             原始碼每份 txt 的大小上限

  產出：
    結構與大小.txt   資料夾大小、最大的檔案、每個檔案收錄或略過的原因
    原始碼-01.txt …  收錄的原始碼內容

  不會收錄：secret\、node_modules\、.git\、app-config.json、.env、金鑰檔、
  一般 JSON 資料檔（帳號、紀錄等可能有個資），以及看起來像密碼或 token 的字串（會換成 ***）。
  這個腳本只讀取檔案，不會修改專案裡的任何東西。
#>
param(
    [string]$Root = 'G:\點歌',
    [string]$OutDir = (Join-Path ([Environment]::GetFolderPath('Desktop')) '點歌分析'),
    [int]$MaxFileKB = 400,
    [int]$PartMB = 4
)

$ErrorActionPreference = 'Stop'
$sep = [IO.Path]::DirectorySeparatorChar

if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "找不到資料夾：$Root" }
$Root = (Get-Item -LiteralPath $Root).FullName.TrimEnd($sep)

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Get-ChildItem -LiteralPath $OutDir -Filter '*.txt' -File | Remove-Item -Force

# 整個資料夾略過：只統計大小，不讀內容
$SkipDirs = @(
    'node_modules', '.git', 'secret', 'dist', 'build', 'out', 'release', '.cache', '.next',
    'coverage', 'logs', 'log', 'tmp', 'temp', '__pycache__', '.venv', 'venv',
    'backup', 'backups', '驗證截圖', '.vscode', '.idea'
)

# 可能含機密，或內容沒有分析價值
$SkipNamePatterns = @(
    'app-config.json', '.env', '.env.*', '*.pem', '*.key', '*.pfx', '*.p12', '*.crt',
    '.npmrc', '*password*', '*token*', '*secret*', '*credential*',
    'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', '*.min.js', '*.min.css', '*.map'
)

$TextExt = @(
    '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.vue', '.html', '.htm', '.css', '.scss',
    '.md', '.txt', '.cmd', '.bat', '.ps1', '.psm1', '.vbs', '.sh', '.py',
    '.yml', '.yaml', '.toml', '.ini', '.xml', '.gitignore', '.editorconfig'
)

# JSON 只收錄設定類，其他（帳號、紀錄、統計）可能有個資
$JsonAllowed = @(
    'package.json', 'defaults.json', 'tsconfig.json', 'jsconfig.json', 'manifest.json',
    'electron-builder.json', '.eslintrc.json', '.prettierrc.json'
)

function Format-Size([long]$b) {
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N1} KB' -f ($b / 1KB) }
    return "$b B"
}

function Get-SkipReason($r) {
    $name = $r.File.Name
    $ext = $r.File.Extension.ToLower()
    if ($r.SkipDir) { return "略過資料夾 $($r.SkipDir)" }
    foreach ($p in $SkipNamePatterns) { if ($name -like $p) { return '可能含機密或不需要' } }
    if ($ext -eq '.json') {
        if (($JsonAllowed -notcontains $name) -and ($name -notlike '*.schema.json') -and ($name -notlike '*.example.json')) {
            return 'JSON 資料檔（可能含個資）'
        }
    } elseif ($TextExt -notcontains $ext) {
        return '非文字檔'
    }
    if ($r.Size -gt ($MaxFileKB * 1KB)) { return "超過 $MaxFileKB KB" }
    return $null
}

function Protect-Secrets([string]$t) {
    $t = [regex]::Replace($t, '(?i)https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/[^\s"''<>`]+', 'https://discord.com/api/webhooks/***')
    $t = [regex]::Replace($t, '[\w-]{24,}\.[\w-]{6}\.[\w-]{27,}', '***')
    $t = [regex]::Replace($t, '(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|client[_-]?secret|webhook)[\w-]*["'']?\s*[:=]\s*)(["''])([A-Za-z0-9_\-\.\+/=:]{12,})\2', '$1$2***$2')
    return $t
}

Write-Host "掃描 $Root ..."
$all = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)

$rows = foreach ($f in $all) {
    $rel = $f.FullName.Substring($Root.Length + 1)
    $segs = $rel.Split($sep)
    $skipBy = $null
    for ($i = 0; $i -lt $segs.Length - 1; $i++) {
        if ($SkipDirs -contains $segs[$i]) { $skipBy = $segs[$i]; break }
    }
    $r = [pscustomobject]@{ File = $f; Rel = $rel; Segs = $segs; SkipDir = $skipBy; Size = $f.Length; Reason = $null }
    $r.Reason = Get-SkipReason $r
    $r
}
$rows = @($rows | Sort-Object Rel)

$totalSize = ($rows | Measure-Object Size -Sum).Sum
$dirCount = @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue).Count

# ---------- 結構與大小.txt ----------
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# 點歌 專案結構與大小')
$lines.Add("產生時間：$(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$lines.Add("專案資料夾：$Root")
$lines.Add("總計：$(Format-Size $totalSize)，$($rows.Count) 個檔案，$dirCount 個資料夾")
$lines.Add("有 .git：$(Test-Path -LiteralPath (Join-Path $Root '.git'))　有 .gitignore：$(Test-Path -LiteralPath (Join-Path $Root '.gitignore'))")
$lines.Add('')

function Add-SizeTable($title, $groups) {
    $lines.Add("## $title")
    $groups | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Size = ($_.Group | Measure-Object Size -Sum).Sum; Count = $_.Count }
    } | Sort-Object Size -Descending | ForEach-Object {
        $lines.Add(('{0,10}  {1,6} 個檔案  {2}' -f (Format-Size $_.Size), $_.Count, $_.Name))
    }
    $lines.Add('')
}

Add-SizeTable '第一層' ($rows | Group-Object { if ($_.Segs.Length -gt 1) { $_.Segs[0] + $sep } else { '(根目錄的檔案)' } })
Add-SizeTable '第二層（前 40 大）' ($rows | Where-Object { $_.Segs.Length -gt 2 } | Group-Object { ($_.Segs[0..1] -join $sep) + $sep } |
    Sort-Object { ($_.Group | Measure-Object Size -Sum).Sum } -Descending | Select-Object -First 40)
Add-SizeTable '略過的資料夾' ($rows | Where-Object { $_.SkipDir } | Group-Object {
    ($_.Segs[0..([array]::IndexOf($_.Segs, $_.SkipDir))] -join $sep) + $sep })

$lines.Add('## 最大的 30 個檔案')
$rows | Sort-Object Size -Descending | Select-Object -First 30 | ForEach-Object {
    $lines.Add(('{0,10}  {1}' -f (Format-Size $_.Size), $_.Rel))
}
$lines.Add('')

$lines.Add('## 檔案清單（略過資料夾裡的檔案不逐一列出）')
foreach ($r in $rows) {
    if ($r.SkipDir) { continue }
    $mark = if ($r.Reason) { "[略過：$($r.Reason)]" } else { '[收錄]' }
    $lines.Add(('{0,10}  {1}  {2}' -f (Format-Size $r.Size), $r.Rel, $mark))
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllLines((Join-Path $OutDir '結構與大小.txt'), $lines, $utf8Bom)

# ---------- 原始碼-NN.txt ----------
$included = @($rows | Where-Object { -not $_.Reason })
$part = 0
$partBytes = 0
$written = 0
$sw = $null
try {
    foreach ($r in $included) {
        try { $text = [IO.File]::ReadAllText($r.File.FullName, [Text.Encoding]::UTF8) } catch { continue }
        if ($text.IndexOf([char]0) -ge 0) { continue }
        $text = Protect-Secrets $text
        $block = "`r`n===== 檔案：$($r.Rel)（$(Format-Size $r.Size)）=====`r`n$text`r`n"
        $blockBytes = $utf8Bom.GetByteCount($block)
        if (($null -eq $sw) -or (($partBytes + $blockBytes) -gt ($PartMB * 1MB))) {
            if ($sw) { $sw.Close() }
            $part++
            $sw = New-Object IO.StreamWriter((Join-Path $OutDir ('原始碼-{0:D2}.txt' -f $part)), $false, $utf8Bom)
            $sw.Write("# 點歌 原始碼 第 $part 份`r`n")
            $partBytes = 0
        }
        $sw.Write($block)
        $partBytes += $blockBytes
        $written++
    }
} finally {
    if ($sw) { $sw.Close() }
}

Write-Host ''
Write-Host "完成：收錄 $written 個檔案，原始碼分成 $part 份。"
Write-Host "輸出位置：$OutDir"
Write-Host '請把資料夾裡所有 txt 傳給 Claude。傳之前可以先打開看一下，確認沒有不想給別人看的內容。'
if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { Start-Process explorer.exe $OutDir }
