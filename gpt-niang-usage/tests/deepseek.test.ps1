$ErrorActionPreference='Stop'
$p=Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\chat-ui.ps1'
$text=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors){throw ($errors|Out-String)}
$jobs=$ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Job'},$true)
if($jobs.Count-ne 1){throw 'Expected one job'}
$block=$jobs[0].CommandElements | Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]} | Select-Object -First 1
$script=$block.ScriptBlock.Extent.Text.Trim().TrimStart('{').TrimEnd('}')
$mock='function Invoke-WebRequest { param([switch]$UseBasicParsing,$Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec) if($Uri -ne "https://api.deepseek.com/chat/completions" -or $Method -ne "Post"){throw "endpoint"}; if($Headers.Authorization -ne "Bearer test-key"){throw "authentication"}; $request=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json; if($request.model -ne "deepseek-v4-flash" -or @($request.messages).Count -ne 3 -or $request.messages[2].content -ne "new"){throw "payload"}; return @{RawContentStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes("{""choices"":[{""message"":{""content"":""你好，世界！""}}]}"))} }'
$script=$script.Replace("`n    `$ErrorActionPreference='Stop'",("`n"+$mock+"`n    `$ErrorActionPreference='Stop'"))
$script=$script.Replace('catch{[pscustomobject]@{ok=$false;', 'catch{throw;[pscustomobject]@{ok=$false;')
$secret=ConvertTo-SecureString 'test-key' -AsPlainText -Force
$cipher=ConvertFrom-SecureString $secret
$json='[{"role":"user","content":"old"},{"role":"assistant","content":"reply"},{"role":"user","content":"new"}]'
$job=Start-Job -ScriptBlock ([scriptblock]::Create($script)) -ArgumentList $cipher,$json
try {$result=Receive-Job $job -Wait -ErrorAction Stop; if(!$result.ok -or $result.reply-ne '你好，世界！'){throw 'Mock request failed'}; 'PASS: encrypted key, asynchronous request, endpoint, multi-turn payload, and UTF-8 Chinese response'}finally{Remove-Job $job -Force}
