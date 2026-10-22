param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$appDir=Split-Path $TestRoot -Parent
foreach($module in @('quota-notifications.ps1','ui-settings.ps1','quote-layout.ps1')){
  . ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $appDir ('runtime/'+$module)),[Text.Encoding]::UTF8)))
}
$source=[IO.File]::ReadAllText((Join-Path $appDir 'widget.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Write-WidgetJson','Open-WidgetBubble','Apply-Scene','Update-BubbleTooltip','Get-QuotaRows','Get-QuotaWindowLabel')){
  $definition=$ast.Find({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst]-and $node.Name-eq $name},$true)
  . ([scriptblock]::Create($definition.Extent.Text))
}
$script:dataDir=Join-Path ([IO.Path]::GetTempPath()) ('quota-ui-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($script:dataDir)
$script:window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $appDir 'widget.xaml'),[Text.Encoding]::UTF8))
$script:ui=@{};foreach($name in @('Root','Bubble','Tail','TailNear','SceneText','QuotaText','QuoteText','Refresh','LiveDot')){$script:ui[$name]=$script:window.FindName($name)}
$script:context=@{IsOpen=$false};$script:settingsSizePreview=$false;$script:collapsed=$true;$script:widgetColors=$null
$script:completionTemporary=$null;$script:bubbleEpoch=0;$script:sceneRevision=0;$script:sceneTimer=$null;$script:closeTimer=$null
$script:status=@{accountKey='fixture-account';plan='plus';ok=$true;queryOk=$true;observedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();windows=@(@{minutes=300;remaining=25})}
$script:shown=0;$script:feedback=0;$script:refreshes=0;$script:scriptFailures=0
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Request-Refresh {$script:refreshes++}
function Test-WidgetUpdateEditor {return $false}
function Test-WidgetCompletionForeground {return $true}
function Test-CompletionFullscreen {return $false}
function Reset-WidgetAutoQuoteSchedule {}
function Fit-QuoteText {$script:ui.QuoteText.Tag=$script:ui.QuoteText.Text}
function Set-AnimatedValue {}
function Animate-Value {}
function Restart-SceneTtl {}
function Save-Settings {}
function Show-WidgetPetFeedback {$script:feedback++}
function Hide-Quota {$script:collapsed=$true}
function Open-TestBubble {Open-WidgetBubble 'quota-alert'}
function Write-EventState($Events,[string]$Account='fixture-account'){
  Write-WidgetJson (Join-Path $script:dataDir 'quota-alert-state.json') @{version=1;enabled=$true;settingsRevision=$script:quotaAlertSettings.revision;accountKey=$Account;plan='plus';events=@($Events)}
}
if(!('CompletionWindowLayer'-as [type])){Add-Type 'public static class CompletionWindowLayer { public static System.IntPtr GetForegroundWindow(){ return System.IntPtr.Zero; } }'}
$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$event=@{id='fixture-event';type='low';windowKey='minutes:300';label='5 小时';remaining=25;at=$now;accountKey='fixture-account'}
try{
  Initialize-WidgetQuotaNotifications
  Assert (!$script:quotaAlertSettings.enabled) 'Reminders must default off'
  Set-WidgetQuotaPreference 'enabled' $true
  Assert ($script:refreshes-eq 1) 'Settings changes request a refresh'
  Write-EventState @($event)
  $script:context.IsOpen=$true;Tick-WidgetQuotaNotifications $true $now
  Assert (@($script:quotaAlertAck).Count-eq 0) 'Opening a menu must defer rather than acknowledge alerts'
  $script:context.IsOpen=$false
  $script:quoteEditor=@{IsVisible=$true};Tick-WidgetQuotaNotifications $true $now
  Assert (@($script:quotaAlertAck).Count-eq 0) 'Editing quotes must defer reminders'
  $script:quoteEditor=$null
  $script:status.queryOk=$false
  Assert (@(Get-WidgetQuotaEvents $now).Count-eq 0) 'Cached failed readings must not present events'
  $script:status.queryOk=$true
  $script:status.accountKey='other-account'
  Assert (@(Get-WidgetQuotaEvents $now).Count-eq 0) 'Previous account events must not leak'
  $script:status.accountKey='fixture-account'
  $script:status.windows[0].remaining=90
  Assert (@(Get-WidgetQuotaEvents $now).Count-eq 0) 'Recovered quota must suppress a queued low warning'
  $script:status.windows[0].remaining=25
  $script:status.windows[0].resetsAt=[Math]::Floor($now/1000)-1
  Assert (@(Get-WidgetQuotaEvents $now).Count-eq 0) 'Expired reset windows must not show an old warning'
  $script:status.windows[0].Remove('resetsAt')
  $script:status.observedAt=$now-180001
  Assert (@(Get-WidgetQuotaEvents $now).Count-eq 0) 'Stale positive status must not authorize an alert'
  $script:status.observedAt=$now
  Tick-WidgetQuotaNotifications $true $now
  Assert ($script:bubbleMode-eq 'quota-alert'-and !$script:collapsed) 'Real widget bubble must accept the quota alert scene'
  Assert ($script:ui.QuoteText.Text.Contains('25%')) 'The alert scene must contain actual event quota'
  Assert ($script:ui.QuotaText.Visibility-eq [Windows.Visibility]::Collapsed) 'Alert text must not overlap quota bars'
  Assert ($script:quotaAlertAck-contains 'fixture-event') 'A displayed event must be acknowledged durably'
  $script:collapsed=$true
  Initialize-WidgetQuotaNotifications
  Assert (@(Get-WidgetQuotaEvents $now).Count-eq 0) 'Restart must not replay acknowledged alerts'
  $recovery=@{id='recovery';type='recovered';windowKey='minutes:300';label='5 小时';remaining=100;at=$now;accountKey='fixture-account'}
  Write-EventState @($recovery)
  $script:status.windows[0].remaining=100
  Tick-WidgetQuotaNotifications $true $now
  Assert ($script:feedback-eq 1) 'Only a confirmed recovery produces happy feedback'
  Assert ($script:ui.QuoteText.Text.Contains('重新可用')) 'Recovery wording must not claim all windows reset'
  $script:collapsed=$true
  $old=@{id='expired';type='low';label='5 小时';remaining=10;at=$now-600001;accountKey='fixture-account'}
  Write-EventState @($old)
  Assert (@(Get-WidgetQuotaEvents $now).Count-eq 0) 'Expired events must not appear'
  $script:quotaAlertMessage='Preview';Open-TestBubble
  Assert ($script:ui.QuoteText.Text-eq 'Preview') 'Preview must use the same real bubble rendering path'
  # Build actual new menu controls, including handlers and nested threshold items.
  $script:settingsMenuUi=@{};$script:settingsMenuTarget=[Windows.Controls.ContextMenu]::new();$script:settingsSubmenus=@()
  $script:settingsMenuResources=[Windows.ResourceDictionary]::new()
  Add-WidgetQuotaSettingsMenu;Update-WidgetQuotaSettingsMenu
  Assert ($script:settingsMenuUi.QuotaAlerts.Items.Count-ge 7) 'Quota settings must expose toggles, thresholds and preview'
  $item=$script:settingsMenuUi.Quota_low_30
  $item.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  Assert ($script:quotaAlertSettings.low-eq 30) 'A real menu click must persist the selected threshold'
  $script:quotaAlertSettings.enabled=$false;Show-WidgetQuotaPreview
  Assert ($script:quotaAlertSettings.enabled-eq $false) 'Preview must not silently enable monitoring'
  'PASS: quota UI deferral, scene rendering, account isolation, durable ack, recovery and menu integration'
}finally{$script:window.Close()}
