# LangChain on OpenHarmony 6.0 — 开发记录

## 2026-03-10 第一次讨论：可行性分析

### 目标

把使用了 LangChain 的 Python 程序跑在 OpenHarmony 6.0（RK3568，aarch64）上。

### 核心问题

LangChain 是 Python 生态的产物，OH 上没有现成的 Python 运行时。

### 技术栈关系

```
Linux 内核（syscall）
    ↑
┌───────────┬───────────┐
│  glibc    │   musl    │  ← C标准库，二选一，二进制不兼容
│ (Ubuntu)  │ (OH/Alpine)│
└───────────┴───────────┘
    ↑
CPython（C写的Python解释器，链接上面某一个libc）
    ↑
LangChain（纯Python包，跑在CPython上面）
    ↑
Nuitka（可选：把Python代码编译成C，但还是依赖CPython运行时）
```

**关键概念：**
- **glibc vs musl**：都是 C 标准库（程序和 Linux 内核之间的翻译层），Ubuntu 用 glibc，OH 用 musl，**二进制不兼容**——glibc 编译的程序直接扔 OH 上跑不了
- **CPython**：Python 语言的官方实现，用 C 写的解释器（~50万行C代码）。`python3` 命令就是它编译出来的二进制
- **Nuitka**：Python→C 编译器，但生成的 C 代码仍依赖 CPython 运行时（libpython），不是真正脱离 Python

### OH 工具链现状（已确认）

| 组件 | 路径 | 状态 |
|------|------|------|
| 交叉编译器 | `prebuilts/ohos-sdk/linux/20/native/llvm/bin/aarch64-unknown-linux-ohos-clang` | ✅ Clang 15 |
| musl sysroot | `prebuilts/ohos-sdk/linux/20/native/sysroot/usr/lib/aarch64-linux-ohos/` | ✅ libc.a/so, crt*.o 全套 |
| musl libc（编译产物） | `out/sdk/obj/third_party/musl/usr/lib/aarch64-linux-ohos/` | ✅ libc.a, libc.so, libpthread.a 等 |
| C++ 运行时 | `prebuilts/clang/ohos/linux-x86_64/llvm/lib/aarch64-linux-ohos/libc++.a` | ✅ |
| 宿主机 Python | `prebuilts/python/linux-x86/3.11.4/` | ✅ x86 版，编译时用，不是目标平台的 |

**OH target triple**: `aarch64-unknown-linux-ohos`（不是标准 linux-gnu 也不是 linux-musl）

### 移植方案评估

| 方案 | 可行性 | 说明 |
|------|--------|------|
| 直接搬 Ubuntu 上的 python3 二进制 | ❌ | 链接 glibc，OH 上没有 |
| 用 OH Clang 交叉编译 CPython 源码 | ✅ 首选 | 静态链接 musl 可绕过动态链接器差异 |
| Nuitka 编译成二进制 | ⚠️ | 最终还是要 CPython 运行时，等于先走上一步 |
| Python 后端 + OH 前端调 HTTP | ✅ 备选 | LangChain 跑服务器，OH 只做 UI |
| 直接移植 LangChain.js 到 ArkTS | ❌ | 依赖链太深，npm 生态不可用 |

### 交叉编译 CPython 的关键点

1. 用 `aarch64-unknown-linux-ohos-clang` 编译 CPython 3.11 源码
2. `--with-sysroot` 指向 OH 的 musl sysroot
3. **静态链接 musl**（关键！绕过 OH 的动态链接器路径 `/system/lib64/ld-musl-aarch64.so.1` 和命名空间隔离 `ld-musl-namespace`）
4. 得到能在 OH 上裸跑的 `python3` 二进制
5. LangChain 是纯 Python 包，CPython 跑通后 pip install 即可

### OH 的 musl 特殊性

- 动态链接器路径：`/system/lib64/ld-musl-aarch64.so.1`（不是标准的 `/lib/`）
- 有 `ld-musl-namespace` 机制，动态库加载受限
- 内核有定制 syscall（安全沙箱相关）
- **静态链接可绕过以上所有问题**

### Python 库的真正难点

CPython 本体能编过（公司内网已有 OH 上的 python3.11）。**真正的坑是 Python 第三方库：**

**纯 Python 库 → 没问题**，.py 文件直接丢进去就跑，不挑 libc 不挑架构。LangChain 核心大部分是纯 Python。

**C/Rust 扩展库 → 每个都要交叉编译**，这才是工程量：

| 库 | 底层语言 | 作用 | LangChain 必须？ |
|---|---|---|---|
| **pydantic-core** | Rust | 数据校验，LangChain 骨架 | ✅ 必须 |
| **cryptography** | Rust + C (OpenSSL) | HTTPS/TLS | ✅ 必须（网络调用） |
| **aiohttp** (multidict/yarl/frozenlist) | C | 异步 HTTP | ⚠️ 可用 httpx 替代 |
| **numpy** | C/Fortran | 数值计算 | ⚠️ 看用不用向量 |
| **orjson** | Rust | 快速 JSON | ❌ 可 fallback 标准库 json |
| **tiktoken** | Rust | token 计数 | ⚠️ 看用不用 OpenAI |
| **SQLAlchemy** (greenlet) | C | 数据库 | ⚠️ 看需求 |

**最头疼的两个：pydantic-core（Rust）和 cryptography（Rust+OpenSSL）**——必须用 OH toolchain 交叉编译 Rust 到 `aarch64-unknown-linux-ohos`。

**依赖链地狱：**
```
pip install langchain
    ↓ 拉几十个依赖
    ↓ 纯 Python 的 → ✅ 直接用
    ↓ 有 C/Rust 扩展的 → 💀 每个都要交叉编译
    ↓ 依赖 OpenSSL 的 → 💀💀 还得先编译 OpenSSL for musl-ohos
```

### 最小验证路径

先跑最小集，别一上来全家桶：

1. ~~CPython 能跑~~（公司内网已有，跳过）
2. `import json, urllib.request` —— 纯标准库，零依赖
3. `import ssl` —— 验证 OpenSSL 有没有
4. `pip install pydantic` —— 验证 Rust 交叉编译链
5. 以上都通了，`pip install langchain-core` 基本就能过

### 下一步

- [x] CPython for OH（公司内网已有）
- [ ] 确认 OH 上的 python3 有没有 ssl 模块（即 OpenSSL 编过没有）
- [ ] 交叉编译 pydantic-core（Rust → aarch64-unknown-linux-ohos）
- [ ] 交叉编译 cryptography（Rust + OpenSSL → aarch64-unknown-linux-ohos）
- [ ] pip install langchain-core 最小集验证
- [ ] 跑 LangChain hello world（调一次 LLM API）

---

*OH 工程路径: `/home/lmxxf/oh6/source`*
