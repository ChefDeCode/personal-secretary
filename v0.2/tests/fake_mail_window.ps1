# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 测试用的假邮件窗口（WPF：左边邮件列表、右边打开的邮件正文），给 mail_uia_test.ps1 用。内容都是虚构的
Add-Type -AssemblyName PresentationFramework
$x = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="假邮件窗口" Width="900" Height="600" Left="120" Top="120" WindowStartupLocation="Manual" ShowActivated="False">
  <DockPanel>
    <ListBox DockPanel.Dock="Left" Width="380">
      <ListBoxItem AutomationProperties.Name="未读 测试发件人A 周五下午3点开会 请准备材料">未读 测试发件人A 周五下午3点开会</ListBoxItem>
      <ListBoxItem AutomationProperties.Name="测试发件人B 报价单 周四前回复">测试发件人B 报价单</ListBoxItem>
      <ListBoxItem AutomationProperties.Name="未读 测试发件人C 合同 下周一前签回">未读 测试发件人C 合同</ListBoxItem>
      <ListBoxItem AutomationProperties.Name="测试发件人D 周报 已读">测试发件人D 周报</ListBoxItem>
    </ListBox>
    <RichTextBox IsReadOnly="True"><FlowDocument>
      <Paragraph>测试发件人A</Paragraph><Paragraph>主题：周五开会</Paragraph>
      <Paragraph>大家好，周五下午3点在会议室开会，请提前准备材料。</Paragraph><Paragraph>谢谢</Paragraph>
    </FlowDocument></RichTextBox>
  </DockPanel>
</Window>
'@
$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x)); [void]$w.ShowDialog()
