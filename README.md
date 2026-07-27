# CSU Campus Autoauth

中南大学校园网（`CSU-Student`）无人值守自动认证服务，适用于使用
systemd 与 NetworkManager 的 Linux 电脑。

该项目基于学校当前 Dr.COM/eportal 门户实测，适合实验室工作站、宿舍主机和
无显示器服务器在开机、断电恢复或校园网会话失效后自动恢复联网。

## 功能

- 通过当前 `:802/eportal/portal/login` API 登录；
- 自动使用门户要求的 `,0,` 账号前缀；
- 支持中国移动、中国联通、中国电信和校园网出口；
- 兼容旧配置中的 `@yd`、`@lt`、`@dx` 后缀；
- 自动发现物理网卡上的 `100.x` 校园 IPv4 地址；
- 绑定真实校园地址并通过校园 DNS 检测公网，绕过 Clash/Meta fake-IP；
- 门户响应成功后继续验证真实公网，而不是把“假在线”当作成功；
- 必要时执行一次带冷却时间的 logout/login 恢复；
- 使用 systemd timer 开机运行并定期复查；
- 凭据仅保存在 root 可读文件中，不写入脚本或日志。

## 环境要求

- 中南大学校园网；
- Linux + systemd；
- NetworkManager；
- Bash、curl、dig、ip、flock、logger。

Ubuntu/Debian 可安装所需依赖：

```bash
sudo apt update
sudo apt install -y curl dnsutils iproute2 util-linux
```

## 安装

```bash
git clone https://github.com/<GitHub-user>/csu-campus-autoauth.git
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

其中凭据目录权限为 `0700`，凭据文件权限为 `0600`，所有者为 root。

再次执行 `install.sh` 可升级程序。默认保留已有凭据；只有账号或密码变化时
才选择替换。

## 查看状态

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

## 安全与隐私

- 项目仓库不包含账号或密码；
- 安装时输入的凭据只写入 `/etc/csu-campus-auth/credentials`；
- 密码不会作为 curl 命令行参数出现，也不会写入 journal；
- 请勿把 `/etc/csu-campus-auth/credentials` 复制到项目目录或提交到 Git；
- 凭据仍以 root-only 明文形式保存在本机，请按普通系统密码同等级保护。

## 工作原理

1. 从物理网卡读取 `100.x` 校园地址；
2. 绑定该地址，通过校园 DNS 解析 Apple captive portal 检测地址；
3. 已联网时直接退出；
4. 未联网时规范化运营商后缀并调用 CSU eportal；
5. 登录后再次进行直连公网检测；
6. 门户会话异常时执行一次 logout/login，随后进入十分钟安全冷却。

认证流程参考并交叉验证了：

- [barkure/CSU-Net-Portal](https://github.com/barkure/CSU-Net-Portal)
- [Muhe-nye/CSU-auto-login](https://github.com/Muhe-nye/CSU-auto-login)
- [Temparo/CSU-WIFI-AutoLogin](https://github.com/Temparo/CSU-WIFI-AutoLogin)

## 局限

- 门户地址、参数或学校网络策略改变后可能需要更新；
- 当前按中南大学常见的 `100.x` 地址段识别校园网；
- 它只能恢复网络认证，无法解决宿舍停电、校园网设备故障或物理链路中断。

## License

[MIT](LICENSE)
