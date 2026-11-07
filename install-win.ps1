# install-win.ps1 - install this modified dsh-infinite-gen-2 into a DSH profile.
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
# Run from the extracted source folder (do NOT run it from inside the installed
# copy under %USERPROFILE%\.dsh\plugins\, it would delete its own source).
param(
  [string]$Profile = 'desktop'
)

$ErrorActionPreference = 'Stop'
$pluginName = 'dsh-infinite-gen-2'
$root = Join-Path $env:USERPROFILE '.dsh'
$dst  = Join-Path $root "plugins\$pluginName"
$profDir = Join-Path $root "profiles\$Profile"
$pkgPath = Join-Path $profDir 'package.json'

function Step($m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   [!]  $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "   [X]  $m" -ForegroundColor Red }

Step "check environment"
if (-not (Test-Path $pkgPath)) {
  $found = @(Get-ChildItem (Join-Path $root 'profiles') -Directory -ErrorAction SilentlyContinue |
             Where-Object { Test-Path (Join-Path $_.FullName 'package.json') })
  if ($found.Count -eq 1) { $profDir = $found[0].FullName; $pkgPath = Join-Path $profDir 'package.json'; Warn "profile '$Profile' missing, using $($found[0].Name)" }
  else { Err "no profile found under $root\profiles; start the app once first"; exit 1 }
}
Ok "profile: $profDir"

function Resolve-Pnpm {
  $c = Get-Command pnpm -ErrorAction SilentlyContinue
  if ($c) { return @{ Exe = $c.Source; Args = @() } }
  foreach ($p in @("$env:APPDATA\npm\pnpm.cmd", "$env:LOCALAPPDATA\pnpm\pnpm.exe",
                   "$env:ProgramFiles\nodejs\pnpm.cmd")) {
    if (Test-Path $p) { return @{ Exe = $p; Args = @() } }
  }
  $corepack = Get-Command corepack -ErrorAction SilentlyContinue
  if ($corepack) { return @{ Exe = $corepack.Source; Args = @('pnpm') } }
  # npx 在两套安装里同时有 npx.cmd 和 npx.ps1；PowerShell 会挑 .ps1，而它对
  # Restricted 执行策略是硬拒绝（无法加载文件 npx.ps1）。优先用 .cmd，绕开策略。
  $npxCmd = Join-Path $env:ProgramFiles 'nodejs\npx.cmd'
  if (Test-Path $npxCmd) { return @{ Exe = $npxCmd; Args = @('--yes', 'pnpm@9') } }
  $npx = Get-Command npx -ErrorAction SilentlyContinue
  if ($npx) {
    $src = $npx.Source
    if ($src -like '*.ps1' -and (Test-Path ([IO.Path]::ChangeExtension($src, '.cmd')))) {
      $src = [IO.Path]::ChangeExtension($src, '.cmd')
    }
    return @{ Exe = $src; Args = @('--yes', 'pnpm@9') }
  }
  return $null
}

$pnpmCmd = Resolve-Pnpm
if ($null -eq $pnpmCmd) {
  Warn "no pnpm/corepack/npx found - switching to direct-copy mode (no package manager)"
} else {
  Ok ("pnpm via: " + $pnpmCmd.Exe + " " + ($pnpmCmd.Args -join ' '))
}

$srcIndex = Join-Path $PSScriptRoot 'index.js'
if (-not (Test-Path $srcIndex)) { Err "index.js not found next to this script; run it from the extracted source folder"; exit 1 }

Step "copy plugin files"
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force; Warn "replaced existing $dst" }
New-Item -ItemType Directory -Force -Path $dst | Out-Null
robocopy $PSScriptRoot $dst /E /XD .git /XF install.ps1 uninstall.ps1 install-win.ps1 | Out-Null
if ($LASTEXITCODE -ge 8) { Err "robocopy failed: $LASTEXITCODE"; exit 1 }
Ok "copied to $dst"

Step "backup package.json"
$bak = "$pkgPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $pkgPath $bak -Force
Ok "backup: $bak"

Step "write dependency and bundle entry"
$pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
if (-not $pkg.dependencies) { $pkg | Add-Member -NotePropertyName dependencies -NotePropertyValue (New-Object psobject) }
$pkg.dependencies | Add-Member -NotePropertyName $pluginName -NotePropertyValue "file:../../plugins/$pluginName" -Force
if (-not $pkg.dsh) { $pkg | Add-Member -NotePropertyName dsh -NotePropertyValue (New-Object psobject) }
if (-not $pkg.dsh.profile) { $pkg.dsh | Add-Member -NotePropertyName profile -NotePropertyValue (New-Object psobject) }
if (-not $pkg.dsh.profile.bundles) { $pkg.dsh.profile | Add-Member -NotePropertyName bundles -NotePropertyValue @() }
if ($pkg.dsh.profile.bundles -notcontains $pluginName) { $pkg.dsh.profile.bundles += $pluginName }
[IO.File]::WriteAllText($pkgPath, ($pkg | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
Ok "package.json updated"

Step "refresh node_modules"
$nm = Join-Path $profDir "node_modules\$pluginName"
if ($null -ne $pnpmCmd) {
  if (Test-Path $nm) { Remove-Item $nm -Recurse -Force }
  Push-Location $profDir
  try {
    # DSH 插件的 @deepseek-ai/dsh-* 是宿主提供的 peer，pnpm 9 默认会去 registry 找
    # 一个满足范围的版本，而它们只有预发布版（latest 仍指向 0.0.1-rc.1），必然
    # 报 ERR_PNPM_NO_MATCHING_VERSION。关掉 peer 自动安装即可，运行时由宿主解析。
    $installArgs = @($pnpmCmd.Args) + @('install', '--config.auto-install-peers=false')
    & $pnpmCmd.Exe @installArgs
    if ($LASTEXITCODE -ne 0) {
      Warn "pnpm install 未通过，关闭严格 peer 校验后重试一次"
      $installArgs = @($pnpmCmd.Args) + @('install', '--config.auto-install-peers=false', '--config.strict-peer-dependencies=false')
      & $pnpmCmd.Exe @installArgs
    }
    if ($LASTEXITCODE -ne 0) { Err "pnpm install failed: $LASTEXITCODE"; exit 1 }
  } finally { Pop-Location }
  Ok "dependencies installed"
} else {
  # Direct-copy mode: overwrite the installed copy in place, keep a backup.
  if (-not (Test-Path $nm)) { Err "installed copy missing and no package manager: $nm"; exit 1 }
  $nmbak = "$nm.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item $nm $nmbak -Recurse -Force
  robocopy $PSScriptRoot $nm /E /XD .git /XF install.ps1 uninstall.ps1 install-win.ps1 INSTALL-WIN.txt | Out-Null
  if ($LASTEXITCODE -ge 8) { Err "direct copy failed: $LASTEXITCODE"; exit 1 }
  Ok "installed copy overwritten (backup: $nmbak)"
}

Step "verify"
$md = Join-Path $profDir "node_modules\$pluginName\prompts\infinite-gen-2.md"
if (Test-Path $md) {
  $raw = Get-Content $md -Raw
  Ok ("file size: " + (Get-Item $md).Length)
  Ok ("preface  : " + ($raw -match 'SECTION PREFACE'))
  Ok ("categories: " + ($raw -match 'Local-analysis categories'))
  Ok ("cheat term: " + ($raw -match 'cheat'))
} else { Err "installed prompt not found: $md" }

Write-Host ""
Write-Host "done. Quit DeepSeek Harness completely (tray too), then reopen." -ForegroundColor Cyan
Write-Host "Verify in a new chat: ask 'what categories may you analyze locally?'" -ForegroundColor Cyan
