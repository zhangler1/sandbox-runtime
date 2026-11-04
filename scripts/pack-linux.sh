#!/usr/bin/env bash
# =============================================================================
# pack-linux.sh —— 把 sandbox-runtime 打成一个可离线投喂的 .tar.gz
#
# -----------------------------------------------------------------------------
# 用法（不写任何绝对路径，在谁的机器上都一样）
#
#   A. Windows：先 cd 到本项目目录（sandbox-runtime\），然后
#        wsl.exe bash scripts/pack-linux.sh                         # 日常打包，约 1.5s
#        wsl.exe bash -lc "CLEAN=1 bash scripts/pack-linux.sh"      # 删构建目录重来，约 7.5s
#        wsl.exe bash -lc "TEST=1 bash scripts/pack-linux.sh"       # 跑 bun test，约 4.6 分钟
#        wsl.exe bash -lc "SKIP_BUILD=1 bash scripts/pack-linux.sh" # 不编译，只重打 tar，约 1s
#      Windows 侧的当前目录会被 WSL 自动翻译成 /mnt/...，所以不需要写路径。
#
#   B. 不在项目目录：用 wsl --cd 指定，或先 cd 进去
#        wsl.exe --cd "C:\path\to\sandbox-runtime" bash scripts/pack-linux.sh
#        wsl.exe bash -lc "cd /mnt/c/path/to/sandbox-runtime && bash scripts/pack-linux.sh"
#
#   C. 已经在 WSL 里（Ubuntu 终端）
#        cd /path/to/sandbox-runtime && bash scripts/pack-linux.sh
#        CLEAN=1 bash scripts/pack-linux.sh
#
#   本脚本不接受位置参数，全部用环境变量控制；加 -h 可看本说明。
# -----------------------------------------------------------------------------
#
# 产物（归档顶层就是 node_modules/，解到 <app>/resources/sandbox/ 即落位）：
#   dist-out/sandbox-runtime/bocomwork-srt-<ver>-linux-<arch>.tar.gz
#     node_modules/
#       ├── @anthropic-ai/sandbox-runtime/
#       │     ├── package.json
#       │     ├── dist/
#       │     └── vendor/
#       │         ├── seccomp/<arch>/apply-seccomp   # static ELF，必须保留 +x
#       │         └── java-proxy-agent/srt-proxy-agent.jar
#       └── zod/ commander/ node-forge/ @pondwader/socks5-server/   # dist 的运行时依赖
#   dist-out/sandbox-runtime/bocomwork-srt-<ver>-linux-<arch>.tar.gz.sha256
#   dist-out/sandbox-runtime/bocomwork-srt-<ver>-linux-<arch>.json
#
# 性能设计（实测：首次 7.4s，重跑 1.5s，只重打包 1s）：
#   - 只装生产依赖（npm ci --omit=dev，0.9s），不装 eslint/prettier/fast-check 等 300+ 个 devDep（33s）
#   - typescript / @types 从共享工具链缓存借用（首次装一次，之后软链）
#   - 构建目录 ~/build/sandbox-runtime 跨次复用（增量 rsync），已是原生 ext4
#   - seccomp/jar 按源文件时间戳跳过；tsc 用 --incremental
#   - 测试默认不跑（bun test 全套 4.6 分钟）；需要时 TEST=1
#
# 为什么必须在 WSL 原生 ext4 里构建和打包：
#   /mnt/d 是 9p，不保留也不区分权限位，apply-seccomp 的 +x 会丢，沙箱会静默降级。
#
# 前置（WSL 内一次性）：
#   sudo apt-get install -y gcc libseccomp-dev openjdk-17-jdk-headless rsync file
#   node >= 22.12  +  bun
#
# 可选环境变量：
#   OUT_DIR=            产物根目录（默认 <repo>/dist-out）
#   OUT_SUB=            产物子目录（默认 sandbox-runtime）
#   WORK_DIR=           构建目录（默认 $HOME/build/sandbox-runtime，禁止 /mnt/*）
#   CACHE_DIR=          工具链缓存（默认 $HOME/.cache/bocomwork-pack）
#   ARCH=               x64 | arm64（默认按 uname -m）
#   SKIP_BUILD=1        不编译，只用构建目录里已有的 dist/vendor 重新打包
#   CLEAN=1             删掉构建目录整体重来（排障用）
#   TEST=1              跑 bun test（默认不跑，全套约 4.6 分钟）
#   STRICT_TEST=1       配合 TEST=1：测试有失败就中止
#   SOURCE_DATE_EPOCH=  固定 mtime（可复现构建）
# =============================================================================
set -euo pipefail

# --- 环境引导 ---------------------------------------------------------------
# 非交互 shell（wsl bash -lc）里 nvm / bun 常常不在 PATH；顺带拒绝 Windows 互操作的
# node/npm（/mnt/c、/mnt/d 下的 .exe），它们跑不了 WSL 原生构建。
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export PATH="$BUN_INSTALL/bin:$PATH"
if [[ -f "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
  . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1 || true
  nvm use --silent default >/dev/null 2>&1 || nvm use --silent 'lts/*' >/dev/null 2>&1 || true
fi

win_bin() {
  local p
  p="$(command -v "$1" 2>/dev/null || true)"
  [[ -n "$p" ]] || return 1
  case "$p" in /mnt/[a-z]/*|*.exe|*.EXE) return 0 ;; *) return 1 ;; esac
}

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_OUT="${OUT_DIR:-$(cd "$SRC/.." && pwd)/dist-out}"
OUT_SUB="${OUT_SUB:-sandbox-runtime}"
ART_DIR="$REPO_OUT/$OUT_SUB"
WORK="${WORK_DIR:-$HOME/build/sandbox-runtime}"
CACHE="${CACHE_DIR:-$HOME/.cache/bocomwork-pack}"
case "$(uname -m)" in
  x86_64|amd64)  DEFAULT_ARCH=x64 ;;
  aarch64|arm64) DEFAULT_ARCH=arm64 ;;
  *)             DEFAULT_ARCH=unknown ;;
esac
ARCH="${ARCH:-$DEFAULT_ARCH}"
PKG_NAME="@anthropic-ai/sandbox-runtime"

die() { echo "[pack-srt] 错误: $*" >&2; exit 1; }
info() { echo "[pack-srt] $*"; }

usage() { awk 'NR>1 && /^set -euo/ {exit} NR>1' "${BASH_SOURCE[0]}"; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die "未知参数: $1（本脚本不接受位置参数，用环境变量控制；-h 看说明）" ;;
esac
need() {
  local c="$1" hint="${2:-}"
  command -v "$c" >/dev/null 2>&1 || die "缺少命令 $c（$hint）"
  if win_bin "$c"; then
    die "$c 解析到 Windows 侧可执行文件（$(command -v "$c")）；请在 WSL 里装 Linux 版：$hint"
  fi
}

# 计时（每个阶段打印耗时，方便一眼看出谁慢）
PHASE_T0=0
phase() { PHASE_T0=$(date +%s%N); info ">> $*"; }
phase_end() {
  info "   -> $1: $(( ($(date +%s%N) - PHASE_T0) / 1000000 ))ms"
}

case "$ARCH" in
  x64|arm64) ;;
  *) die "ARCH 只支持 x64 / arm64，当前: $ARCH" ;;
esac
case "$WORK" in
  /mnt/*) die "WORK_DIR=$WORK 在 /mnt（9p）上，权限位不保留。删掉 WORK_DIR= 用默认的 \$HOME/build/..." ;;
esac

need node "node >= 22.12"
need bun  "curl -fsSL https://bun.sh/install | bash"
need gcc  "sudo apt-get install -y gcc libseccomp-dev"
need javac "sudo apt-get install -y openjdk-17-jdk-headless"
need rsync "sudo apt-get install -y rsync"
need tar
command -v file >/dev/null 2>&1 || info "警告: 没有 file，跳过 static 链接检查"

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 22 ]] || die "node 版本过低（$NODE_MAJOR），package.json engines 要求 >=22.12"

VER="$(node -p "JSON.parse(require('fs').readFileSync('$SRC/package.json','utf8')).version")"
[[ -n "$VER" ]] || die "无法从 $SRC/package.json 读出 version"
info "srt $VER / arch=$ARCH / node $(node -v) / bun $(bun -v)"

T0=$(date +%s%N)

[[ "${CLEAN:-0}" == "1" ]] && { info "CLEAN=1 -> 删除 $WORK"; rm -rf "$WORK"; }
mkdir -p "$WORK" "$CACHE" "$ART_DIR"

# ---------------------------------------------------------------------------
# 1) 增量同步源码（首次 1.9s，之后 <0.2s）
# ---------------------------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  phase "同步源码 -> $WORK"
  EXCLUDES=(--exclude node_modules --exclude dist --exclude .git
            --exclude .cache --exclude .stage
            --exclude 'vendor/srt-win' --exclude 'vendor/srt-win-src'
            --exclude 'vendor/seccomp/x64' --exclude 'vendor/seccomp/arm64'
            --exclude 'vendor/java-proxy-agent/*.jar'
            --exclude .github --exclude docs)
  [[ "${TEST:-0}" == "1" ]] || EXCLUDES+=(--exclude test)
  rsync -a --delete "${EXCLUDES[@]}" "$SRC"/ "$WORK"/
  phase_end "rsync"

  cd "$WORK"

  # -------------------------------------------------------------------------
  # 2) 依赖：只装生产依赖（0.9s），编译工具链走共享缓存
  # -------------------------------------------------------------------------
  LOCK_SUM="$(sha256sum package-lock.json | awk '{print $1}')"
  if [[ "$(cat node_modules/.pack-lock 2>/dev/null || true)" != "$LOCK_SUM" ]]; then
    phase "安装生产依赖（npm ci --omit=dev）"
    rm -rf node_modules
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund --prefer-offline >/dev/null 2>&1 \
      || die "npm ci 失败（网络/镜像？可先手动跑一次 npm ci --omit=dev 看报错）"
    printf '%s' "$LOCK_SUM" > node_modules/.pack-lock
    phase_end "npm ci"
  else
    info ">> 生产依赖已是最新，跳过 npm ci"
  fi

  # 工具链缓存：typescript + @types（devDep，但编译正好需要它们）
  TC_KEY="$(printf '%s|%s|%s|%s' \
    "$(node -p "require('./package.json').devDependencies.typescript")" \
    "$(node -p "require('./package.json').devDependencies['@types/node']")" \
    "$(node -p "require('./package.json').devDependencies['@types/node-forge']")" \
    "$(node -p "require('./package.json').devDependencies['@types/bun']")" \
    | sha256sum | cut -c1-12)"
  TC="$CACHE/toolchain-$TC_KEY"
  if [[ ! -x "$TC/node_modules/typescript/bin/tsc" ]]; then
    phase "准备编译工具链（一次性，缓存到 $TC）"
    mkdir -p "$TC"
    npm i --prefix "$TC" --no-audit --no-fund --ignore-scripts --prefer-offline \
      "typescript@$(node -p "require('./package.json').devDependencies.typescript")" \
      "@types/node@$(node -p "require('./package.json').devDependencies['@types/node']")" \
      "@types/node-forge@$(node -p "require('./package.json').devDependencies['@types/node-forge']")" \
      "@types/bun@$(node -p "require('./package.json').devDependencies['@types/bun']")" \
      >/dev/null 2>&1 || die "工具链安装失败（typescript/@types）"
    phase_end "toolchain"
  else
    info ">> 编译工具链命中缓存"
  fi
  mkdir -p node_modules/@types
  ln -sfn "$TC/node_modules/typescript"           node_modules/typescript
  ln -sfn "$TC/node_modules/@types/node"          node_modules/@types/node
  ln -sfn "$TC/node_modules/@types/node-forge"    node_modules/@types/node-forge
  ln -sfn "$TC/node_modules/@types/bun"           node_modules/@types/bun

  # -------------------------------------------------------------------------
  # 3) 编译：seccomp / java agent 按时间戳跳过，tsc 走 incremental
  # -------------------------------------------------------------------------
  SECCOMP="vendor/seccomp/$ARCH/apply-seccomp"
  JAR="vendor/java-proxy-agent/srt-proxy-agent.jar"

  if [[ -x "$SECCOMP" ]] && find vendor/seccomp-src vendor/seccomp/build.ts vendor/build-common.ts -type f -newer "$SECCOMP" -print -quit | grep -q .; then
    rm -f "$SECCOMP"
  fi
  if [[ -x "$SECCOMP" ]]; then
    info ">> apply-seccomp 已是最新，跳过编译"
  else
    phase "build:seccomp（gcc + libseccomp，静态）"
    bun vendor/seccomp/build.ts
    touch "$SECCOMP"          # 让“时间戳跳过”对下一次真正生效
    phase_end "seccomp"
  fi

  if [[ -f "$JAR" ]] && ! find vendor/java-proxy-agent-src vendor/java-proxy-agent/build.ts vendor/build-common.ts -type f -newer "$JAR" -print -quit | grep -q .; then
    info ">> srt-proxy-agent.jar 已是最新，跳过编译"
  else
    phase "build:java-agent（javac）"
    bun vendor/java-proxy-agent/build.ts
    touch "$JAR"              # 同上：避免每次都重编
    phase_end "javac"
  fi

  phase "tsc（incremental）"
  mkdir -p "$WORK/.cache"
  node "$TC/node_modules/typescript/bin/tsc" -p tsconfig.json \
    --incremental --tsBuildInfoFile "$WORK/.cache/tsconfig.tsbuildinfo"
  phase_end "tsc"
else
  info "SKIP_BUILD=1：复用 $WORK 里已有的 dist/vendor"
  [[ -f "$WORK/dist/index.js" ]] || die "SKIP_BUILD=1 但 $WORK/dist 不存在，先完整跑一次"
  cd "$WORK"
fi

# ---------------------------------------------------------------------------
# 4) 校验
# ---------------------------------------------------------------------------
DIST="$WORK/dist"
SECCOMP="$WORK/vendor/seccomp/$ARCH/apply-seccomp"
JAR="$WORK/vendor/java-proxy-agent/srt-proxy-agent.jar"

[[ -f "$DIST/index.js" ]] || die "缺少 dist/index.js（tsc 没跑成）"
[[ -x "$SECCOMP" ]]       || die "缺少可执行文件 $SECCOMP"
[[ -s "$JAR" ]]           || die "缺少 $JAR"

if command -v file >/dev/null 2>&1; then
  file "$SECCOMP" | grep -q 'statically linked' \
    || info "警告: $SECCOMP 不是静态链接，目标机可能需要 libseccomp.so.2"
fi

if [[ "${TEST:-0}" == "1" ]]; then
  phase "bun test（全套，约 4.6 分钟）"
  if ! bun test; then
    [[ "${STRICT_TEST:-0}" == "1" ]] && die "bun test 未通过（STRICT_TEST=1）"
    info "警告: bun test 有失败（常见环境因素：LANG 非 UTF-8 / 继承 HTTP(S)_PROXY / 无 bwrap / 无 sshd）"
  fi
  phase_end "bun test"
fi

# ---------------------------------------------------------------------------
# 5) 摆成 node_modules 布局并打包
# ---------------------------------------------------------------------------
phase "组装与打包"
STAGE="$WORK/.stage"
rm -rf "$STAGE"
PKG_DIR="$STAGE/node_modules/$PKG_NAME"
mkdir -p "$PKG_DIR/vendor/seccomp" "$PKG_DIR/vendor/java-proxy-agent"

cp -a "$DIST" "$PKG_DIR/dist"
cp -a "$WORK/vendor/seccomp/$ARCH" "$PKG_DIR/vendor/seccomp/$ARCH"
cp -a "$JAR" "$PKG_DIR/vendor/java-proxy-agent/srt-proxy-agent.jar"
cp -a "$WORK/package.json" "$PKG_DIR/package.json"
[[ -f "$WORK/LICENSE" ]] && cp -a "$WORK/LICENSE" "$PKG_DIR/LICENSE" || true

# 运行时依赖：npm ls 是唯一可靠来源（含传递依赖）；跳过工具链软链
DEP_COUNT=0
while IFS= read -r dep; do
  [[ -L "$dep" ]] && continue
  rel="${dep#$WORK/}"
  case "$rel" in node_modules/*) ;; *) continue ;; esac
  [[ "$rel" == "node_modules/$PKG_NAME" ]] && continue
  case "$rel" in node_modules/@types/*|node_modules/typescript) continue ;; esac
  mkdir -p "$STAGE/$(dirname "$rel")"
  rm -rf "$STAGE/$rel"
  cp -a "$dep" "$STAGE/$rel"
  DEP_COUNT=$((DEP_COUNT + 1))
done < <(cd "$WORK" && npm ls --omit=dev --all --parseable 2>/dev/null | tail -n +2 || true)
[[ "$DEP_COUNT" -gt 0 ]] || die "没有收集到运行时依赖（npm ls 失败？）"

find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
chmod 755 "$PKG_DIR/vendor/seccomp/$ARCH/apply-seccomp"

NAME="bocomwork-srt-${VER}-linux-${ARCH}"
OUT="$ART_DIR/$NAME.tar.gz"
rm -f "$OUT" "$OUT.sha256" "$ART_DIR/$NAME.json"

MTIME_FLAG=()
[[ -n "${SOURCE_DATE_EPOCH:-}" ]] && MTIME_FLAG=(--mtime="@$SOURCE_DATE_EPOCH")

( cd "$STAGE" && tar --sort=name --owner=0 --group=0 --numeric-owner \
    "${MTIME_FLAG[@]+"${MTIME_FLAG[@]}"}" -czf "$OUT" node_modules )
phase_end "组装+tar"

# ---------------------------------------------------------------------------
# 6) 归档自检
# ---------------------------------------------------------------------------
LINE="$(tar -tvzf "$OUT" | grep "node_modules/$PKG_NAME/vendor/seccomp/$ARCH/apply-seccomp" || true)"
[[ -n "$LINE" ]] || die "归档里没有 apply-seccomp"
case "$LINE" in
  -rwx*) : ;;
  *) die "apply-seccomp 执行位丢失（$LINE）；不要把 WORK_DIR 指到 /mnt/*" ;;
esac

FILES="$(tar -tzf "$OUT" | grep -vc '/$' || true)"
SIZE="$(du -h "$OUT" | awk '{print $1}')"
SHA="$(sha256sum "$OUT" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$(basename "$OUT")" > "$OUT.sha256"

cat > "$ART_DIR/$NAME.json" <<EOF
{
  "package": "$PKG_NAME",
  "version": "$VER",
  "platform": "linux",
  "arch": "$ARCH",
  "deps": $DEP_COUNT,
  "files": $FILES,
  "bytes": $(stat -c%s "$OUT"),
  "sha256": "$SHA",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

info "产物: $ART_DIR/"
info "完成: $OUT（$SIZE，$FILES 个文件，依赖 $DEP_COUNT 个）总耗时 $(( ($(date +%s%N) - T0) / 1000000 ))ms"
cat <<EOF

接入 deb 流水线（build-desktop-tauri-uos.sh）：

  SBX="\$ROOT/out/linux/sandbox"
  mkdir -p "\$SBX"
  tar -xzf $OUT -C "\$SBX"          # -> \$SBX/node_modules/@anthropic-ai/sandbox-runtime
  test -x "\$SBX/node_modules/$PKG_NAME/vendor/seccomp/$ARCH/apply-seccomp"

  # assemble：cp -R "\$SBX" "\$APP/resources/sandbox"
  # package：REQUIRED 里加
  #   resources/sandbox/node_modules/$PKG_NAME/vendor/seccomp/$ARCH/apply-seccomp
EOF
