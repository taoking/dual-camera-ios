#!/bin/bash
#
# 双摄相机 —— 开发签名包重新安装
#
# 个人开发签名约 7 天到期，到期后应用图标点不开。此脚本用当前源码重新构建、
# 签名、覆盖安装并启动，不需要删除旧应用，也不需要重新配置任何东西。
#
#   ./scripts/install-to-device.sh
#
# Team ID 与 Bundle Identifier 首次运行时自动探测并保存到 scripts/.device-config
# （已在 .gitignore 中，不会进仓库）。要覆盖可用环境变量：
#
#   DUAL_CAMERA_TEAM=XXXXXXXXXX DUAL_CAMERA_BUNDLE_ID=com.example.app ./scripts/install-to-device.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/scripts/.device-config"
BUILD_DIR="${DUAL_CAMERA_BUILD_DIR:-/tmp/dualcamera-install}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$1"; }
die()  { printf '\033[31m\n✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- 1. 工具链
bold "1/6  选择 Xcode"

# 设备系统可能比稳定版 Xcode 的 SDK 新，优先选 SDK 版本最高的那个。
pick_xcode() {
  local best_dir="" best_ver=0 app dir ver
  for app in "$HOME/Downloads/Xcode-beta.app" /Applications/Xcode-beta.app /Applications/Xcode*.app; do
    [ -d "$app" ] || continue
    dir="$app/Contents/Developer"
    [ -d "$dir" ] || continue
    # 取该 Xcode 支持的最高 iOS SDK 主版本号
    ver=$(ls "$dir/Platforms/iPhoneOS.platform/Developer/SDKs" 2>/dev/null \
          | sed -n 's/^iPhoneOS\([0-9][0-9]*\)\..*\.sdk$/\1/p' | sort -n | tail -1)
    [ -n "$ver" ] || continue
    if [ "$ver" -gt "$best_ver" ]; then best_ver=$ver; best_dir=$dir; fi
  done
  echo "$best_dir"
}

DEVELOPER_DIR="${DEVELOPER_DIR:-$(pick_xcode)}"
[ -n "$DEVELOPER_DIR" ] || die "没有找到带 iOS SDK 的 Xcode。请安装 Xcode 后重试。"
export DEVELOPER_DIR
ok "$("$DEVELOPER_DIR/usr/bin/xcodebuild" -version | head -1)  ($DEVELOPER_DIR)"

# ---------------------------------------------------------------- 2. 设备
bold "2/6  查找已连接的 iPhone"

DEVICE_JSON="$(mktemp)"
trap 'rm -f "$DEVICE_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1 \
  || die "无法列出设备。确认已安装 Xcode 命令行工具。"

DEVICE_FIELDS="$(mktemp)"
python3 - "$DEVICE_JSON" >"$DEVICE_FIELDS" <<'PYEOF'
import json, sys

devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hardware = d.get("hardwareProperties", {})
    props = d.get("deviceProperties", {})
    connection = d.get("connectionProperties", {})
    # reality 区分真机与模拟器；模拟器同样是 iOS 平台，只按 platform 过滤会选错。
    if hardware.get("reality") != "physical":
        continue
    if connection.get("pairingState") != "paired":
        continue
    if not props.get("osVersionNumber"):
        continue
    print("DEVICE_ID=%s" % d["identifier"])
    print("DEVICE_UDID=%s" % hardware["udid"])
    print("DEVICE_NAME=%s" % props.get("name", "iPhone"))
    print("DEVICE_OS=%s" % props["osVersionNumber"])
    break
PYEOF

DEVICE_ID=""; DEVICE_UDID=""; DEVICE_NAME=""; DEVICE_OS=""
while IFS='=' read -r field value; do
  case "$field" in
    DEVICE_ID)   DEVICE_ID="$value" ;;
    DEVICE_UDID) DEVICE_UDID="$value" ;;
    DEVICE_NAME) DEVICE_NAME="$value" ;;
    DEVICE_OS)   DEVICE_OS="$value" ;;
  esac
done <"$DEVICE_FIELDS"
rm -f "$DEVICE_FIELDS"

[ -n "${DEVICE_ID:-}" ] || die "没有找到已配对的 iPhone。
  · 用数据线连接手机并保持解锁
  · 首次连接时在手机上选择「信任此电脑」
  · 确认「设置 → 隐私与安全性 → 开发者模式」已开启"
ok "$DEVICE_NAME （iOS ${DEVICE_OS}）"

# ---------------------------------------------------------------- 3. 签名配置
bold "3/6  读取签名配置"

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

TEAM="${DUAL_CAMERA_TEAM:-${SAVED_TEAM:-}}"
BUNDLE_ID="${DUAL_CAMERA_BUNDLE_ID:-${SAVED_BUNDLE_ID:-}}"

if [ -z "$TEAM" ]; then
  # 从本机已有的描述文件里取 Team ID
  TEAM=$(for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; do
    [ -e "$p" ] || continue
    security cms -D -i "$p" 2>/dev/null \
      | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null
  done | sort -u | head -1)
fi
[ -n "$TEAM" ] || die "无法自动探测 Team ID。
  请先用 Xcode 打开 DualCamera.xcodeproj，在 Signing & Capabilities 里
  登录 Apple ID 并选择 Team，运行一次后再执行本脚本；
  或直接指定：DUAL_CAMERA_TEAM=<你的 Team ID> $0"

if [ -z "$BUNDLE_ID" ]; then
  # 从设备上已安装的同名应用反查，避免猜错前缀后装成第二个应用而不是覆盖。
  BUNDLE_ID=$(xcrun devicectl device info apps --device "$DEVICE_ID" 2>/dev/null \
    | awk '$1 == "双摄相机" { print $2; exit }')
fi
BUNDLE_ID="${BUNDLE_ID:-com.$(whoami).dualcamera}"

cat > "$CONFIG_FILE" <<CONF
# 本机专属，不进仓库。删除本文件可重新探测。
SAVED_TEAM="$TEAM"
SAVED_BUNDLE_ID="$BUNDLE_ID"
CONF
ok "Team ${TEAM:0:2}****${TEAM: -2}   Bundle $BUNDLE_ID"

# ---------------------------------------------------------------- 4. 构建
bold "4/6  构建并签名（首次约 1 分钟）"

BUILD_LOG=$(mktemp)
if ! xcodebuild -project "$REPO_ROOT/DualCamera.xcodeproj" -scheme DualCamera \
      -configuration Debug \
      -destination "platform=iOS,id=$DEVICE_UDID" \
      -derivedDataPath "$BUILD_DIR" \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$TEAM" \
      PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
      CODE_SIGN_STYLE=Automatic \
      'CODE_SIGN_IDENTITY=Apple Development' \
      build >"$BUILD_LOG" 2>&1; then
  echo
  grep -E "error:|No Account|No profiles|Signing for" "$BUILD_LOG" | sort -u | head -10
  echo
  warn "完整日志：$BUILD_LOG"
  die "构建失败。若提示 No Account／No profiles，请先在 Xcode → Settings → Accounts 登录 Apple ID。"
fi
rm -f "$BUILD_LOG"
APP="$BUILD_DIR/Build/Products/Debug-iphoneos/双摄相机.app"
[ -d "$APP" ] || die "构建成功但没找到产物：$APP"
codesign --verify --deep --strict "$APP" 2>/dev/null || die "签名校验失败。"
ok "已签名"

# ---------------------------------------------------------------- 5. 安装
bold "5/6  覆盖安装"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/dev/null 2>&1 \
  || die "安装失败。确认手机已解锁并保持连接。"
ok "已安装"

# ---------------------------------------------------------------- 6. 启动
bold "6/6  启动"
LAUNCH_OUT=$(xcrun devicectl device process launch \
  --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" 2>&1)

if echo "$LAUNCH_OUT" | grep -q "Launched"; then
  ok "已启动"
  echo
  bold "完成。应用可用约 7 天，到期后再跑一次本脚本即可。"
  exit 0
fi

echo
if echo "$LAUNCH_OUT" | grep -qi "unlock"; then
  warn "手机处于锁定状态。解锁后直接在桌面点开「双摄相机」即可，不必重跑脚本。"
elif echo "$LAUNCH_OUT" | grep -qiE "trust|entitlement|provisioning"; then
  warn "需要信任开发者（换了签名证书后第一次启动会遇到）："
  info "手机上打开 设置 → 通用 → VPN 与设备管理"
  info "在「开发者 App」下选择你的 Apple Development 开发者，点「信任」"
  info "然后直接在桌面点开「双摄相机」"
else
  warn "安装成功，但自动启动失败："
  echo "$LAUNCH_OUT" | tail -3
  info "可直接在手机桌面点开「双摄相机」"
fi
echo
bold "应用已装好，可用约 7 天。"
