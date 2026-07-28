[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$sourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRunner = Join-Path $sourceDirectory 'CSUCampusAutoAuth.ps1'
$installDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CSUCampusAutoAuth'
$installedRunner = Join-Path $installDirectory 'CSUCampusAutoAuth.ps1'
$credentialPath = Join-Path $installDirectory 'credential.xml'
$startupShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'CSU Campus AutoAuth.lnk'

if (-not (Test-Path -LiteralPath $sourceRunner)) {
    [void][System.Windows.Forms.MessageBox]::Show(
        '安装包不完整：找不到 CSUCampusAutoAuth.ps1。',
        '中南大学校园网自动连接',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = '安装中南大学校园网自动连接'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(500, 390)
$form.MinimumSize = $form.Size
$form.MaximumSize = $form.Size
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.FormBorderStyle = 'FixedDialog'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$heading = New-Object System.Windows.Forms.Label
$heading.Text = '中南大学校园网自动连接'
$heading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$heading.Location = New-Object System.Drawing.Point(28, 22)
$heading.Size = New-Object System.Drawing.Size(430, 36)
$form.Controls.Add($heading)

$description = New-Object System.Windows.Forms.Label
$description.Text = '当前用户登录 Windows 时运行一次；失败时可重试、修改凭据或关闭。'
$description.Location = New-Object System.Drawing.Point(30, 65)
$description.Size = New-Object System.Drawing.Size(430, 42)
$form.Controls.Add($description)

$accountLabel = New-Object System.Windows.Forms.Label
$accountLabel.Text = '统一身份认证账号'
$accountLabel.Location = New-Object System.Drawing.Point(31, 119)
$accountLabel.Size = New-Object System.Drawing.Size(130, 26)
$form.Controls.Add($accountLabel)

$accountBox = New-Object System.Windows.Forms.TextBox
$accountBox.Location = New-Object System.Drawing.Point(168, 116)
$accountBox.Size = New-Object System.Drawing.Size(285, 28)
$form.Controls.Add($accountBox)

$passwordLabel = New-Object System.Windows.Forms.Label
$passwordLabel.Text = '校园网密码'
$passwordLabel.Location = New-Object System.Drawing.Point(31, 166)
$passwordLabel.Size = New-Object System.Drawing.Size(130, 26)
$form.Controls.Add($passwordLabel)

$passwordBox = New-Object System.Windows.Forms.TextBox
$passwordBox.Location = New-Object System.Drawing.Point(168, 163)
$passwordBox.Size = New-Object System.Drawing.Size(285, 28)
$passwordBox.UseSystemPasswordChar = $true
$form.Controls.Add($passwordBox)

$providerLabel = New-Object System.Windows.Forms.Label
$providerLabel.Text = '登录出口'
$providerLabel.Location = New-Object System.Drawing.Point(31, 213)
$providerLabel.Size = New-Object System.Drawing.Size(130, 26)
$form.Controls.Add($providerLabel)

$providerBox = New-Object System.Windows.Forms.ComboBox
$providerBox.Location = New-Object System.Drawing.Point(168, 210)
$providerBox.Size = New-Object System.Drawing.Size(285, 28)
$providerBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$providerBox.Items.Add('校园网')
[void]$providerBox.Items.Add('中国移动')
[void]$providerBox.Items.Add('中国联通')
[void]$providerBox.Items.Add('中国电信')
$providerBox.SelectedIndex = 0
$form.Controls.Add($providerBox)

$privacy = New-Object System.Windows.Forms.Label
$privacy.Text = '密码由 Windows 当前用户加密保存，不会写进脚本、日志或命令行。'
$privacy.ForeColor = [System.Drawing.Color]::DimGray
$privacy.Location = New-Object System.Drawing.Point(31, 255)
$privacy.Size = New-Object System.Drawing.Size(420, 28)
$form.Controls.Add($privacy)

$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = '安装'
$installButton.Location = New-Object System.Drawing.Point(264, 298)
$installButton.Size = New-Object System.Drawing.Size(88, 34)
$form.Controls.Add($installButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = '取消'
$cancelButton.Location = New-Object System.Drawing.Point(365, 298)
$cancelButton.Size = New-Object System.Drawing.Size(88, 34)
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancelButton)

$form.CancelButton = $cancelButton
$script:confirmed = $false

$installButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($accountBox.Text)) {
        [void][System.Windows.Forms.MessageBox]::Show('请输入统一身份认证账号。', $form.Text)
        $accountBox.Focus()
        return
    }
    if ([string]::IsNullOrEmpty($passwordBox.Text)) {
        [void][System.Windows.Forms.MessageBox]::Show('请输入校园网密码。', $form.Text)
        $passwordBox.Focus()
        return
    }
    $script:confirmed = $true
    $form.Close()
})

[void]$form.ShowDialog()
if (-not $script:confirmed) {
    exit 2
}

$suffix = switch ($providerBox.SelectedItem.ToString()) {
    '中国移动' { '@cmccn' }
    '中国联通' { '@unicomn' }
    '中国电信' { '@telecomn' }
    default { '' }
}
$baseAccount = $accountBox.Text.Trim()
if ($baseAccount.StartsWith(',0,')) {
    $baseAccount = $baseAccount.Substring(3)
}
$baseAccount = $baseAccount -replace '(?i)@(cmccn|unicomn|telecomn|yd|lt|dx)$', ''
$storedAccount = $baseAccount + $suffix
$securePassword = ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
$passwordBox.Text = ''
$credential = New-Object System.Management.Automation.PSCredential($storedAccount, $securePassword)

try {
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    Copy-Item -LiteralPath $sourceRunner -Destination $installedRunner -Force

    $temporaryCredential = Join-Path $installDirectory ('credential.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $credential | Export-Clixml -LiteralPath $temporaryCredential -Force
    Move-Item -LiteralPath $temporaryCredential -Destination $credentialPath -Force

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupShortcutPath)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        $installedRunner + '" -Startup'
    $shortcut.WorkingDirectory = $installDirectory
    $shortcut.Description = '中南大学校园网登录时自动连接一次'
    $shortcut.WindowStyle = 7
    $shortcut.Save()

    $argumentList = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-WindowStyle'
        'Hidden'
        '-File'
        ('"{0}"' -f $installedRunner)
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -WindowStyle Hidden

    [void][System.Windows.Forms.MessageBox]::Show(
        "安装完成。`n`n以后登录 Windows 时会自动尝试连接一次；失败时可重试、修改账号密码或关闭。",
        '中南大学校园网自动连接',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}
catch {
    [void][System.Windows.Forms.MessageBox]::Show(
        ('安装失败：' + $_.Exception.Message),
        '中南大学校园网自动连接',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}
finally {
    $shortcut = $null
    $shell = $null
    $credential = $null
    $securePassword = $null
    $baseAccount = $null
    $storedAccount = $null
}
