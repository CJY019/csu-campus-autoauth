#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
    exec sudo -- "$0" "$@"
fi

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_DIR="/etc/csu-campus-auth"
readonly CREDENTIAL_FILE="${CONFIG_DIR}/credentials"

require_command() {
    local command_name="$1"
    local package_hint="$2"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '缺少命令 %s，请先安装软件包：%s\n' \
            "${command_name}" "${package_hint}" >&2
        exit 127
    fi
}

require_command systemctl systemd
require_command curl curl
require_command dig dnsutils
require_command ip iproute2
require_command flock util-linux
require_command logger bsdutils

printf '\n中南大学校园网开机自动认证安装程序\n'
printf '账号密码只会保存到 %s（root:root, 0600）。\n\n' "${CREDENTIAL_FILE}"

keep_credentials=false
if [[ -s "${CREDENTIAL_FILE}" ]]; then
    read -r -p '检测到已有凭据，保留并只升级程序？[Y/n]: ' keep_answer
    case "${keep_answer:-Y}" in
        Y|y|Yes|yes|YES) keep_credentials=true ;;
    esac
fi

if [[ "${keep_credentials}" != true ]]; then
    read -r -p '统一身份认证账号（不要输入 @ 后缀）: ' base_account
    if [[ -z "${base_account}" ]]; then
        printf '账号不能为空。\n' >&2
        exit 2
    fi

    printf '\n选择登录出口：\n'
    printf '  1) 中国移动\n'
    printf '  2) 中国联通\n'
    printf '  3) 中国电信\n'
    printf '  4) 校园网\n'
    read -r -p '请输入 1-4 [4]: ' provider
    provider="${provider:-4}"

    case "${provider}" in
        1) suffix="@cmccn" ;;
        2) suffix="@unicomn" ;;
        3) suffix="@telecomn" ;;
        4) suffix="" ;;
        *)
            printf '无效选项：%s\n' "${provider}" >&2
            exit 2
            ;;
    esac

    read -r -s -p '校园网密码（输入时不会显示）: ' password
    printf '\n'
    if [[ -z "${password}" ]]; then
        printf '密码不能为空。\n' >&2
        exit 2
    fi

    install -d -o root -g root -m 0700 "${CONFIG_DIR}"
    credential_tmp="$(mktemp "${CONFIG_DIR}/.credentials.XXXXXX")"
    trap 'rm -f -- "${credential_tmp:-}"' EXIT
    chmod 0600 "${credential_tmp}"
    printf '%s\n%s\n' "${base_account}${suffix}" "${password}" > "${credential_tmp}"
    chown root:root "${credential_tmp}"
    mv -f -- "${credential_tmp}" "${CREDENTIAL_FILE}"
    trap - EXIT
    unset password
fi

install -o root -g root -m 0755 \
    "${SOURCE_DIR}/csu-campus-auth" \
    /usr/local/sbin/csu-campus-auth
install -o root -g root -m 0644 \
    "${SOURCE_DIR}/csu-campus-auth.service" \
    /etc/systemd/system/csu-campus-auth.service
install -o root -g root -m 0644 \
    "${SOURCE_DIR}/csu-campus-auth.timer" \
    /etc/systemd/system/csu-campus-auth.timer

systemctl daemon-reload
systemctl enable --now csu-campus-auth.timer
if ! systemctl start csu-campus-auth.service; then
    printf '\n警告：首次认证检查失败；定时器仍会继续重试，请查看下方日志。\n' >&2
fi

printf '\n安装完成。\n'
systemctl --no-pager --full status csu-campus-auth.timer || true
printf '\n最近一次认证检查日志：\n'
journalctl -u csu-campus-auth.service -n 8 --no-pager || true
