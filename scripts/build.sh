#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
cd "$project_dir"

source "${script_dir}/config.sh"

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/${APP_NAME,,}"
mkdir -p "$cache_dir"

sdk_file="${cache_dir}/sdk_path.tmp"
xcrun --show-sdk-path >"$sdk_file" 2>/dev/null
if [[ ! -s "$sdk_file" ]]; then
    rm -f "$sdk_file"
    printf '%s\n' "Error: Failed to obtain SDK path from xcrun" >&2
    exit 1
fi
IFS= read -r sdk_path <"$sdk_file"
rm -f "$sdk_file"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "Error: VERSION file must contain a version like 1.2.3 (found '${VERSION}')" >&2
    exit 1
fi

# Every build increments BUILD_NUMBER; the file is the single source of truth.
if [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    build_number=$((10#$BUILD_NUMBER + 1))
else
    build_number=1
fi
printf '%s\n' "$build_number" >"$build_num_file"
export BUILD_NUMBER="$build_number"

build_dir="build"
app_name="${APP_NAME}"
app_display_name="${APP_DISPLAY_NAME:-$app_name}"
bundle_id="${BUNDLE_ID}"
app_dir="${build_dir}/${app_display_name}.app"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"

if [[ "$app_name" != "$app_display_name" && -d "${build_dir}/${app_name}.app" ]]; then
    rm -rf "${build_dir}/${app_name}.app"
fi

mkdir -p "$macos_dir" "$resources_dir"

if [[ -f "Resources/AppIcon.png" && (! -f "Resources/AppIcon.icns" || "Resources/AppIcon.png" -nt "Resources/AppIcon.icns") ]]; then
    printf '%s\n' "Generating Resources/AppIcon.icns from Resources/AppIcon.png..."
    iconset_dir="$(mktemp -d "${TMPDIR:-/tmp}/AppIcon.XXXXXX.iconset")"
    sips -z 16 16 "Resources/AppIcon.png" --out "${iconset_dir}/icon_16x16.png" >/dev/null 2>&1 || true
    sips -z 32 32 "Resources/AppIcon.png" --out "${iconset_dir}/icon_16x16@2x.png" >/dev/null 2>&1 || true
    sips -z 32 32 "Resources/AppIcon.png" --out "${iconset_dir}/icon_32x32.png" >/dev/null 2>&1 || true
    sips -z 64 64 "Resources/AppIcon.png" --out "${iconset_dir}/icon_32x32@2x.png" >/dev/null 2>&1 || true
    sips -z 128 128 "Resources/AppIcon.png" --out "${iconset_dir}/icon_128x128.png" >/dev/null 2>&1 || true
    sips -z 256 256 "Resources/AppIcon.png" --out "${iconset_dir}/icon_128x128@2x.png" >/dev/null 2>&1 || true
    sips -z 256 256 "Resources/AppIcon.png" --out "${iconset_dir}/icon_256x256.png" >/dev/null 2>&1 || true
    sips -z 512 512 "Resources/AppIcon.png" --out "${iconset_dir}/icon_256x256@2x.png" >/dev/null 2>&1 || true
    sips -z 512 512 "Resources/AppIcon.png" --out "${iconset_dir}/icon_512x512.png" >/dev/null 2>&1 || true
    sips -z 1024 1024 "Resources/AppIcon.png" --out "${iconset_dir}/icon_512x512@2x.png" >/dev/null 2>&1 || true
    iconutil -c icns "$iconset_dir" -o "Resources/AppIcon.icns" >/dev/null 2>&1 || true
    rm -rf "$iconset_dir"
fi

if [[ -d "Resources" ]]; then
    cp -R Resources/. "${resources_dir}/"
fi

if [[ -f "VERSION" ]]; then
    cp "VERSION" "${resources_dir}/VERSION"
fi
printf '%s\n' "$build_number" >"${resources_dir}/BUILD_NUMBER"

sources=()
while IFS= read -r file; do
    sources+=("$file")
done < <(find Sources/App -type f -name "*.swift" | sort)

host_arch() {
    case "$(uname -m)" in
    arm64 | aarch64) printf '%s\n' "arm64" ;;
    *) printf '%s\n' "x86_64" ;;
    esac
}

normalize_arch() {
    case "$1" in
    intel | x86_64 | amd64) printf '%s\n' "x86_64" ;;
    silicon | apple-silicon | arm64 | aarch64) printf '%s\n' "arm64" ;;
    host | current | native) host_arch ;;
    *) printf '%s\n' "$1" ;;
    esac
}

arch_list=()
for a in ${ARCHS:-host}; do
    arch_norm="$(normalize_arch "$a")"
    if [[ ! " ${arch_list[*]:-} " =~ [[:space:]]${arch_norm}[[:space:]] ]]; then
        arch_list+=("$arch_norm")
    fi
done

[[ ${#arch_list[@]} -gt 0 ]] || arch_list=("$(host_arch)")

if [[ "${DEBUG:-0}" == "1" || "${CONFIGURATION:-}" == "debug" ]]; then
    swiftc_flags=(
        -Onone
        -DDEBUG
    )
    build_mode="debug"
else
    swiftc_flags=(
        -Osize
        -whole-module-optimization
        -lto=llvm-thin
        -Xlinker -dead_strip
        -Xlinker -x
    )
    build_mode="release"
fi

printf '%s\n' "Compiling ${app_name} v${VERSION} (Build ${BUILD_NUMBER}) [${build_mode}] for ${arch_list[*]} (${#sources[@]} source files)..."
if [[ ${#arch_list[@]} -eq 1 ]]; then
    swiftc -sdk "$sdk_path" \
        -target "${arch_list[0]}-apple-macos${MIN_MACOS_VERSION}" \
        "${swiftc_flags[@]}" \
        "${sources[@]}" \
        -o "${macos_dir}/${app_name}"
else
    tmp_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/${app_name}_build.XXXXXX")"
    trap 'rm -rf "$tmp_build_dir"' EXIT
    slice_bins=()
    pids=()
    for arch in "${arch_list[@]}"; do
        slice_bin="${tmp_build_dir}/${app_name}_${arch}"
        slice_bins+=("$slice_bin")
        swiftc -sdk "$sdk_path" \
            -target "${arch}-apple-macos${MIN_MACOS_VERSION}" \
            "${swiftc_flags[@]}" \
            "${sources[@]}" \
            -o "$slice_bin" &
        pids+=($!)
    done
    compile_err=0
    for pid in "${pids[@]}"; do
        wait "$pid" || compile_err=$?
    done
    if [[ "$compile_err" -ne 0 ]]; then
        printf '%s\n' "Error: Compilation failed for one or more architecture slices" >&2
        exit "$compile_err"
    fi
    lipo -create "${slice_bins[@]}" -output "${macos_dir}/${app_name}"
    rm -rf "$tmp_build_dir"
    trap - EXIT
fi

plugins_dir="${contents_dir}/PlugIns"

# Sources shared by both Quick Look extensions (parser + scene building + viewer).
shared_ext_sources=(
    "Sources/App/ZipArchive.swift"
    "Sources/App/ThreeMFModel.swift"
    "Sources/App/ThreeMFParser.swift"
    "Sources/App/ModelSceneBuilder.swift"
    "Sources/App/ModelSnapshot.swift"
    "Sources/App/ThreeMFView.swift"
)

# compile_appex <module/executable name> <output binary> <framework...> -- <sources...>
compile_appex() {
    local name="$1" out="$2"
    shift 2
    local frameworks=() srcs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        frameworks+=(-framework "$1")
        shift
    done
    shift
    srcs=("$@")

    local flags=(
        -module-name "$name"
        "${swiftc_flags[@]}"
        -parse-as-library
        -application-extension
        -Xlinker -e -Xlinker _NSExtensionMain
        -Xlinker -dead_strip
        "${frameworks[@]}"
        "${srcs[@]}"
    )

    printf '%s\n' "Compiling ${name}.appex for ${arch_list[*]} (${#srcs[@]} source files)..."
    if [[ ${#arch_list[@]} -eq 1 ]]; then
        swiftc -sdk "$sdk_path" -target "${arch_list[0]}-apple-macos${MIN_MACOS_VERSION}" "${flags[@]}" -o "$out"
        return
    fi

    local tmp slices=() pids=() err=0 arch
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/${name}_ext_build.XXXXXX")"
    for arch in "${arch_list[@]}"; do
        slices+=("${tmp}/${name}_${arch}")
        swiftc -sdk "$sdk_path" -target "${arch}-apple-macos${MIN_MACOS_VERSION}" "${flags[@]}" \
            -o "${tmp}/${name}_${arch}" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || err=$?; done
    if [[ "$err" -ne 0 ]]; then
        rm -rf "$tmp"
        printf '%s\n' "Error: Compilation failed for ${name} extension slice" >&2
        exit "$err"
    fi
    lipo -create "${slices[@]}" -output "$out"
    rm -rf "$tmp"
}

# Preview extension (interactive 3D viewer in the Quick Look panel)
ql_name="QuickLook3mf"
ql_bundle_id="${bundle_id}.QuickLook"
appex_dir="${plugins_dir}/${ql_name}.appex"
appex_contents="${appex_dir}/Contents"
rm -rf "$appex_dir"
mkdir -p "${appex_contents}/MacOS"
compile_appex "$ql_name" "${appex_contents}/MacOS/${ql_name}" \
    Foundation Cocoa QuickLookUI SceneKit Metal -- \
    "Sources/QuickLook/PreviewViewController.swift" "${shared_ext_sources[@]}"

# Thumbnail extension (Finder icons, column view, Get Info)
th_name="Thumbnail3mf"
th_bundle_id="${bundle_id}.Thumbnail"
th_appex_dir="${plugins_dir}/${th_name}.appex"
th_appex_contents="${th_appex_dir}/Contents"
rm -rf "$th_appex_dir"
mkdir -p "${th_appex_contents}/MacOS"
compile_appex "$th_name" "${th_appex_contents}/MacOS/${th_name}" \
    Foundation Cocoa QuickLookThumbnailing SceneKit Metal -- \
    "Sources/Thumbnail/ThumbnailProvider.swift" "${shared_ext_sources[@]}"

xml_escape() {
    local s="$1"
    shopt -u patsub_replacement 2>/dev/null || true
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "$s"
}

app_name_xml="$(xml_escape "$app_name")"
app_display_name_xml="$(xml_escape "$app_display_name")"
bundle_id_xml="$(xml_escape "$bundle_id")"
version_xml="$(xml_escape "$VERSION")"
build_number_xml="$(xml_escape "$BUILD_NUMBER")"
min_macos_xml="$(xml_escape "$MIN_MACOS_VERSION")"
copyright_xml="$(xml_escape "$COPYRIGHT")"

printf '%s\n' "Generating ${app_name} Info.plist..."
lproj_dir="${resources_dir}/en.lproj"
mkdir -p "$lproj_dir"
cat <<EOF >"${lproj_dir}/InfoPlist.strings"
"CFBundleDisplayName" = "${app_display_name}";
"CFBundleName" = "${app_display_name}";
EOF
cat <<EOF >"${contents_dir}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${app_name_xml}</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id_xml}</string>
    <key>CFBundleName</key>
    <string>${app_display_name_xml}</string>
    <key>CFBundleDisplayName</key>
    <string>${app_display_name_xml}</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version_xml}</string>
    <key>CFBundleVersion</key>
    <string>${build_number_xml}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>${min_macos_xml}</string>
    <key>LSUIElement</key>
    <${LS_UI_ELEMENT}/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>3D Manufacturing Format (3MF)</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>3mf</string>
            </array>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.3mf.3mf</string>
                <string>public.3mf</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.3mf.3mf</string>
            <key>UTTypeDescription</key>
            <string>3D Manufacturing Format</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
                <string>public.archive</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>3mf</string>
                </array>
                <key>public.mime-type</key>
                <string>application/vnd.ms-package.3dmanufacturing-3dmodel+xml</string>
            </dict>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>${copyright_xml}</string>
</dict>
</plist>
EOF

# write_appex_plist <contents dir> <executable> <bundle id> <display name> <extension point> <principal class> <extra attributes xml>
write_appex_plist() {
    cat <<EOF >"$1/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$4</string>
    <key>CFBundleExecutable</key>
    <string>$2</string>
    <key>CFBundleIdentifier</key>
    <string>$3</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$2</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>${version_xml}</string>
    <key>CFBundleVersion</key>
    <string>${build_number_xml}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>${min_macos_xml}</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLSupportedContentTypes</key>
            <array>
                <string>org.3mf.3mf</string>
                <string>public.3mf</string>
                <string>com.microsoft.3mf</string>
                <string>dyn.ah62d4rv4ge804550</string>
            </array>
$7
        </dict>
        <key>NSExtensionPointIdentifier</key>
        <string>$5</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$6</string>
    </dict>
</dict>
</plist>
EOF
}

write_appex_plist "$appex_contents" "$ql_name" "$ql_bundle_id" "3MF Quick Look" \
    "com.apple.quicklook.preview" "PreviewViewController" \
    "            <key>QLSupportsSearchableItems</key>
            <false/>"

write_appex_plist "$th_appex_contents" "$th_name" "$th_bundle_id" "3MF Thumbnails" \
    "com.apple.quicklook.thumbnail" "ThumbnailProvider" \
    "            <key>QLThumbnailMinimumDimension</key>
            <integer>0</integer>"

# macOS QuickLook app extensions require sandbox entitlements:
ql_entitlements="${cache_dir}/quicklook.entitlements"
cat <<EOF >"$ql_entitlements"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
</plist>
EOF

signing_identity="${SIGNING_IDENTITY:--}"
designated_requirement="designated => identifier \"${bundle_id}\""

for ext in "${appex_dir}:${ql_bundle_id}" "${th_appex_dir}:${th_bundle_id}"; do
    ext_dir="${ext%%:*}"
    ext_id="${ext#*:}"
    printf '%s\n' "Signing $(basename "$ext_dir") (ad-hoc, sandboxed)..."
    codesign --force --sign "$signing_identity" --entitlements "$ql_entitlements" \
        --requirements "=designated => identifier \"${ext_id}\"" "$ext_dir"
done

printf '%s\n' "Signing ${app_name} bundle (ad-hoc, ${designated_requirement})..."
codesign --force --sign "$signing_identity" --requirements "=${designated_requirement}" "$app_dir"

if [[ "$signing_identity" == "-" ]]; then
    signed_requirement="$(codesign -d -r- "$app_dir" 2>&1 | grep '^designated => ' || true)"
    if [[ "$signed_requirement" != "$designated_requirement" ]]; then
        printf '%s\n' "Error: Unexpected designated requirement '${signed_requirement}'; permissions would not persist." >&2
        exit 1
    fi
fi

if [[ "${DEBUG:-0}" != "1" && "${FAST_BUILD:-0}" != "1" ]]; then
    printf '%s\n' "Refreshing macOS LaunchServices and QuickLook cache..."
    touch "$app_dir"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$app_dir" >/dev/null 2>&1 || true
    /usr/bin/pluginkit -a "$appex_dir" "$th_appex_dir" >/dev/null 2>&1 || true
    /usr/bin/pluginkit -e use -i "${ql_bundle_id}" >/dev/null 2>&1 || true
    /usr/bin/pluginkit -e use -i "${th_bundle_id}" >/dev/null 2>&1 || true
    qlmanage -r >/dev/null 2>&1 || true
    qlmanage -r cache >/dev/null 2>&1 || true
fi

printf '%s\n' "✅ Build complete:"
printf '%s\n' "   - ${app_dir}"
