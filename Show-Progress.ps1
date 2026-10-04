#requires -Version 5.1
<#
  Show-Progress.ps1
  Runs in the signed-in user's session (no admin rights needed).
  Polls status.json written by Install-Apps.ps1 and renders progress.
  Triggered AtLogOn by the AppProvision-Progress scheduled task.
#>
param(
    [string]$Root = 'C:\ProgramData\AppProvisioning'
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$StatusFile = Join-Path $Root 'status.json'

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="セットアップ" Height="660" Width="540"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        FontFamily="Segoe UI Variable Text, Segoe UI, Meiryo UI">
  <Window.Resources>
    <Style x:Key="ModernBar" TargetType="ProgressBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border CornerRadius="4" Background="#EDEBE9" Height="8"/>
              <Border x:Name="PART_Indicator" CornerRadius="4" Background="#0078D4" Height="8" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="#0078D4"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border CornerRadius="8" Background="{TemplateBinding Background}" Padding="16,9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#106EBE"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Background" Value="#EDEBE9"/>
          <Setter Property="Foreground" Value="#A19F9D"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#605E5C"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border CornerRadius="6" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#F3F2F1"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Border CornerRadius="16" Background="White" BorderBrush="#E8E8E8" BorderThickness="1" Margin="12">
    <Border.Effect>
      <DropShadowEffect Color="#40000000" BlurRadius="24" ShadowDepth="4" Opacity="0.35"/>
    </Border.Effect>
    <Grid Margin="24,16,24,20">
      <Grid.RowDefinitions>
        <RowDefinition Height="30"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="110"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="●  Device Setup" Foreground="#A19F9D" FontSize="11" VerticalAlignment="Center"/>
        <Button Grid.Column="1" x:Name="BtnCloseTop" Content="✕" Style="{StaticResource GhostButton}"/>
      </Grid>

      <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,8,0,0">
        <Border Width="52" Height="52" CornerRadius="14" Background="#0078D4">
          <TextBlock Text="▣" Foreground="White" FontSize="24" FontWeight="Bold"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock x:Name="HeaderTitle" Text="アプリを準備しています" FontSize="19" FontWeight="SemiBold" Foreground="#201F1E"/>
          <TextBlock Text="サインイン後に必要なアプリを自動セットアップします" FontSize="12" Foreground="#605E5C" Margin="0,2,0,0"/>
        </StackPanel>
      </StackPanel>

      <StackPanel Grid.Row="2" Margin="0,20,0,0">
        <Grid>
          <TextBlock Text="全体の進捗" FontSize="12" FontWeight="SemiBold" Foreground="#323130"/>
          <TextBlock x:Name="OverallPct" Text="0%" FontSize="12" FontWeight="Bold" Foreground="#0078D4"
                     HorizontalAlignment="Right"/>
        </Grid>
        <ProgressBar x:Name="OverallBar" Style="{StaticResource ModernBar}" Minimum="0" Maximum="100" Value="0" Margin="0,8,0,0"/>
        <TextBlock x:Name="StatusText" Text="開始を待っています..." FontSize="12" Foreground="#605E5C" Margin="0,8,0,0" TextWrapping="Wrap"/>
      </StackPanel>

      <ScrollViewer Grid.Row="3" Margin="0,14,0,0" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="AppList"/>
      </ScrollViewer>

      <Border Grid.Row="4" CornerRadius="10" Background="#FAFAFA" BorderBrush="#EDEBE9" BorderThickness="1" Margin="0,12,0,0">
        <TextBox x:Name="LogBox" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                 FontFamily="Consolas" FontSize="10.5" Foreground="#605E5C"
                 VerticalScrollBarVisibility="Auto" Padding="10" TextWrapping="Wrap"/>
      </Border>

      <Grid Grid.Row="5" Margin="0,14,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="HintText" Text="この画面を閉じてもインストールは続行されます" FontSize="11" Foreground="#A19F9D" VerticalAlignment="Center" TextWrapping="Wrap"/>
        <Button Grid.Column="1" x:Name="BtnClose" Content="閉じる" Style="{StaticResource PrimaryButton}" Width="120" IsEnabled="False" Margin="12,0,0,0"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{
    Window      = $window
    HeaderTitle = $window.FindName('HeaderTitle')
    OverallBar  = $window.FindName('OverallBar')
    OverallPct  = $window.FindName('OverallPct')
    StatusText  = $window.FindName('StatusText')
    AppList     = $window.FindName('AppList')
    LogBox      = $window.FindName('LogBox')
    BtnClose    = $window.FindName('BtnClose')
    BtnCloseTop = $window.FindName('BtnCloseTop')
    HintText    = $window.FindName('HintText')
}

$window.Add_MouseLeftButtonDown({ param($s, $e) try { $s.DragMove() } catch { Out-Null } })
$ui.BtnClose.Add_Click({ $ui.Window.Close() })
$ui.BtnCloseTop.Add_Click({ $ui.Window.Close() })

$script:rows = @{}
$script:builtFor = ''

function Convert-Brush([string]$Hex) {
    (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
}

function Set-RowBadge($Row, [string]$Status) {
    $label = $Status
    $bg = '#EDEBE9'; $fg = '#605E5C'
    switch ($Status) {
        'Pending'     { $label = '待機中'; $bg = '#EDEBE9'; $fg = '#605E5C' }
        'Downloading' { $label = 'ダウンロード中'; $bg = '#DEECF9'; $fg = '#0078D4' }
        'Installing'  { $label = 'インストール中'; $bg = '#DEECF9'; $fg = '#0078D4' }
        'Installed'   { $label = '完了'; $bg = '#DFF6DD'; $fg = '#107C10' }
        'Skipped'     { $label = 'スキップ'; $bg = '#EDEBE9'; $fg = '#605E5C' }
        'Failed'      { $label = 'エラー'; $bg = '#FDE7E9'; $fg = '#D13438' }
    }
    $Row.Badge.Text = $label
    $Row.BadgeBorder.Background = (Convert-Brush $bg)
    $Row.Badge.Foreground = (Convert-Brush $fg)
}

function New-AppRow([string]$Name) {
    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $card.Background = (Convert-Brush '#F8F8F8')
    $card.BorderBrush = (Convert-Brush '#EDEBE9')
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    $card.Padding = New-Object System.Windows.Thickness(14)

    $stack = New-Object System.Windows.Controls.StackPanel

    $grid = New-Object System.Windows.Controls.Grid
    $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c2)

    $nameBlock = New-Object System.Windows.Controls.TextBlock
    $nameBlock.Text = $Name
    $nameBlock.FontSize = 13
    $nameBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
    $nameBlock.Foreground = (Convert-Brush '#201F1E')
    $nameBlock.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 0)
    $grid.Children.Add($nameBlock) | Out-Null

    $badgeBorder = New-Object System.Windows.Controls.Border
    $badgeBorder.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $badgeBorder.Padding = New-Object System.Windows.Thickness(10, 4, 10, 4)
    $badgeBorder.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $badgeBorder.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $badge = New-Object System.Windows.Controls.TextBlock
    $badge.FontSize = 11
    $badge.FontWeight = [System.Windows.FontWeights]::SemiBold
    $badgeBorder.Child = $badge
    $grid.Children.Add($badgeBorder) | Out-Null
    $stack.Children.Add($grid) | Out-Null

    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 0
    $bar.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
    $bar.Style = $window.FindResource('ModernBar')
    $stack.Children.Add($bar) | Out-Null

    $err = New-Object System.Windows.Controls.TextBlock
    $err.FontSize = 11
    $err.Foreground = (Convert-Brush '#D13438')
    $err.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $err.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
    $err.Visibility = [System.Windows.Visibility]::Collapsed
    $stack.Children.Add($err) | Out-Null

    $card.Child = $stack
    $ui.AppList.Children.Add($card) | Out-Null
    return @{ Bar = $bar; Badge = $badge; BadgeBorder = $badgeBorder; Error = $err }
}

$script:logLines = New-Object System.Collections.ArrayList
function Add-Log([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    $ts = (Get-Date).ToString('HH:mm:ss')
    [void]$script:logLines.Add("[$ts] $line")
    while ($script:logLines.Count -gt 60) { $script:logLines.RemoveAt(0) }
    $ui.LogBox.Text = ($script:logLines -join "`r`n")
    $ui.LogBox.ScrollToEnd()
}
$script:lastKey = ''

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({
    if (-not (Test-Path -LiteralPath $StatusFile)) {
        $ui.StatusText.Text = 'インストーラーの開始を待っています... (ログオン直後は数十秒かかります)'
        return
    }
    try {
        $st = Get-Content -LiteralPath $StatusFile -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch { return }

    $apps = @($st.apps)
    $sig = (($apps | ForEach-Object { [string]$_.name }) -join '|')
    if ($sig -ne $script:builtFor) {
        $ui.AppList.Children.Clear()
        $script:rows = @{}
        foreach ($a in $apps) {
            $script:rows[[string]$a.name] = (New-AppRow ([string]$a.name))
        }
        $script:builtFor = $sig
    }

    foreach ($a in $apps) {
        $key = [string]$a.name
        if ($script:rows.ContainsKey($key)) {
            $r = $script:rows[$key]
            $r.Bar.Value = [double]$a.percent
            Set-RowBadge $r ([string]$a.status)
            if ([string]$a.status -eq 'Failed' -and -not [string]::IsNullOrWhiteSpace([string]$a.error)) {
                $r.Error.Text = [string]$a.error
                $r.Error.Visibility = [System.Windows.Visibility]::Visible
            } else {
                $r.Error.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    }

    $pct = 0
    if ($st.overallPercent -ne $null) { $pct = [int]$st.overallPercent }
    $ui.OverallBar.Value = $pct
    $ui.OverallPct.Text = "$pct%"

    if ($st.state -eq 'Running') {
        $cur = [string]$st.currentName
        if ($cur) { $ui.StatusText.Text = "処理中: $cur ($pct%)" }
        else { $ui.StatusText.Text = "準備中... ($pct%)" }
    } elseif ($st.state -eq 'Complete') {
        $ui.HeaderTitle.Text = 'セットアップが完了しました'
        $ui.StatusText.Text = 'すべてのアプリの準備ができました。'
        $ui.BtnClose.IsEnabled = $true
        $ui.HintText.Text = 'アプリが使えるようになりました'
    } elseif ($st.state -eq 'Error') {
        $ui.HeaderTitle.Text = '一部でエラーが発生しました'
        $ui.StatusText.Text = '失敗したアプリがあります。ログを確認してください。'
        $ui.BtnClose.IsEnabled = $true
        $ui.HintText.Text = '管理者に logs フォルダの確認を依頼してください'
    }

    $key = "$($st.state)|$($st.currentName)|$pct"
    if ($key -ne $script:lastKey) {
        $script:lastKey = $key
        Add-Log "$($st.state) $pct% - $($st.currentName)"
    }
})

$timer.Start()
Add-Log '進捗の監視を開始しました'
[void]$window.ShowDialog()
$timer.Stop()
