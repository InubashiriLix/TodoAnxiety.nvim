# 同步服务的认证与安全边界

## 谁能读取任务

这是一套**单用户、多设备**服务，不是多个互不信任账号共用的多租户系统。
为每台设备签发不同 Token，所有有效设备 Token 访问同一份数据。

| 路径 | 认证要求 |
|---|---|
| `GET /v1/status` | 公开，只返回 `{"version":2}` |
| `GET /v1/pull` | Bearer Token |
| `POST /v1/push` | Bearer Token |
| `GET/PUT /v1/blobs/{sha256}` | Bearer Token，知道图片 hash 也不能匿名下载 |
| `POST/DELETE /v1/leases/{session}` | Bearer Token；释放／续租还验证会话锁凭据 |

路径相对于客户端 `sync.url`；反向代理可以使用 `/todo-sync` 前缀。
没有通过 HTTP 签发、查询或找回设备密钥的接口。缺失、伪造、已撤销的 Token 返回 401。
认证中间件在 JSON 解析和正文读取之前执行，拒绝未认证的大正文与畸形请求。

新 Token 由操作系统随机源支持的两个独立 UUIDv4 生成，串联为 64 位十六进制字符串。
已有 Token 在升级后仍有效。数据库只存 Token 的 SHA-256 摘要，不存原文。
每次请求都查询当前有效性，撤销后下一次请求即失效。

Token 通过服务端管理员命令创建；输出只显示一次。保存到设备的私有文件，客户端配置：

```lua
sync = {
  enabled = true,
  provider = 'server',
  url = 'https://YOUR_HOST/todo-sync',
  token_file = vim.fn.stdpath('data') .. '/todo.nvim/sync-token',
  tls_verify = true,
  allow_http = false,
}
```

`sync.token` 也支持字符串或返回字符串的函数，`sync.token_env` 支持自定义环境变量。
完整优先级见[Lua 配置](configuration.md)。

## 设备密钥管理

在服务器上使用同一服务用户／StateDirectory 创建、撤销 Token；权限示例见
[服务端文档](../server/README.md#install-with-systemd)。创建时将 stdout 重定向到
权限为 0600 的文件，通过 `oracle-download` 等受保护通道传输，确认后删除远端原文。
不要将真实密钥写入命令行、日志或仓库。

撤销命令从文件读取，不接收命令行中的真实 Token：

```sh
todoanxiety-sync token revoke --token-file /private/path/device.token --data-dir /var/lib/todoanxiety-sync
```

密钥轮换：为设备签发新 Token，更新设备私有文件、验证同步成功，再撤销旧 Token。
密钥泄漏后应尽快撤销；服务无法区分持有同一有效密钥的本人和他人。

## 部署防护

- HTTPS 终止在现有 Nginx；客户端默认验证证书，默认不允许 HTTP。
- 后端默认只监听 `127.0.0.1:8787`，不把后端端口直接暴露到公网。
- Nginx 限流模板按真实连接 IP 限制平均每秒 10 个请求，允许 40 个请求的突发排队；
  超出队列返回 429。每 IP 最多 8 个活动请求，服务合计最多 32 个。
  请求队列中的请求会被平滑处理，不会直接重试用户的写操作。
- 模板限制正文大小、正文超时及代理超时，认证接口响应禁止缓存。
  `nginx-limits.conf` 放在 `http {}`，`nginx-location.conf` 放在已有 HTTPS `server {}`。
  不影响其他站点路由。默认不信任外部请求传入的 `X-Forwarded-For` 来决定限流 IP。
- JSON 写入最多 4 MiB／1000 个修改；图片最多 10 MiB，验证格式、路径 hash 和完整内容 hash。
- SQLite 参数绑定、整批事务、版本检查和幂等操作 ID 防止覆盖冲突及重复提交。
- systemd 使用 DynamicUser、UMask=0077（默认文件权限 0600）、只读系统保护、持久 StateDirectory，
  并限制内存上限 512 MiB、任务数量 128、打开文件数 4096。
- HTTP 500 不暴露内部路径与数据库错误；管理员通过服务日志排查。
  客户端网络日志不记录请求正文、任务内容或密钥。

限流与排队语义参考 [Nginx 官方文档](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html)；
实际限制值可在服务器的 Nginx 模板和 systemd override 中调整。

## 仍需理解的边界

Bearer Token 是访问凭据，不能分享给不可信的人。同一个服务没有账号级的数据隔离。
同步内容在服务端以 SQLite 和图片原件存储，**没有端到端加密**；服务器管理员或有权限
读取这些文件的人可以看到内容。Token 摘要不能代替任务数据加密。

应用限流限制请求处理和资源消耗，不能保证抵挡打满公网带宽的分布式攻击。公网入口的
网络防护、服务器补丁、证书续期和备份仍由部署环境管理。对于只允许自己设备访问的
场景，可进一步用防火墙限制来源或通过私有网络访问，不必开放给所有公网来源。
