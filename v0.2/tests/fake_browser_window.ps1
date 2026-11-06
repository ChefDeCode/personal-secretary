# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 测试用的假浏览器窗口（地址栏 + 网页正文），给 web_source_test.ps1 用。参数：地址。内容都是虚构的
param([string]$Url = 'https://work.example.com/tasks')
Add-Type -AssemblyName PresentationFramework
$x = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="假浏览器" Width="900" Height="600" Left="140" Top="140" WindowStartupLocation="Manual" ShowActivated="False">
  <DockPanel>
    <TextBox x:Name="Addr" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" DockPanel.Dock="Top" AutomationProperties.Name="地址和搜索栏"/>
    <RichTextBox IsReadOnly="True"><FlowDocument>
      <Paragraph>测试任务看板</Paragraph><Paragraph>周三下午5点前提交测试报告</Paragraph><Paragraph>负责人：测试同事</Paragraph>
    </FlowDocument></RichTextBox>
  </DockPanel>
</Window>
'@
$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x)); $w.FindName('Addr').Text = $Url; [void]$w.ShowDialog()
