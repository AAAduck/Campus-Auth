# Campus-Auth 一键安装器

为校园网认证工具 [Campus-Auth-rs](https://github.com/Misyra/Campus-Auth-rs) 打包的**一键安装器构建项目**。
目标：让不懂技术的同学双击即可完成「下载 → 解压 → 写入配置 → 启动托盘程序」，全程无需打开 Web 控制台。

> 本项目只负责**构建安装器**，本体程序来自上游 `Misyra/Campus-Auth-rs` 的 GitHub Release。

---

## 目录结构

| 文件 | 作用 |
| --- | --- |
| `build_onekey.py` | 构建脚本：从模板 + 预设配置拼出独立安装器（`.ps1` 与多语言 `.bat`） |
| `onekey-template.ps1.tpl` | PowerShell 安装器模板：解析最新 Release（含 gh-proxy 加速回退）、下载解压、写入完整配置、启动托盘 |
| `preset-settings.json` | 抓取自真实运行的程序设置快照（`config_version: 8`），让重建不依赖已安装目录 |
| `campus-auth-default-fixed.json` | 固定的默认认证任务（通用校园网登录流程），使用 `{{USERNAME}}`/`{{PASSWORD}}`/`{{ISP}}`/`{{LOGIN_URL}}` 占位符 |
| `campus-auth-onekey-setup.ps1` | **生成产物** — 独立 PowerShell 安装器（UTF-8 BOM + CRLF） |
| `campus-auth-一键安装.bat` | **生成产物** — 双语言 polyglot（cmd 头 + PowerShell 体），双击即运行 |

> `.ps1` / `.bat` 两个产物由 `build_onekey.py` 生成，已在 `.gitignore` 中忽略；需要发布时重新构建即可。

---

## 给同学用（终端用户）

1. 拿到 `campus-auth-一键安装.bat`，**双击运行**（会弹一次 UAC 提权，点「是」即可启用完整的开机 + 唤醒自启）。
2. 按提示输入校园网**账号**与**密码**（也可通过环境变量静默安装，见下）。
3. 脚本自动下载最新版、解压到安装目录、写入配置并启动托盘程序。

静默 / 测试安装（无需交互）：

```powershell
$env:CA_INSTALLDIR  = 'D:\campus-auth'   # 可选，默认 D:\campus-auth
$env:CA_USERNAME    = '你的学号'
$env:CA_PASSWORD    = '你的密码'
$env:CA_ASSUMEYES   = '1'                # 跳过所有确认
$env:CA_NOLAUNCH    = '1'                # 下载配置后不自动启动
powershell -ExecutionPolicy Bypass -File campus-auth-onekey-setup.ps1
```

---

## 重新构建安装器（维护者）

需要 Python 3，且模板与配置源文件齐备：

```bash
python build_onekey.py
```

产物写入同目录：`campus-auth-onekey-setup.ps1` 与 `campus-auth-一键安装.bat`。

---

## 学校相关自定义

编辑 `onekey-template.ps1.tpl` 顶部的变量即可适配本校：

- `$AUTH_URL` — 本校认证页面地址（默认 `http://211.69.15.10:6060/portalReceiveAction.do`）
- `$ISP` — 运营商选项（默认 `本地账号`）
- `$API_URL` / `$FALLBACK` — 上游 Release 地址与固定版本回退链接
- `$CHANNELS` — 下载通道，直连优先、其次 `gh-proxy.com` 加速

账号/密码/登录地址的填充逻辑在 `campus-auth-default-fixed.json` 中，使用占位符，安装时由用户输入替换。

---

## 关于启动时的「SHA256 校验文件缺失」提示

程序内置更新器（`preset-settings.json` 中 `updater.check_on_startup: true`）会在启动时向 GitHub Release 拉取更新并校验 assets 的 SHA256。
若某次 Release 中**当前平台包未附带 `.sha256` 校验文件**，更新器会拒绝更新并提示：

> 更新检查（启动时）失败：发布中当前平台包缺失 SHA256 校验文件，已拒绝更新

这是**上游发布打包问题**，与本项目安装器无关，不影响已安装程序的正常使用。可选处理：

- 忽略该提示（程序仍正常认证）；
- 等上游补齐校验文件后自动恢复更新；
- 或临时关闭启动检查：将 `preset-settings.json` 的 `global.updater.check_on_startup` 改为 `false` 后重新构建安装器。

---

## 开机 / 唤醒自启动（安装器自动配置）

安装器会在安装时**自动配置自启动**，无需同学手动设置。

**问题背景**：程序自带的 Run 键（`HKCU\...\Run`）只在**登录 / 重启**时触发，**睡眠 / 锁屏唤醒后不会补拉起**——这正是「自启动不太灵」的根因。

**解决方案**：安装器额外注册一个 **计划任务**，同时挂两个触发器：

- `LogonTrigger` — 登录时启动（延迟 30 秒，避开开机繁忙期）；
- `SessionStateChangeTrigger (SessionUnlock)` — **从睡眠 / 锁屏唤醒解锁时**也启动。

两者配合 Run 键，覆盖「登录」与「唤醒」两种场景；任务设 `MultipleInstancesPolicy = IgnoreNew`，重复触发也只会拉起一个实例。

**权限要求**：
- 注册计划任务**需要管理员权限**。安装器**直接双击时会自动请求提权**——弹一次 UAC「是否允许此应用对你的设备进行更改」，点「是」即可启用完整功能，**无需手动右键**。
- 若在 UAC 弹窗点了「否」（或安装器在非管理员环境下被调用），会**按普通权限继续**：自动回退到 Run 键（仅登录自启，即程序自带机制），并提示「唤醒自启需管理员」。
- 静默模式（`CA_ASSUMEYES=1`）不弹 UAC，固定走普通权限（仅登录自启）；如需唤醒自启，请以管理员身份运行。

**可移植性**：任务的用户（`$env:USERDOMAIN\$env:USERNAME`）与程序路径（`$InstallDir`）均在安装时**按当前机器动态生成**，不写死任何机器 / 账户信息。同一份安装器发给任何人、装到任意目录都能正确注册自启。

> 如需手动管理该任务：任务名称固定为 `Campus-Auth Autostart`，可在「任务计划程序」中查看 / 禁用 / 删除。

---

## 许可证

安装器构建脚本以 MIT 许可证分发；本体程序版权与许可证归 `Misyra/Campus-Auth-rs` 上游所有。
