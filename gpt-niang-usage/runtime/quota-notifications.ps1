# Settings and acknowledgements belong to the UI; the worker alone writes alert state.
function Read-WidgetQuotaAlertSettings {
  $value=@{version=1;enabled=$false;recovery=$true;background=$false;sound=$false;low=25;critical=10;hysteresis=2}
  $file=Join-Path $script:dataDir 'quota-alert-settings.json'
  if([IO.File]::Exists($file)){
    try{
      if(([IO.FileInfo]::new($file)).Length-gt 8192){throw '额度提醒配置过大。'}
      $saved=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
      if($saved.version-ne 1){throw '额度提醒配置版本无效。'}
      if($saved.revision-is [string]-and $saved.revision.Length-le 64){$value.revision=$saved.revision}
      foreach($key in @('enabled','recovery','background','sound')){if($saved.$key-is [bool]){$value[$key]=$saved.$key}}
      foreach($key in @('low','critical','hysteresis')){
        $number=$saved.$key
        if(($number-isnot [int]-and $number-isnot [long]-and $number-isnot [double])-or [double]::IsNaN([double]$number)-or [double]::IsInfinity([double]$number)){continue}
        if($key-eq 'low'-and $number-ge 1-and $number-le 99){$value.low=[double]$number}
        if($key-eq 'critical'-and $number-gt 0-and $number-lt $value.low){$value.critical=[double]$number}
        if($key-eq 'hysteresis'-and $number-ge 0-and $number-le 10){$value.hysteresis=[double]$number}
      }
      if($value.critical-ge $value.low){$value.critical=[Math]::Min(10,$value.low/2)}
    }catch{$value=@{version=1;enabled=$false;recovery=$true;background=$false;sound=$false;low=25;critical=10;hysteresis=2}}
  }
  return $value
}

function Initialize-WidgetQuotaNotifications {
  $script:quotaAlertSettings=Read-WidgetQuotaAlertSettings
  $script:quotaAlertMessage='';$script:quotaAlertLastError=$null;$script:quotaAlertDisplayed=0
  $script:quotaAlertAck=@()
  try{
    $file=Join-Path $script:dataDir 'quota-alert-ack.json'
    if([IO.File]::Exists($file)-and ([IO.FileInfo]::new($file)).Length-le 65536){
      $saved=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
      $script:quotaAlertAck=@($saved.ids|Where-Object{$_-is [string]-and $_.Length-le 256}|Select-Object -Last 256)
    }
  }catch{$script:quotaAlertLastError='上次提醒记录无法读取。'}
}

function Set-WidgetQuotaPreference([string]$Name,$Value) {
  if($Name-notin @('enabled','recovery','background','sound','low','critical')){throw '未知额度提醒选项。'}
  $next=@{};foreach($key in $script:quotaAlertSettings.Keys){$next[$key]=$script:quotaAlertSettings[$key]};$next[$Name]=$Value
  if($Name-eq 'enabled'){$next.revision=[Guid]::NewGuid().ToString('N')}
  if($next.low-lt 1-or $next.low-gt 99-or $next.critical-le 0-or $next.critical-ge $next.low){throw '严重阈值必须大于 0，且小于低额度阈值。'}
  Write-WidgetJson (Join-Path $script:dataDir 'quota-alert-settings.json') $next
  $script:quotaAlertSettings=$next
  if(!$next.enabled-and $script:bubbleMode-eq 'quota-alert'){Hide-Quota}
  Request-Refresh
}

function Get-WidgetQuotaEvents([long]$Now) {
  if(!$script:quotaAlertSettings.enabled){return}
  $file=Join-Path $script:dataDir 'quota-alert-state.json'
  if(![IO.File]::Exists($file)){return}
  try{
    if(([IO.FileInfo]::new($file)).Length-gt 262144){throw '额度提醒记录过大。'}
    $state=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
    # A valid reading of the current login is required, even when an old outbox survives.
    if(!$state.enabled-or !$script:status.accountKey-or $state.accountKey-ne $script:status.accountKey-or $script:status.queryOk-ne $true-or !$script:status.ok){return}
    if($state.settingsRevision-ne $script:quotaAlertSettings.revision){return}
    if($state.plan-ne $script:status.plan){return}
    if(!$script:status.observedAt-or $Now-[double]$script:status.observedAt-lt 0-or $Now-[double]$script:status.observedAt-gt 180000){return}
    foreach($entry in @($state.events)|Select-Object -First 32){
      if(!$entry-or $entry.id-isnot [string]-or $entry.id.Length-gt 256-or $script:quotaAlertAck-contains $entry.id){continue}
      if($entry.type-notin @('low','critical','exhausted','recovered')-or $entry.accountKey-ne $state.accountKey){continue}
      if($entry.type-eq 'recovered'-and !$script:quotaAlertSettings.recovery){continue}
      if($entry.at-isnot [long]-and $entry.at-isnot [double]-and $entry.at-isnot [int]){continue}
      if($Now-[double]$entry.at-lt 0-or $Now-[double]$entry.at-gt 600000){continue}
      if($null-eq $entry.remaining-or [double]$entry.remaining-lt 0-or [double]$entry.remaining-gt 100){continue}
      $window=@($script:status.windows|Where-Object{
        $key=if($_.kind-eq 'individual'){'individual'}else{'minutes:'+([string]$_.minutes)}
        $key-eq $entry.windowKey
      })|Select-Object -First 1
      if(!$window-or $null-eq $window.remaining-or ($window.resetsAt-and [double]$window.resetsAt*1000-le $Now)){continue}
      $remaining=[double]$window.remaining
      if([double]::IsNaN($remaining)-or [double]::IsInfinity($remaining)-or $remaining-lt 0-or $remaining-gt 100){continue}
      $limit=switch($entry.type){'low'{$script:quotaAlertSettings.low}'critical'{$script:quotaAlertSettings.critical}'exhausted'{0}default{100}}
      if($entry.type-eq 'recovered'){if($remaining-le 0){continue}}
      elseif($remaining-gt [double]$limit+$script:quotaAlertSettings.hysteresis){continue}
      $entry
    }
  }catch{$script:quotaAlertLastError='额度提醒记录暂时无法读取。'}
}

function Get-WidgetQuotaMessage($Events) {
  $rows=@(foreach($entry in $Events){
    $label=([string]$entry.label)-replace '[\x00-\x1f]','';if($label.Length-gt 32){$label=$label.Substring(0,32)}
    $caption=switch($entry.type){'recovered'{'重新可用'}'exhausted'{'已耗尽'}'critical'{'严重不足'}default{'额度偏低'}}
    $label+' '+$caption+' '+([double]$entry.remaining).ToString('0.#')+'%'
  })
  return ($rows-join "`n")
}

function Confirm-WidgetQuotaEvents($Events) {
  $next=@(@($script:quotaAlertAck)+@($Events|ForEach-Object{$_.id})|Select-Object -Unique|Select-Object -Last 256)
  # Reserve before presentation: crashes can omit one attempt, but cannot replay it on restart.
  Write-WidgetJson (Join-Path $script:dataDir 'quota-alert-ack.json') @{version=1;ids=$next}
  $script:quotaAlertAck=$next
}

function Tick-WidgetQuotaNotifications([bool]$Visible,[long]$Now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
  if(!$script:quotaAlertSettings.enabled){return}
  $events=@(Get-WidgetQuotaEvents $Now);if(!$events.Count){return}
  $busy=[bool]$script:drag-or $script:context.IsOpen-or $script:settingsSizePreview-or (Test-WidgetUpdateEditor)-or ($script:characterGallery-and $script:characterGallery.IsVisible)-or ($script:expressionSettingsWindow-and $script:expressionSettingsWindow.IsVisible)-or ($script:quoteEditor-and $script:quoteEditor.IsVisible)
  if($busy-or !$script:collapsed-or ($script:closeTimer-and $script:closeTimer.IsEnabled)-or $script:completionTemporary){return}
  $foreground=[CompletionWindowLayer]::GetForegroundWindow()
  if(Test-CompletionFullscreen $foreground){return}
  $temporary=!$Visible-or !(Test-WidgetCompletionForeground)
  if($temporary-and !$script:quotaAlertSettings.background){return}
  try{
    $script:quotaAlertMessage=Get-WidgetQuotaMessage $events
    if($temporary-and !(Start-TemporaryCompletion 'quota-alert')){return}
    Confirm-WidgetQuotaEvents $events
    Open-WidgetBubble 'quota-alert'
    $script:quotaAlertDisplayed++
    if(@($events|Where-Object{$_.type-eq 'recovered'}).Count-and (Get-Command Show-WidgetPetFeedback -ErrorAction SilentlyContinue)){Show-WidgetPetFeedback 'happy' 3000}
    if($script:quotaAlertSettings.sound-and $script:soundOn-and $script:soundVolume-gt 0){Play-WidgetReleaseSound}
    $script:quotaAlertLastError=$null
  }catch{
    $script:quotaAlertLastError='额度提醒显示失败。'
    if($script:completionTemporary-and $script:completionTemporary.kind-eq 'quota-alert'){Stop-TemporaryCompletion}
  }
}

function Show-WidgetQuotaPreview {
  if(!$script:collapsed){return}
  $script:quotaAlertMessage="预览：5 小时额度偏低 25%`n此提示不查询或修改真实额度"
  Open-WidgetBubble 'quota-alert'
}

function Add-WidgetQuotaSettingsMenu {
  $script:settingsMenuUi.QuotaAlerts=Add-SettingsSubmenu '额度预警与恢复' {
    $script:settingsMenuUi.QuotaAlertsEnabled=Add-SettingsAction '开启额度预警' {param($sender,$event)Set-WidgetQuotaPreference 'enabled' ([bool]$sender.IsChecked)} -Checkable -ReturnItem
    $script:settingsMenuUi.QuotaRecovery=Add-SettingsAction '耗尽后恢复提醒' {param($sender,$event)Set-WidgetQuotaPreference 'recovery' ([bool]$sender.IsChecked)} -Checkable -ReturnItem
    $script:settingsMenuUi.QuotaBackground=Add-SettingsAction '隐藏时继续监测和提醒' {param($sender,$event)Set-WidgetQuotaPreference 'background' ([bool]$sender.IsChecked)} -Description '挂件仍运行时每分钟查询；退出后停止' -Checkable -ReturnItem
    $script:settingsMenuUi.QuotaSound=Add-SettingsAction '提醒音效' {param($sender,$event)Set-WidgetQuotaPreference 'sound' ([bool]$sender.IsChecked)} -Checkable -ReturnItem
    Add-SettingsDivider
    foreach($kind in @(@{id='low';text='低额度阈值';values=@(20,25,30)},@{id='critical';text='严重不足阈值';values=@(5,10,15)})){
      $setting=$kind.id
      Add-SettingsSubmenu $kind.text {
        foreach($number in $kind.values){
          $choice=Add-SettingsAction ($number.ToString()+'%') {param($sender,$event)Set-WidgetQuotaPreference $sender.Tag.key $sender.Tag.value;Update-WidgetQuotaSettingsMenu} -Checkable -ReturnItem
          $choice.Tag=@{key=$setting;value=$number};$script:settingsMenuUi['Quota_'+$setting+'_'+$number]=$choice
        }
      }
    }
    Add-SettingsAction '预览提醒' {Show-WidgetQuotaPreview}
  } -ReturnItem
}

function Update-WidgetQuotaSettingsMenu {
  if(!$script:quotaAlertSettings-or !$script:settingsMenuUi.QuotaAlerts){return}
  foreach($pair in @(@{ui='QuotaAlertsEnabled';key='enabled'},@{ui='QuotaRecovery';key='recovery'},@{ui='QuotaBackground';key='background'},@{ui='QuotaSound';key='sound'})){$script:settingsMenuUi[$pair.ui].IsChecked=[bool]$script:quotaAlertSettings[$pair.key]}
  foreach($key in @('low','critical')){
    foreach($number in @(5,10,15,20,25,30)){
      $item=$script:settingsMenuUi['Quota_'+$key+'_'+$number]
      if($item){$item.IsChecked=$script:quotaAlertSettings[$key]-eq $number}
    }
  }
}
