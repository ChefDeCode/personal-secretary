# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 07_AI边框特效.ps1 — 秘书读取某个窗口时，在该窗口外围显示赤陶色柔和发光边框 + “秘书正在读取”小标签（正式配色）
# 独立的透明覆盖窗口：鼠标穿透、不抢焦点、不进任务栏和 Alt+Tab，不向目标软件发送任何输入。
# 覆盖窗口设为“被微信窗口拥有”，因此只出现在微信所在的虚拟桌面（用户在桌面 1 时看不到它）。
# 用法：powershell -ExecutionPolicy Bypass -File .\07_AI边框特效.ps1 -Process Weixin -Seconds 15
#       值守模式：-StateFile <state.json>：状态为“读取中”时保持显示，停止读取后 0.8s 淡出并退出（由 08 边缘线按需启动）
param([string]$Process = 'Weixin', [int]$Seconds = 15, [string]$Label = '',   # 不传 -Label 时显示 {config.json 里的名字}正在读取，改名实时生效
      [string]$StateFile = '')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
. (Join-Path $PSScriptRoot 'lib_窗口工具.ps1')

$h = [WinTools]::LargestVisibleWindow([uint32[]](Get-Process $Process -ErrorAction Stop).Id)
if ($h -eq [IntPtr]::Zero) { Write-Host "没找到 $Process 的可见窗口"; exit 1 }

$pad = 14   # 发光区宽度（DIP）
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize">
  <Grid>
    <!-- 柔和发光：赤陶色细描边 + 同色模糊光晕 -->
    <Border x:Name="Glow" Margin="$($pad/2)" BorderThickness="2.5" CornerRadius="10" BorderBrush="#C2643C" Opacity="0.55">
      <Border.Effect><DropShadowEffect Color="#C2643C" ShadowDepth="0" BlurRadius="18" Opacity="0.6"/></Border.Effect>
    </Border>
    <!-- 右上角标签：面板底色 + 墨色文字 + 赤陶小圆点 -->
    <Border HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,$($pad+8),$($pad+10),0"
            Background="#FBF8F2" BorderBrush="#E2DACC" BorderThickness="1" CornerRadius="8" Padding="10,4,12,5">
      <StackPanel Orientation="Horizontal">
        <Ellipse x:Name="Dot" Width="7" Height="7" Fill="#C2643C" Margin="0,0,7,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="Text" Text="" Foreground="#2B2722" FontFamily="Microsoft YaHei UI" FontSize="12.5"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@
$win = [Windows.Markup.XamlReader]::Parse($xaml)
$win.Opacity = 0   # 先透明，确认在微信所在桌面后再淡入
$glow = $win.FindName('Glow'); $shadow = $glow.Effect; $dot = $win.FindName('Dot'); $text = $win.FindName('Text')
function Update-Label { $text.Text = $(if ($Label) { $Label } else { "$(Get-SecretaryName)正在读取" }) }
Update-Label
$lastCfg = 0; $vis = 1.0; $lastState = -1; $offSince = -1
$endAt = if ($StateFile) { [double]::MaxValue } else { [double]$Seconds }   # 结束时刻（秒）；值守模式下由状态文件决定
$reduced = -not [System.Windows.SystemParameters]::ClientAreaAnimation   # 系统关闭动画效果时不做呼吸

$win.Add_SourceInitialized({
  $me = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
  [WinTools]::MakeOverlay($me, $false)
  [WinTools]::SetOwner($me, $h)   # 归属微信窗口 → 只出现在微信所在的桌面，且始终紧贴在微信上一层（不再置顶，别的窗口盖住微信时也会盖住边框）
  [WinTools]::StartFollow($me, $h, $pad)   # 事件驱动跟随：微信一移动就一次 SetWindowPos；拖动/缩放期间隐藏
})
$win.Add_Closed({ [WinTools]::StopFollow() })

$sw = [Diagnostics.Stopwatch]::StartNew()
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(33)
$timer.Add_Tick({
  $t = $sw.Elapsed.TotalSeconds
  if ($StateFile) {
    # 值守模式：读到“停止读取”后，把结束时间定在 0.8s 之后，复用下面的淡出逻辑
    if ($t - $script:lastState -gt 0.25) { $script:lastState = $t
      # 停止读取，或功能开关 border 被关掉：淡出退出
      if (-not (Test-Lit $StateFile) -or -not (Get-Feature 'border')) { if ($script:offSince -lt 0) { $script:offSince = $t }; if ($t - $script:offSince -ge 2 -and $script:endAt -gt $t + 0.2) { $script:endAt = $t + 0.2 } } else { $script:offSince = -1; if ($script:endAt -gt $t + 0.2) { $script:endAt = [double]::MaxValue } } }   # 熄灭要持续 2 秒才淡出：两步之间的空隙不闪
  }
  if ($t -gt $script:endAt) { $timer.Stop(); $win.Close(); return }
  # 位置由 StartFollow 的事件回调负责（外扩 pad、与显示器工作区求交、一次 SetWindowPos），这里只管动画
  if ([WinTools]::IsIconic($h)) { $win.Opacity = 0; return }
  # 边框只出现在微信所在的桌面：靠 SetOwner（被微信窗口拥有），系统自动让它跟随微信所在桌面，微信换桌面也同步
  if ($t - $script:lastCfg -gt 1) { Update-Label; $script:lastCfg = $t }   # 每秒读一次名字，改名即时生效
  # 慢呼吸 2.8s（余弦 = ease-in-out）；开头 0.6s 淡入、结尾 0.8s 淡出
  $fade = [Math]::Max([double]0, [Math]::Min([double]1, $t / 0.2) * [Math]::Min([double]1, [Math]::Min([double]1e6, $script:endAt - $t) / 0.2))   # 只在开头淡入、结尾淡出（各 0.2 秒）
  $b = 0.6   # 稳定常亮，不呼吸（呼吸看起来像一闪一闪）
  # 拖动/缩放中：约 0.15s 淡出；松手后约 0.3s 在新位置淡入
  $target = if ([WinTools]::Dragging) { 0 } else { 1 }
  $script:vis += [Math]::Sign($target - $script:vis) * [Math]::Min([Math]::Abs($target - $script:vis), $(if ($target -eq 0) { 0.22 } else { 0.11 }))
  $win.Opacity = $fade * $script:vis
  $glow.Opacity = 0.35 + 0.35 * $b
  $shadow.BlurRadius = 12 + 10 * $b
  $dot.Opacity = 0.55 + 0.45 * $b
})
$win.Add_ContentRendered({
  # WPF 首次显示时会套用自己的默认位置，显示后再按微信位置摆一次
  [void][WinTools]::Place((New-Object Windows.Interop.WindowInteropHelper $win).Handle, $h, $pad)
  $timer.Start() })
[void]$win.ShowDialog()
Write-Host "边框特效已结束"
