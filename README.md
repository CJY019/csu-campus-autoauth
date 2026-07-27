# CSU Campus Autoauth

中南大学校园网（`CSU-Student`）自动认证工具，同时提供 Ubuntu/Linux
定时服务版与 Windows 登录单次版。

项目基于学校当前 Dr.COM/eportal 门户实测，适合实验室工作站、宿舍主机、
无显示器服务器和 Windows 笔记本在开机或校园网会话失效后恢复联网。

## 版本选择

| 版本 | 文件位置 | 自动触发方式 | 失败后的行为 |
| --- | --- | --- | --- |
| Ubuntu/Linux systemd 版 | 仓库根目录 | 开机 30 秒后运行，并每两分钟复查 | 写入 journal，定时器稍后自动重试 |
| Windows 10/11 版 | `windows/` | 当前用户登录 Windows 时运行一次 | 弹窗提示，可重试、修改凭据或关闭 |

两个版本不会混装，也不会共享凭据。Ubuntu/Linux 版保留适合无人值守主机的
两分钟复查；Windows 版不在后台定时扫描，成功、已联网或不在
`CSU-Student` 网络时都会静默退出。

## 共同功能

- 通过当前 `:802/eportal/portal/login` API 登录；
- 自动使用门户要求的 `,0,` 账号前缀；
- 支持中国移动、中国联通、中国电信和校园网出口；
- 兼容旧配置中的 `@yd`、`@lt`、`@dx` 后缀；
- 自动发现物理网卡上的 `100.x` 校园 IPv4 地址；
- 绑定真实校园地址并通过校园 DNS 检测公网，绕过 Clash/Meta fake-IP；
- 门户响应成功后继续验证真实公网，而不是把“假在线”当作成功；
- 密码不会写入脚本、日志或命令行。

## Ubuntu/Linux systemd 版

### 环境要求

- 中南大学校园网；
- Ubuntu/Debian 或其他使用 systemd 的 Linux；
- NetworkManager；
- Bash、curl、dig、ip、flock、logger。

Ubuntu/Debian 可安装所需依赖：

```bash
sudo apt update
sudo apt install -y curl dnsutils iproute2 util-linux
```

### 安装

```bash
git clone https://github.com/CJY019/csu-campus-autoauth.git
cd csu-campus-autoauth
./install.sh
```

安装程序会要求输入：

1. 统一身份认证账号（不要输入运营商后缀）；
2. 登录出口；
3. 校园网密码（输入时不会显示）。

配置完成后会安装：

```text
/usr/local/sbin/csu-campus-auth
/etc/systemd/system/csu-campus-auth.service
/etc/systemd/system/csu-campus-auth.timer
/etc/csu-campus-auth/credentials
```

凭据目录权限为 `0700`，凭据文件权限为 `0600`，所有者为 root。再次执行
`install.sh` 可升级程序，并可选择保留已有凭据。

systemd timer 在开机 30 秒后触发，并在服务结束后每两分钟复查一次。它适合
需要无人值守恢复网络的 Ubuntu 工作站或服务器。

### 查看状态

```bash
systemctl status csu-campus-auth.timer
sudo systemctl start csu-campus-auth.service
sudo journalctl -t csu-campus-auth -n 30 --no-pager
```

正常自动恢复会出现类似日志：

```text
The CSU eportal API accepted the login request.
Campus network login succeeded and Internet connectivity is available.
```

## Windows 10/11 版

Windows 版的代码与说明位于 [`windows/`](windows/)。

### 环境要求

- Windows 10 或 Windows 11；
- Windows PowerShell 5.1 或更高版本；
- 系统自带的 `curl.exe`；
- 已连接 `CSU-Student`。

### 安装

1. 打开仓库的 `windows` 文件夹；
2. 右键 `Install-CSUCampusAutoAuth.ps1`，选择“使用 PowerShell 运行”；
3. 填写统一身份认证账号、校园网密码和登录出口；
4. 点击“安装”。

安装位置为：

```text
%LOCALAPPDATA%\CSUCampusAutoAuth
```

安装程序会创建当前用户的 Windows 登录启动快捷方式。它只在登录时运行
一次，不创建两分钟定时任务：

- 已联网或当前不在 `CSU-Student`：静默退出；
- 连接成功：记录日志后立即退出；
- 连接失败：弹出“重试 / 修改账号密码 / 关闭”窗口；
- 点击“重试”：重新检查公网状态，仍离线时才再次认证，不主动注销现有会话；
- 点击“修改账号密码”：重新填写账号、密码和运营商出口，保存后立即重试；
- 点击“关闭”：结束本次运行。

### 手动触发测试

安装后，在 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CSUCampusAutoAuth\CSUCampusAutoAuth.ps1"
```

这会立即执行一次，与登录启动行为相同，但不会等待启动时的 15 秒网络准备
时间。若需要完整模拟登录启动，可在命令末尾加上 `-Startup`。

仅测试校园网网卡的公网直连，不读取凭据、不调用认证门户：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CSUCampusAutoAuth\CSUCampusAutoAuth.ps1" -ConnectivityTest
```

Windows 日志位置：

```text
%LOCALAPPDATA%\CSUCampusAutoAuth\autoauth.log
```

随时主动修改账号、密码或运营商出口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CSUCampusAutoAuth\CSUCampusAutoAuth.ps1" -EditCredentials
```

### 卸载

右键运行：

```text
windows\Uninstall-CSUCampusAutoAuth.ps1
```

卸载程序会删除登录启动快捷方式、程序文件、日志和本机加密凭据。

## 安全与隐私

- 项目仓库不包含账号、密码、日志或本机配置；
- Windows 密码通过 DPAPI/`PSCredential` 加密，只能由同一台电脑上的同一
  Windows 用户解密；
- Linux 凭据只写入 `/etc/csu-campus-auth/credentials`，权限为 root-only；
- 密码通过 curl 标准输入传递，不会出现在命令行参数中；
- `.gitignore` 明确排除两个版本的凭据文件及运行日志；
- 请勿手动把本机凭据或日志复制进项目目录并提交到 Git。

## 工作原理

1. 从物理网卡读取 `100.x` 校园地址；
2. 绑定该地址，通过校园 DNS 解析 Apple captive portal，并以 Windows NCSI
   作为备用联网探针；
3. 已联网时直接退出；
4. 未联网时规范化运营商后缀并调用 CSU eportal；
5. 登录后再次进行直连公网检测；
6. Ubuntu/Linux 版必要时执行带冷却时间的 logout/login 恢复；
7. Windows 版失败后由用户决定关闭或手动重试。

认证流程参考并交叉验证了：

- [barkure/CSU-Net-Portal](https://github.com/barkure/CSU-Net-Portal)
- [Muhe-nye/CSU-auto-login](https://github.com/Muhe-nye/CSU-auto-login)
- [Temparo/CSU-WIFI-AutoLogin](https://github.com/Temparo/CSU-WIFI-AutoLogin)

## 局限

- 门户地址、参数或学校网络策略改变后可能需要更新；
- 当前按中南大学常见的 `100.x` 地址段识别校园网；
- Windows 登录启动依赖用户会话，因此不是登录前运行的系统服务；
- 工具只能恢复网络认证，无法解决停电、校园网设备故障或物理链路中断。

## License

[MIT](LICENSE)
