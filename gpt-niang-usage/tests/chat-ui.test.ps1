$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$p=Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\chat-ui.ps1'
. ([scriptblock]::Create([IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)))
function Add-CodexChatSettings {}
function Set-CodexChatEnabled([bool]$Enabled){}
function Write-WidgetJson($Path,$Value){}
function Read-ChatHistory {return @()}
function Get-DeepSeekKeyFile {return (Join-Path $env:TEMP 'nonexistent-gpt-niang-ui-test.dat')}
function Save-ChatHistory {return $true}
function Read-CodexChatState {return [pscustomobject]@{connected=$true;at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();threads=@();selectedThreadId='';reply='';busy=$false;error=''}}
$script:appDir=Join-Path $env:TEMP 'gpt-niang-ui-test-nonexistent'
$script:ui=@{Girl=[Windows.Controls.Image]::new();ChatPanel=[Windows.Controls.Grid]::new();ChatTitle=[Windows.Controls.TextBlock]::new();ChatReply=[Windows.Controls.TextBlock]::new();ChatScroll=[Windows.Controls.ScrollViewer]::new();ChatCopy=[Windows.Controls.Button]::new();ChatTalk=[Windows.Controls.Button]::new();ChatClose=[Windows.Controls.Button]::new()}
$script:context=[Windows.Controls.ContextMenu]::new()
Initialize-WidgetChat
$script:chatComposer.FindName('Provider').SelectedIndex=1
if($script:chatProvider-ne 'DeepSeek' -or $script:chatComposer.FindName('KeyPanel').Visibility-ne 'Visible'){throw 'Switch to DeepSeek failed'}
$keyFile=Join-Path $env:TEMP ('gpt-niang-test-'+[Guid]::NewGuid().ToString('N')+'.dat')
function Get-DeepSeekKeyFile {return $keyFile}
$script:chatComposer.FindName('ApiKey').Password='test-key'
try {Save-DeepSeekKey; $stored=[IO.File]::ReadAllText($keyFile);if($stored -eq 'test-key' -or !$stored){throw 'Key not encrypted'}; if($script:chatComposer.FindName('ApiKey').Password){throw 'Key input not cleared'};if($script:chatComposer.FindName('KeyPanel').Visibility-ne 'Collapsed'){throw 'Key panel did not hide'}} finally {Remove-Item -LiteralPath $keyFile -ErrorAction SilentlyContinue}
$script:deepSeekHistory=@();$script:deepSeekPending='hello';$script:deepSeekJob=Start-Job -ScriptBlock {[pscustomobject]@{ok=$true;reply='test reply'}}
Wait-Job $script:deepSeekJob|Out-Null
Update-DeepSeekJob
if($script:deepSeekReply-ne 'test reply' -or $script:deepSeekHistory.Count-ne 2){throw 'DeepSeek result handling failed'}
$script:chatRecords=@([pscustomobject]@{id='record-1';provider='DeepSeek';question='我的提问';answer='回答';status='完成';time='10:00';threadId=''})
Show-ChatHistory
$exp=$script:chatComposer.FindName('HistoryList').Children[0]
if($exp.IsExpanded -or $exp.Content.Text -notmatch '我的提问' -or $exp.Content.Text -notmatch '回答'){throw 'Collapsible history failed'}
Set-ChatHistoryExpanded $true;if(!$exp.IsExpanded){throw 'Expand all failed'}
Set-ChatHistoryExpanded $false;if($exp.IsExpanded){throw 'Collapse all failed'}
Set-ChatBackground 'blue';if($script:chatBackground-ne 'blue'){throw 'Background setting failed'}
$script:chatComposer.FindName('Provider').SelectedIndex=0
if($script:chatProvider-ne 'Codex' -or $script:chatComposer.FindName('KeyPanel').Visibility-ne 'Collapsed'){throw 'Switch to Codex failed'}
$script:chatComposer.Close()
'PASS: WPF initialization, service switching and DeepSeek reply handling'
