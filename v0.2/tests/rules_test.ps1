# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 设置 → 秘书可以自己做的事：规则怎么存、固定底线挡不挡得住。会临时改设置，结束后改回原样
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . "$v2\lib_事件.ps1"
$pass = 0; $fail = 0; function Check($name, $ok) { if ($ok) { $script:pass++ } else { $script:fail++; "FAIL $name" } }
$orig = (Read-Config).rules
try {
  $at = (Get-Date).AddHours(2).ToString('s')
  Check 'default ask' ((Get-ActRules).self_remind -eq 'ask')
  Check 'self do ok' ((Set-ActRule 'self_remind' 'do') -eq '')
  Check 'self do applies' ((Get-CardRule @{ kind = 'event'; etype = '叫你做事'; at = $at; what = '交方案' }) -eq 'do')
  Check 'floor: file stays ask' ((Get-CardRule @{ kind = 'event'; etype = '叫你做事'; at = $at; what = '把文件发给对方' }) -eq 'ask')
  Check 'floor: money stays ask' ((Get-CardRule @{ kind = 'event'; etype = '你答应的'; at = $at; what = '转账给房东' }) -eq 'ask')
  Check 'no time -> ask' ((Get-CardRule @{ kind = 'event'; etype = '叫你做事'; what = '交方案' }) -eq 'ask')
  Check 'waiting for time -> ask' ((Get-CardRule @{ kind = 'event'; etype = '叫你做事'; at = $at; waitTime = $true; what = '交方案' }) -eq 'ask')
  Check 'remind_other cannot be do' ((Set-ActRule 'remind_other' 'do') -ne '')
  Check 'remind_other still ask' ((Get-CardRule @{ kind = 'event'; etype = '提醒对方'; at = $at; draft = '记得交周报' }) -eq 'ask')
  Check 'reply_other cannot be do' ((Set-ActRule 'reply_other' 'do') -ne '')
  Check 'tamper in config ignored' ($(
      $c = Read-Config; $c.rules | Add-Member -NotePropertyName remind_other -NotePropertyValue 'do' -Force; Save-Config $c
      (Get-ActRules).remind_other -eq 'ask'))
  Check 'tell' ($(Set-ActRule 'add_next' 'tell') -eq '' -and (Get-CardRule @{ kind = 'event'; etype = '约好的事'; at = $at; what = '开会' }) -eq 'tell')
  Check 'unknown key' ((Set-ActRule 'pay_bills' 'do') -ne '')
  Check 'send card never do' ((Get-CardRule @{ kind = 'send'; at = $at; who = 'x'; text = 'y' }) -eq 'ask')
  Check 'settings carries rules' ((Get-Settings).rules.self_remind -eq 'do')
} finally { $c = Read-Config; if ($null -eq $orig) { $c.PSObject.Properties.Remove('rules') } else { $c | Add-Member -NotePropertyName rules -NotePropertyValue $orig -Force }; Save-Config $c }
"restored: $([bool]((ConvertTo-Json (Read-Config).rules -Compress) -eq (ConvertTo-Json $orig -Compress)))"
"rules_test: $pass pass, $fail fail"
