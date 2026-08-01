# 共享 OpenStack Yoga 集群安全部署

本文只覆盖三台共享宿主机上的“预检、渲染、暂存、核验和回滚”：

- `controller`：`172.25.6.11`
- `compute2`：`172.25.6.13`，初始源节点
- `compute3`：`172.25.6.14`，迁移目标节点

暂存不等于启用。该流程不会启动或启用 systemd 服务，不会挂载 TC/XDP，
不会修改 OVS 网桥、路由、时钟或 OpenStack 资源。共享 unit 带有
`RefuseManualStart=yes`，正式激活必须走另一轮资源级授权和回归门禁。

## 前置条件

1. 从独立可信渠道核验三台机器各自的 Ed25519 主机指纹。禁止用
   `accept-new`，也不能把一次现场 `ssh-keyscan` 的结果当成独立凭据。
2. 为 `ubuntu` 用户登记一把明确的 SSH 公钥，并使用对应私钥文件。
   不在命令行、仓库、聊天记录或部署包中保存密码。
3. 在 Linux 构建机运行 `linux_accel/scripts/build_linux.sh`，确认用户态程序、
   BPF 对象和回归测试全部通过。Windows 工作区没有可直接部署的 Linux 产物。
4. 只使用本项目拥有的两台实例和两个 Neutron 端口。实例与端口必须同时匹配
   专用 project UUID 和 `vnet-dataplane-owner-*` 标签；实例 UUID、端口 UUID、
   固定 IPv4、MAC、libvirt domain、源节点 tap、`br-int` 成员关系和 OVS
   `external_ids:iface-id` 必须形成同一条所有权链。实例存在额外端口时预检失败。
5. 三节点时钟误差上限显式设为不大于 `10 ms`。不得执行
   `chronyc makestep` 或其他跳变时钟操作。

## 私有拓扑

复制 `linux_accel/deploy/lab/shared-yoga/topology.json.example` 到仓库外的私有
运行目录，替换所有 `REPLACE_...`。不得提交真实 UUID、来宾 IP、主机指纹、
`clouds.yaml`、SSH 私钥或现场证据。

关键绑定必须满足：

```text
server UUID
    -> owner project UUID + ownership tag
    -> Neutron port UUID / device_id
    -> exact fixed IPv4 + MAC
    -> binding_host_id == compute2
    -> OVS external_ids:iface-id == port UUID
    -> unique observed tap interface on br-int
```

目标节点在首次迁移前没有这些 tap，因此 inventory 中 target 的
`required_tap_interfaces` 和 `required_port_bindings` 必须为空。拓扑中的目标 tap
名称与源名称一致，迁移后仍需重新观测 `iface-id`，不能把名称相同当成绑定成立。

## 只读预检

以下命令只允许公钥认证、固定 Ed25519 指纹和严格 known-hosts：

```sh
python3 linux_accel/bench/openstack_shared_cluster_preflight.py \
  --inventory /private/run/inventory.json \
  --identity-file /private/keys/shared-cluster-ed25519 \
  --output /private/run/shared-preflight.json \
  --timeout 15
```

预检会失败关闭地检查：三节点身份、活动登录会话、Chrony 拓扑与误差界、
Nova/Neutron 服务、活动迁移、其他用户实例、目标容量、两台获授权实例的状态与
宿主、端口到实例绑定、libvirt domain、`br-int`、tap 和 OVS `iface-id`。
原始命令输出不写入报告，只记录经过筛选的证据和摘要。

初轮采集结束后，预检会在不超过 `60` 秒的窗口中重新采集登录会话、服务、迁移、
实例、端口、容量、libvirt、OVS 和链路状态，并只用这轮末端快照计算关键门禁。
`snapshot.confirmed` 未通过的报告不能用于暂存。

## 渲染部署包

预检 inventory 和拓扑使用同一份规范化数据：

```sh
python3 linux_accel/bench/render_openstack_shared_bundle.py \
  --topology /private/run/topology.json \
  --artifact-root /private/run/vnet-dataplane-linux-build \
  --output /private/run/shared-yoga-bundle
```

渲染器要求所有 Linux 构建产物存在且不是符号链接，并为每个文件生成 SHA-256、
目标路径和权限。宿主文件与来宾文件分开列出；三宿主机暂存器不会分发来宾文件。
输出路径必须是从未存在过的新路径；渲染器采用独占发布，不会替换并发创建的目录。
生成的 Agent endpoint 配置使用 schema `2`，每台实例只允许拓扑声明的精确
`port_ids`，发现额外本机 ACTIVE OVS 端口时不会挂载任何 hook。

## 零写入演练

预检报告默认只有 `120` 秒有效。先执行零写入演练：

```sh
python3 linux_accel/bench/stage_openstack_shared_deployment.py \
  --topology /private/run/topology.json \
  --artifact-root /private/run/vnet-dataplane-linux-build \
  --inventory /private/run/inventory.json \
  --preflight /private/run/shared-preflight.json \
  --bundle /private/run/shared-yoga-bundle \
  --identity-file /private/keys/shared-cluster-ed25519 \
  --output /private/run/shared-stage-dry-run.json \
  --dry-run
```

演练会在三节点上核验主机指纹、hostname、目标文件冲突和 unit 状态，但不写文件。
任何目标已经存在、unit 活动或启用都会阻断，避免覆盖其他人的部署。

## 暂存

开始前必须向共享集群用户公告精确路径和操作窗口；生成收据后立即公布随机
`backup_id`。确认预检仍新鲜后执行：

```sh
python3 linux_accel/bench/stage_openstack_shared_deployment.py \
  --topology /private/run/topology.json \
  --artifact-root /private/run/vnet-dataplane-linux-build \
  --inventory /private/run/inventory.json \
  --preflight /private/run/shared-preflight.json \
  --bundle /private/run/shared-yoga-bundle \
  --identity-file /private/keys/shared-cluster-ed25519 \
  --recovery-output /private/run/shared-stage-recovery.json \
  --output /private/run/shared-stage-receipt.json \
  --stage
```

部署器先核验全部节点，再按 `compute2 -> compute3 -> controller` 逐台暂存。写入范围
只包括：

- `/opt/vnet-dataplane-shared/`
- `/etc/vnet-dataplane-shared/`
- `/etc/systemd/system/vnet-dataplane-shared-*.service`
- `/var/backups/vnet-dataplane-shared/codex-backup-.../`
- `/run/lock/vnet-dataplane-shared-stage.lock`

部署器在三节点核验结束后以及每台节点写入前都按真实 UTC 重新检查末端快照年龄。
证据在等待期间过期会停止后续写入，并反序回滚本轮已经完成的节点。

暂存阶段不调用 `daemon-reload`，也不包含 `start`、`stop`、`restart`、`enable`
或 `disable` 操作。sudoers 必须与仓库内受信模板逐字节一致并通过 `visudo -cf`，
但只以 root-only 的 `vnet-dataplane-shared.sudoers.pending` 暂存在 shared 配置目录，
不会写入 `/etc/sudoers.d`。成功收据固定写入 `activation_ready: false`，在独立激活
流程完成前不得安装 sudoers、启动服务或挂载 TC/XDP。

`--recovery-output` 在首次远端检查前落盘，记录随机 `backup_id`、manifest 摘要和
节点事务状态。不得删除、覆盖或提交该文件；即使最终 stage 收据写入失败，它仍是
可用的回滚凭据。
其父目录必须在命令执行前已经存在，且整条目录链不得包含符号链接；部署器会在
首次 SSH 前同步该目录链。不要把 recovery 文件放进临时创建但尚未持久化的目录。

## 回滚与后续激活

每台节点在写入前都会生成 root-only rollback manifest。任一节点失败时，部署器按
`controller -> compute3 -> compute2` 的已完成节点反序恢复；若自动回滚不完整，
失败收据会保留 `backup_id` 和失败角色，供人工使用同一 manifest 精确恢复。

成功暂存后使用最终收据回滚；若最终收据没有成功落盘，则把 recovery 文件传给
同一个 `--receipt` 参数：

```sh
python3 linux_accel/bench/stage_openstack_shared_deployment.py \
  --inventory /private/run/inventory.json \
  --receipt /private/run/shared-stage-receipt.json \
  --identity-file /private/keys/shared-cluster-ed25519 \
  --output /private/run/shared-rollback-receipt.json \
  --rollback
```

紧急回滚只依赖 inventory、stage/recovery 收据和固定主机身份，不依赖 topology、
bundle 或已经可能被清理的 Linux 构建目录。回滚也不会重新加载 systemd manager。

暂存成功后仍不得直接运行正式 E2E。后续激活门禁至少还需完成：

1. 独立核验 runtime known-hosts 和显式 SSH identity，不放入仓库或部署包。
2. 安全提供只读 `OS_CLOUD`/`OS_CLIENT_CONFIG_FILE`，并以真实 service identity 复核。
3. 对远端所有暂存文件、运行期 pin/run/state 残留做 manifest 和清理审计。
4. 在 activation 事务中原子安装 pending sudoers，并支持失败时恢复或移除。
5. 让 E2E runner 消费 stage receipt，并切换到 shared unit、state、log 和 pin 路径。
6. 为 guest 文件和可执行产物生成同一 manifest 绑定的独立暂存收据。
7. 激活前再跑一次新鲜预检，经单独授权后执行 `daemon-reload` 并发布 activation 收据。
8. 迁移后重新核验目标 tap 的唯一 OVS `iface-id`；两台 Agent 都健康后才发布 epoch。
9. 清理时分别审计 compute2、compute3 的 TC/XDP hook、pin、进程、marker 和 quiesce 文件。
10. 单轮 DNS+gRPC 通过并完成清理审计后，再考虑五轮正式性能实验。
