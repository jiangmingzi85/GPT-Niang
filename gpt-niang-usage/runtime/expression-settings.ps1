function Update-WidgetExpressionSettingsStatus {
  if(!$script:expressionSettingsWindow -or !$script:expressionSettingsControls.reason){return}
  $message=if($script:expressionDecision){$script:expressionDecision.reason}else{'正在读取当前额度状态。'}
  if(!$script:expressionConfig.enabled){$message='状态表情已关闭，显示角色默认立绘。 '+$message}
  elseif($script:expressionPreview){
    $name=@{normal='普通';low='额度偏低';critical='额度紧张';exhausted='额度耗尽';unknown='读取异常';happy='开心 / 恢复'}[$script:expressionPreview]
    $message='正在预览'+$name+'；关闭窗口后恢复真实状态。 '+$message
  }
  elseif($script:expressionTemporary){$message='正在显示短暂互动表情，结束后恢复额度状态。 '+$message}
  if($script:expressionError){$message+=' '+$script:expressionError}
  $script:expressionSettingsControls.reason.Text=$message
}
function Update-WidgetExpressionSettingsRows {
  if(!$script:expressionSettingsWindow){return}
  $person=$script:expressionConfig.characters[$script:characterId]
  foreach($state in @('normal','low','critical','exhausted','unknown','happy')){
    $file=if($person){$person[$state]}else{$null}
    $row=$script:expressionSettingsRows[$state];$asset=Get-WidgetExpressionAsset $state
    $row.image.Source=$null
    if($asset.image){
      # Detach small previews so the settings panel does not retain six full decoded portraits.
      $visual=[Windows.Media.DrawingVisual]::new();$drawing=$visual.RenderOpen()
      try{$drawing.DrawImage($asset.image,[Windows.Rect]::new(0,0,64,64))}finally{$drawing.Close()}
      $thumbnail=[Windows.Media.Imaging.RenderTargetBitmap]::new(64,64,96,96,[Windows.Media.PixelFormats]::Pbgra32)
      $thumbnail.Render($visual);$thumbnail.Freeze();$row.image.Source=$thumbnail
    }
    $caption=switch($asset.kind){'configured'{'已配置'}'normal'{'回退普通表情'}default{'回退默认立绘'}}
    $row.text.Text=$caption
    $row.text.ToolTip=if($file){$file}else{'未配置独立图片'}
    if($asset.notice){$row.text.Text+=' · 图片失效';$row.text.ToolTip=$asset.notice}
  }
  Update-WidgetExpressionSettingsStatus
}
function Open-WidgetExpressionSettings {
  if($script:expressionSettingsWindow){$script:expressionSettingsWindow.Activate()|Out-Null;return}
  Stop-WidgetPetAction
  $window=[Windows.Window]::new();$window.Title='表情与互动 · '+$script:activeCharacter.name
  $window.Width=720;$window.Height=780;$window.MinWidth=680;$window.MinHeight=540
  $window.WindowStartupLocation=[Windows.WindowStartupLocation]::CenterOwner;$window.Owner=$script:window
  $window.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#FFFCFF')
  $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.VerticalScrollBarVisibility='Auto';$window.Content=$scroll
  $panel=[Windows.Controls.StackPanel]::new();$panel.Margin=[Windows.Thickness]::new(20);$scroll.Content=$panel
  $title=[Windows.Controls.TextBlock]::new();$title.Text='为当前角色配置状态表情';$title.FontSize=20;$title.FontWeight='SemiBold';$panel.Children.Add($title)|Out-Null
  $help=[Windows.Controls.TextBlock]::new();$help.Text='图片立即保存为本地独立 PNG，原图不受影响。未配置或图片失效时回退普通表情 / 默认立绘。预览只改变当前显示，关闭后恢复真实额度状态。';$help.TextWrapping='Wrap';$help.Margin=[Windows.Thickness]::new(0,8,0,12);$panel.Children.Add($help)|Out-Null
  $enabled=[Windows.Controls.CheckBox]::new();$enabled.Content='启用状态表情与互动动作';$enabled.IsChecked=$script:expressionConfig.enabled;$panel.Children.Add($enabled)|Out-Null
  $script:expressionSettingsWindow=$window;$script:expressionSettingsRows=@{};$script:expressionSettingsControls=@{enabled=$enabled;characterId=$script:characterId}
  $reason=[Windows.Controls.TextBlock]::new();$reason.TextWrapping='Wrap';$reason.Margin=[Windows.Thickness]::new(0,12,0,8)
  $panel.Children.Add($reason)|Out-Null;$script:expressionSettingsControls.reason=$reason
  $names=@{normal='普通';low='额度偏低';critical='额度紧张';exhausted='额度耗尽';unknown='读取异常';happy='开心 / 恢复'}
  foreach($state in @('normal','low','critical','exhausted','unknown','happy')){
    $row=[Windows.Controls.DockPanel]::new();$row.Margin=[Windows.Thickness]::new(0,10,0,0)
    $thumbnail=[Windows.Controls.Image]::new();$thumbnail.Width=64;$thumbnail.Height=64;$thumbnail.Margin=[Windows.Thickness]::new(0,0,10,0)
    $row.Children.Add($thumbnail)|Out-Null
    $label=[Windows.Controls.TextBlock]::new();$label.Text=$names[$state];$label.Width=95;$label.VerticalAlignment='Center';$row.Children.Add($label)|Out-Null
    foreach($command in @('导入','清除','预览')){
      $button=[Windows.Controls.Button]::new();$button.Content=$command;$button.Tag=@{state=$state;command=$command};$button.Margin=[Windows.Thickness]::new(3);$button.Padding=[Windows.Thickness]::new(7,4,7,4)
      [Windows.Controls.DockPanel]::SetDock($button,'Right');$row.Children.Add($button)|Out-Null
      $button.Add_Click({param($sender,$event)
        try{
          if($script:expressionSettingsControls.characterId-cne $script:characterId){throw '角色已切换，请关闭后重新打开配置。'}
          $state=[string]$sender.Tag.state
          switch($sender.Tag.command){
            '导入' {
              $picker=[Microsoft.Win32.OpenFileDialog]::new();$picker.Title='选择表情图片（不超过 400 万像素）';$picker.Filter='图片|*.png;*.jpg;*.jpeg;*.bmp;*.gif'
              if($picker.ShowDialog($script:expressionSettingsWindow)-eq $true){$null=Import-WidgetExpressionImage $script:characterId $state $picker.FileName;Update-WidgetExpressionSettingsRows;$script:expressionSettingsFeedback.Text='已保存独立 PNG。GIF 使用第一帧。'}
            }
            '清除' {
              $person=$script:expressionConfig.characters[$script:characterId]
              if($person -and $person.ContainsKey($state)){
                $old=$person[$state];$person.Remove($state)
                try{Save-WidgetExpressionConfig}catch{$person[$state]=$old;throw}
              }
              Reset-WidgetExpression;Update-WidgetExpressionSettingsRows;$script:expressionSettingsFeedback.Text='已清除绑定；已有图片文件保留。'
            }
            '预览' {$script:expressionPreview=$state;$script:expressionCurrentKey=$null;$script:expressionSettingsFeedback.Text='正在预览：'+$state+'。关闭此窗口后恢复真实状态。'}
          }
          Update-WidgetExpression ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        }catch{$script:expressionSettingsFeedback.Text=$_.Exception.Message}
      })
    }
    $file=[Windows.Controls.TextBlock]::new();$file.TextTrimming='CharacterEllipsis';$file.VerticalAlignment='Center';$script:expressionSettingsRows[$state]=@{image=$thumbnail;text=$file};$row.Children.Add($file)|Out-Null
    $panel.Children.Add($row)|Out-Null
  }
  $actionTitle=[Windows.Controls.TextBlock]::new();$actionTitle.Text='点击 / 恢复提醒的轻量动作';$actionTitle.FontWeight='SemiBold';$actionTitle.Margin=[Windows.Thickness]::new(0,18,0,8);$panel.Children.Add($actionTitle)|Out-Null
  $kind=[Windows.Controls.ComboBox]::new();$kind.Margin=[Windows.Thickness]::new(0,0,0,8)
  foreach($item in @(@{id='none';label='不播放动作'},@{id='sway';label='轻轻摇摆'},@{id='bounce';label='轻跳'},@{id='pulse';label='呼吸缩放'})){
    $choice=[Windows.Controls.ComboBoxItem]::new();$choice.Content=$item.label;$choice.Tag=$item.id;$kind.Items.Add($choice)|Out-Null
    if($item.id-eq $script:expressionConfig.action.kind){$kind.SelectedItem=$choice}
  }
  $panel.Children.Add($kind)|Out-Null;$script:expressionSettingsControls.kind=$kind
  foreach($field in @(@{key='amplitude';label='幅度（1–8，像素或对应缩放强度）';min=1;max=8},@{key='durationMs';label='持续时间（200–1500 毫秒）';min=200;max=1500})){
    $text=[Windows.Controls.TextBlock]::new();$text.Text=$field.label;$panel.Children.Add($text)|Out-Null
    $slider=[Windows.Controls.Slider]::new();$slider.Minimum=$field.min;$slider.Maximum=$field.max;$slider.Value=$script:expressionConfig.action[$field.key];$slider.IsSnapToTickEnabled=$true;$slider.TickFrequency=if($field.key-eq 'amplitude'){1}else{100};$slider.Margin=[Windows.Thickness]::new(0,3,0,10)
    $panel.Children.Add($slider)|Out-Null;$script:expressionSettingsControls[$field.key]=$slider
  }
  $note=[Windows.Controls.TextBlock]::new();$note.Text='音乐律动开启时暂停额外动作，仍可切换表情。拖动、打开菜单或窗口隐藏时取消动作。';$note.TextWrapping='Wrap';$panel.Children.Add($note)|Out-Null
  $feedback=[Windows.Controls.TextBlock]::new();$feedback.TextWrapping='Wrap';$feedback.Margin=[Windows.Thickness]::new(0,10,0,10);$panel.Children.Add($feedback)|Out-Null;$script:expressionSettingsFeedback=$feedback
  $apply=[Windows.Controls.Button]::new();$apply.Content='保存开关与动作设置';$apply.Padding=[Windows.Thickness]::new(12,7,12,7);$panel.Children.Add($apply)|Out-Null
  $apply.Add_Click({
    $oldEnabled=$script:expressionConfig.enabled;$oldAction=$script:expressionConfig.action
    try{
      $controls=$script:expressionSettingsControls;$script:expressionConfig.enabled=[bool]$controls.enabled.IsChecked
      $script:expressionConfig.action=@{kind=[string]$controls.kind.SelectedItem.Tag;amplitude=[int]$controls.amplitude.Value;durationMs=[int]$controls.durationMs.Value}
      Save-WidgetExpressionConfig;Reset-WidgetExpression;Update-WidgetExpression ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds());$script:expressionSettingsFeedback.Text='设置已保存。'
    }catch{$script:expressionConfig.enabled=$oldEnabled;$script:expressionConfig.action=$oldAction;$script:expressionSettingsFeedback.Text=$_.Exception.Message}
  })
  $window.Add_Closed({$script:expressionSettingsWindow=$null;$script:expressionSettingsRows=$null;$script:expressionSettingsControls=$null;$script:expressionPreview=$null;$script:expressionCurrentKey=$null;Stop-WidgetPetAction;Update-WidgetExpression ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())})
  Update-WidgetExpression ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds());Update-WidgetExpressionSettingsRows;$window.Show()
}
