[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$installDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CSUCampusAutoAuth'
$startupShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'CSU Campus AutoAuth.lnk'
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'CSUCampusAutoAuth'

$answer = [System.Windows.Forms.MessageBox]::Show(
    "确定卸载中南大学校园网自动连接吗？`n`n这会同时删除本机保存的加密账号密码。",
    '卸载中南大学校园网自动连接',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
    exit 2
}

try {
    Remove-Item -LiteralPath $startupShortcutPath -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installDirectory) {
        $resolvedPath = (Resolve-Path -LiteralPath $installDirectory).Path
        $expectedPath = [System.IO.Path]::GetFullPath($installDirectory)
        if ($resolvedPath -ne $expectedPath -or -not $resolvedPath.EndsWith('\CSUCampusAutoAuth')) {
            throw '安装目录安全检查失败，未执行删除。'
        }
        Remove-Item -LiteralPath $resolvedPath -Recurse -Force
    }
    [void][System.Windows.Forms.MessageBox]::Show(
        '卸载完成。',
        '中南大学校园网自动连接',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}
catch {
    [void][System.Windows.Forms.MessageBox]::Show(
        ('卸载失败：' + $_.Exception.Message),
        '中南大学校园网自动连接',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}
