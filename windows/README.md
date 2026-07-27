# Windows 10/11 单次登录版

本目录是 CSU Campus Autoauth 的 Windows 专用版本。它与仓库根目录的
Ubuntu/Linux systemd 版本相互独立。

## 行为

- 当前用户登录 Windows 时运行一次；
- 不进行两分钟定时扫描；
- 已联网或不在 `CSU-Student` 时静默退出；
- 成功连接后立即退出；
- 失败时显示“重试 / 修改账号密码 / 关闭”；
- 可直接更新账号、密码和运营商出口，保存后立即重试；
- 重试会先重新检查公网，不会主动注销当前校园网会话；
- 账号密码由 Windows DPAPI 加密，只能由当前电脑上的当前用户解密。

## 文件

| 文件 | 用途 |
| --- | --- |
| `CSUCampusAutoAuth.ps1` | 单次认证程序 |
| `Install-CSUCampusAutoAuth.ps1` | 图形化安装与凭据配置 |
| `Uninstall-CSUCampusAutoAuth.ps1` | 卸载程序、启动项和加密凭据 |

## 安装

右键 `Install-CSUCampusAutoAuth.ps1`，选择“使用 PowerShell 运行”，填写
账号、密码和运营商出口后点击“安装”。

程序安装到：

```text
%LOCALAPPDATA%\CSUCampusAutoAuth
```

## 手动测试

安装完成后，在 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CSUCampusAutoAuth\CSUCampusAutoAuth.ps1"
```

命令会立即执行一次认证。若失败，可在窗口中重试或重新填写认证信息；若
成功、已经联网或不在校园网环境中，程序会静默退出。

仅测试校园网网卡的公网直连，不读取凭据、不调用认证门户：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CSUCampusAutoAuth\CSUCampusAutoAuth.ps1" -ConnectivityTest
```

模拟登录启动时的 15 秒准备延迟：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CSUCampusAutoAuth\CSUCampusAutoAuth.ps1" -Startup
```

随时主动修改账号、密码或运营商出口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CSUCampusAutoAuth\CSUCampusAutoAuth.ps1" -EditCredentials
```

日志位于：

```text
%LOCALAPPDATA%\CSUCampusAutoAuth\autoauth.log
```

## 卸载

右键 `Uninstall-CSUCampusAutoAuth.ps1`，选择“使用 PowerShell 运行”。

卸载会删除：

- Windows 登录启动快捷方式；
- `%LOCALAPPDATA%\CSUCampusAutoAuth` 中的程序和日志；
- 只在本机保存的 DPAPI 加密凭据。

## 隐私

不要把 `credential.xml`、`autoauth.log` 或其他本机配置复制进仓库。
`.gitignore` 已排除这些文件，但提交前仍应检查暂存内容。
