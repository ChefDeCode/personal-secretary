# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 代码自检（不运行任何东西，只看代码）：今天踩过的三种坑
# 1) 调用了但哪儿都没定义的函数（精简时删掉了还有人用）
# 2) 自己定义的函数名和 PowerShell 自带的短名字（别名）撞了：别名优先，自己的函数根本不会被调用（R、Mv 那种）
# 3) 同一个函数里只差大小写的两个变量名（PowerShell 不分大小写，$t 会把 $T 盖掉）
param([switch]$Verbose)
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $root = Split-Path $v2 -Parent
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$files = @(Get-ChildItem $root -Recurse -Include *.ps1 -File | Where-Object { $_.FullName -notmatch '\\旧东西\\|\\tests\\|\\server\\|\\node_modules\\|\\webview2|\\review\\|\\data\\' })
$tests = @(Get-ChildItem "$v2\tests" -Filter *.ps1 -File)
$asts=@{}; $syntax=@()
foreach($f in $files+$tests){$parseErrors=$null;$asts[$f.FullName]=[Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$null,[ref]$parseErrors);foreach($e in $parseErrors){$syntax+="$($f.Name):$($e.Extent.StartLineNumber):$($e.ErrorId)"}}
Check "all PowerShell files parse (errors=$($syntax.Count))" (-not $syntax.Count)
if($syntax.Count){$syntax|ForEach-Object{"SYNTAX $_"}}
$defs = @{}; foreach ($k in $asts.Keys) { foreach ($d in $asts[$k].FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defs[$d.Name] = $true } }
$rel = { param($p) $p.Substring($root.Length + 1) }
# 1) 产品代码里调用了却没定义的
$miss = @{}
foreach ($f in $files) { foreach ($c in $asts[$f.FullName].FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
  $nm = $c.GetCommandName(); if (-not $nm -or $nm -notmatch '^[A-Za-z]+-[A-Za-z0-9]+$' -or $defs[$nm] -or $miss[$nm]) { continue }
  if (-not (Get-Command $nm -ErrorAction SilentlyContinue)) { $miss[$nm] = "$(& $rel $f.FullName):$($c.Extent.StartLineNumber)" } } }
Check "every function the product calls exists ($($miss.Count) missing$(if ($miss.Count) { ': ' + (($miss.GetEnumerator() | ForEach-Object { "$($_.Key) @ $($_.Value)" }) -join '; ') }))" (-not $miss.Count)
# 2) 自己定义的函数名被自带别名盖住（产品和测试都查）
$aliases = @{}; foreach ($a in Get-Alias) { $aliases[$a.Name.ToLower()] = $a.Definition }
$shadow = @(foreach ($k in $asts.Keys) { foreach ($d in $asts[$k].FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { if ($aliases[$d.Name.ToLower()]) { "$($d.Name) (= $($aliases[$d.Name.ToLower()])) @ $(& $rel $k):$($d.Extent.StartLineNumber)" } } })
Check "no function is hidden by a built-in alias ($($shadow.Count)$(if ($shadow.Count) { ': ' + ($shadow -join '; ') }))" (-not $shadow.Count)
# 3) 同一个作用域里只差大小写的变量（自动变量和 $_ 之类不算）
$auto = 'true', 'false', 'null', '_', 'psitem', 'args', 'input', 'matches', 'this', 'error', 'psscriptroot', 'pscommandpath', 'env', 'host', 'pid', 'lastexitcode', 'myinvocation', 'psboundparameters', 'erroractionpreference', 'script', 'global', 'local', 'using'
$case = @()
foreach ($k in $asts.Keys) {
  $scopes = @($asts[$k]) + @($asts[$k].FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
  foreach ($s in $scopes) {
    $body = if ($s -is [Management.Automation.Language.FunctionDefinitionAst]) { $s.Body } else { $s }
    $nested = @($body.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -or $n -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true) | Where-Object { $_ -ne $body })
    $vars = @($body.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true) | Where-Object { $v = $_; -not ($nested | Where-Object { $_.Extent.StartOffset -le $v.Extent.StartOffset -and $_.Extent.EndOffset -ge $v.Extent.EndOffset }) })
    $by = @{}; foreach ($v in $vars) { $n = $v.VariablePath.UserPath -replace '^(script|global|local|private):', ''; if ($auto -contains $n.ToLower()) { continue }; $l = $n.ToLower(); if (-not $by[$l]) { $by[$l] = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal) }; $by[$l][$n] = $v.Extent.StartLineNumber }
    foreach ($e in $by.GetEnumerator()) { if ($e.Value.get_Count() -gt 1) { $case += "$(($e.Value.Keys | Sort-Object) -join '/') @ $(& $rel $k):$(@($e.Value.Values)[0])" } }
  }
}
$case = @($case | Sort-Object -Unique)
Check "no two variables in one scope differ only by capitals ($($case.Count)$(if ($case.Count) { ': ' + ($case -join '; ') }))" (-not $case.Count)
# 4) Only real inline comment tokens are examined; strings and full-line examples are not code.
function Find-CommentCode([string]$text){
 $tokens=$null;[void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$null)
 foreach($token in $tokens|Where-Object {$_.Kind -eq 'Comment' -and $_.Text.StartsWith('#')}){
  $lineStart=$text.LastIndexOf("`n",[Math]::Max(0,$token.Extent.StartOffset-1))+1
  if(-not $text.Substring($lineStart,$token.Extent.StartOffset-$lineStart).Trim()){continue}
  if($token.Text -match ';\s*\$[\w.:]+(\.\w+)*\s*=\s*\S|;\s*\$\w+\s*\|\s*Add-Member|;\s*(Update-ChatItem|Write-ChatLine|Save-\w+|Set-\w+|Post)\s+[\$@(]'){$token.Extent.StartLineNumber}
 }
}
$swallowed=@(foreach($f in $files){foreach($line in @(Find-CommentCode ([IO.File]::ReadAllText($f.FullName)))){"$(& $rel $f.FullName):$line"}})
Check "no executable tail swallowed by inline comment (count=$($swallowed.Count))" (-not $swallowed.Count)
if($swallowed.Count){$swallowed|ForEach-Object{"COMMENT $_"}}
Check 'comment detector catches assignment and result update' (@(Find-CommentCode '$a=1 # explanation; $it.card.status = ''closed''; Update-ChatItem $it').Count -eq 1)
Check 'comment detector ignores color strings and documented examples' (@(Find-CommentCode ('$a = ''#C2643C''; $a=2'+"`n"+'# example; $x = 1')).Count -eq 0)
# 5) 测试不能把 HTTP 出错状态（4xx / 5xx）算成通过（2026-11-05：有几项测试曾经把 401 / 404 也算通过）
$lenient = @(foreach ($f in @(Get-ChildItem "$v2\tests" -Filter *.ps1 -File)) { $i = 0; foreach ($l in [IO.File]::ReadLines($f.FullName)) { $i++; if ($l -match '(PASS|exit 0).*-lt\s*[45]\d\d|-lt\s*[45]\d\d.*(PASS|exit 0)|-lt\s*[45]\d\d\)\s*\{\s*"\[PASS') { "$($f.Name):$i" } } })
Check "no test counts an HTTP 4xx / 5xx response as a pass ($($lenient.Count)$(if ($lenient.Count) { ': ' + ($lenient -join '; ') }))" (-not $lenient.Count)# 6) 程序文件夹以外的改动（注册表、环境变量、计划任务、「启动」文件夹快捷方式、Windows 凭据、在临时 / AppData 里建文件夹）只能经过 lib_改动记录.ps1，卸载时才能原样还原
$extWrite = 'Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|New-Item\s+(-Path\s+)?[''"]?HK(CU|LM):|SetEnvironmentVariable|Register-ScheduledTask|schtasks(\.exe)?\s+/(create|change|delete)|cmdkey\s+/(add|generic)|CreateShortcut\([^)]*\)[^\r\n]*\.Save\(\)|(CreateDirectory|New-Item[^\r\n]*-ItemType\s+Directory)[^\r\n]*\$env:(TEMP|TMP|LOCALAPPDATA|APPDATA)'
$rootDir = Split-Path $v2 -Parent
$unjournaled = @(foreach ($f in @(Get-ChildItem $rootDir -Recurse -Include *.ps1 -File | Where-Object { $_.FullName -notmatch '\\旧东西\\|\\tests\\|\\server\\|\\node_modules\\|webview2|reliability-code-backups|test-runs' -and $_.Name -notin 'lib_改动记录.ps1', '卸载秘书.ps1', '跑测试.ps1' })) {
  $i = 0; foreach ($l in [IO.File]::ReadLines($f.FullName)) { $i++; if ($l -match $extWrite -and $l.TrimStart() -notmatch '^#') { "$($f.Name):$i" } } })
Check "changes outside the app folder only go through the change journal ($($unjournaled.Count)$(if ($unjournaled.Count) { ': ' + ($unjournaled -join '; ') }))" (-not $unjournaled.Count)"code_check_test: $pass pass, $fail fail"
if($fail){exit 1}
