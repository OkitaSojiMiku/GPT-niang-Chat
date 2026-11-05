function Get-CodexChatDirectory {return (Join-Path $script:appDir 'local-codex-chat-state')}
function Write-CodexChatCommand([hashtable]$Command){
  $directory=Get-CodexChatDirectory;$null=New-Item -ItemType Directory -Path $directory -Force
  $Command.id=[Guid]::NewGuid().ToString('N');$Command.at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Write-WidgetJson (Join-Path $directory ('request-'+$Command.at+'-'+$Command.id+'.json')) $Command
  return $Command.id
}
function Read-CodexChatState {
  $stream=$null;$reader=$null
  try{
    $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream=[IO.File]::Open((Join-Path (Get-CodexChatDirectory) 'state.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
    return ($reader.ReadToEnd()|ConvertFrom-Json)
  }catch{return $null}finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
}
function Test-CodexChatConnected {
  return $script:chatState -and $script:chatState.connected -and ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-[long]$script:chatState.at)-lt 45000
}
function Save-CodexChatUi {
  Write-WidgetJson (Join-Path (Get-CodexChatDirectory) 'ui-preferences.json') @{enabled=$script:chatEnabled;background=$script:chatBackground}
}
function Set-CodexChatEnabled([bool]$Enabled){
  $script:chatEnabled=$Enabled;Save-CodexChatUi
  if($Enabled){
    $script:desktopTopmost=$true
    if($script:followHost){Set-WidgetFollowHost $false}else{Save-Settings;Tick-Widget}
  }else{
    if($script:chatComposer){$script:chatComposer.Hide()}
    if($script:chatToolbar){$script:chatToolbar.IsOpen=$false}
    if($script:bubbleMode-eq 'chat'){Hide-Quota}
  }
}
function Set-CodexToolbarVisible([bool]$Visible){
  if($script:chatToolbar){$script:chatToolbar.IsOpen=$Visible -and $script:chatEnabled -and $script:window.IsVisible}
}
function Test-CodexToolbarHover {
  return $script:chatToolbar -and $script:chatToolbar.IsOpen -and $script:chatToolbar.Child.IsMouseOver
}
function Get-ChatHistoryFile {return (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local\GPTNiangUsage\chat-history.dat')}
function Save-ChatHistory {
  if($script:chatHistoryReadError){if($script:chatComposer){$script:chatComposer.FindName('ComposeStatus').Text='历史记录无法读取，未覆盖原文件。'};return $false}
  $file=Get-ChatHistoryFile;$temp=$file+'.'+$PID+'.tmp'
  try{
    $null=New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force
    $json=ConvertTo-Json -InputObject @($script:chatRecords) -Depth 8 -Compress
    $secret=ConvertTo-SecureString $json -AsPlainText -Force
    [IO.File]::WriteAllText($temp,(ConvertFrom-SecureString $secret),[Text.Encoding]::ASCII)
    if([IO.File]::Exists($file)){[IO.File]::Replace($temp,$file,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$file)}
    return $true
  }catch{if($script:chatComposer){$script:chatComposer.FindName('ComposeStatus').Text='对话记录保存失败，本次仅保留在内存。'};return $false}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Read-ChatHistory {
  $file=Get-ChatHistoryFile;if(!(Test-Path -LiteralPath $file)){return @()}
  $ptr=[IntPtr]::Zero
  try{$secure=ConvertTo-SecureString ([IO.File]::ReadAllText($file));$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);$json=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr);$parsed=ConvertFrom-Json -InputObject $json;foreach($entry in $parsed){Write-Output $entry}}
  catch{$script:chatHistoryReadError=$true;return @()}finally{if($ptr-ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}}
}
function Set-ChatBackground([string]$Style){
  if($Style-notin @('transparent','purple','blue') -and $Style-notmatch '^#[0-9A-Fa-f]{6}$'){return}
  $script:chatBackground=$Style
  if($script:chatComposer){
    $colors=@{transparent='#00272038';purple='#E1272038';blue='#D51D3146'}
    $panels=@{transparent='#70191427';purple='#A8191427';blue='#A8102439'}
    if($Style-match '^#[0-9A-Fa-f]{6}$'){$colors[$Style]='#D0'+$Style.Substring(1);$panels[$Style]='#C0191427'}
    $script:chatComposer.FindName('ChatFrame').Background=[Windows.Media.BrushConverter]::new().ConvertFromString($colors[$Style])
    foreach($name in @('DialoguePanel','HistoryPanel')){$script:chatComposer.FindName($name).Background=[Windows.Media.BrushConverter]::new().ConvertFromString($panels[$Style])}
  }
  Save-CodexChatUi
}
function Add-ChatRecord([string]$Provider,[string]$Question,[string]$ThreadId=''){
  $record=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');provider=$Provider;threadId=$ThreadId;question=$Question;answer='';status='等待回复';time=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm')}
  $script:chatRecords+=@($record);$null=Save-ChatHistory;Update-ChatHistoryView;return $record
}
function Complete-ChatRecord([string]$Id,[string]$Answer,[string]$Status){
  $record=$script:chatRecords|Where-Object{$_.id-eq $Id}|Select-Object -First 1
  if($record){$record.answer=$Answer;$record.status=$Status;$null=Save-ChatHistory;Update-ChatHistoryView}
}
function Update-ChatHistoryView {
  if(!$script:chatComposer){return}
  $list=$script:chatComposer.FindName('HistoryList');if(!$list){return}
  $open=@{};foreach($old in $list.Children){if($old.Tag){$open[[string]$old.Tag]=[bool]$old.IsExpanded}}
  $list.Children.Clear()
  foreach($r in @($script:chatRecords)){
    if($r.provider-ne $script:chatProvider){continue}
    if($r.provider-eq 'Codex' -and $r.threadId-ne [string]$script:chatState.selectedThreadId){continue}
    $summary=([string]$r.question -replace '\s+',' ').Trim();if($summary.Length-gt 32){$summary=$summary.Substring(0,32)+'…'}
    $exp=[Windows.Controls.Expander]::new();$exp.Tag=$r.id;$exp.Header=([string]$r.time+'  ·  '+$summary);$exp.Foreground=[Windows.Media.Brushes]::White;$exp.Margin=[Windows.Thickness]::new(0,4,0,4)
    $exp.IsExpanded=if($open.ContainsKey([string]$r.id)){$open[[string]$r.id]}else{$false}
    $body=[Windows.Controls.TextBlock]::new();$body.TextWrapping=[Windows.TextWrapping]::Wrap;$body.Foreground=[Windows.Media.Brushes]::White;$body.FontSize=14;$body.LineHeight=22;$body.Margin=[Windows.Thickness]::new(8,5,6,9)
    $answer=if($r.answer){[string]$r.answer}else{[string]$r.status};$body.Text='你：'+[string]$r.question+"`n`n龙娘："+$answer;$exp.Content=$body
    $null=$list.Children.Add($exp)
  }
}
function Set-ChatHistoryExpanded([bool]$Expanded){
  if(!$script:chatComposer){return};foreach($item in $script:chatComposer.FindName('HistoryList').Children){$item.IsExpanded=$Expanded}
}
function Show-ChatHistory {
  if(!$script:chatComposer){return}
  $script:chatComposer.FindName('HistoryPanel').Visibility=[Windows.Visibility]::Visible
  $script:chatComposer.FindName('DialoguePanel').Visibility=[Windows.Visibility]::Collapsed
  Update-ChatHistoryView
}
function Show-CurrentDialogue {
  $script:chatComposer.FindName('HistoryPanel').Visibility=[Windows.Visibility]::Collapsed
  $script:chatComposer.FindName('DialoguePanel').Visibility=[Windows.Visibility]::Visible
}
function Show-DeepSeekKeySettings {
  if(!$script:chatComposer){return}
  $script:chatComposer.FindName('Provider').SelectedIndex=1
  Open-CodexComposer
  $script:chatComposer.FindName('KeyPanel').Visibility=[Windows.Visibility]::Visible
  $script:chatComposer.FindName('ApiKey').Focus()|Out-Null
}
function Get-DeepSeekKeyFile { return (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local\GPTNiangUsage\deepseek-key.dat') }
function Save-DeepSeekKey {
  $secret=$script:chatComposer.FindName('ApiKey').SecurePassword
  if(!$secret.Length){$script:chatComposer.FindName('ComposeStatus').Text='请输入 DeepSeek API 密钥。';return}
  try {
    New-Item -ItemType Directory -Path (Split-Path (Get-DeepSeekKeyFile) -Parent) -Force|Out-Null
    [IO.File]::WriteAllText((Get-DeepSeekKeyFile),(ConvertFrom-SecureString $secret),[Text.Encoding]::ASCII)
    $script:chatComposer.FindName('ApiKey').Clear();$script:chatComposer.FindName('KeyPanel').Visibility=[Windows.Visibility]::Collapsed;$script:chatComposer.FindName('ComposeStatus').Text='密钥已加密保存在本机。'
  } catch {$script:chatComposer.FindName('ComposeStatus').Text='密钥保存失败。'}
}
function Send-DeepSeekDraft([string]$Draft){
  if($script:deepSeekJob){$script:chatComposer.FindName('ComposeStatus').Text='DeepSeek 正在回复，请稍候。';return}
  if(!(Test-Path -LiteralPath (Get-DeepSeekKeyFile))){$script:chatComposer.FindName('ComposeStatus').Text='请先输入并保存 DeepSeek 密钥。';return}
  $cipher=[IO.File]::ReadAllText((Get-DeepSeekKeyFile))
  $messages=@($script:deepSeekHistory)+@(@{role='user';content=$Draft})
  $script:deepSeekPending=$Draft;$script:deepSeekReply='';$script:deepSeekStatus='DeepSeek 正在回复…'
  $script:deepSeekJob=Start-Job -ArgumentList $cipher,(ConvertTo-Json -InputObject $messages -Depth 8 -Compress) -ScriptBlock {
    param($cipher,$messagesJson)
    $ErrorActionPreference='Stop';$ptr=[IntPtr]::Zero;$plain=$null
    try {
      $secret=ConvertTo-SecureString $cipher;$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret);$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
      [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
      $messages=ConvertFrom-Json -InputObject $messagesJson
      $json=ConvertTo-Json -InputObject @{model='deepseek-v4-flash';messages=@($messages);stream=$false} -Depth 10 -Compress
      $raw=Invoke-WebRequest -UseBasicParsing -Uri 'https://api.deepseek.com/chat/completions' -Method Post -Headers @{Authorization=('Bearer '+$plain)} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 120
      $response=[Text.Encoding]::UTF8.GetString($raw.RawContentStream.ToArray()) | ConvertFrom-Json
      $answer=[string]$response.choices[0].message.content;if(!$answer){throw 'empty response'}
      [pscustomobject]@{ok=$true;reply=$answer}
    }catch{[pscustomobject]@{ok=$false;reply='DeepSeek 请求失败，请检查密钥、余额或网络。'}}finally{if($ptr-ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)};$plain=$null}
  }
  $record=Add-ChatRecord 'DeepSeek' $Draft;$script:deepSeekRecordId=$record.id
  $script:chatComposer.FindName('Draft').Clear();Update-CodexReplyText
}
function Update-DeepSeekJob {
  if(!$script:deepSeekJob -or $script:deepSeekJob.State -in @('Running','NotStarted')){return}
  $job=$script:deepSeekJob;$script:deepSeekJob=$null
  try{$result=Receive-Job $job -ErrorAction Stop|Select-Object -Last 1
    if($result.ok){$script:deepSeekReply=[string]$result.reply;$script:deepSeekStatus='回复完成';$script:deepSeekHistory+=@(@{role='user';content=$script:deepSeekPending},@{role='assistant';content=$script:deepSeekReply})}
    else{$script:deepSeekReply='';$script:deepSeekStatus=if($result.reply){[string]$result.reply}else{'DeepSeek 请求失败，请重试。'}}
  }catch{$script:deepSeekReply='';$script:deepSeekStatus='DeepSeek 请求失败，请重试。'}finally{Remove-Job $job -Force -ErrorAction SilentlyContinue;$script:deepSeekPending=$null}
  if($script:deepSeekRecordId){Complete-ChatRecord $script:deepSeekRecordId $script:deepSeekReply $script:deepSeekStatus;$script:deepSeekRecordId=$null}
  if($script:chatProvider-eq 'DeepSeek'){Update-CodexReplyText}
}
function Update-CodexReplyText {
  if(!$script:ui.ChatPanel){return}
  $state=$script:chatState
  $thread=@($state.threads|Where-Object{$_.id-eq $state.selectedThreadId}|Select-Object -First 1)
  if($script:chatProvider-eq 'DeepSeek'){
    $title='DeepSeek';$copy=[string]$script:deepSeekReply
    $text=if($copy){$copy}elseif($script:deepSeekStatus){$script:deepSeekStatus}else{'你好，想聊些什么？'}
  }else{
    $title=if($thread.Count){[string]$thread[0].title}else{'Codex 聊天'}
    $copy=if(!$state.busy -and !$script:chatImmediateStatus -and $state.reply -and $state.replyThreadId-eq $state.selectedThreadId){[string]$state.reply}else{''}
    $text=if($script:chatImmediateStatus){$script:chatImmediateStatus}elseif($state.busy){[string]$state.status}elseif($state.error){[string]$state.error}elseif($copy){$copy}elseif(!(Test-CodexChatConnected)){'聊天未连接，请先刷新 GPT 娘额度。'}elseif(!$state.selectedThreadId){'请先在设置中选择一个 Codex 会话。'}else{'你好，想聊些什么？'}
  }
  $script:ui.ChatTitle.ToolTip=$title
  if($script:chatDisplayTarget-cne $text){
    $script:chatDisplayTarget=$text
    $script:chatDisplayElements=[Globalization.StringInfo]::ParseCombiningCharacters($text)
    $script:chatDisplayCount=if($copy){0}else{$script:chatDisplayElements.Length}
    $script:ui.ChatScroll.ScrollToHome()
  }
  if($script:chatDisplayCount-lt $script:chatDisplayElements.Length){$script:chatDisplayCount=[Math]::Min($script:chatDisplayCount+12,$script:chatDisplayElements.Length)}
  $end=if($script:chatDisplayCount-lt $script:chatDisplayElements.Length){$script:chatDisplayElements[$script:chatDisplayCount]}else{$text.Length}
  $script:ui.ChatReply.Text=$text.Substring(0,$end);$script:ui.ChatReply.Tag=$copy
  $script:ui.ChatCopy.IsEnabled=[bool]$copy
  $script:ui.ChatTitle.Text='龙娘  ◆  '+$title
  if($script:chatComposer){$script:chatComposer.FindName('DialogueText').Text=$script:ui.ChatReply.Text;$script:chatComposer.FindName('DialogueName').Text='龙娘  ·  '+$title}
}
function Show-CodexReply {
  if(!$script:chatEnabled){return}
  if($script:sceneTimer){$script:sceneTimer.Stop()}
  if($script:closeTimer){$script:closeTimer.Stop();$script:closeTimer=$null}
  if($script:resetPhaseTimer){$script:resetPhaseTimer.Stop();$script:resetPhaseTimer=$null}
  $script:collapsed=$false;$script:bubbleMode='chat';$script:sceneDeadline=0;$script:bubbleEpoch++
  Update-CodexReplyText;Apply-Scene;Set-BubbleState
}
function Position-CodexComposer {
  if(!$script:chatComposer -or !$script:chatComposer.IsVisible){return}
  $origin=$script:ui.Girl.PointToScreen([Windows.Point]::new(0,$script:ui.Girl.ActualHeight))
  $screen=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new([int]$origin.X,[int]$origin.Y)).WorkingArea
  $handle=[Windows.Interop.WindowInteropHelper]::new($script:chatComposer).Handle
  if($handle-eq [IntPtr]::Zero){return}
  $rect=[GptWidgetNative]::Frame($handle);$w=$rect.Right-$rect.Left;$h=$rect.Bottom-$rect.Top
  $x=[int][Math]::Max($screen.Left+8,[Math]::Min($screen.Right-$w-8,$origin.X-($w-208*$script:displayScale)/2))
  $y=[int]($origin.Y+8)
  if($y+$h-gt $screen.Bottom-8){$top=$script:ui.Girl.PointToScreen([Windows.Point]::new(0,0));$y=[int]($top.Y-$h-8)}
  $y=[int][Math]::Max($screen.Top+8,[Math]::Min($screen.Bottom-$h-8,$y))
  [GptWidgetNative]::SetWindowPos($handle,[IntPtr]::Zero,$x,$y,0,0,0x15)|Out-Null
}
function Open-CodexComposer {
  if(!$script:chatEnabled){return}
  $script:context.IsOpen=$false;$script:chatImmediateStatus='';Update-CodexReplyText
  $script:chatComposer.Topmost=$true
  if(!$script:chatComposer.IsVisible){$script:chatComposer.Show()}
  Position-CodexComposer
  # Only this user-opened input window activates. Reply updates never activate a window.
  $script:chatComposer.Activate()|Out-Null;$script:chatComposer.FindName('Draft').Focus()|Out-Null
  $script:chatComposer.FindName('ComposeStatus').Text=if($script:chatProvider-eq 'DeepSeek'){'DeepSeek · Enter 发送 · Shift+Enter 换行'}elseif($script:chatState.selectedThreadId){'Enter 发送 · Shift+Enter 换行 · Esc 收起'}else{'先在龙娘左上角的设置中选择一个 Codex 会话'}
}
function Send-CodexDraft {
  $draft=$script:chatComposer.FindName('Draft').Text.Trim();if(!$draft){return}
  if($draft.Length-gt 20000){$script:chatComposer.FindName('ComposeStatus').Text='每条消息最多 20000 字';return}
  if($script:chatProvider-eq 'DeepSeek'){Send-DeepSeekDraft $draft;return}
  if($script:chatState.busy){$script:chatComposer.FindName('ComposeStatus').Text='正在等待上一条回复';return}
  if(!(Test-CodexChatConnected)){$script:chatComposer.FindName('ComposeStatus').Text='聊天未连接，请在 Codex 中让 GPT 娘刷新一次额度';return}
  if(!$script:chatState.selectedThreadId){$script:chatComposer.FindName('ComposeStatus').Text='请先在设置 → Codex 聊天中选择会话';return}
  $draft=$script:chatComposer.FindName('Draft').Text.Trim();if(!$draft){return}
  if($draft.Length-gt 20000){$script:chatComposer.FindName('ComposeStatus').Text='每条消息最多 20000 字';return}
  $script:chatExpectedRequestId=Write-CodexChatCommand @{type='send';threadId=[string]$script:chatState.selectedThreadId;model=[string]$script:chatState.selectedModel;prompt=$draft}
  $record=Add-ChatRecord 'Codex' $draft ([string]$script:chatState.selectedThreadId);$script:codexRecordId=$record.id
  $script:chatImmediateStatus='正在发送…';Show-CodexReply
}
function Initialize-WidgetChat {
  $script:chatBackground='transparent';$script:chatHistoryReadError=$false;$script:chatRecords=@(Read-ChatHistory);$script:deepSeekRecordId=$null;$script:codexRecordId=$null
  $script:chatProvider='Codex';$script:deepSeekHistory=@();$script:deepSeekJob=$null;$script:deepSeekReply='';$script:deepSeekStatus='';$script:chatDisplayTarget=$null;$script:chatDisplayElements=@();$script:chatDisplayCount=0
  $script:chatEnabled=$true;$script:chatState=$null;$script:chatImmediateStatus='';$script:chatRevision=$null;$script:chatExpectedRequestId=$null;$script:chatReadAt=0
  try{$prefs=Get-Content -LiteralPath (Join-Path (Get-CodexChatDirectory) 'ui-preferences.json') -Raw -Encoding UTF8|ConvertFrom-Json;if($null-ne $prefs.enabled){$script:chatEnabled=[bool]$prefs.enabled};if($prefs.background-in @('transparent','purple','blue') -or $prefs.background-match '^#[0-9A-Fa-f]{6}$'){$script:chatBackground=[string]$prefs.background}}catch{}
  $script:chatToolbar=[Windows.Markup.XamlReader]::Parse(@'
<Popup xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Placement="Bottom" VerticalOffset="6" AllowsTransparency="True" StaysOpen="True" PopupAnimation="Fade" Focusable="False">
 <Border Background="#FFFCFF" BorderBrush="#DCCDEB" BorderThickness="1" CornerRadius="12" Padding="8,5">
  <StackPanel Orientation="Horizontal">
   <Button x:Name="Talk" Content="聊天" ToolTip="继续已选的 Codex 会话" Padding="10,5" Foreground="#745A98" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
   <Button x:Name="Reply" Content="回复" ToolTip="查看气泡回复" Padding="10,5" Foreground="#745A98" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
   <Button x:Name="Quota" Content="额度" Padding="10,5" Foreground="#745A98" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
  </StackPanel>
 </Border>
</Popup>
'@)
  $script:chatToolbar.PlacementTarget=$script:ui.Girl
  $script:chatToolbar.FindName('Talk').Add_Click({Open-CodexComposer})
  $script:chatToolbar.FindName('Reply').Add_Click({Show-CodexReply})
  $script:chatToolbar.FindName('Quota').Add_Click({Show-Quota})
  $script:chatToolbar.Child.Add_MouseEnter({$script:menuTimer.Stop()})
  $script:chatToolbar.Child.Add_MouseLeave({$script:menuTimer.Start()})
  $script:chatComposer=[Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="GPT-niang-Chat · 对话" Width="480" Height="410" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" ShowActivated="False" Topmost="True" FontFamily="Microsoft YaHei UI">
 <Border x:Name="ChatFrame" Background="#30272038" BorderBrush="#D8B7E5" BorderThickness="1.5" CornerRadius="12" Padding="16,12">
  <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="76"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Grid Margin="0,0,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Border HorizontalAlignment="Left" Background="#AC668F" CornerRadius="4" Padding="12,5"><TextBlock x:Name="DialogueName" Text="龙娘  ·  Codex" FontWeight="SemiBold" Foreground="White"/></Border>
    <ComboBox x:Name="Provider" Grid.Column="1" Width="100" Margin="4,0" SelectedIndex="0"><ComboBoxItem Content="Codex"/><ComboBoxItem Content="DeepSeek"/></ComboBox><Button x:Name="HideCompose" Grid.Column="2" Content="×" Width="25" Margin="3,0"/>
   </Grid>
   <Grid x:Name="KeyPanel" Grid.Row="1" Visibility="Collapsed" Margin="0,0,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><PasswordBox x:Name="ApiKey" Padding="6" ToolTip="输入 DeepSeek API 密钥"/><Button x:Name="SaveKey" Grid.Column="1" Content="保存密钥" Padding="8,3" Margin="6,0,0,0"/></Grid>
   <Border x:Name="DialoguePanel" Grid.Row="2" Background="#A8191427" BorderBrush="#805D8097" BorderThickness="1" CornerRadius="6" Padding="12,10"><ScrollViewer x:Name="DialogueScroll" VerticalScrollBarVisibility="Auto"><TextBlock x:Name="DialogueText" TextWrapping="Wrap" FontSize="15" LineHeight="23" Foreground="#FFF6FD" Text="你好，想聊些什么？"/></ScrollViewer></Border>
   <Border x:Name="HistoryPanel" Grid.Row="2" Background="#C0191427" BorderBrush="#805D8097" BorderThickness="1" CornerRadius="6" Padding="12,6" Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="HistoryList"/></ScrollViewer></Border>
   <TextBox x:Name="Draft" Grid.Row="3" Margin="0,9,0,0" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" FontSize="14" Padding="8" BorderBrush="#AE8BB9" Background="#FFF8FC" Foreground="#33243F"/>
   <Grid Grid.Row="4" Margin="0,9,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="ComposeStatus" Text="Enter 发送 · Shift+Enter 换行" TextWrapping="Wrap" VerticalAlignment="Center" FontSize="10.5" Foreground="#E6CFEA"/><Button x:Name="Full" Grid.Column="1" Content="记录" Padding="8,4" Margin="3,0"/><Button x:Name="CopyReply" Grid.Column="2" Content="复制" Padding="8,4" Margin="3,0"/><Button x:Name="Reset" Grid.Column="3" Content="新对话" Padding="8,4" Margin="3,0"/><Button x:Name="Send" Grid.Column="4" Content="发送  ▶" Padding="12,4" Margin="3,0" Background="#AC668F" Foreground="White"/></Grid>
  </Grid>
 </Border>
</Window>
'@)
  $script:chatComposer.FindName('Provider').Add_SelectionChanged({param($sender,$event)
    $script:chatProvider=[string]$sender.SelectedItem.Content;$script:chatDisplayTarget=$null
    $script:chatComposer.FindName('KeyPanel').Visibility=if($script:chatProvider-eq 'DeepSeek' -and !(Test-Path -LiteralPath (Get-DeepSeekKeyFile))){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
    $script:chatComposer.FindName('ComposeStatus').Text=if($script:chatProvider-eq 'DeepSeek'){'DeepSeek · Enter 发送'}else{'Codex · Enter 发送'}
    Update-ChatHistoryView
    $script:chatComposer.FindName('Reset').IsEnabled=$script:chatProvider-eq 'DeepSeek' -and !$script:deepSeekJob
    Update-CodexReplyText
  })
  $script:chatComposer.FindName('Reset').IsEnabled=$false
  $script:chatComposer.FindName('SaveKey').Add_Click({Save-DeepSeekKey})
  $script:chatComposer.FindName('CopyReply').Add_Click({if($script:ui.ChatReply.Tag){try{[Windows.Clipboard]::SetText([string]$script:ui.ChatReply.Tag);$script:chatComposer.FindName('ComposeStatus').Text='已复制完整回复。'}catch{$script:chatComposer.FindName('ComposeStatus').Text='复制失败，请重试。'}}})
  $script:chatComposer.FindName('Full').Add_Click({if($script:chatComposer.FindName('HistoryPanel').Visibility-eq [Windows.Visibility]::Visible){Show-CurrentDialogue;$script:chatComposer.FindName('Full').Content='记录'}else{$script:chatDisplayCount=$script:chatDisplayElements.Length;Update-CodexReplyText;Show-ChatHistory;$script:chatComposer.FindName('Full').Content='对白'}})
  $script:chatComposer.FindName('Reset').Add_Click({if(!$script:deepSeekJob){$script:deepSeekHistory=@();$script:deepSeekReply='';$script:deepSeekStatus='已开始新对话。';Update-CodexReplyText}})
  $script:chatComposer.FindName('HideCompose').Add_Click({$script:chatComposer.Hide()})
  $script:chatComposer.FindName('Send').Add_Click({Send-CodexDraft})
  $script:chatComposer.Add_PreviewKeyDown({param($sender,$event)
    if($event.Key-eq [Windows.Input.Key]::Escape){$sender.Hide();$event.Handled=$true}
    elseif($event.Key-eq [Windows.Input.Key]::Return -and $script:chatComposer.FindName('ApiKey').IsKeyboardFocused){Save-DeepSeekKey;$event.Handled=$true}
    elseif($event.Key-eq [Windows.Input.Key]::Return -and !([Windows.Input.Keyboard]::Modifiers-band [Windows.Input.ModifierKeys]::Shift)){Send-CodexDraft;$event.Handled=$true}
  })
  $script:ui.ChatTalk.Add_Click({Open-CodexComposer})
  $script:ui.ChatCopy.Add_Click({if($script:ui.ChatReply.Tag){try{[Windows.Clipboard]::SetText([string]$script:ui.ChatReply.Tag);$script:ui.ChatCopy.ToolTip='已复制全文'}catch{$script:ui.ChatCopy.ToolTip='剪贴板暂时忙，请重试'}}})
  $script:ui.ChatClose.Add_Click({Hide-Quota})
  $script:chatState=Read-CodexChatState
  Set-ChatBackground $script:chatBackground
  if($script:chatHistoryReadError){$script:chatComposer.FindName('ComposeStatus').Text='无法读取已保存的对话记录。'}
  Add-CodexChatSettings
  if($script:chatEnabled){Set-CodexChatEnabled $true}
}
function Add-CodexChatSettings {
  $previous=$script:settingsMenuTarget;$script:settingsMenuTarget=$script:context
  try{
    $script:chatSettings=Add-SettingsSubmenu '聊天设置' {
      $script:chatEnableItem=Add-SettingsAction '启用桌面聊天' {param($sender,$event)Set-CodexChatEnabled ([bool]$sender.IsChecked)} -Checkable -ReturnItem
      $script:chatEnableItem.IsChecked=$script:chatEnabled
      Add-SettingsAction '输入消息' {Open-CodexComposer}
      Add-SettingsAction 'DeepSeek 密钥设置' {Show-DeepSeekKeySettings}
      Add-SettingsAction '查看对话记录' {Open-CodexComposer;Show-ChatHistory;$script:chatComposer.FindName('Full').Content='对白'}
      Add-SettingsAction '全部展开对话' {Set-ChatHistoryExpanded $true}
      Add-SettingsAction '全部折叠对话' {Set-ChatHistoryExpanded $false}
      Add-SettingsSubmenu '聊天背景' {
        Add-SettingsAction '透明' {Set-ChatBackground 'transparent'}
        Add-SettingsAction '紫色' {Set-ChatBackground 'purple'}
        Add-SettingsAction '蓝色' {Set-ChatBackground 'blue'}
        Add-SettingsAction '自定义颜色…' {
          $dialog=[Windows.Forms.ColorDialog]::new();try{if($dialog.ShowDialog()-eq [Windows.Forms.DialogResult]::OK){Set-ChatBackground ('#{0:X2}{1:X2}{2:X2}' -f $dialog.Color.R,$dialog.Color.G,$dialog.Color.B)}}finally{$dialog.Dispose()}
        }
      }
      Add-SettingsAction '查看回复气泡' {Show-CodexReply}
      $script:chatThreadMenu=Add-SettingsSubmenu '选择会话' {} -ReturnItem
      $script:chatModelMenu=Add-SettingsSubmenu '选择模型' {} -ReturnItem
      Add-SettingsAction '刷新会话列表' {$null=Write-CodexChatCommand @{type='refresh'}}
      $script:chatConnectionItem=Add-SettingsAction '正在连接…' {} -ReturnItem;$script:chatConnectionItem.IsEnabled=$false
    } -ReturnItem
    $script:context.Items.Remove($script:chatSettings);$script:context.Items.Insert(0,$script:chatSettings)
    $script:chatSettings.Add_SubmenuOpened({Update-CodexChatSettings})
  }finally{$script:settingsMenuTarget=$previous}
  Update-CodexChatSettings
}
function Update-CodexChatSettings {
  if(!$script:chatSettings){return}
  $state=Read-CodexChatState;if($state){$script:chatState=$state}
  $script:chatEnableItem.IsChecked=$script:chatEnabled
  $script:chatConnectionItem.Header=if(Test-CodexChatConnected){'已连接 · 本机 Codex'}else{'未连接：在 Codex 中刷新 GPT 娘额度'}
  $key=(@($script:chatState.threads|ForEach-Object{$_.id+'|'+$_.title})-join ';')+'#'+$script:chatState.selectedThreadId+'#'+$script:chatState.selectedModel+'#'+$script:chatState.busy+'#'+(@($script:chatState.models|ForEach-Object{$_.id})-join ';')
  if($key-eq $script:chatMenuKey){return};$script:chatMenuKey=$key
  $script:chatThreadMenu.Items.Clear();$script:chatModelMenu.Items.Clear()
  $previous=$script:settingsMenuTarget
  try{
    $script:settingsMenuTarget=$script:chatThreadMenu
    foreach($thread in $script:chatState.threads){
      $label=[string]$thread.title;if($label.Length-gt 28){$label=$label.Substring(0,28)+'…'}
      $row=Add-SettingsAction $label {param($sender,$event)$script:chatImmediateStatus='';$null=Write-CodexChatCommand @{type='select';threadId=[string]$sender.Tag}} -Checkable -ReturnItem
      $row.Tag=$thread.id;$row.ToolTip=$thread.title;$row.IsChecked=$thread.id-eq $script:chatState.selectedThreadId;$row.IsEnabled=!$script:chatState.busy;$row.Uid='radio'
    }
    if(!$script:chatThreadMenu.Items.Count){$item=Add-SettingsAction '暂无本地 Codex 会话' {} -ReturnItem;$item.IsEnabled=$false}
    $script:settingsMenuTarget=$script:chatModelMenu
    $choices=@([pscustomobject]@{id='';label='沿用会话模型'})+@($script:chatState.models)
    foreach($model in $choices){
      $item=Add-SettingsAction $model.label {param($sender,$event)$null=Write-CodexChatCommand @{type='model';model=[string]$sender.Tag}} -Checkable -ReturnItem
      $item.Tag=$model.id;$item.IsChecked=$model.id-eq [string]$script:chatState.selectedModel;$item.IsEnabled=!$script:chatState.busy;$item.Uid='radio'
    }
  }finally{$script:settingsMenuTarget=$previous}
  Sync-CodexChatMenuChecks
}
function Sync-CodexChatMenuChecks {
  if(!$script:chatSettings){return}
  foreach($row in $script:chatThreadMenu.Items){if($row.IsCheckable){$row.IsChecked=[string]$row.Tag-eq [string]$script:chatState.selectedThreadId;$row.IsEnabled=!$script:chatState.busy}}
  foreach($row in $script:chatModelMenu.Items){if($row.IsCheckable){$row.IsChecked=[string]$row.Tag-eq [string]$script:chatState.selectedModel;$row.IsEnabled=!$script:chatState.busy}}
  $thread=$script:chatState.threads|Where-Object{$_.id-eq $script:chatState.selectedThreadId}|Select-Object -First 1
  $title=if($thread){[string]$thread.title}else{''};if($title.Length-gt 17){$title=$title.Substring(0,17)+'…'}
  $script:chatThreadMenu.Header=if($title){'会话：'+$title}else{'选择会话'}
  $model=$script:chatState.models|Where-Object{$_.id-eq $script:chatState.selectedModel}|Select-Object -First 1
  $script:chatModelMenu.Header=if($model){'模型：'+$model.label}else{'模型：沿用会话'}
  $script:chatConnectionItem.Header=if(Test-CodexChatConnected){'已连接 · 本机 Codex'}else{'未连接：在 Codex 中刷新 GPT 娘额度'}
}
function Tick-WidgetChat([long]$Now){
  if(!$script:chatToolbar){return}
  if($Now-$script:chatReadAt-lt 400){return};$script:chatReadAt=$Now
  Update-DeepSeekJob
  if($script:chatComposer){$script:chatComposer.FindName('Reset').IsEnabled=$script:chatProvider-eq 'DeepSeek' -and !$script:deepSeekJob}
  $state=Read-CodexChatState
  if($state){
    $script:chatState=$state
    if($script:chatProvider-eq 'Codex' -and $script:chatHistoryThread-ne [string]$state.selectedThreadId){$script:chatHistoryThread=[string]$state.selectedThreadId;Update-ChatHistoryView}
    if($script:chatProvider-eq 'Codex' -and $script:chatEnabled -and $state.busy -and $state.requestId -and $state.requestId-ne $script:chatObservedRequestId){
      $script:chatObservedRequestId=$state.requestId;$script:chatExpectedRequestId=$state.requestId;Show-CodexReply
    }
    if($script:chatExpectedRequestId -and $state.lastCommandId-eq $script:chatExpectedRequestId){
      $script:chatImmediateStatus=''
      if($script:chatProvider-eq 'Codex' -and $state.busy -and $state.requestId-eq $script:chatExpectedRequestId){$script:chatComposer.FindName('Draft').Clear()}
      if($state.replyRequestId-eq $script:chatExpectedRequestId -or $state.error){if($script:codexRecordId){Complete-ChatRecord $script:codexRecordId $(if($state.replyRequestId-eq $script:chatExpectedRequestId){[string]$state.reply}else{''}) $(if($state.error){[string]$state.error}else{'回复完成'});$script:codexRecordId=$null};if($script:chatProvider-eq 'Codex'){Show-CodexReply};$script:chatExpectedRequestId=$null}
    }
    if($script:context.IsOpen){Sync-CodexChatMenuChecks}
  }
  if($script:bubbleMode-eq 'chat' -or $script:chatComposer.IsVisible){Update-CodexReplyText}
  if($script:chatComposer.IsVisible){Position-CodexComposer}
}
function Stop-WidgetChat {
  if($script:deepSeekJob){Stop-Job $script:deepSeekJob -ErrorAction SilentlyContinue;Remove-Job $script:deepSeekJob -Force -ErrorAction SilentlyContinue}
  if($script:chatToolbar){$script:chatToolbar.IsOpen=$false}
  if($script:chatComposer){$script:chatComposer.Close()}
}
