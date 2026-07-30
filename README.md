# 钉钉虚拟定位注入插件（TrollStore 版）v2.0

基于 Objective-C runtime method swizzling 实现的定位欺骗 dylib，用于注入钉钉 IPA。
**带悬浮配置按钮 + 剪贴板快捷配置**，可在手机上实时切换坐标。

## ⚠️ 免责声明

**本代码仅供技术研究和学习交流使用。** 使用本插件绕过公司考勤系统可能违反公司规章制度、钉钉用户服务协议及相关法律法规。后果自负。

---

## 🚀 零 Mac 编译方案：用 GitHub Actions 在线编译

**你没有 Mac 也没关系**，项目已配置好 GitHub Actions 自动编译。你只需要：

### 第一步：注册 GitHub 并创建仓库

1. 打开 [github.com](https://github.com) 注册账号
2. 点右上角 `+` → **New repository**
3. 仓库名随意（如 `dingtalk-location-hook`），选 **Public**，点 **Create repository**

### 第二步：上传代码

打开电脑终端（cmd / PowerShell / Git Bash），逐条执行：

```bash
# 进入项目目录
cd D:/Work/杂文件/会话/dingtalk-location-hook

# 初始化 git
git init
git add .
git commit -m "首次提交：钉钉虚拟定位插件"

# 关联你的 GitHub 仓库（替换 YOUR_USERNAME 和 YOUR_REPO）
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO.git

# 推送到 GitHub
git push -u origin main
```

> 💡 如果 push 要输密码，建议用 **GitHub Token**（Settings → Developer settings → Personal access tokens）

### 第三步：自动编译

1. 打开你的 GitHub 仓库页面
2. 点顶部 **Actions** 标签
3. 你会看到正在运行的 `Build LocationHook.dylib` 工作流
4. 等它跑完（约 2-3 分钟），点进去
5. 在最下方 **Artifacts** 处下载 `LocationHook.dylib`

> 以后每次 `git push` 都会自动重新编译，你也可以在 Actions 页面点 **Run workflow** 手动触发。

### 第四步：注入钉钉 IPA

下载到 `LocationHook.dylib` 后，在电脑上继续：

```bash
# 解压钉钉 IPA
unzip DingTalk_6.x.x.ipa -d Payload

# 复制 dylib
cp LocationHook.dylib Payload/DingTalk.app/

# 注入（需要有 insert_dylib）
# Windows 版 insert_dylib 下载：
# https://github.com/Tyilo/insert_dylib/releases
insert_dylib @executable_path/LocationHook.dylib \
    Payload/DingTalk.app/DingTalk --inplace --all-yes

# 重新打包
cd Payload
zip -r ../DingTalk_Hooked.ipa DingTalk.app/
cd ..
```

打好包后用 TrollStore 安装即可。

---

## 🎯 推荐钉钉版本

| 版本 | 完整性校验 | 定位检测 | 登录兼容 | 推荐度 |
|:---|:---:|:---:|:---:|:---:|
| **6.2.x ~ 6.3.x** | ✅ 较弱 | ✅ 较弱 | ✅ 正常 | ⭐⭐⭐⭐⭐ **强烈推荐** |
| 6.5.x ~ 6.9.x | ⚠️ 中等 | ⚠️ 中等 | ✅ 正常 | ⭐⭐⭐ |
| 7.0.x ~ 7.2.x | ❌ 严格 | ❌ 严格 | ✅ 正常 | ⭐⭐ |
| 7.5.x+ | ❌ 非常严格 | ❌ 非常严格 | ✅ 正常 | ⭐ |
| 5.x 及以下 | ✅ 基本无 | ✅ 基本无 | ❌ **可能无法登录** | ⭐ |

---

## 📱 功能特性

- ✅ **自动拦截定位** — 透明替换 CLLocationManager 回调
- ✅ **清除模拟标记** — 绕过 isFromMockProvider 等 8 种检测
- ✅ **悬浮配置按钮** — 在钉钉界面显示 `📍` 浮动按钮
- ✅ **一键切换预设坐标** — 内置 5 个常用地点预设
- ✅ **剪贴板快捷设置** — 复制 `loc:39.9042,116.4074` 即可切换
- ✅ **坐标输入器** — 通过弹窗手动输入任意坐标
- ✅ **启用/禁用开关** — 随时开关虚拟定位

---

## 🎮 使用方法

安装注入版钉钉后，会看到一个 `📍` 悬浮按钮：

| 操作 | 效果 |
|:---|:---|
| **点击** | 弹出配置菜单 |
| **拖动** | 改变按钮位置 |
| **菜单 → 预设坐标** | 一键切换到预设位置 |
| **菜单 → 暂停/启用** | 开关虚拟定位（绿色/红色指示灯） |
| **菜单 → 输入自定义坐标** | 手动输入纬度,经度 |
| **菜单 → 隐藏此按钮** | 隐藏浮动按钮 |

### 剪贴板配置

复制到剪贴板即可自动识别：

```
loc:39.9042,116.4074
loc:31.2304,121.4737    （上海）
```

---

## 📋 项目文件结构

```
dingtalk-location-hook/
├── .github/workflows/
│   └── build.yml          # GitHub Actions 自动编译配置
├── LocationHook.m          # 主入口 + CLLocationManager Hook
├── ConfigManager.h/.m      # 配置管理 + 预设坐标 + 剪贴板解析
├── FloatingMenu.m          # 浮动按钮 UI + 菜单 + Toast
├── test_inject.m           # 极简测试 dylib（只打日志不 hook）
├── Makefile                # Mac 本地编译脚本（有 Mac 时用）
└── README.md               # 本文件
```

---

## 🔍 查看日志

```log
[LocationHook] ========================================
[LocationHook] 钉钉虚拟定位插件 v2.0 (带配置界面)
[LocationHook] 当前坐标: 39.9042, 116.4074
[LocationHook] 状态: 已启用
[LocationHook] ========================================
[LocationHook] 定位 Hook 注册完成 ✓
[LocationHook] 插件加载完成 ✓
[LocationHook] 📍 拦截定位 → 注入: 39.9042, 116.4074
```

---

## ❓ 常见问题

**Q: 钉钉闪退 / 提示"应用被篡改"**
A: 换 **钉钉 6.2.x ~ 6.3.x** 版本，完整性校验较弱

**Q: 定位没变但插件已加载**
A: 检查定位权限 → 查看日志确认 `📍 拦截定位` 出现

**Q: 浮动按钮没显示**
A: 杀掉钉钉重开；或在 `ConfigManager.m` 中确认 `showFloatingButton = YES`

**Q: insert_dylib 在 Windows 上怎么用？**
A: 下载 Windows 版：[Tyilo/insert_dylib](https://github.com/Tyilo/insert_dylib) 或使用 WSL
