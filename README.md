# MacOS

macOS 实用脚本集合。

## check_v2rayn.sh

针对 [v2rayN](https://github.com/2dust/v2rayN) 的严格健康检查脚本，一次性核验代理链路是否真正生效，专为「TUN 全局代理 + 系统代理」的使用场景设计。

### 检查项

- **进程**：v2rayN 主程序、Xray 核心、sing-box TUN 核心是否运行
- **监听端口**：本地代理端口是否监听、监听进程是否为 Xray
- **系统代理**：HTTP / HTTPS / SOCKS 的启用状态、地址、端口是否正确
- **TUN 和路由**：TUN 地址是否存在、路由表是否包含指向 `utun` 的透明代理路由
- **配置校验**：`xray run -test`、`sing-box check`、v2rayN 的 `EnableTun`
- **代理服务器可达性**：从 Xray 配置自动提取出站 server 的地址与端口，单独探测其 TCP 可达性，并对比「经物理网卡直连」的结果。「连不上 server」多数是这一环不通（服务器宕机 / 被墙 / 端口变更 / 本地断网），单独探测便于第一时间定位
- **网络连通性**：显式代理与普通请求的可达性，并比对两者出口 IP（TUN 兜底是否生效）
- **App / CLI 连接检查**：核验目标 App（Claude / Cursor / ChatGPT 等）及 Claude Code CLI / Grok CLI 的每一条已建立 TCP 连接是否都走 v2rayN，发现未走代理的公网直连即报错
- **最近日志**：扫描当天 v2rayN 日志中的关键错误；当天无日志时回退到最近一份，且该日志超过 7 天会降级为 WARN，避免用陈旧日志给出虚假的「未发现错误」

#### 连接分类口径

每条已建立连接会被归入下列某一类，全部归类成功才算通过：

| 分类 | 含义 |
| --- | --- |
| `local_proxy` | 连到本地代理端口（显式代理） |
| `tun_socket` | 本端地址为 TUN 地址，由 TUN 直接发出 |
| `tun_route` | 远端 IP 的路由指向 v2rayN 的 `utun` |
| `other_tun` | 路由指向其它 VPN 的 `utun`（如奇安信 aTrust 接管的公司内网），各管一段，不算漏代理 |
| `route_excluded` | 命中 v2rayN「TUN 模式设置 → 路由排除地址」的网段，属刻意直连（如 aTrust 网关、代理 server 自身），不算漏代理 |
| `local_skip` | 回环与私网地址 |

排除网段直接从 `guiNConfig.json` 的 `TunModeItem.RouteExcludeAddress` 动态读取并做 CIDR 掩码匹配，因此调整排除列表后无需改脚本。

### 用法

```bash
chmod +x check_v2rayn.sh
./check_v2rayn.sh
```

也可通过环境变量覆盖默认配置：

```bash
PROXY_PORT=10809 REQUIRE_TUN=0 ./check_v2rayn.sh
```

### 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 服务正常（可能带 WARN 警告） |
| `1` | 存在 FAIL 失败项，建议重启 v2rayN 后重试 |
| `2` | 基础命令缺失，无法完成检查 |

### 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PROXY_HOST` | `127.0.0.1` | 本地代理监听地址 |
| `PROXY_PORT` | `10808` | 本地代理监听端口（Xray 混合入站） |
| `REQUIRE_TUN` | `1` | 是否强制要求 TUN 生效；`1` 时相关缺失记为 FAIL，`0` 时降级为 WARN |
| `TUN_ADDR` | `172.18.0.1` | sing-box TUN 网关地址，用于识别 TUN socket 与路由 |
| `TEST_URL` | `https://www.google.com/generate_204` | 连通性测试 URL（期望返回 204/200） |
| `IP_URL` | `https://api.ipify.org` | 出口 IP 查询 URL |
| `TIMEOUT` | `15` | 每次 curl 请求的最大秒数 |
| `CHECK_APPS` | `Claude:/Applications/Claude.app Cursor:/Applications/Cursor.app ChatGPT:/Applications/ChatGPT.app` | 需要做连接检查的 App，格式为空格分隔的 `标签:App路径` |
| `SERVER_ADDR` | 空（自动探测） | 代理服务器（入口）地址；留空则从 Xray 配置的代理出站自动提取 |
| `SERVER_PORT` | 空（自动探测） | 代理服务器端口；留空则自动提取。非 1-65535 的纯数字会被视为解析失败 |
| `SERVER_PROBE_TIMEOUT` | `5` | server TCP 探测的超时秒数 |

### 依赖

macOS 自带命令：`pgrep`、`ps`、`lsof`、`scutil`、`ifconfig`、`netstat`、`route`、`curl`、`awk`、`sed`、`grep`、`tr`。脚本会在开头检查这些命令是否可用。

`nc` 用于 TCP 探测（server 可达性、端口监听兜底），缺失时自动回退到 bash 的 `/dev/tcp`。
