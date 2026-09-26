#!/bin/bash
# Kanade 一键编译脚本（仅支持 Apple 芯片的 Mac）
#   bash build.sh            编译 Kanade.app
#   bash build.sh --release  编译并打包成可上传到 GitHub Releases 的 zip
set -euo pipefail

# 应用标识符：macOS 用它区分不同的应用。
BUNDLE_ID="io.github.accelhp.kanade"
# 版本号（显示给用户看的）和内部编号（每次发布加 1）
VERSION="3.1"
BUILD_NUMBER="16"
# 左上角 logo 的字体，可选：
#   Quicksand  Nunito  Comfortaa  Zen Maru Gothic
#   Outfit  Urbanist  Sora  Lexend  Poppins  Montserrat
#   Josefin Sans  Space Grotesk  DM Serif Display  Cormorant Garamond
# 留空则使用思源黑体
LOGO_FONT="Sora"

cd "$(dirname "$0")"

RELEASE=0
for ARG in "$@"; do
  case "${ARG}" in
    --release) RELEASE=1 ;;
    *) echo "不认识的参数：${ARG}（可用参数：--release）"; exit 1 ;;
  esac
done

if ! xcrun --show-sdk-path >/dev/null 2>&1; then
  echo "没有找到 Apple 命令行工具。请先在终端运行："
  echo "    xcode-select --install"
  echo "装好后再运行一次 bash build.sh"
  exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
  echo "提示：Kanade 只在 Apple 芯片（M 系列）的 Mac 上测试过。"
  echo "在 Intel Mac 上可以继续编译，但不保证能正常工作。"
fi

echo "正在编译（第一次需要一两分钟）…"
swift build -c release --product Kanade
BIN="$(swift build -c release --show-bin-path)/Kanade"

APP="Kanade.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Kanade"

# 思源黑体（SIL 开源字体许可）：第一次编译时从 Adobe 官方仓库下载，之后使用缓存
FONT_BASE="https://github.com/adobe-fonts/source-han-sans/raw/release"
mkdir -p Fonts
FONT_OK=1
for W in Regular Medium Bold; do
  F="Fonts/SourceHanSansCN-${W}.otf"
  if [ ! -s "${F}" ]; then
    echo "正在下载思源黑体 ${W}（约 8 MB）…"
    if ! curl -fL --retry 2 -o "${F}.part" "${FONT_BASE}/SubsetOTF/CN/SourceHanSansCN-${W}.otf"; then
      rm -f "${F}.part"; FONT_OK=0; continue
    fi
    mv "${F}.part" "${F}"
  fi
done
if [ ! -s Fonts/LICENSE.txt ]; then
  curl -fL --retry 2 -o Fonts/LICENSE.txt "${FONT_BASE}/LICENSE.txt" || true
fi
FONT_KEY=""
if [ "${FONT_OK}" = "1" ]; then
  mkdir -p "${APP}/Contents/Resources/Fonts"
  cp Fonts/SourceHanSansCN-*.otf "${APP}/Contents/Resources/Fonts/"
  [ -s Fonts/LICENSE.txt ] && cp Fonts/LICENSE.txt "${APP}/Contents/Resources/Fonts/SourceHanSans-LICENSE.txt"
  FONT_KEY="<key>ATSApplicationFontsPath</key><string>Fonts</string>"
else
  echo "字体下载失败，这次先使用系统字体。网络恢复后重新运行 bash build.sh 即可。"
fi

# logo 字体（SIL 开源字体许可，来自 Google Fonts 官方仓库）
LOGO_KEY=""
if [ -n "${LOGO_FONT}" ]; then
  LOGO_DIR=""; LOGO_FILE=""; LOGO_WEIGHT="700"
  case "${LOGO_FONT}" in
    "Quicksand")          LOGO_DIR="quicksand";         LOGO_FILE="Quicksand[wght].ttf";          LOGO_WEIGHT="700" ;;
    "Nunito")             LOGO_DIR="nunito";            LOGO_FILE="Nunito[wght].ttf";             LOGO_WEIGHT="800" ;;
    "Comfortaa")          LOGO_DIR="comfortaa";         LOGO_FILE="Comfortaa[wght].ttf";          LOGO_WEIGHT="700" ;;
    "Zen Maru Gothic")    LOGO_DIR="zenmarugothic";     LOGO_FILE="ZenMaruGothic-Bold.ttf";       LOGO_WEIGHT="700" ;;
    "Outfit")             LOGO_DIR="outfit";            LOGO_FILE="Outfit[wght].ttf";             LOGO_WEIGHT="600" ;;
    "Urbanist")           LOGO_DIR="urbanist";          LOGO_FILE="Urbanist[wght].ttf";           LOGO_WEIGHT="700" ;;
    "Sora")               LOGO_DIR="sora";              LOGO_FILE="Sora[wght].ttf";               LOGO_WEIGHT="600" ;;
    "Lexend")             LOGO_DIR="lexend";            LOGO_FILE="Lexend[wght].ttf";             LOGO_WEIGHT="600" ;;
    "Poppins")            LOGO_DIR="poppins";           LOGO_FILE="Poppins-SemiBold.ttf";         LOGO_WEIGHT="600" ;;
    "Montserrat")         LOGO_DIR="montserrat";        LOGO_FILE="Montserrat[wght].ttf";         LOGO_WEIGHT="700" ;;
    "Josefin Sans")       LOGO_DIR="josefinsans";       LOGO_FILE="JosefinSans[wght].ttf";        LOGO_WEIGHT="600" ;;
    "Space Grotesk")      LOGO_DIR="spacegrotesk";      LOGO_FILE="SpaceGrotesk[wght].ttf";       LOGO_WEIGHT="600" ;;
    "DM Serif Display")   LOGO_DIR="dmserifdisplay";    LOGO_FILE="DMSerifDisplay-Regular.ttf";   LOGO_WEIGHT="400" ;;
    "Cormorant Garamond") LOGO_DIR="cormorantgaramond"; LOGO_FILE="CormorantGaramond[wght].ttf";  LOGO_WEIGHT="700" ;;
    *) echo "不认识的 logo 字体：${LOGO_FONT}，这次使用思源黑体。" ;;
  esac
  if [ -n "${LOGO_FILE}" ]; then
    GF="https://raw.githubusercontent.com/google/fonts/main/ofl/${LOGO_DIR}"
    mkdir -p "Fonts/logo/${LOGO_DIR}"
    LF="Fonts/logo/${LOGO_DIR}/${LOGO_FILE}"
    ENC_FILE="$(printf '%s' "${LOGO_FILE}" | sed 's/\[/%5B/g; s/\]/%5D/g')"
    if [ ! -s "${LF}" ]; then
      echo "正在下载 logo 字体 ${LOGO_FONT}…"
      curl -fL --retry 2 -o "${LF}.part" "${GF}/${ENC_FILE}" && mv "${LF}.part" "${LF}" || rm -f "${LF}.part"
    fi
    if [ ! -s "Fonts/logo/${LOGO_DIR}/OFL.txt" ]; then
      curl -fL --retry 2 -o "Fonts/logo/${LOGO_DIR}/OFL.txt" "${GF}/OFL.txt" || true
    fi
    if [ -s "${LF}" ]; then
      mkdir -p "${APP}/Contents/Resources/Fonts"
      cp "${LF}" "${APP}/Contents/Resources/Fonts/"
      [ -s "Fonts/logo/${LOGO_DIR}/OFL.txt" ] && cp "Fonts/logo/${LOGO_DIR}/OFL.txt" "${APP}/Contents/Resources/Fonts/${LOGO_DIR}-OFL.txt"
      LOGO_KEY="<key>KanadeLogoFontFamily</key><string>${LOGO_FONT}</string><key>KanadeLogoFontWeight</key><integer>${LOGO_WEIGHT}</integer>"
      # 思源黑体下载失败时也要让系统载入 logo 字体
      FONT_KEY="<key>ATSApplicationFontsPath</key><string>Fonts</string>"
    else
      echo "logo 字体下载失败，这次使用思源黑体。"
    fi
  fi
fi

# MIT 许可随 app 一起分发
[ -s LICENSE ] && cp LICENSE "${APP}/Contents/Resources/LICENSE.txt"

# 生成图标（失败也不影响使用）
ICON_KEY=""
TMP="$(mktemp -d)"
if swift Tools/MakeIcon.swift "${TMP}/Kanade.iconset" >/dev/null 2>&1 \
   && iconutil -c icns "${TMP}/Kanade.iconset" -o "${APP}/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi
rm -rf "${TMP}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Kanade</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Kanade</string>
  <key>CFBundleDisplayName</key><string>Kanade</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  ${ICON_KEY}
  ${FONT_KEY}
  ${LOGO_KEY}
</dict>
</plist>
PLIST

codesign --force --sign - "${APP}" >/dev/null 2>&1 || true
echo ""
echo "完成：$(pwd)/${APP}（版本 ${VERSION}）"

if [ "${RELEASE}" = "1" ]; then
  ZIP="Kanade-${VERSION}-macOS.zip"
  rm -f "${ZIP}"
  ditto -c -k --keepParent "${APP}" "${ZIP}"
  echo "已打包：$(pwd)/${ZIP}"
  echo "把这个 zip 上传到 GitHub 仓库的 Releases 页面即可。"
else
  echo "双击即可打开，也可以把它拖进“应用程序”文件夹。"
fi
