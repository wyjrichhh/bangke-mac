# 构建与安装蚌壳拼音

> 蚌壳拼音 macOS 版（Bangke Pinyin）的完整构建说明。
> 快捷路径见 [README.md](README.md)，本篇是逐项的详细选项。

## 前置依赖

安装 **Xcode 14.0** 以上，以便构建 Universal app。

安装 **cmake**，任选一种：

``` sh
brew install cmake          # Homebrew
port install cmake          # MacPorts
```

或从 https://cmake.org/download/ 下载安装。

## 取得代码

``` sh
git clone --recursive https://github.com/wyjrichhh/bangke-mac.git

cd bangke-mac
```

按需注册 Rime 插件（参数是 GitHub 仓库 slug 列表）：

``` sh
bash librime/install-plugins.sh \
    hchunhui/librime-lua \
    lotem/librime-octagram \
    rime/librime-predict \
    wyjrichhh/librime-ai-predict
```

`librime-ai-predict` 还需要预编译它依赖的 CTranslate2 静态库：

``` sh
( cd librime/plugins/ai-predict && make deps )
```

## 安装 Boost C++ 库

三种方式任选。

**方式一：从源码构建（可移植性最好）**

``` sh
export BUILD_UNIVERSAL=1

bash librime/install-boost.sh

export BOOST_ROOT="$(pwd)/librime/deps/boost-1.84.0"
```

`BUILD_UNIVERSAL` 告诉 `make` 按 universal 构架编译 Boost；只为本机构建则不必设。
构建完成后把 `BOOST_ROOT` 指向其顶层目录（如上）。

**方式二：Homebrew**

``` sh
brew install boost
export BOOST_ROOT="$(brew --prefix boost)"
```

> **注意**：这种方式产出的 `BangkePinyin.app` 不可移植——它链接到本机 Homebrew 的库。
> 详见 https://github.com/rime/librime/blob/master/README.mac.md#install-boost-c-libraries

**方式三：MacPorts**

``` sh
port install boost -no_static
```

## 构建

* 确认子模块已更新（用上面的 `--recursive` 克隆则已完成）：

``` sh
git submodule update --init --recursive
```

* 可用的环境变量：

``` sh
export BOOST_ROOT="path_to_boost"        # 必需
export DEV_ID="Your Apple ID name"       # 需要签名时填，可选
export BUILD_UNIVERSAL=1                 # 构建 universal binary
export PLUM_TAG=":preset"                # 或 ":extra"，按一组 plum 配方构建
export ARCHS='arm64 x86_64'              # 不填则只编译当前架构
export MACOSX_DEPLOYMENT_TARGET='13.0'   # 低于 13.0 未经验证
```

* 依赖齐备后构建：

``` sh
make
```

也可以把变量直接跟在 `make` 后面：

``` sh
# Universal macOS app
make ARCHS='arm64 x86_64' BUILD_UNIVERSAL=1
```

产物为 `build/Build/Products/Release/BangkePinyin.app`。

> 产物名、bundle id、连接名、配置文件名都来自 `Brand.xcconfig`（单一事实来源），
> 打包脚本经 `scripts/brand.sh` 读同一份值，不必也不应在脚本里硬编码产物名。

## 安装到本机

### 打包成 pkg

出分发包只有一条路，入口是 `package/build-pkg`（`make package` 是同一脚本的别名）：

``` sh
bash package/build-pkg                              # arm64 + 公证
ARCHS='arm64 x86_64' bash package/build-pkg         # Universal
SKIP_NOTARIZE=1 bash package/build-pkg              # 本机自测，不公证
SKIP_BUILD=1 bash package/build-pkg                 # 复用 build/ 下已有 .app
```

它会自己跑完「编译 librime + 插件 → 编译 .app → 注入模型与默认配置 → 签名 →
公证 → 验证 → 归档」，不必再单独记 `make librime` / `make release`。

**正式包只在 `main` 分支出。** 脚本会检查当前分支（可用 `RELEASE_BRANCH=` 改判据）：

| 当前分支 | 行为 |
|---|---|
| `main` | 正常签名 + 公证，产物 `BangkePinyin-<版本>-ai-predict-<arch>.pkg` |
| 其他 | 视为**测试包**：产物名带 `-test-<分支>` 后缀、默认跳过公证、首尾各打一次醒目提示 |

特性分支上打包是为了「合入 main 前本地验证」，所以默认不占公证时间/配额；
要验证完整公证安装流程，显式 `SKIP_NOTARIZE=0`。

签名与[公证](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)需要 Apple Developer ID，凭据先存一次：

``` sh
xcrun notarytool store-credentials 'your name/org'
```

不打算分发就加 `SKIP_NOTARIZE=1`。

> 上游的 `package/make_package` + `Distribution` + `sign_app` 已删除：它们与本
> 分发版要注入的 CT2 模型、默认配置、安装钩子不兼容，两条并存会让安装行为漂移。

### 直接安装

**可能需要 sudo；且不注销重登的话输入法未必工作正常，因此不太推荐直接安装。**

``` sh
make install
```

安装到 `/Library/Input Methods/BangkePinyin.app`，然后到
「系统设置 → 键盘 → 输入法」添加「蚌壳拼音」。

## 清理产物

重新来过之前，**务必先清掉上一次的构建产物**。

``` sh
make clean           # 清理蚌壳拼音自身的产物，不动依赖
make clean-deps      # 清理依赖：librime、插件、plum、Sparkle
make clean-package   # 清理打包产物
```
