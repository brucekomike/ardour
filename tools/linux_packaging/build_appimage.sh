#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WAF=${WAF:-"$ROOT_DIR/waf"}
BUILD_DIR=${BUILD_DIR:-"$ROOT_DIR/build"}
WORK_DIR=${WORK_DIR:-"$BUILD_DIR/appimage"}
APPDIR=${APPDIR:-"$WORK_DIR/AppDir"}
OUTPUT_DIR=${OUTPUT_DIR:-"$WORK_DIR/out"}
TOOLS_DIR=${TOOLS_DIR:-"$WORK_DIR/tools"}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
LINUXDEPLOY_URL=${LINUXDEPLOY_URL:-https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage}
APPIMAGETOOL_URL=${APPIMAGETOOL_URL:-https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage}

require_path() {
    local path=$1
    local label=$2
    if [[ -z "$path" || ! -e "$path" ]]; then
        echo "Missing ${label}: ${path}" >&2
        exit 1
    fi
}

fetch_tool() {
    local url=$1
    local target=$2
    curl -fsSL "$url" -o "$target"
    chmod +x "$target"
}

cd "$ROOT_DIR"
mkdir -p "$TOOLS_DIR" "$OUTPUT_DIR"
rm -rf "$APPDIR"

configure_args=(configure --freebie --freedesktop --no-phone-home --prefix=/usr --libdir=/usr/lib --noconfirm)
if [[ -n "${WAF_EXTRA_ARGS:-}" ]]; then
    read -r -a extra_args <<<"$WAF_EXTRA_ARGS"
    configure_args+=("${extra_args[@]}")
fi

"$WAF" "${configure_args[@]}"
"$WAF" build "-j${JOBS}"
DESTDIR="$APPDIR" "$WAF" install

launcher_path=$(find "$APPDIR/usr/bin" -maxdepth 1 -type f -name 'ardour*' | sort | head -n 1)
lib_dir=$(find "$APPDIR/usr/lib" -maxdepth 1 -type d -name 'ardour*' | sort | head -n 1)
conf_dir=$(find "$APPDIR/usr/etc" -maxdepth 1 -type d -name 'ardour*' | sort | head -n 1)
data_dir=$(find "$APPDIR/usr/share" -maxdepth 1 -type d -name 'ardour*' | sort | head -n 1)
desktop_src=$(find "$APPDIR/usr/share/applications" -maxdepth 1 -type f -name '*.desktop' | sort | head -n 1)
icon_src=$(find "$APPDIR/usr/share/icons/hicolor" -path '*/apps/*.png' | sort | tail -n 1)
binary_path=$(find "$lib_dir" -maxdepth 1 -type f -name 'ardour-*' | sort | head -n 1)

require_path "$launcher_path" 'launcher'
require_path "$lib_dir" 'library directory'
require_path "$conf_dir" 'config directory'
require_path "$data_dir" 'data directory'
require_path "$desktop_src" 'desktop file'
require_path "$icon_src" 'icon file'
require_path "$binary_path" 'main executable'

launcher_name=$(basename "$launcher_path")
lib_dir_name=$(basename "$lib_dir")
conf_dir_name=$(basename "$conf_dir")
data_dir_name=$(basename "$data_dir")
desktop_name=$(basename "$desktop_src")
binary_name=$(basename "$binary_path")
version=${binary_name#ardour-}
desktop_icon=$(awk -F= '/^Icon=/{print $2; exit}' "$desktop_src")
if [[ -z "$desktop_icon" ]]; then
    desktop_icon=${desktop_name%.desktop}
fi

cat > "$APPDIR/AppRun" <<EOF2
#!/usr/bin/env bash
set -euo pipefail
app_root=\$(cd "\$(dirname "\$(readlink -f "\$0")")" && pwd)
usr_dir="\$app_root/usr"
lib_dir="\$usr_dir/lib/${lib_dir_name}"
conf_dir="\$usr_dir/etc/${conf_dir_name}"
data_dir="\$usr_dir/share/${data_dir_name}"
export GTK_PATH="\$conf_dir:\$lib_dir\${GTK_PATH:+:\$GTK_PATH}"
export LD_LIBRARY_PATH="\$lib_dir:\$usr_dir/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export ARDOUR_DATA_PATH="\$data_dir"
export ARDOUR_CONFIG_PATH="\$conf_dir"
export ARDOUR_DLL_PATH="\$lib_dir"
export VAMP_PATH="\$lib_dir/vamp\${VAMP_PATH:+:\$VAMP_PATH}"
export SUIL_MODULE_DIR="\$lib_dir"
export PATH="\$usr_dir/bin:\$PATH"
export UBUNTU_MENUPROXY=""
export GTK_MODULES=""
exec "\$lib_dir/${binary_name}" "\$@"
EOF2
chmod +x "$APPDIR/AppRun"
ln -sf AppRun "$APPDIR/$launcher_name"

cp "$desktop_src" "$APPDIR/$desktop_name"
python3 - "$APPDIR/$desktop_name" "$launcher_name" "$desktop_icon" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
launcher = sys.argv[2]
icon = sys.argv[3]
lines = path.read_text().splitlines()
updated = []
for line in lines:
    if line.startswith('Exec='):
        updated.append(f'Exec={launcher}')
    elif line.startswith('TryExec='):
        updated.append(f'TryExec={launcher}')
    elif line.startswith('X-NSM-Exec='):
        updated.append(f'X-NSM-Exec={launcher}')
    elif line.startswith('Icon='):
        updated.append(f'Icon={icon}')
    else:
        updated.append(line)
path.write_text('\n'.join(updated) + '\n')
PY
cp "$icon_src" "$APPDIR/${desktop_icon}.png"

fetch_tool "$LINUXDEPLOY_URL" "$TOOLS_DIR/linuxdeploy.AppImage"
fetch_tool "$APPIMAGETOOL_URL" "$TOOLS_DIR/appimagetool.AppImage"
ln -sf appimagetool.AppImage "$TOOLS_DIR/appimagetool"

linuxdeploy_args=(
    --appdir "$APPDIR"
    -e "$binary_path"
    -e "$launcher_path"
    -d "$APPDIR/$desktop_name"
    -i "$APPDIR/${desktop_icon}.png"
)

while IFS= read -r so_file; do
    linuxdeploy_args+=(--library "$so_file")
done < <(find "$lib_dir" -type f \( -name '*.so' -o -name '*.so.*' \) | sort)

rm -f "$WORK_DIR"/*.AppImage
(
    cd "$WORK_DIR"
    APPIMAGE_EXTRACT_AND_RUN=1 PATH="$TOOLS_DIR:$PATH" "$TOOLS_DIR/linuxdeploy.AppImage" "${linuxdeploy_args[@]}" --output appimage
)

appimage_path=$(find "$WORK_DIR" -maxdepth 1 -type f -name '*.AppImage' | sort | head -n 1)
require_path "$appimage_path" 'AppImage output'
mv "$appimage_path" "$OUTPUT_DIR/Ardour-${version}-demo-$(uname -m).AppImage"

echo "Created $OUTPUT_DIR/Ardour-${version}-demo-$(uname -m).AppImage"
