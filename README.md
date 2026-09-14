# Campus-Auth 一键安装器

给本校同学用的校园网自动认证工具，一个文件、双击就装好。

> 只负责**打包安装器**；本体程序来自上游 [Campus-Auth-rs](https://github.com/Misyra/Campus-Auth-rs) 的 GitHub Release。

---

## 怎么用

1. 拿到 `campus-auth-一键安装.bat`，**双击**。
2. 弹出「是否允许此应用对你的设备进行更改」→ 点「**是**」（这样开机和唤醒都能自启）。
3. 按提示输入校园网**账号**与**密码**（密码不显示）。
4. 等它自动下载、解压、配好，任务栏出现托盘图标即可用。

装在哪：默认 `D:\campus-auth`；没有 D 盘会装到 `%LOCALAPPDATA%\campus-auth`。

### 静默安装（可选）

```powershell
$env:CA_USERNAME  = '学号'
$env:CA_PASSWORD  = '密码'
$env:CA_ASSUMEYES = '1'    # 跳过所有确认
powershell -ExecutionPolicy Bypass -File campus-auth-onekey-setup.ps1
```

其他可选变量：`CA_INSTALLDIR`（安装目录）、`CA_NOLAUNCH`（装完不启动）。

---

## 自启动（安装器自动配好，不用管）

| 场景 | 是否自动启动 |
| --- | --- |
| 关机 → 开机 / 重新登录 | ✅ |
| 合盖睡眠 / 锁屏 → 唤醒解锁 | ✅（需第 2 步点了「是」） |

原因：程序自带的 Run 键只在登录时触发，**睡眠唤醒后不会补拉起**。安装器额外注册一个计划任务（任务名 `Campus-Auth Autostart`），补上唤醒这一格。

第 2 步点了「否」也能正常用，只是**唤醒后不自动启动**。想补上，右键安装器 →「以管理员身份运行」重跑一次即可。

---

## 启动时提示「缺失 SHA256 校验文件」

这是**上游发布打包的问题**，与安装器无关，**不影响使用**，忽略即可；上游补齐后会自动恢复更新。

---

## 维护者：重新构建

```bash
python build_onekey.py
```

产出 `campus-auth-onekey-setup.ps1` + `campus-auth-一键安装.bat`（已在 `.gitignore` 忽略，发布时重新构建）。

| 文件 | 作用 |
| --- | --- |
| `build_onekey.py` | 构建脚本：模板 + 预设配置 → 独立安装器 |
| `onekey-template.ps1.tpl` | 安装器模板：解析最新 Release（含 gh-proxy 加速回退）、下载解压、写配置、启动托盘 |
| `preset-settings.json` | 真实运行的设置快照，让重建不依赖已安装目录 |
| `campus-auth-default-fixed.json` | 默认认证任务，账号/密码用 `{{USERNAME}}`/`{{PASSWORD}}` 占位符 |

---

## 换学校 / 自定义（一般用不到，本节放最后）

本项目**只为本校定制**，模板里的默认值已是本校参数，同学直接双击用即可。

若要给别的学校用，改 `onekey-template.ps1.tpl` 顶部这几项，然后重新 `python build_onekey.py`：

- `$AUTH_URL` — 认证页面地址（默认 `http://211.69.15.10:6060/portalReceiveAction.do`）
- `$ISP` — 运营商选项（默认 `本地账号`）
- `$API_URL` / `$FALLBACK` — 上游 Release 地址与固定版本回退链接
- `$CHANNELS` — 下载通道，直连优先、其次 `gh-proxy.com` 加速

---

## 许可证

安装器构建脚本以 MIT 许可证分发；本体程序版权与许可证归上游 `Misyra/Campus-Auth-rs` 所有。
