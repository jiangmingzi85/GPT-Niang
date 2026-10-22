param([string]$OutputDirectory,[string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
foreach($module in @('characters.ps1','expressions.ps1','expression-settings.ps1')){. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $appDir ('runtime\'+$module)),[Text.Encoding]::UTF8)))}
if(!$OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('expressions-'+[Guid]::NewGuid().ToString('N'))}
$script:dataDir=$OutputDirectory;$null=[IO.Directory]::CreateDirectory($script:dataDir)
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
function New-TestStatus([double]$Remaining,[long]$ObservedAt){return @{ok=$true;queryOk=$true;observedAt=$ObservedAt;accountKey='account-a';plan='Plus';windows=@(@{id='primary';remaining=$Remaining;resetsAt=[Math]::Floor($ObservedAt/1000)+3600})}}
function Assert-StateSequence([double[]]$Remaining,[string[]]$Expected,[long]$Now){
  Assert ($Remaining.Count-eq $Expected.Count) 'State sequence fixture lengths must match'
  for($index=0;$index-lt $Remaining.Count;$index++){
    $decision=Get-WidgetExpressionDecision (New-TestStatus $Remaining[$index] $Now) $Now
    Assert ($decision.state-eq $Expected[$index]) ('Remaining '+$Remaining[$index]+' expected '+$Expected[$index]+' but was '+$decision.state)
    Assert (![string]::IsNullOrWhiteSpace([string]$decision.reason)) 'Every expression decision must explain its cause'
  }
}
function New-TestImage([byte]$Red){$pixels=[byte[]]@(0,0,$Red,255,0,0,0,0,0,0,$Red,255,0,0,$Red,255);$image=[Windows.Media.Imaging.BitmapSource]::Create(2,2,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,8);$image.Freeze();return $image}
function Write-TestImage($Image,[string]$Path){$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Image));$stream=[IO.File]::Create($Path);try{$encoder.Save($stream)}finally{$stream.Dispose()}}
Initialize-WidgetExpressions
$script:quotaAlertSettings=@{low=20;critical=5};$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:status=[pscustomobject]@{ok=$true;queryOk=$true;observedAt=$now;windows=@([pscustomobject]@{remaining=80},[pscustomobject]@{remaining=15})}
Assert ((Get-WidgetExpressionState $script:status $now)-eq 'low') 'Most constrained window should select low'
$script:status.windows[1].remaining=4;Assert ((Get-WidgetExpressionState $script:status $now)-eq 'critical') 'Critical threshold'
$script:status.windows[1].remaining=0;Assert ((Get-WidgetExpressionState $script:status $now)-eq 'exhausted') 'Exhausted threshold'
$script:status.queryOk=$false;Assert ((Get-WidgetExpressionState $script:status $now)-eq 'unknown') 'Failed queries must not look exhausted'
$script:status.queryOk=$true;Assert ((Get-WidgetExpressionState $script:status ($now+180001))-eq 'unknown') 'Stale snapshots must be unknown'
$script:status.windows[1].remaining='NaN';Assert ((Get-WidgetExpressionState $script:status $now)-eq 'normal') 'Reject nonfinite remaining values'
$script:status.windows[1].remaining=80
Initialize-WidgetExpressions;$script:quotaAlertSettings=@{low=25;critical=10}
Assert-StateSequence @(25,26,27,28,25) @('low','low','low','normal','low') $now
Initialize-WidgetExpressions
Assert-StateSequence @(10,11,12,13,10) @('critical','critical','critical','low','critical') $now
Initialize-WidgetExpressions
Assert-StateSequence @(0,1,11,13,26,28) @('exhausted','critical','critical','low','low','normal') $now
Initialize-WidgetExpressions;$script:quotaAlertSettings=@{low=25;critical=10;hysteresis=4}
Assert-StateSequence @(25,28,29,30) @('low','low','low','normal') $now
$script:quotaAlertSettings=@{low=25;critical=10;hysteresis=2}
$unknownCases=@(
  @{label='Failed query';status=(New-TestStatus 26 $now);change={param($value) $value.queryOk=$false}},
  @{label='Stale snapshot';status=(New-TestStatus 26 ($now-180001));change={param($value)}},
  @{label='Future snapshot';status=(New-TestStatus 26 ($now+1000));change={param($value)}},
  @{label='Missing snapshot';status=$null;change={param($value)}}
)
$unknownReasons=@()
foreach($case in $unknownCases){
  Initialize-WidgetExpressions
  Assert-StateSequence @(25) @('low') $now
  & $case.change $case.status
  $decision=Get-WidgetExpressionDecision $case.status $now
  Assert ($decision.state-eq 'unknown') ($case.label+' must select unknown')
  Assert (![string]::IsNullOrWhiteSpace([string]$decision.reason)) ($case.label+' must explain unknown')
  $unknownReasons+=[string]$decision.reason
  Assert-StateSequence @(26) @('normal') $now
}
Assert (@($unknownReasons|Select-Object -Unique).Count-eq $unknownCases.Count) 'Unknown causes must have distinct reasons for the settings explanation'
Initialize-WidgetExpressions
$emptyStatus=New-TestStatus 80 $now;$emptyStatus.windows=@()
Assert ((Get-WidgetExpressionDecision $emptyStatus $now).state-eq 'unknown') 'No valid quota windows must select unknown'
foreach($context in @('account','plan','character','reset','threshold')){
  Initialize-WidgetExpressions;$script:characterId='context-a';$script:quotaAlertSettings=@{low=25;critical=10;hysteresis=2}
  Assert-StateSequence @(25) @('low') $now
  $changed=New-TestStatus 26 $now
  switch($context){
    'account' {$changed.accountKey='account-b'}
    'plan' {$changed.plan='Pro'}
    'character' {$script:characterId='context-b'}
    'reset' {$changed.windows[0].resetsAt+=3600}
    'threshold' {$script:quotaAlertSettings.low=24}
  }
  Assert ((Get-WidgetExpressionDecision $changed $now).state-eq 'normal') ($context+' change must discard previous quota hysteresis')
}
Initialize-WidgetExpressions;$script:quotaAlertSettings=@{low=20;critical=5}
$script:status=[pscustomobject]@{ok=$true;queryOk=$true;observedAt=$now;windows=@([pscustomobject]@{remaining=80},[pscustomobject]@{remaining=80})}
$script:characterId='custom-test';$default=Join-Path $script:dataDir 'default.png';$source=Join-Path $script:dataDir 'source.png'
Write-TestImage (New-TestImage 40) $default;Write-TestImage (New-TestImage 200) $source
$script:activeCharacter=@{id=$script:characterId;name='Test';path=$default}
$script:ui=@{Girl=[Windows.Controls.Image]::new()};$script:ui.Girl.Width=208;$script:ui.Girl.Height=208
$script:window=[pscustomobject]@{IsVisible=$true};$script:context=[pscustomobject]@{IsOpen=$false}
$halo=[Windows.Shapes.Rectangle]::new();$tint=[Windows.Shapes.Rectangle]::new()
foreach($element in @($halo,$tint)){$element.Width=208;$element.Height=208;$element.OpacityMask=[Windows.Media.ImageBrush]::new()}
$script:widgetColors=@{halo=$halo;tint=$tint};$script:drag=$null;$script:widgetMusic=$null
Update-WidgetExpression $now
Assert ($script:ui.Girl.Source.PixelWidth-eq 2 -and $script:alphaPixels[3]-eq 255 -and $script:alphaPixels[7]-eq 0) 'Default image and alpha click map'
$file=Import-WidgetExpressionImage $script:characterId 'happy' $source
Assert ([IO.File]::Exists((Join-Path $script:dataDir ('expressions\'+$file)))) 'Import owns PNG copy'
Assert ([IO.File]::Exists($source)) 'Import preserves source'
$script:expressionTemporary=@{state='happy';until=$now+1000};Update-WidgetExpression $now
Assert ($script:alphaPixels[2]-eq 200) 'Temporary happy image should render'
Assert ([object]::ReferenceEquals($halo.OpacityMask.ImageSource,$script:ui.Girl.Source)) 'Color mask follows expression'
$script:status.windows[1].remaining=0;Update-WidgetExpression ($now+1001)
Assert ($script:alphaPixels[2]-eq 40 -and !$script:expressionTemporary) 'Temporary end re-evaluates current state and fallback'
$script:expressionConfig.characters[$script:characterId].exhausted='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png';Reset-WidgetExpression;Update-WidgetExpression $now
Assert ($script:expressionCache.ContainsKey($script:characterId+'|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png')) 'Missing image failure is cached'
Assert ($script:alphaPixels[2]-eq 40) 'Missing image falls back to same character'
$script:quotaAlertSettings=@{low=25;critical=10;hysteresis=2};$script:status=New-TestStatus 10 $now
Assert ((Get-WidgetExpressionState $script:status $now)-eq 'critical') 'Set quota baseline before temporary feedback'
$script:expressionTemporary=@{state='happy';until=$now+1000};$script:status.windows[0].remaining=11;Update-WidgetExpression $now
Assert ($script:alphaPixels[2]-eq 200) 'Happy feedback renders while quota remains critical'
Assert ((Get-WidgetExpressionDecision $script:status $now).state-eq 'critical') 'Happy feedback must not replace quota history'
Update-WidgetExpression ($now+1001)
Assert (!$script:expressionTemporary -and (Get-WidgetExpressionDecision $script:status ($now+1001)).state-eq 'critical') 'Expired feedback returns to the held quota state'
$originalBindings=$script:expressionConfig.characters[$script:characterId].Clone()
try{
  $normalFile=Import-WidgetExpressionImage $script:characterId 'normal' $source
  $configured=Get-WidgetExpressionAsset 'normal'
  Assert ($configured.kind-eq 'configured' -and $configured.image.PixelWidth-eq 2 -and $configured.path-eq (Join-Path $script:dataDir ('expressions\'+$normalFile))) 'Configured thumbnail resolves the imported image and path'
  $originalAsset=Get-WidgetExpressionAsset 'default'
  Assert ($originalAsset.kind-eq 'default' -and $originalAsset.path-eq $default) 'Default state must not use the configured normal expression'
  $script:expressionConfig.enabled=$false;Update-WidgetExpression $now
  Assert ($script:alphaPixels[2]-eq 40) 'Disabled expressions must render the original character even with normal configured'
  $script:expressionConfig.enabled=$true;Reset-WidgetExpression
  $script:expressionConfig.characters[$script:characterId].Remove('low');Reset-WidgetExpression
  $fallback=Get-WidgetExpressionAsset 'low'
  Assert ($fallback.kind-eq 'normal' -and $fallback.path-eq $configured.path) 'Unconfigured state thumbnail falls back to normal'
  $script:expressionSettingsWindow=[Windows.Window]::new();$script:expressionSettingsRows=@{}
  $script:expressionSettingsControls=@{reason=[Windows.Controls.TextBlock]::new()}
  foreach($state in @('normal','low','critical','exhausted','unknown','happy')){
    $script:expressionSettingsRows[$state]=@{image=[Windows.Controls.Image]::new();text=[Windows.Controls.TextBlock]::new()}
  }
  Update-WidgetExpressionSettingsRows
  foreach($row in $script:expressionSettingsRows.Values){Assert ($row.image.Source.PixelWidth-eq 64 -and $row.image.Source.PixelHeight-eq 64) 'Settings thumbnails must retain only 64px render targets'}
  Assert ($script:expressionSettingsRows.normal.text.Text-eq '已配置') 'Configured thumbnail caption'
  Assert ($script:expressionSettingsRows.low.text.Text-eq '回退普通表情') 'Unconfigured thumbnail caption explains normal fallback'
  $script:status=New-TestStatus 80 $now;Update-WidgetExpression $now
  $validReason=$script:expressionSettingsControls.reason.Text
  Assert ($validReason-eq $script:expressionDecision.reason -and $validReason) 'Settings reason follows the live valid decision'
  Update-WidgetExpression ($now+180001)
  Assert ($script:expressionSettingsControls.reason.Text-ne $validReason -and $script:expressionDecision.state-eq 'unknown') 'Settings reason refreshes when the same snapshot expires'
  $script:expressionConfig.enabled=$false;Update-WidgetExpression $now
  Assert ($script:expressionSettingsControls.reason.Text.Contains('已关闭')) 'Disabled status explanation is visible'
  $script:expressionConfig.enabled=$true;$script:expressionPreview='happy';Update-WidgetExpression $now
  Assert ($script:expressionSettingsControls.reason.Text.Contains('预览')) 'Preview explanation is visible'
  $script:expressionPreview=$null
  $badFile='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png';$badPath=Join-Path $script:dataDir ('expressions\'+$badFile)
  [IO.File]::WriteAllText($badPath,'not a PNG',[Text.UTF8Encoding]::new($false))
  $script:expressionConfig.characters[$script:characterId].low=$badFile;Reset-WidgetExpression
  $fallback=Get-WidgetExpressionAsset 'low'
  Assert ($fallback.kind-eq 'normal' -and $fallback.image -and $fallback.notice) 'Corrupt expression explains fallback to a usable normal image'
  Update-WidgetExpressionSettingsRows
  Assert ($script:expressionSettingsRows.low.text.Text.Contains('回退普通表情') -and $script:expressionSettingsRows.low.text.Text.Contains('图片失效')) 'Corrupt thumbnail caption identifies both fallback and failure'
  $script:expressionConfig.characters[$script:characterId].normal=$badFile;Reset-WidgetExpression
  $fallback=Get-WidgetExpressionAsset 'low'
  Assert ($fallback.kind-eq 'default' -and $fallback.path-eq $default -and $fallback.image -and $fallback.notice) 'Corrupt expression and normal images fall back to the original character'
}finally{
  $script:expressionSettingsWindow=$null;$script:expressionSettingsControls=$null;$script:expressionSettingsRows=$null
  $script:expressionConfig.enabled=$true;$script:expressionConfig.characters[$script:characterId]=$originalBindings;Reset-WidgetExpression
}
$music=[pscustomobject]@{Enabled=$true;RefreshCount=0};$music|Add-Member -MemberType ScriptMethod -Name RefreshLayout -Value {$this.RefreshCount++};$script:widgetMusic=$music
Set-WidgetPetImage (New-TestImage 70);Assert ($music.RefreshCount-eq 1) 'Music alpha bounds refresh without stopping playback'
$script:expressionConfig.action=@{kind='bounce';amplitude=4;durationMs=600};Start-WidgetPetAction $now;Assert (!$script:petAction) 'Music suppresses extra motion'
$script:widgetMusic=$null;$original=$script:ui.Girl.RenderTransform;Start-WidgetPetAction $now;Update-WidgetPetAction ($now+150)
Assert ($script:petAction.entries[0].motion.Y-lt 0) 'Bounce moves only dedicated transform'
Assert ($halo.RenderTransform-is [Windows.Media.TransformGroup]) 'Color layer shares action'
$script:drag=@{moved=$true};Update-WidgetPetAction ($now+200)
Assert (!$script:petAction -and [object]::ReferenceEquals($original,$script:ui.Girl.RenderTransform)) 'Drag cancels and restores original transform'
$script:drag=$null;Save-WidgetExpressionConfig;Initialize-WidgetExpressions
Assert ($script:expressionConfig.characters[$script:characterId].happy-eq $file) 'Expression bindings survive restart'
Assert ($script:expressionConfig.action.kind-eq 'bounce') 'Action settings survive restart'
$future=@{ok=$true;queryOk=$true;observedAt=$now+1000;windows=@(@{remaining=50})}
Assert ((Get-WidgetExpressionState $future $now)-eq 'unknown') 'Future snapshots must not choose a normal expression'
$expired=@{ok=$true;queryOk=$true;observedAt=$now;windows=@(@{remaining=50;resetsAt=[Math]::Floor($now/1000)-1})}
Assert ((Get-WidgetExpressionState $expired $now)-eq 'unknown') 'Expired windows must not choose a normal expression'
Write-Output ('PASS: expressions thresholds/hysteresis, context resets, decision causes, thumbnail fallback, temporary feedback, independent import, mask/alpha, music refresh, action cancellation, persistence. Test files: '+$OutputDirectory)
