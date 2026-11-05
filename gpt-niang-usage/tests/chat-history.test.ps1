$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$p=Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\chat-ui.ps1'
. ([scriptblock]::Create([IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)))
$script:historyTestPath=Join-Path $env:TEMP ('gpt-niang-history-test-'+[Guid]::NewGuid().ToString('N')+'.dat')
function Get-ChatHistoryFile {return $script:historyTestPath}
function Update-ChatHistoryView {}
$script:chatComposer=$null;$script:chatHistoryReadError=$false;$script:chatRecords=@()
try{
 $r=Add-ChatRecord 'DeepSeek' '今天好吗？';Complete-ChatRecord $r.id '很好，谢谢！' '回复完成'
 $raw=[IO.File]::ReadAllText($script:historyTestPath);if($raw.Contains('今天好吗') -or $raw.Contains('很好')){throw 'History must be encrypted'}
 $loaded=@(Read-ChatHistory);if($loaded.Count-ne 1 -or $loaded[0].question-ne '今天好吗？' -or $loaded[0].answer-ne '很好，谢谢！'){throw 'History round trip failed'}
 $r2=Add-ChatRecord 'Codex' '测试二' 'thread-1';Complete-ChatRecord $r2.id '回复二' '回复完成'
 $loaded=@(Read-ChatHistory);if($loaded.Count-ne 2 -or $loaded[1].question-ne '测试二'){throw 'History replace failed'}
 'PASS: encrypted persistence, update, and Chinese conversation round trip'
}finally{Remove-Item -LiteralPath $script:historyTestPath -ErrorAction SilentlyContinue}
