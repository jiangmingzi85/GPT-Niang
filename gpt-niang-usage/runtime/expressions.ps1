# Expression selection is transient; only explicit configuration changes write to disk.
function New-WidgetExpressionConfig {
  return @{version=1;enabled=$true;characters=@{};action=@{kind='none';amplitude=4;durationMs=600}}
}
function Initialize-WidgetExpressions {
  $script:expressionConfig=New-WidgetExpressionConfig
  $script:expressionCache=@{};$script:expressionCurrentKey=$null;$script:expressionTemporary=$null
  $script:expressionPreview=$null;$script:expressionError=$null;$script:petAction=$null
  $script:expressionHistory=$null;$script:expressionDecision=$null;$script:expressionAssetNotices=@{}
  $path=Join-Path $script:dataDir 'expressions.json'
  if([IO.File]::Exists($path)){
    try{
      if(([IO.FileInfo]::new($path)).Length-gt 1MB){throw '表情配置文件过大。'}
      $value=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
      if($value.version-ne 1 -or $value.enabled-isnot [bool] -or !$value.characters){throw '表情配置格式无效。'}
      $script:expressionConfig.enabled=$value.enabled
      foreach($person in $value.characters.PSObject.Properties){
        $row=@{}
        foreach($state in @('normal','low','critical','exhausted','unknown','happy')){
          $file=$person.Value.$state
          if($file-is [string] -and $file-match '^[a-f0-9]{32}\.png$'){$row[$state]=$file}
        }
        $script:expressionConfig.characters[$person.Name]=$row
      }
      if($value.action.kind-in @('none','sway','bounce','pulse')){
        $script:expressionConfig.action=@{kind=[string]$value.action.kind;amplitude=[Math]::Max(1,[Math]::Min(8,[double]$value.action.amplitude));durationMs=[Math]::Max(200,[Math]::Min(1500,[int]$value.action.durationMs))}
      }
    }catch{$script:expressionError=$_.Exception.Message}
  }
}
function Save-WidgetExpressionConfig {
  $path=Join-Path $script:dataDir 'expressions.json';$temp=$path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
  try{
    [IO.File]::WriteAllText($temp,($script:expressionConfig|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,$path+'.bak',$true)}else{[IO.File]::Move($temp,$path)}
  }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Import-WidgetExpressionImage([string]$CharacterId,[string]$State,[string]$SourcePath) {
  if($State-notin @('normal','low','critical','exhausted','unknown','happy')){throw '未知表情状态。'}
  if(!$CharacterId -or $CharacterId-cne $script:characterId){throw '请先选择需要配置的角色。'}
  $image=Read-WidgetCharacterImage $SourcePath
  # A role can own several images: cap each decoded image more tightly than a single portrait.
  if(([long]$image.PixelWidth*$image.PixelHeight)-gt 4000000){throw '表情图片不能超过 400 万像素。'}
  $directory=Join-Path $script:dataDir 'expressions';$file=[Guid]::NewGuid().ToString('N')+'.png'
  $path=Resolve-WidgetCharacterPath $directory $file
  $null=[IO.Directory]::CreateDirectory($directory);$temp=$path+'.tmp';$stream=$null
  try{
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
    $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write);$encoder.Save($stream);$stream.Dispose();$stream=$null
    [IO.File]::Move($temp,$path)
    $characters=$script:expressionConfig.characters
    if(!$characters.ContainsKey($CharacterId)){$characters[$CharacterId]=@{}}
    $row=$characters[$CharacterId];$had=$row.ContainsKey($State);$previous=$row[$State];$row[$State]=$file
    try{Save-WidgetExpressionConfig}catch{if($had){$row[$State]=$previous}else{$row.Remove($State)};throw}
    Reset-WidgetExpression
    return $file
  }finally{if($stream){$stream.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-WidgetExpressionReading($Status,[long]$Now) {
  if(!$Status -or !$Status.observedAt){return @{state='unknown';reason='正在读取额度，尚无有效数据。'}}
  if($Status.queryOk-ne $true -or $Status.ok-ne $true -or $Status.error){return @{state='unknown';reason='额度查询失败，等待下次刷新。'}}
  if($Now-[long]$Status.observedAt-lt 0){return @{state='unknown';reason='额度数据时间异常，等待重新读取。'}}
  if($Now-[long]$Status.observedAt-gt 180000){return @{state='unknown';reason='额度数据已超过 180 秒，等待刷新。'}}
  $remaining=@()
  foreach($window in @($Status.windows)){
    if($null-eq $window -or $null-eq $window.remaining){continue}
    if($window.resetsAt-and [double]$window.resetsAt*1000-le $Now){return @{state='unknown';reason='额度窗口已到重置时间，等待新数据。'}}
    $number=0.0
    if(![double]::TryParse([string]$window.remaining,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){continue}
    if([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number-lt 0 -or $number-gt 100){continue}
    $remaining+=,$number
  }
  if(!$remaining.Count){return @{state='unknown';reason='没有可用的额度窗口数据。'}}
  $minimum=($remaining|Measure-Object -Minimum).Minimum
  $low=25;$critical=10
  if($script:quotaAlertSettings){$low=[double]$script:quotaAlertSettings.low;$critical=[double]$script:quotaAlertSettings.critical}
  $state=if($minimum-le 0){'exhausted'}elseif($minimum-le $critical){'critical'}elseif($minimum-le $low){'low'}else{'normal'}
  return @{state=$state;remaining=$minimum;low=$low;critical=$critical}
}
function Get-WidgetExpressionDecision($Status,[long]$Now) {
  $decision=Get-WidgetExpressionReading $Status $Now
  if($decision.state-eq 'unknown'){$script:expressionHistory=$null;return $decision}
  $gap=2.0
  if($script:quotaAlertSettings -and $null-ne $script:quotaAlertSettings.hysteresis){$gap=[Math]::Max(0,[Math]::Min(10,[double]$script:quotaAlertSettings.hysteresis))}
  # History belongs to one identity, reset cycle and threshold configuration; UI previews never enter it.
  $cycles=@($Status.windows|ForEach-Object{[string]$_.kind+':'+[string]$_.minutes+':'+[string]$_.resetsAt})
  $identity=@($script:characterId,$Status.accountKey,$Status.plan,$decision.low,$decision.critical,$gap,($cycles-join ','))-join '|'
  $previous=$script:expressionHistory
  $held=$false
  if($previous -and $previous.identity-ceq $identity -and $decision.remaining-gt 0){
    if($previous.state-eq 'critical' -and $decision.remaining-le $decision.critical+$gap){$decision.state='critical';$held=$decision.remaining-gt $decision.critical}
    elseif($previous.state-eq 'low' -and $decision.state-eq 'normal' -and $decision.remaining-le $decision.low+$gap){$decision.state='low';$held=$true}
  }
  $script:expressionHistory=@{identity=$identity;state=$decision.state}
  $label=@{normal='普通';low='担忧';critical='紧张';exhausted='疲惫'}[$decision.state]
  $decision.reason='最少剩余额度 '+$decision.remaining.ToString('0.#',[Globalization.CultureInfo]::InvariantCulture)+'%，当前为'+$label+'表情。'
  if($held){$decision.reason+=' 恢复需超过阈值 '+$gap+' 个百分点，避免临界值反复切换。'}
  return $decision
}
function Get-WidgetExpressionState($Status,[long]$Now) {
  return (Get-WidgetExpressionDecision $Status $Now).state
}
function Get-WidgetExpressionAsset([string]$State) {
  $person=$script:expressionConfig.characters[$script:characterId];$candidates=@();$notice=''
  if($person -and $person[$State]){$candidates+=@{file=$person[$State];kind='configured'}}
  if($State-notin @('normal','default') -and $person -and $person.normal){$candidates+=@{file=$person.normal;kind='normal'}}
  $candidates+=@{file=$null;kind='default'}
  foreach($candidate in $candidates){
    try{
      $path=$script:activeCharacter.path
      if($candidate.file){$path=Resolve-WidgetCharacterPath (Join-Path $script:dataDir 'expressions') $candidate.file}
      $image=Read-WidgetCharacterImage $path
      if($candidate.file -and ([long]$image.PixelWidth*$image.PixelHeight)-gt 4000000){throw '表情图片超过 400 万像素。'}
      return @{image=$image;path=$path;kind=$candidate.kind;notice=$notice}
    }catch{$notice='配置图片无法读取，已尝试回退素材。'}
  }
  return @{image=$null;path=$null;kind='default';notice='配置图片和默认立绘均无法读取。'}
}
function Set-WidgetPetImage($Image) {
  $alpha=[Windows.Media.Imaging.FormatConvertedBitmap]::new($Image,[Windows.Media.PixelFormats]::Bgra32,$null,0)
  $alpha.Freeze();$stride=$Image.PixelWidth*4;$pixels=New-Object byte[] ($stride*$Image.PixelHeight);$alpha.CopyPixels($pixels,$stride,0)
  $old=@{bitmap=$script:bitmap;alpha=$script:alphaBitmap;stride=$script:alphaStride;pixels=$script:alphaPixels}
  try{
    $script:bitmap=$Image;$script:alphaBitmap=$alpha;$script:alphaStride=$stride;$script:alphaPixels=$pixels;$script:ui.Girl.Source=$Image
    if($script:widgetColors){foreach($overlay in @($script:widgetColors.halo,$script:widgetColors.tint)){if($overlay -and $overlay.OpacityMask){$overlay.OpacityMask.ImageSource=$Image}}}
    if($script:widgetMusic -and $script:widgetMusic.Enabled){$script:widgetMusic.RefreshLayout()}
  }catch{
    $script:bitmap=$old.bitmap;$script:alphaBitmap=$old.alpha;$script:alphaStride=$old.stride;$script:alphaPixels=$old.pixels;$script:ui.Girl.Source=$old.bitmap
    if($script:widgetColors){foreach($overlay in @($script:widgetColors.halo,$script:widgetColors.tint)){if($overlay -and $overlay.OpacityMask){$overlay.OpacityMask.ImageSource=$old.bitmap}}}
    if($script:widgetMusic -and $script:widgetMusic.Enabled){
      try{$script:widgetMusic.RefreshLayout()}catch{Stop-WidgetMusic;$script:expressionError='表情更新失败，音乐布局已恢复。'}
    }
    throw
  }
}
function Reset-WidgetExpression {
  Stop-WidgetPetAction
  $script:expressionCache=@{};$script:expressionCurrentKey=$null;$script:expressionTemporary=$null;$script:expressionPreview=$null
  $script:expressionAssetNotices=@{}
}
function Stop-WidgetPetAction {
  if(!$script:petAction){return}
  if($script:petAction.timer){$script:petAction.timer.Stop()}
  foreach($entry in $script:petAction.entries){
    # Music captures the current transform on entry; never replace its active transform here.
    if([object]::ReferenceEquals($entry.element.RenderTransform,$entry.group)){$entry.element.RenderTransform=$entry.original}
  }
  $script:petAction=$null
}
function Start-WidgetPetAction([long]$Now) {
  Stop-WidgetPetAction
  if(!$script:expressionConfig.enabled -or $script:expressionConfig.action.kind-eq 'none' -or $script:drag -or $script:settingsSizePreview -or $script:expressionSettingsWindow -or ($script:characterGallery -and $script:characterGallery.IsVisible) -or ($script:context -and $script:context.IsOpen) -or ($script:widgetMusic -and $script:widgetMusic.Enabled)){return}
  $entries=@();$elements=@($script:ui.Girl)
  if($script:widgetColors){$elements+=@($script:widgetColors.halo,$script:widgetColors.tint)}
  foreach($element in $elements){
    if(!$element){continue}
    $group=[Windows.Media.TransformGroup]::new();$original=$element.RenderTransform
    if($original){$group.Children.Add($original)}
    $motion=[Windows.Media.TranslateTransform]::new();$scale=[Windows.Media.ScaleTransform]::new(1,1,$element.Width/2,$element.Height)
    $group.Children.Add($scale);$group.Children.Add($motion);$element.RenderTransform=$group
    $entries+=,@{element=$element;original=$original;group=$group;motion=$motion;scale=$scale}
  }
  $script:petAction=@{entries=$entries;started=$Now;duration=[int]$script:expressionConfig.action.durationMs;kind=$script:expressionConfig.action.kind;amplitude=[double]$script:expressionConfig.action.amplitude}
  $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(16)
  $timer.Add_Tick({try{Update-WidgetPetAction ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())}catch{Stop-WidgetPetAction}})
  $script:petAction.timer=$timer;$timer.Start()
}
function Update-WidgetPetAction([long]$Now) {
  if(!$script:petAction){return}
  if($script:drag -or $script:settingsSizePreview -or $script:expressionSettingsWindow -or ($script:characterGallery -and $script:characterGallery.IsVisible) -or ($script:context -and $script:context.IsOpen) -or ($script:widgetMusic -and $script:widgetMusic.Enabled) -or !$script:window.IsVisible){Stop-WidgetPetAction;return}
  $action=$script:petAction;$progress=($Now-$action.started)/[double]$action.duration
  if($progress-ge 1 -or $progress-lt 0){Stop-WidgetPetAction;return}
  $wave=[Math]::Sin($progress*[Math]::PI*2)*(1-$progress)
  foreach($entry in $action.entries){
    switch($action.kind){
      'sway' {$entry.motion.X=$wave*$action.amplitude}
      'bounce' {$entry.motion.Y=-[Math]::Abs($wave)*$action.amplitude}
      'pulse' {$entry.scale.ScaleX=1+$wave*$action.amplitude/200;$entry.scale.ScaleY=1+$wave*$action.amplitude/200}
    }
  }
}
function Show-WidgetPetFeedback([string]$State,[int]$DurationMs=3000) {
  if($State-notin @('normal','low','critical','exhausted','unknown','happy') -or !$script:expressionConfig.enabled){return}
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $script:expressionTemporary=@{state=$State;until=$now+[Math]::Max(200,[Math]::Min(10000,$DurationMs))}
  Start-WidgetPetAction $now
  Update-WidgetExpression $now
}
function Update-WidgetExpression([long]$Now) {
  if(!$script:expressionConfig -or !$script:activeCharacter -or !$script:ui.Girl){return}
  Update-WidgetPetAction $Now
  $script:expressionDecision=Get-WidgetExpressionDecision $script:status $Now
  $state=$script:expressionDecision.state
  if($script:expressionTemporary){if($Now-lt $script:expressionTemporary.until){$state=$script:expressionTemporary.state}else{$script:expressionTemporary=$null}}
  if($script:expressionPreview){$state=$script:expressionPreview}
  if(!$script:expressionConfig.enabled){$state='default'}
  if(Get-Command Update-WidgetExpressionSettingsStatus -ErrorAction SilentlyContinue){Update-WidgetExpressionSettingsStatus}
  $file=$null;$person=$script:expressionConfig.characters[$script:characterId]
  if($person -and $state-ne 'default'){$file=$person[$state];if(!$file){$file=$person['normal']}}
  $key=$script:characterId+'|'+[string]$file
  if($key-ceq $script:expressionCurrentKey){return}
  if(!$script:expressionCache.ContainsKey($key)){
    try{
      $asset=Get-WidgetExpressionAsset $state
      $script:expressionError=$asset.notice
      $image=$asset.image
      if(!$image){throw $asset.notice}
      $cachedPixels=0L
      foreach($cached in $script:expressionCache.Values){if($cached){$cachedPixels+=[long]$cached.PixelWidth*$cached.PixelHeight}}
      if($cachedPixels+[long]$image.PixelWidth*$image.PixelHeight-gt 8000000){$script:expressionCache.Clear();$script:expressionAssetNotices.Clear()}
      $script:expressionCache[$key]=$image
      $script:expressionAssetNotices[$key]=$asset.notice
    }catch{
      $script:expressionError=$_.Exception.Message
      # Remember failed assets as well so each refresh does not decode the same bad file.
      $script:expressionCache[$key]=$null
      $script:expressionAssetNotices[$key]=$script:expressionError
    }
  }
  $image=$script:expressionCache[$key]
  $script:expressionError=$script:expressionAssetNotices[$key]
  if(!$image){
    $fallback=$script:characterId+'|'
    if(!$script:expressionCache.ContainsKey($fallback)){
      try{$script:expressionCache[$fallback]=Read-WidgetCharacterImage $script:activeCharacter.path}catch{$script:expressionCache[$fallback]=$null;$script:expressionError=$_.Exception.Message}
    }
    $image=$script:expressionCache[$fallback]
  }
  if($image){try{Set-WidgetPetImage $image;$script:expressionCurrentKey=$key}catch{$script:expressionError=$_.Exception.Message}}
  if(Get-Command Update-WidgetExpressionSettingsStatus -ErrorAction SilentlyContinue){Update-WidgetExpressionSettingsStatus}
}
