[CmdletBinding()]
param(
    [switch]$Startup,
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

function Test-DirectCampusInternet {
    param([Parameter(Mandatory = $true)][string]$UserIp)

    try {
        $resolvedAddress = Resolve-DnsName -Name $script:OnlineCheckHost -Server $script:CampusDnsServer `
            -Type A -DnsOnly -ErrorAction Stop |
            Where-Object { $_.IPAddress -match '^\d{1,3}(\.\d{1,3}){3}$' } |
            Select-Object -First 1 -ExpandProperty IPAddress

        if ([string]::IsNullOrWhiteSpace($resolvedAddress)) {
            return $false
        }

        $config = @(
            (New-CurlConfigLine -Name 'interface' -Value $UserIp)
            (New-CurlConfigLine -Name 'resolve' -Value ('{0}:80:{1}' -f $script:OnlineCheckHost, $resolvedAddress))
            'connect-timeout = 4'
            'max-time = 8'
            (New-CurlConfigLine -Name 'url' -Value $script:OnlineCheckUrl)
        )
        $result = Invoke-CurlConfig -ConfigLines $config
        return $result.ExitCode -eq 0 -and
            $result.Output -like '*<TITLE>Success</TITLE>*' -and
            $result.Output -like '*<BODY>Success</BODY>*'
    }
    catch {
        Write-AppLog ('公网直连检测失败：' + $_.Exception.Message)
        return $false
    }
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
    param([switch]$RecoverSession)

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

        if ($RecoverSession) {
            Write-AppLog '按用户选择执行一次注销后重试。'
            [void](Invoke-PortalRequest -Action logout -UserIp $userIp)
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
            Message = '认证门户已接受登录，但公网仍不可用。'
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

function Show-RetryOrCloseDialog {
    param([Parameter(Mandatory = $true)][string]$Message)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '中南大学校园网自动连接'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(470, 245)
    $form.MinimumSize = $form.Size
    $form.MaximumSize = $form.Size
    $form.TopMost = $true
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.FormBorderStyle = 'FixedDialog'

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '自动连接失败'
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $title.Size = New-Object System.Drawing.Size(400, 32)
    $form.Controls.Add($title)

    $detail = New-Object System.Windows.Forms.Label
    $detail.Text = $Message
    $detail.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $detail.Location = New-Object System.Drawing.Point(26, 62)
    $detail.Size = New-Object System.Drawing.Size(405, 75)
    $form.Controls.Add($detail)

    $retryButton = New-Object System.Windows.Forms.Button
    $retryButton.Text = '重试'
    $retryButton.Location = New-Object System.Drawing.Point(242, 154)
    $retryButton.Size = New-Object System.Drawing.Size(88, 34)
    $retryButton.DialogResult = [System.Windows.Forms.DialogResult]::Retry
    $form.Controls.Add($retryButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = '关闭'
    $closeButton.Location = New-Object System.Drawing.Point(343, 154)
    $closeButton.Size = New-Object System.Drawing.Size(88, 34)
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($closeButton)

    $form.AcceptButton = $retryButton
    $form.CancelButton = $closeButton
    return $form.ShowDialog()
}

function Invoke-SelfTest {
    $failures = New-Object System.Collections.Generic.List[string]
    if ((Normalize-CampusAccount '123456') -ne ',0,123456') { $failures.Add('校园网账号规范化失败') }
    if ((Normalize-CampusAccount '123456@yd') -ne ',0,123456@cmccn') { $failures.Add('移动账号规范化失败') }
    if ((Normalize-CampusAccount ',0,123456@lt') -ne ',0,123456@unicomn') { $failures.Add('联通账号规范化失败') }
    if ((Normalize-CampusAccount '123456@dx') -ne ',0,123456@telecomn') { $failures.Add('电信账号规范化失败') }
    if ((ConvertTo-CurlConfigValue 'a"b\c') -ne 'a\"b\\c') { $failures.Add('curl 配置转义失败') }
    if (-not (Test-PortalSuccess '{"result":"1","msg":"ok"}')) { $failures.Add('门户成功响应识别失败') }
    if (Test-PortalSuccess '{"result":"0","msg":"bad"}') { $failures.Add('门户失败响应识别失败') }
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

    $recoverSession = $false
    while ($true) {
        $result = Invoke-ConnectionAttempt -RecoverSession:$recoverSession
        if ($result.Success) {
            exit 0
        }

        Write-AppLog ('准备提示用户：' + $result.Message)
        $choice = Show-RetryOrCloseDialog -Message $result.Message
        if ($choice -ne [System.Windows.Forms.DialogResult]::Retry) {
            Write-AppLog '用户关闭了失败提示。'
            exit 1
        }
        $recoverSession = $true
    }
}
finally {
    if ($createdNew) {
        [void]$mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
