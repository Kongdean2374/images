#requires -Version 5.1
<#
  柴柴點歌機 ↔ GitHub 編輯區 同步工具

  用法（在 PowerShell 裡執行，沒加 -Mode 會跳出選單）：
    powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Downloads\jukebox-sync.ps1"
    ... -Mode push   上傳：把 G:\點歌 目前的檔案送到編輯區，給 Claude 修改
    ... -Mode pull   下載：把 Claude 改好的檔案拿回 G:\點歌（覆蓋前會先備份舊檔）

  可選參數：
    -Root "G:\點歌"
    -RepoUrl "https://github.com/Kongdean2374/jukebox-work.git"
    -Force           略過安全檢查（只有 Claude 叫你加的時候才加）

  規則：
    - 只同步 git 會管理的檔案（遵守 .gitignore），另外一定排除 secret\、app-config.json、.wrangler\。
    - 編輯區的 .claude-work\ 和 .gitattributes 是 Claude 自己用的，不會拿回 G:\點歌。
    - 下載時，被覆蓋或刪除的舊檔會先複製到「G:\點歌-同步備份\時間\」。
    - 如果 G:\點歌 裡某個檔案在上傳之後被你改過，Claude 也改了同一個檔案，下載會停下來，不會蓋掉你的修改。
#>
param(
    [ValidateSet('', 'push', 'pull')]
    [string]$Mode = '',
    [string]$Root = 'G:\點歌',
    [string]$RepoUrl = 'https://github.com/Kongdean2374/jukebox-work.git',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$sep = [IO.Path]::DirectorySeparatorChar

$WorkDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'jukebox-work'
$BaseFile = Join-Path $WorkDir '.git\jukebox-sync-base'
$WorkspaceOnly = @('.claude-work/', '.gitattributes')

function Invoke-Git {
    $out = & git @args
    if ($LASTEXITCODE -ne 0) { throw "git 指令失敗：git $($args -join ' ')" }
    return $out
}

function Split-Z($s) { return @(($s -join '') -split "`0" | Where-Object { $_ -ne '' }) }

function Test-WorkspaceOnly([string]$p) {
    foreach ($w in $WorkspaceOnly) {
        if ($w.EndsWith('/')) { if ($p.StartsWith($w)) { return $true } }
        elseif ($p -eq $w) { return $true }
    }
    return $false
}

function Test-NeverSync([string]$p) {
    $l = $p.ToLower()
    return ($l -match '(^|/)secret/') -or ($l -match '(^|/)node_modules/') -or ($l -match '(^|/)\.wrangler/') -or
        ($l -eq 'yt-music-host/config/app-config.json') -or ($l -match '\.(log|bak|tmp)$')
}

function To-Local([string]$p) { return Join-Path $Root ($p -replace '/', [string]$sep) }
function To-Work([string]$p) { return Join-Path $WorkDir ($p -replace '/', [string]$sep) }

function Test-RemoteMain {
    $heads = Invoke-Git -C $WorkDir ls-remote --heads origin main
    return [bool]($heads -join '')
}

function Initialize-WorkDir {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw '找不到 git。請先安裝 Git for Windows：https://git-scm.com/download/win （安裝時全部用預設值），裝好後重開 PowerShell 再執行。'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { throw "找不到 $Root\.git，確認 -Root 是點歌專案資料夾。" }
    if (-not (Test-Path -LiteralPath (Join-Path $WorkDir '.git'))) {
        Write-Host "第一次使用，下載編輯區到 $WorkDir ..."
        Invoke-Git clone $RepoUrl $WorkDir | Out-Null
    }
    Invoke-Git -C $WorkDir config core.autocrlf false | Out-Null
    Invoke-Git -C $WorkDir config core.quotepath false | Out-Null
    Invoke-Git -C $WorkDir config user.name 'jukebox-sync' | Out-Null
    Invoke-Git -C $WorkDir config user.email 'jukebox-sync@localhost' | Out-Null
    Invoke-Git -C $WorkDir remote set-url origin $RepoUrl | Out-Null
    Invoke-Git -C $WorkDir fetch origin | Out-Null
}

function Get-Base { if (Test-Path -LiteralPath $BaseFile) { return (Get-Content -LiteralPath $BaseFile -Raw).Trim() } return $null }

# ---------------- 上傳 ----------------
function Invoke-Push {
    Initialize-WorkDir
    $hasMain = Test-RemoteMain
    $base = Get-Base

    if ($hasMain -and -not $Force) {
        if ($base) {
            $pending = Split-Z (Invoke-Git -C $WorkDir diff --name-only -z $base origin/main)
            $pending = @($pending | Where-Object { -not (Test-WorkspaceOnly $_) })
            if ($pending.Count -gt 0) {
                Write-Host ''
                Write-Host '編輯區裡有 Claude 改好、但還沒下載回來的檔案：' -ForegroundColor Yellow
                $pending | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
                throw '請先執行「下載」(-Mode pull)，再上傳。這樣才不會把 Claude 的修改蓋掉。'
            }
        } else {
            $existing = Split-Z (Invoke-Git -C $WorkDir ls-tree -r --name-only -z origin/main)
            $existing = @($existing | Where-Object { -not (Test-WorkspaceOnly $_) -and $_ -ne 'README.md' })
            if ($existing.Count -gt 0) {
                throw '編輯區已經有專案檔案，但這台電腦沒有同步紀錄。請把這段訊息告訴 Claude。'
            }
        }
    }

    if ($hasMain) { Invoke-Git -C $WorkDir checkout -q -B main origin/main | Out-Null }
    else { Invoke-Git -C $WorkDir symbolic-ref HEAD refs/heads/main | Out-Null }

    Write-Host "讀取 $Root 的檔案清單 ..."
    $list = Split-Z (Invoke-Git -c 'safe.directory=*' -C $Root ls-files -c -o --exclude-standard -z)
    $files = @($list | Where-Object { -not (Test-NeverSync $_) -and -not (Test-WorkspaceOnly $_) -and (Test-Path -LiteralPath (To-Local $_) -PathType Leaf) } | Sort-Object -Unique)
    $keep = @{}
    foreach ($f in $files) { $keep[$f] = $true }

    # 編輯區裡多出來的檔案（本機已經刪掉的）跟著刪
    $inWork = Split-Z (Invoke-Git -C $WorkDir ls-files -z)
    foreach ($p in $inWork) {
        if ((Test-WorkspaceOnly $p) -or $keep.ContainsKey($p)) { continue }
        Remove-Item -LiteralPath (To-Work $p) -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in $files) {
        $dst = To-Work $f
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath (To-Local $f) -Destination $dst -Force
    }
    $ga = Join-Path $WorkDir '.gitattributes'
    if (-not (Test-Path -LiteralPath $ga)) { [IO.File]::WriteAllText($ga, "* -text`n") }

    Invoke-Git -C $WorkDir add -A | Out-Null
    $changed = Invoke-Git -C $WorkDir status --porcelain
    if ($changed) {
        Invoke-Git -C $WorkDir commit -q -m "本機同步 $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-Null
        Write-Host '上傳到 GitHub（第一次可能會跳出 GitHub 登入視窗）...'
        Invoke-Git -C $WorkDir push -q -u origin main | Out-Null
        Write-Host ''
        Write-Host "完成：上傳 $($files.Count) 個檔案。可以叫 Claude 開始改了。" -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host '完成：編輯區已經是最新的，不用上傳。' -ForegroundColor Green
    }
    Set-Content -LiteralPath $BaseFile -Value (Invoke-Git -C $WorkDir rev-parse HEAD) -Encoding ASCII
}

# ---------------- 下載 ----------------
function Invoke-Pull {
    Initialize-WorkDir
    $base = Get-Base
    if (-not $base) { throw '這台電腦還沒上傳過，請先執行「上傳」(-Mode push)。' }
    $target = (Invoke-Git -C $WorkDir rev-parse origin/main).Trim()
    if ($target -eq $base) { Write-Host '編輯區沒有新的修改。' -ForegroundColor Green; return }

    $raw = Split-Z (Invoke-Git -C $WorkDir diff --no-renames --name-status -z $base $target)
    $changes = @()
    for ($i = 0; $i -lt $raw.Count; $i += 2) {
        $p = $raw[$i + 1]
        if (Test-WorkspaceOnly $p) { continue }
        if (Test-NeverSync $p) { Write-Host "略過（不同步的檔案）：$p" -ForegroundColor Yellow; continue }
        $changes += [pscustomobject]@{ Status = $raw[$i].Substring(0, 1); Path = $p }
    }

    # 檢查：本機檔案從上次上傳後有沒有被改過
    $conflicts = @()
    $todo = @()
    foreach ($c in $changes) {
        $local = To-Local $c.Path
        $exists = Test-Path -LiteralPath $local -PathType Leaf
        $localHash = if ($exists) { (Invoke-Git -C $WorkDir hash-object --no-filters $local).Trim() } else { $null }
        $baseHash = if ($c.Status -eq 'A') { $null } else { (Invoke-Git -C $WorkDir rev-parse "${base}:$($c.Path)").Trim() }
        $newHash = if ($c.Status -eq 'D') { $null } else { (Invoke-Git -C $WorkDir rev-parse "${target}:$($c.Path)").Trim() }
        if ($localHash -eq $newHash) { continue }
        if ($localHash -ne $baseHash) { $conflicts += $c.Path }
        $todo += $c
    }
    if ($conflicts.Count -gt 0 -and -not $Force) {
        Write-Host ''
        Write-Host '這些檔案在上次上傳之後，你在本機改過，Claude 也改了：' -ForegroundColor Yellow
        $conflicts | ForEach-Object { Write-Host "  $_" }
        throw '為了不蓋掉你的修改，這次沒有下載任何檔案。請把這段訊息告訴 Claude。'
    }

    Invoke-Git -C $WorkDir checkout -q -B main $target | Out-Null

    $backup = Join-Path ((Split-Path -Parent $Root)) ("$(Split-Path -Leaf $Root)-同步備份" + $sep + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    foreach ($c in $todo) {
        $local = To-Local $c.Path
        if (Test-Path -LiteralPath $local -PathType Leaf) {
            $bk = Join-Path $backup ($c.Path -replace '/', [string]$sep)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bk) | Out-Null
            Copy-Item -LiteralPath $local -Destination $bk -Force
        }
        if ($c.Status -eq 'D') {
            Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
            Write-Host "  刪除 $($c.Path)"
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $local) | Out-Null
            Copy-Item -LiteralPath (To-Work $c.Path) -Destination $local -Force
            Write-Host "  $(if ($c.Status -eq 'A') { '新增' } else { '更新' }) $($c.Path)"
        }
    }
    Set-Content -LiteralPath $BaseFile -Value $target -Encoding ASCII

    Write-Host ''
    Write-Host "完成：$($todo.Count) 個檔案已更新到 $Root。" -ForegroundColor Green
    if (Test-Path -LiteralPath $backup) { Write-Host "舊檔備份在：$backup" }
    $log = Invoke-Git -C $WorkDir log --format='  %s' "$base..$target"
    Write-Host 'Claude 這次的修改：'
    $log | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host '接下來請執行 工具\3 檢查與修復\自我檢查.cmd，把結果告訴 Claude。'
}

try {
    if (-not $Mode) {
        Write-Host '柴柴點歌機 同步工具'
        Write-Host '  1  上傳（本機 → 編輯區，給 Claude 改）'
        Write-Host '  2  下載（編輯區 → 本機，拿回 Claude 改好的檔案）'
        $ans = Read-Host '請輸入 1 或 2'
        $Mode = switch ($ans) { '1' { 'push' } '2' { 'pull' } default { throw '沒有選擇，結束。' } }
    }
    if ($Mode -eq 'push') { Invoke-Push } else { Invoke-Pull }
} catch {
    Write-Host ''
    Write-Host "錯誤：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
