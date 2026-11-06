# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 读取来源的统一调度（12_值守.ps1）：顺序和以前一样、关着的不读、一个出错不影响别的、连着出错就歇一会、太慢也算、状态写给设置页
# 全在临时文件夹，读的函数换成假的，不碰微信和真数据
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $realRoot = Split-Path $v2 -Parent
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$T = Join-Path $env:TEMP 'secretary_sources'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\v0.2\data", "$T\data" | Out-Null
$root = $T; $data = "$T\data"; $Interval = 10; $Process = 'NoSuchApp_x'; $stats = @{ 错误 = 0; 最后错误 = '' }
$ast = [Management.Automation.Language.Parser]::ParseFile("$realRoot\12_值守.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-WatchCfg', 'Get-SrcState', 'Set-SrcResult', 'Invoke-Source', 'Invoke-Sources', 'Set-WeChatSource', 'Write-SourcesStatus' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$asg = $ast.FindAll({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$script:Sources' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($asg.Extent.Text))
# 1) 真的来源表：顺序和以前主循环里一样，每个读的还是原来那个函数
Check "real table order: $(($script:Sources | ForEach-Object id) -join ', ')" ((($script:Sources | ForEach-Object id) -join ',') -eq 'wechat,adapters,plugins,outlook,folders,edge')
Check 'each source reads with the same function as before' ((@($script:Sources | Where-Object read | ForEach-Object { $_.read.ToString().Trim() }) -join ',') -eq 'Watch-Adapted,Watch-Plugins,Watch-Mail,Watch-Folders,Watch-Edge')
Check 'every source has id / kind / enabled / interval / selfcheck' (-not @($script:Sources | Where-Object { -not ($_.id -and $_.kind -and $_.enabled -and $null -ne $_.interval -and $_.selfcheck) }).Count)
# 2) 换成假的读函数来测调度
$script:Calls = New-Object System.Collections.ArrayList; $script:On = @{ a = $true; b = $true; c = $true; d = $false }
$script:Sources = @(
  @{ id = 'wechat'; kind = 'screen'; name = '微信'; interval = 10; timeout = 60; read = $null; enabled = { $true }; selfcheck = { '' } }
  @{ id = 'a'; kind = 'screen'; name = 'A'; interval = 0; timeout = 30; read = { [void]$script:Calls.Add('a') }; enabled = { $script:On.a }; selfcheck = { 'A 自检' } }
  @{ id = 'b'; kind = 'uia'; name = 'B'; interval = 0; timeout = 30; read = { [void]$script:Calls.Add('b'); throw 'B 坏了' }; enabled = { $script:On.b }; selfcheck = { throw 'x' } }
  @{ id = 'c'; kind = 'files'; name = 'C'; interval = 0; timeout = 30; read = { [void]$script:Calls.Add('c'); $stats.错误++; $stats.最后错误 = 'C 自己接住的错' }; enabled = { $script:On.c }; selfcheck = { '' } }
  @{ id = 'd'; kind = 'uia'; name = 'D'; interval = 0; timeout = 30; read = { [void]$script:Calls.Add('d') }; enabled = { $script:On.d }; selfcheck = { '' } }
  @{ id = 'e'; kind = 'plugin'; name = 'E'; interval = 0; timeout = 0; read = { [void]$script:Calls.Add('e'); Start-Sleep -Milliseconds 30 }; enabled = { $true }; selfcheck = { '' } }
)
Invoke-Sources
Check "one round runs the sources in order, skipping the one that is off ($($script:Calls -join ','))" (($script:Calls -join ',') -eq 'a,b,c,e')
Check 'a source that throws does not stop the ones after it' ($script:Calls -contains 'c' -and $script:Calls -contains 'e')
Check 'the switched-off source is marked off and not read' ((Get-SrcState 'd').state -eq 'off' -and $script:Calls -notcontains 'd')
Check 'an error the read caught itself still counts for that source' ((Get-SrcState 'c').state -eq 'error' -and (Get-SrcState 'a').state -eq 'ok')
Check 'too slow counts as a problem too' ((Get-SrcState 'e').slow -eq 1)
Invoke-Sources; Invoke-Sources; $script:Calls.Clear(); Invoke-Sources
Check "after 3 problems in 10 minutes a source rests (B, C, E skipped; A still read: $($script:Calls -join ','))" (($script:Calls -join ',') -eq 'a' -and (Get-SrcState 'b').state -eq 'backoff' -and (Get-SrcState 'b').until -gt (Get-Date).AddSeconds(50))
(Get-SrcState 'b').until = (Get-Date).AddSeconds(-1); $script:Calls.Clear(); Invoke-Sources
Check 'after the rest it is tried again by itself' ($script:Calls -contains 'b')
Invoke-Sources; Invoke-Sources; Check 'resting again is longer (2 minutes)' ((Get-SrcState 'b').until -gt (Get-Date).AddSeconds(110))
# 3) 微信那一轮
Set-WeChatSource '' '' 500; Check 'wechat read -> ok' ((Get-SrcState 'wechat').state -eq 'ok')
Set-WeChatSource '无变化' '' 50; Check 'wechat unchanged screen -> still ok' ((Get-SrcState 'wechat').state -eq 'ok')
Set-WeChatSource '微信不可读' '' 5; Check 'wechat minimized -> waiting (with the reason)' ((Get-SrcState 'wechat').state -eq 'waiting')
1..4 | ForEach-Object { Set-WeChatSource '' '读坏了' 5 }; Check 'wechat errors are recorded but wechat never rests' ((Get-SrcState 'wechat').state -eq 'error' -and -not (Get-SrcState 'wechat').until)
# 3b) 状态马上更新：收起来等着读 → 显示原因；一读成功马上变回正常、清掉旧提示；两次透明读之间不算「等着」
[IO.File]::WriteAllText("$data\hint.txt", '微信收起来了：你停手几秒后秘书会悄悄读，不会弹出来'); Set-WeChatSource '微信不可读' '' 5
Check 'wechat put away -> waiting, with the plain reason' ((Get-SrcState 'wechat').state -eq 'waiting' -and (Get-SrcState 'wechat').detail -like '微信收起来了*')
Remove-Item "$data\hint.txt"; Set-WeChatSource '' '' 900; Check 'first good read -> normal right away, old hint cleared' ((Get-SrcState 'wechat').state -eq 'ok' -and -not (Get-SrcState 'wechat').detail)
Set-WeChatSource '等下一次透明读' '' 1; Check 'between two invisible reads -> stays normal' ((Get-SrcState 'wechat').state -eq 'ok')# 4) 状态文件
Write-SourcesStatus; $js = @(Get-Content "$T\v0.2\data\sources_status.json" -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
Check "status file has one line per source ($($js.Count))" ($js.Count -eq 6 -and (($js | ForEach-Object id) -join ',') -eq 'wechat,a,b,c,d,e')
Check 'self-check text is kept, a failing self-check does not break the file' (($js | Where-Object id -eq 'a').detail -eq 'A 自检' -and ($js | Where-Object id -eq 'b').detail -eq '自检没做成')
"sources_test: $pass pass, $fail fail"
