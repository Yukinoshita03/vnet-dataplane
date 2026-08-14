# 校园网防掉守护程序

`build/campus_net_guard` 是一个用户态网络守护程序，可在 Linux 和 macOS 编译运行；其中 systemd 常驻安装方式适用于 Linux。工作流程是：

```text
定时访问 probe_url
       │
       ├─ 返回期望状态：保持等待
       │
       └─ 超时 / 失败 / 被门户重定向
                    │
                    └─ 向 auth_url 提交账号密码 → 延迟后再次探测
```

它只调用用户在配置里指定的校园网官方认证入口，不修改路由、DNS、防火墙或网卡状态。认证失败时使用指数退避，避免网络故障期间重复轰击认证服务器。

## 支持范围

当前内置适配器支持：

- `POST` 表单：`application/x-www-form-urlencoded`；
- `POST` JSON：`application/json`；
- `GET` 查询参数（仅为兼容旧门户，不推荐，因为密码会出现在 URL）；
- 可选的登录页预请求、Cookie 持久化、自定义字段和 HTTP 头；
- 认证后用独立的探测请求确认网络真的恢复。

深澜/SRun、锐捷或 Dr.COM 等要求先取 challenge、计算校验和/密码摘要、验证码或动态字段的门户，不能直接套用固定表单。需要先抓取你所在学校当前浏览器登录请求，再为该协议增加专用 adapter；不要把一个过期的 hash 或别人的登录接口硬写进通用配置。

## 构建

Linux 构建依赖 `clang`、`c++`、`tc`、`pkg-config` 和 libcurl 开发文件：

```bash
cd linux_accel
./scripts/build_linux.sh
```

输出为 `linux_accel/build/campus_net_guard`。Ubuntu/Debian 上通常需要：

```bash
sudo apt-get install clang g++ iproute2 pkg-config libcurl4-openssl-dev
```

macOS 只构建这个守护程序时可使用：

```bash
./scripts/build_macos.sh
```

需要 Homebrew 的 `pkg-config` 和 `curl` 开发文件；脚本不会构建 Linux 专用的 eBPF/`tc` 部分。

## 配置账号与认证请求

先复制样例并收紧权限：

```bash
sudo install -d -m 0750 /etc/campus-net-guard
sudo install -m 0600 config/campus-net-guard.conf.example \
  /etc/campus-net-guard/config.conf
sudo install -d -m 0750 /var/lib/campus-net-guard
sudo sh -c 'umask 077; printf "%s\\n" "你的校园网密码" > /etc/campus-net-guard/password'
```

然后编辑 `config.conf`，至少修改：

```ini
probe_url=https://你的可用性探测地址/generate_204
probe_success_status=204
auth_url=https://你的校园网门户/实际登录接口
auth_method=POST
request_format=form
username_field=页面请求中的账号字段名
password_field=页面请求中的密码字段名
username=你的校园网账号
password_file=/etc/campus-net-guard/password
```

认证 URL 和字段名必须来自你自己学校当前官方登录页面的请求。可以在浏览器开发者工具的 Network 面板中登录一次，查看实际的 Request URL、方法、Content-Type 和表单字段；不要把包含真实密码的抓包、配置或日志提交到仓库。

程序会拒绝权限不是用户私有的配置文件和密码文件（Linux 下要求不带 group/other 权限）。密码也可以通过 `CAMPUS_NET_PASSWORD` 环境变量提供，但 systemd 环境变量文件同样必须按 0600 保护。

如果门户需要额外字段：

```ini
field.service=campus
field.ac_id=1
field.n=200
header.Referer=https://你的校园网门户/login
```

字段值可以使用 `{username}` 和 `{password}` 占位符；`username_field`、`password_field` 对应的两个字段会由程序自动填入。

如果门户要求包装账号或追加运营商后缀，可以改用 `username_value`、`password_value`，例如 Dr.COM 常见的形式：

```ini
username_field=user_account
password_field=user_password
username_value=,0,{username}@{operator}
password_value={password}
operator=telecom
```

程序还支持 `{local_ipv4}` 和 `{local_mac}`。设置 `interface=wlan0`（Linux）或 `interface=en0`（macOS）后，程序会自动从该接口读取 IPv4/MAC；如果学校门户要求固定字段，也可以直接填写 `local_ipv4` 或 `local_mac`。

你提供的截图页脚显示为广州热点/Dr.COM 系列，可以先从 `config/drcom-eportal.conf.example` 开始。把 `PORTAL_HOST`、网卡名、运营商字段和浏览器实际请求中的版本/隐藏参数替换掉；不同学校即使使用同一厂商，也可能部署不同的 ePortal 路径和参数。

## 先单次验证

单次模式不会常驻，也方便确认配置是否正确：

```bash
./build/campus_net_guard \
  --config /etc/campus-net-guard/config.conf \
  --once
```

只检查而不发认证请求：

```bash
./build/campus_net_guard \
  --config /etc/campus-net-guard/config.conf \
  --once --dry-run
```

成功路径的日志大致如下；日志不会输出账号、密码、请求体或响应正文：

```text
[probe] offline or captive (HTTP 302, response_bytes=...)
[auth] request accepted (HTTP 200, response_bytes=...)
[probe] network restored (HTTP 204, response_bytes=0)
```

## systemd 部署

守护程序不需要 root 权限。创建一个专用用户，并让它只读配置、密码，写 Cookie 目录：

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin campus-net-guard
sudo install -d -o campus-net-guard -g campus-net-guard -m 0750 \
  /etc/campus-net-guard /var/lib/campus-net-guard
sudo chown campus-net-guard:campus-net-guard /etc/campus-net-guard/config.conf \
  /etc/campus-net-guard/password
sudo chmod 600 /etc/campus-net-guard/config.conf /etc/campus-net-guard/password
sudo install -m 0755 build/campus_net_guard /usr/local/bin/campus_net_guard
sudo install -m 0644 systemd/campus-net-guard.service \
  /etc/systemd/system/campus-net-guard.service
sudo systemctl daemon-reload
sudo systemctl enable --now campus-net-guard.service
```

查看日志：

```bash
journalctl -u campus-net-guard.service -f
```

修改配置后执行 `sudo systemctl restart campus-net-guard.service`。收到 SIGTERM/SIGINT 时程序会在当前请求结束后退出。

## 安全边界和常见问题

- 只对你有权使用的校园网账号和官方认证入口启用自动登录，并遵守学校网络使用规定。
- `tls_verify=true` 默认开启。只有在学校官方门户确实使用自签名证书且你已确认风险时，才考虑关闭；更好的做法是配置正确的 CA。
- 如果 `auth_url` 是 `http://`，程序会明确警告：密码在链路上没有加密。许多旧的内网门户仍然如此，建议优先使用学校提供的 HTTPS 入口。
- `auth_success_status` 只说明 HTTP 请求返回了指定状态；如果门户有稳定的成功 JSON/文本标记，应同时配置 `auth_success_contains`，并可配置 `auth_failure_contains` 防止把错误页误判为成功。
- “认证请求成功但探测仍失败”通常表示认证参数、运营商字段、设备/IP 绑定、Cookie 或探测 URL 配置不匹配；程序会进入退避，不会无限高频重试。
- 如果校园网只是物理断开、DHCP 尚未恢复或 Wi-Fi 未重新关联，认证请求本身也无法发送；程序会等待链路恢复后重试。
