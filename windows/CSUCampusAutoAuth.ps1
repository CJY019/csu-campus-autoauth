[CmdletBinding()]
param(
    [switch]$Startup,
    [switch]$EditCredentials,
    [switch]$ConnectivityTest,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CredentialPath = Join-Path $script:AppDirectory 'credential.xml'
$script:LogPath = Join-Path $script:AppDirectory 'autoauth.log'
$script:PortalApi = 'https://10.1.1.1:802/eportal/portal'
$script:OnlineCheckUrl = 'http://captive.apple.com/hotspot-detect.html'
$script:OnlineCheckHost = 'captive.apple.com'
$script:CampusDnsServer = '10.1.1.1'
$script:CampusWifiName = 'CSU-Student'
$systemCurlPath = Join-Path $env:SystemRoot 'System32\curl.exe'
if (Test-Path -LiteralPath $systemCurlPath) {
    $script:CurlPath = $systemCurlPath
}
else {
    $curlCommand = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    $script:CurlPath = if ($null -ne $curlCommand) { $curlCommand.Source } else { $null }
}

function Write-AppLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        if (Test-Path -LiteralPath $script:LogPath) {
            $logFile = Get-Item -LiteralPath $script:LogPath
            if ($logFile.Length -gt 1MB) {
                Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
            }
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never prevent authentication.
    }
}

function ConvertTo-CurlConfigValue {
    param([AllowEmptyString()][string]$Value)

    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t').Replace("`r", '\r').Replace("`n", '\n')
}

function New-CurlConfigLine {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    return '{0} = "{1}"' -f $Name, (ConvertTo-CurlConfigValue $Value)
}

function Invoke-CurlConfig {
    param([Parameter(Mandatory = $true)][string[]]$ConfigLines)

    if ([string]::IsNullOrWhiteSpace($script:CurlPath)) {
        throw '系统中未找到 curl.exe。请先安装 Windows 更新，或手动安装 curl。'
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:CurlPath
    $startInfo.Arguments = '--noproxy "*" --insecure --fail --silent --show-error --get --config -'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $originalInputEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = $utf8NoBom
        [void]$process.Start()
        $process.StandardInput.WriteLine(($ConfigLines -join "`n"))
        $process.StandardInput.Close()
    }
    finally {
        [Console]::InputEncoding = $originalInputEncoding
    }
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $standardOutput
        Error = $standardError
    }
}

function Get-CampusIPv4 {
    $campusAddresses = @(
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -match '^100\.' -and
                $_.AddressState -ne 'Duplicate' -and
                $_.AddressState -ne 'Tentative'
            }
    )

    foreach ($address in $campusAddresses) {
        $adapter = Get-NetAdapter -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue
        if ($null -ne $adapter -and $adapter.Status -eq 'Up' -and $adapter.HardwareInterface) {
            return $address.IPAddress
        }
    }

    return $null
}

function Get-ConnectedWifiName {
    try {
        $lines = & "$env:SystemRoot\System32\netsh.exe" wlan show interfaces 2>$null
        foreach ($line in $lines) {
            if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') {
                return $Matches[1]
            }
        }
    }
    catch {
        return $null
    }
    return $null
}

function Restart-CampusWifi {
    Write-AppLog ('准备重新连接 ' + $script:CampusWifiName + '。')
    $netshPath = Join-Path $env:SystemRoot 'System32\netsh.exe'

    try {
        & $netshPath wlan disconnect 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-AppLog ('断开 ' + $script:CampusWifiName + ' 失败。')
            return $false
        }

        Start-Sleep -Seconds 2
        & $netshPath wlan connect ('name=' + $script:CampusWifiName) 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-AppLog ('重新连接 ' + $script:CampusWifiName + ' 失败。')
            return $false
        }

        for ($attempt = 1; $attempt -le 15; $attempt++) {
            Start-Sleep -Seconds 2
            if ((Get-ConnectedWifiName) -eq $script:CampusWifiName -and
                -not [string]::IsNullOrWhiteSpace((Get-CampusIPv4))) {
                Write-AppLog ('已经重新连接 ' + $script:CampusWifiName + ' 并取得校园网地址。')
                return $true
            }
        }
    }
    catch {
        Write-AppLog ('重新连接校园 Wi-Fi 时出错：' + $_.Exception.Message)
        return $false
    }

    Write-AppLog ('重新连接 ' + $script:CampusWifiName + ' 后未能取得校园网地址。')
    return $false
}

function Select-FirstIPv4Address {
    param([AllowEmptyCollection()][object[]]$Records)

    foreach ($record in $Records) {
        if ($null -eq $record) {
            continue
        }
        $ipProperty = $record.PSObject.Properties['IPAddress']
        if ($null -ne $ipProperty -and
            $ipProperty.Value -match '^\d{1,3}(\.\d{1,3}){3}$') {
            return [string]$ipProperty.Value
        }
    }
    return $null
}

function Test-DirectCampusInternet {
    param([Parameter(Mandatory = $true)][string]$UserIp)

    $probes = New-Object System.Collections.Generic.List[object]
    $probes.Add([pscustomobject]@{
        Name = 'Apple captive portal'
        Host = $script:OnlineCheckHost
        Url = $script:OnlineCheckUrl
        ExpectedContent = @('<TITLE>Success</TITLE>', '<BODY>Success</BODY>')
    })

    try {
        $ncsiSettings = Get-ItemProperty -Path `
            'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet' `
            -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($ncsiSettings.ActiveWebProbeHost) -and
            -not [string]::IsNullOrWhiteSpace($ncsiSettings.ActiveWebProbePath) -and
            -not [string]::IsNullOrWhiteSpace($ncsiSettings.ActiveWebProbeContent)) {
            $ncsiUrl = 'http://' + $ncsiSettings.ActiveWebProbeHost + '/' +
                $ncsiSettings.ActiveWebProbePath.TrimStart('/')
            $probes.Add([pscustomobject]@{
                Name = 'Windows NCSI'
                Host = $ncsiSettings.ActiveWebProbeHost
                Url = $ncsiUrl
                ExpectedContent = @($ncsiSettings.ActiveWebProbeContent)
            })
        }
    }
    catch {
        Write-AppLog ('无法读取 Windows NCSI 备用探针：' + $_.Exception.Message)
    }

    $lastProbeError = $null
    foreach ($probe in $probes) {
        try {
            $dnsRecords = @(
                Resolve-DnsName -Name $probe.Host -Server $script:CampusDnsServer `
                    -Type A -DnsOnly -ErrorAction Stop
            )
            $resolvedAddress = Select-FirstIPv4Address -Records $dnsRecords
            if ([string]::IsNullOrWhiteSpace($resolvedAddress)) {
                continue
            }

            $config = @(
                (New-CurlConfigLine -Name 'interface' -Value $UserIp)
                (New-CurlConfigLine -Name 'resolve' -Value ('{0}:80:{1}' -f $probe.Host, $resolvedAddress))
                'connect-timeout = 4'
                'max-time = 8'
                (New-CurlConfigLine -Name 'url' -Value $probe.Url)
            )
            $result = Invoke-CurlConfig -ConfigLines $config
            if ($result.ExitCode -ne 0) {
                $lastProbeError = $result.Error.Trim()
                continue
            }

            $contentMatched = $true
            foreach ($expected in @($probe.ExpectedContent)) {
                if ($result.Output -notlike ('*' + $expected + '*')) {
                    $contentMatched = $false
                    break
                }
            }
            if ($contentMatched) {
                return $true
            }
        }
        catch {
            $lastProbeError = $_.Exception.Message
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($lastProbeError)) {
        Write-AppLog ('公网直连探针均失败：' + $lastProbeError)
    }
    return $false
}

function Wait-ForDirectCampusInternet {
    param([Parameter(Mandatory = $true)][string]$UserIp)

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        if (Test-DirectCampusInternet -UserIp $UserIp) {
            return $true
        }
        if ($attempt -lt 6) {
            Start-Sleep -Seconds 5
        }
    }
    return $false
}

function Normalize-CampusAccount {
    param([Parameter(Mandatory = $true)][string]$Account)

    $normalized = $Account
    if ($normalized.StartsWith(',0,')) {
        $normalized = $normalized.Substring(3)
    }

    if ($normalized.EndsWith('@dx', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 3) + '@telecomn'
    }
    elseif ($normalized.EndsWith('@lt', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 3) + '@unicomn'
    }
    elseif ($normalized.EndsWith('@yd', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 3) + '@cmccn'
    }

    return ',0,' + $normalized
}

function ConvertFrom-StoredCampusAccount {
    param([AllowEmptyString()][string]$Account)

    $baseAccount = $Account
    if ($baseAccount.StartsWith(',0,')) {
        $baseAccount = $baseAccount.Substring(3)
    }

    $provider = '校园网'
    $suffixes = @(
        [pscustomobject]@{ Suffix = '@cmccn'; LegacySuffix = '@yd'; Provider = '中国移动' }
        [pscustomobject]@{ Suffix = '@unicomn'; LegacySuffix = '@lt'; Provider = '中国联通' }
        [pscustomobject]@{ Suffix = '@telecomn'; LegacySuffix = '@dx'; Provider = '中国电信' }
    )
    foreach ($item in $suffixes) {
        foreach ($suffix in @($item.Suffix, $item.LegacySuffix)) {
            if ($baseAccount.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $baseAccount = $baseAccount.Substring(0, $baseAccount.Length - $suffix.Length)
                $provider = $item.Provider
                break
            }
        }
        if ($provider -ne '校园网') {
            break
        }
    }

    return [pscustomobject]@{
        BaseAccount = $baseAccount
        Provider = $provider
    }
}

function New-StoredCampusAccount {
    param(
        [Parameter(Mandatory = $true)][string]$BaseAccount,
        [Parameter(Mandatory = $true)]
        [ValidateSet('校园网', '中国移动', '中国联通', '中国电信')]
        [string]$Provider
    )

    $accountSettings = ConvertFrom-StoredCampusAccount -Account $BaseAccount.Trim()
    $suffix = switch ($Provider) {
        '中国移动' { '@cmccn' }
        '中国联通' { '@unicomn' }
        '中国电信' { '@telecomn' }
        default { '' }
    }
    return $accountSettings.BaseAccount + $suffix
}

function Invoke-PortalRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('login', 'logout')][string]$Action,
        [Parameter(Mandatory = $true)][string]$UserIp,
        [string]$Account,
        [string]$Password
    )

    $data = New-Object System.Collections.Generic.List[string]
    if ($Action -eq 'login') {
        $data.Add('callback=csu_auth_login')
        $data.Add('login_method=1')
        $data.Add('user_account=' + (Normalize-CampusAccount $Account))
        $data.Add('user_password=' + $Password)
        $data.Add('wlan_user_ip=' + $UserIp)
        $data.Add('wlan_user_ipv6=')
        $data.Add('wlan_user_mac=000000000000')
        $data.Add('wlan_ac_ip=')
        $data.Add('wlan_ac_name=')
        $data.Add('jsVersion=4.1.3')
        $data.Add('terminal_type=1')
        $data.Add('lang=zh-cn')
        $milliseconds = [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalMilliseconds)
        $data.Add('v=' + $milliseconds)
    }
    else {
        $data.Add('callback=csu_auth_logout')
        $data.Add('login_method=1')
        $data.Add('user_account=drcom')
        $data.Add('user_password=123')
        $data.Add('ac_logout=1')
        $data.Add('register_mode=1')
        $data.Add('wlan_user_ip=' + $UserIp)
        $data.Add('wlan_user_ipv6=')
        $data.Add('wlan_vlan_id=0')
        $data.Add('wlan_user_mac=000000000000')
        $data.Add('wlan_ac_ip=')
        $data.Add('wlan_ac_name=')
        $data.Add('jsVersion=4.1.3')
    }

    $config = New-Object System.Collections.Generic.List[string]
    $config.Add((New-CurlConfigLine -Name 'interface' -Value $UserIp))
    $config.Add('connect-timeout = 5')
    $config.Add('max-time = 20')
    foreach ($item in $data) {
        $config.Add((New-CurlConfigLine -Name 'data-urlencode' -Value $item))
    }
    $config.Add((New-CurlConfigLine -Name 'url' -Value ($script:PortalApi + '/' + $Action)))

    return Invoke-CurlConfig -ConfigLines $config.ToArray()
}

function Test-PortalSuccess {
    param([AllowEmptyString()][string]$Response)

    return $Response -match '"result"\s*:\s*"?(1|ok)"?'
}

function Invoke-ConnectionAttempt {
    param([switch]$ForcePortalRecovery)

    $userIp = Get-CampusIPv4
    if ([string]::IsNullOrWhiteSpace($userIp)) {
        $wifiName = Get-ConnectedWifiName
        if ($wifiName -ne 'CSU-Student') {
            Write-AppLog '当前未连接 CSU-Student，启动检查静默结束。'
            return [pscustomobject]@{ Success = $true; Message = '当前未连接 CSU-Student。' }
        }
        return [pscustomobject]@{
            Success = $false
            Message = '已经连接 CSU-Student，但尚未获得 100.x 校园网地址。请稍候后重试。'
            ReconnectWifiOnRetry = $true
        }
    }

    Write-AppLog ('检测到校园网地址 ' + $userIp + '。')
    if (Test-DirectCampusInternet -UserIp $userIp) {
        Write-AppLog '公网已经可用，无需重复认证。'
        return [pscustomobject]@{ Success = $true; Message = '公网已经可用。' }
    }

    if (-not (Test-Path -LiteralPath $script:CredentialPath)) {
        return [pscustomobject]@{
            Success = $false
            Message = '未找到加密凭据，请重新运行安装程序。'
        }
    }

    $plainPassword = $null
    try {
        $credential = Import-Clixml -LiteralPath $script:CredentialPath
        if ($null -eq $credential -or -not ($credential -is [System.Management.Automation.PSCredential])) {
            throw '凭据文件格式无效。'
        }
        $networkCredential = $credential.GetNetworkCredential()
        $account = $networkCredential.UserName
        $plainPassword = $networkCredential.Password
        if ([string]::IsNullOrWhiteSpace($account) -or [string]::IsNullOrEmpty($plainPassword)) {
            throw '账号或密码为空。'
        }

        if ($ForcePortalRecovery) {
            Write-AppLog '准备清理旧的校园网门户会话。'
            $logoutResponse = Invoke-PortalRequest -Action logout -UserIp $userIp
            if ($logoutResponse.ExitCode -ne 0) {
                Write-AppLog '门户未确认注销，仍继续执行一次登录恢复。'
            }
            else {
                Write-AppLog '已发送门户注销请求，等待会话释放。'
            }
            Start-Sleep -Seconds 3
        }

        $response = Invoke-PortalRequest -Action login -UserIp $userIp -Account $account -Password $plainPassword
        if ($response.ExitCode -ne 0) {
            $detail = $response.Error.Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = '无法访问校园网认证门户。'
            }
            return [pscustomobject]@{ Success = $false; Message = $detail }
        }

        if (-not (Test-PortalSuccess -Response $response.Output)) {
            Write-AppLog '校园网认证门户拒绝了登录请求或返回了未知结果。'
            return [pscustomobject]@{
                Success = $false
                Message = '认证未通过。请检查统一身份认证账号、密码和运营商出口。'
            }
        }

        Write-AppLog '认证门户已接受登录请求，正在验证公网。'
        if (Wait-ForDirectCampusInternet -UserIp $userIp) {
            Write-AppLog '校园网连接成功，程序退出。'
            return [pscustomobject]@{ Success = $true; Message = '校园网连接成功。' }
        }

        return [pscustomobject]@{
            Success = $false
            Message = '认证门户已接受登录，但公网仍不可用。点击“重试”将重新连接 CSU-Student、清理旧会话后再次认证。'
            ReconnectWifiOnRetry = $true
        }
    }
    catch {
        Write-AppLog ('连接失败：' + $_.Exception.Message)
        return [pscustomobject]@{ Success = $false; Message = $_.Exception.Message }
    }
    finally {
        $plainPassword = $null
        $networkCredential = $null
        $credential = $null
    }
}

function Save-EncryptedCampusCredential {
    param(
        [Parameter(Mandatory = $true)][string]$BaseAccount,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)]
        [ValidateSet('校园网', '中国移动', '中国联通', '中国电信')]
        [string]$Provider
    )

    $temporaryCredential = $null
    $securePassword = $null
    $credential = $null
    try {
        $storedAccount = New-StoredCampusAccount -BaseAccount $BaseAccount -Provider $Provider
        if ([string]::IsNullOrWhiteSpace($storedAccount) -or [string]::IsNullOrEmpty($Password)) {
            throw '账号或密码不能为空。'
        }

        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($storedAccount, $securePassword)
        $temporaryCredential = Join-Path $script:AppDirectory (
            'credential.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        )
        $credential | Export-Clixml -LiteralPath $temporaryCredential -Force
        Move-Item -LiteralPath $temporaryCredential -Destination $script:CredentialPath -Force
        $temporaryCredential = $null
        Write-AppLog '用户更新了加密账号、密码或运营商出口。'
    }
    finally {
        if ($null -ne $temporaryCredential -and (Test-Path -LiteralPath $temporaryCredential)) {
            Remove-Item -LiteralPath $temporaryCredential -Force -ErrorAction SilentlyContinue
        }
        $storedAccount = $null
        $credential = $null
        $securePassword = $null
        $Password = $null
    }
}

function Show-CredentialEditorDialog {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $accountSettings = [pscustomobject]@{ BaseAccount = ''; Provider = '校园网' }
    try {
        if (Test-Path -LiteralPath $script:CredentialPath) {
            $existingCredential = Import-Clixml -LiteralPath $script:CredentialPath
            if ($existingCredential -is [System.Management.Automation.PSCredential]) {
                $accountSettings = ConvertFrom-StoredCampusAccount -Account $existingCredential.UserName
            }
        }
    }
    catch {
        Write-AppLog ('读取现有账号设置失败：' + $_.Exception.Message)
    }
    finally {
        $existingCredential = $null
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '修改校园网账号密码'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(500, 355)
    $form.MinimumSize = $form.Size
    $form.MaximumSize = $form.Size
    $form.TopMost = $true
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.FormBorderStyle = 'FixedDialog'
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $form.Tag = 'Cancelled'

    $heading = New-Object System.Windows.Forms.Label
    $heading.Text = '重新填写认证信息'
    $heading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $heading.Location = New-Object System.Drawing.Point(28, 20)
    $heading.Size = New-Object System.Drawing.Size(420, 34)
    $form.Controls.Add($heading)

    $description = New-Object System.Windows.Forms.Label
    $description.Text = '账号已为你预填；为安全起见，密码需要重新输入。'
    $description.Location = New-Object System.Drawing.Point(30, 61)
    $description.Size = New-Object System.Drawing.Size(420, 26)
    $form.Controls.Add($description)

    $accountLabel = New-Object System.Windows.Forms.Label
    $accountLabel.Text = '统一身份认证账号'
    $accountLabel.Location = New-Object System.Drawing.Point(31, 105)
    $accountLabel.Size = New-Object System.Drawing.Size(130, 26)
    $form.Controls.Add($accountLabel)

    $accountBox = New-Object System.Windows.Forms.TextBox
    $accountBox.Location = New-Object System.Drawing.Point(168, 102)
    $accountBox.Size = New-Object System.Drawing.Size(285, 28)
    $accountBox.Text = $accountSettings.BaseAccount
    $form.Controls.Add($accountBox)

    $passwordLabel = New-Object System.Windows.Forms.Label
    $passwordLabel.Text = '新密码'
    $passwordLabel.Location = New-Object System.Drawing.Point(31, 152)
    $passwordLabel.Size = New-Object System.Drawing.Size(130, 26)
    $form.Controls.Add($passwordLabel)

    $passwordBox = New-Object System.Windows.Forms.TextBox
    $passwordBox.Location = New-Object System.Drawing.Point(168, 149)
    $passwordBox.Size = New-Object System.Drawing.Size(285, 28)
    $passwordBox.UseSystemPasswordChar = $true
    $form.Controls.Add($passwordBox)

    $providerLabel = New-Object System.Windows.Forms.Label
    $providerLabel.Text = '登录出口'
    $providerLabel.Location = New-Object System.Drawing.Point(31, 199)
    $providerLabel.Size = New-Object System.Drawing.Size(130, 26)
    $form.Controls.Add($providerLabel)

    $providerBox = New-Object System.Windows.Forms.ComboBox
    $providerBox.Location = New-Object System.Drawing.Point(168, 196)
    $providerBox.Size = New-Object System.Drawing.Size(285, 28)
    $providerBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$providerBox.Items.Add('校园网')
    [void]$providerBox.Items.Add('中国移动')
    [void]$providerBox.Items.Add('中国联通')
    [void]$providerBox.Items.Add('中国电信')
    $providerBox.SelectedItem = $accountSettings.Provider
    if ($providerBox.SelectedIndex -lt 0) {
        $providerBox.SelectedIndex = 0
    }
    $form.Controls.Add($providerBox)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = '保存并重试'
    $saveButton.Location = New-Object System.Drawing.Point(252, 257)
    $saveButton.Size = New-Object System.Drawing.Size(100, 34)
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Location = New-Object System.Drawing.Point(365, 257)
    $cancelButton.Size = New-Object System.Drawing.Size(88, 34)
    $form.Controls.Add($cancelButton)

    $saveButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($accountBox.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show('请输入统一身份认证账号。', $form.Text)
            $accountBox.Focus()
            return
        }
        if ([string]::IsNullOrEmpty($passwordBox.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show('请重新输入校园网密码。', $form.Text)
            $passwordBox.Focus()
            return
        }
        try {
            Save-EncryptedCampusCredential -BaseAccount $accountBox.Text `
                -Password $passwordBox.Text -Provider $providerBox.SelectedItem.ToString()
            $passwordBox.Text = ''
            $form.Tag = 'Saved'
            $form.Close()
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                ('保存失败：' + $_.Exception.Message),
                $form.Text,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })
    $cancelButton.Add_Click({
        $passwordBox.Text = ''
        $form.Tag = 'Cancelled'
        $form.Close()
    })

    $form.AcceptButton = $saveButton
    $form.CancelButton = $cancelButton
    [void]$form.ShowDialog()
    $passwordBox.Text = ''
    return $form.Tag -eq 'Saved'
}

function Show-FailureDialog {
    param([Parameter(Mandatory = $true)][string]$Message)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '中南大学校园网自动连接'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(570, 245)
    $form.MinimumSize = $form.Size
    $form.MaximumSize = $form.Size
    $form.TopMost = $true
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.FormBorderStyle = 'FixedDialog'
    $form.Tag = 'Close'

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '自动连接失败'
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $title.Size = New-Object System.Drawing.Size(500, 32)
    $form.Controls.Add($title)

    $detail = New-Object System.Windows.Forms.Label
    $detail.Text = $Message
    $detail.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $detail.Location = New-Object System.Drawing.Point(26, 62)
    $detail.Size = New-Object System.Drawing.Size(505, 75)
    $form.Controls.Add($detail)

    $retryButton = New-Object System.Windows.Forms.Button
    $retryButton.Text = '重试'
    $retryButton.Location = New-Object System.Drawing.Point(231, 154)
    $retryButton.Size = New-Object System.Drawing.Size(88, 34)
    $retryButton.Add_Click({
        $form.Tag = 'Retry'
        $form.Close()
    })
    $form.Controls.Add($retryButton)

    $editButton = New-Object System.Windows.Forms.Button
    $editButton.Text = '修改账号密码'
    $editButton.Location = New-Object System.Drawing.Point(331, 154)
    $editButton.Size = New-Object System.Drawing.Size(112, 34)
    $editButton.Add_Click({
        $form.Tag = 'EditCredentials'
        $form.Close()
    })
    $form.Controls.Add($editButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = '关闭'
    $closeButton.Location = New-Object System.Drawing.Point(455, 154)
    $closeButton.Size = New-Object System.Drawing.Size(88, 34)
    $closeButton.Add_Click({
        $form.Tag = 'Close'
        $form.Close()
    })
    $form.Controls.Add($closeButton)

    $form.AcceptButton = $retryButton
    $form.CancelButton = $closeButton
    [void]$form.ShowDialog()
    return [string]$form.Tag
}

function Invoke-SelfTest {
    $failures = New-Object System.Collections.Generic.List[string]
    if ((Normalize-CampusAccount '123456') -ne ',0,123456') { $failures.Add('校园网账号规范化失败') }
    if ((Normalize-CampusAccount '123456@yd') -ne ',0,123456@cmccn') { $failures.Add('移动账号规范化失败') }
    if ((Normalize-CampusAccount ',0,123456@lt') -ne ',0,123456@unicomn') { $failures.Add('联通账号规范化失败') }
    if ((Normalize-CampusAccount '123456@dx') -ne ',0,123456@telecomn') { $failures.Add('电信账号规范化失败') }
    if ((New-StoredCampusAccount -BaseAccount ',0,123456@yd' -Provider '中国联通') -ne '123456@unicomn') {
        $failures.Add('账号编辑出口转换失败')
    }
    $editedAccount = ConvertFrom-StoredCampusAccount -Account '123456@telecomn'
    if ($editedAccount.BaseAccount -ne '123456' -or $editedAccount.Provider -ne '中国电信') {
        $failures.Add('账号编辑预填解析失败')
    }
    if ((ConvertTo-CurlConfigValue 'a"b\c') -ne 'a\"b\\c') { $failures.Add('curl 配置转义失败') }
    if (-not (Test-PortalSuccess '{"result":"1","msg":"ok"}')) { $failures.Add('门户成功响应识别失败') }
    if (Test-PortalSuccess '{"result":"0","msg":"bad"}') { $failures.Add('门户失败响应识别失败') }
    $mockDnsRecords = @(
        [pscustomobject]@{ Name = 'alias.example'; Type = 'CNAME' }
        [pscustomobject]@{ Name = 'target.example'; Type = 'A'; IPAddress = '203.0.113.10' }
    )
    if ((Select-FirstIPv4Address -Records $mockDnsRecords) -ne '203.0.113.10') {
        $failures.Add('混合 DNS 记录解析失败')
    }
    if (Test-Path -LiteralPath $systemCurlPath) {
        $expectedCurlPath = (Get-Item -LiteralPath $systemCurlPath).FullName
        if ($script:CurlPath -ne $expectedCurlPath) { $failures.Add('未优先使用 Windows 系统 curl.exe') }
    }
    try {
        $curlTestUrl = 'file:///' + ($env:SystemRoot.Replace('\', '/')) + '/win.ini'
        $curlTest = Invoke-CurlConfig -ConfigLines @(
            (New-CurlConfigLine -Name 'url' -Value $curlTestUrl)
        )
        if ($curlTest.ExitCode -ne 0) {
            $curlTestError = $curlTest.Error.Trim()
            if ([string]::IsNullOrWhiteSpace($curlTestError)) {
                $curlTestError = 'curl exit code ' + $curlTest.ExitCode
            }
            $failures.Add('curl 标准输入配置兼容性测试失败：' + $curlTestError)
        }
    }
    catch {
        $failures.Add('curl 标准输入配置兼容性测试失败：' + $_.Exception.Message)
    }

    if ($failures.Count -gt 0) {
        throw ($failures -join '；')
    }
    Write-Output 'Self-test passed.'
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if ($ConnectivityTest) {
    $connectivityTestIp = Get-CampusIPv4
    if ([string]::IsNullOrWhiteSpace($connectivityTestIp)) {
        Write-Output 'Connectivity test failed: no physical 100.x campus IPv4 address.'
        exit 2
    }
    if (Test-DirectCampusInternet -UserIp $connectivityTestIp) {
        Write-Output 'Connectivity test passed: direct Internet access is available.'
        exit 0
    }
    Write-Output 'Connectivity test failed: direct Internet probes did not confirm access.'
    exit 1
}

if ($EditCredentials) {
    if (Show-CredentialEditorDialog) {
        exit 0
    }
    exit 2
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CSUCampusAutoAuth', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    if ($Startup) {
        Start-Sleep -Seconds 15
    }

    $reconnectWifiBeforeAttempt = $false
    :connectionLoop while ($true) {
        if ($reconnectWifiBeforeAttempt) {
            $reconnectWifiBeforeAttempt = $false
            if (-not (Restart-CampusWifi)) {
                $result = [pscustomobject]@{
                    Success = $false
                    Message = '重新连接 CSU-Student 失败。请确认 Wi-Fi 已开启且已保存该网络，然后重试。'
                    ReconnectWifiOnRetry = $true
                }
            }
            else {
                $result = Invoke-ConnectionAttempt -ForcePortalRecovery
            }
        }
        else {
            $result = Invoke-ConnectionAttempt
        }
        if ($result.Success) {
            exit 0
        }

        Write-AppLog ('准备提示用户：' + $result.Message)
        :promptLoop while ($true) {
            $choice = Show-FailureDialog -Message $result.Message
            switch ($choice) {
                'Retry' {
                    $reconnectProperty = $result.PSObject.Properties['ReconnectWifiOnRetry']
                    $reconnectWifiBeforeAttempt = (
                        $null -ne $reconnectProperty -and [bool]$reconnectProperty.Value
                    )
                    continue connectionLoop
                }
                'EditCredentials' {
                    if (Show-CredentialEditorDialog) {
                        continue connectionLoop
                    }
                    continue promptLoop
                }
                default {
                    Write-AppLog '用户关闭了失败提示。'
                    exit 1
                }
            }
        }
    }
}
finally {
    if ($createdNew) {
        [void]$mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
