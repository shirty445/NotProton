#!/bin/bash
# NotProtonGPTK: builds CrossOver's open source Wine into a runner the Wine Manager installs.
#
# The bridge (lsteamclient) is built against Wine 11, the base of CrossOver 26, and its two
# halves only talk to each other through a matching Wine. The Wine 7 and 8 era runtimes Gcenx
# and Heroic package crash in steamclient_init, so this builds CodeWeavers' published CrossOver
# 26.3 tree instead. That tree also carries the winemac.drv and ntdll hooks D3DMetal needs, so
# Apple's GPTK can be laid over the result. Nothing of Apple's is built in or packaged.
#
# Like bridge/setup-wine-tree.sh, everything is built for x86_64 (the runner runs under
# Rosetta) with -arch x86_64 on an Apple Silicon machine; Wine's own build tools run under
# Rosetta, the compilers natively.
#
#   wine/build.sh              every stage, skipping the ones already done
#   wine/build.sh deps wine    only those stages
#
# Output: scratch/cxwine/out/notproton-wine-cx<version>-<revision>.tar.xz holding Wine/, with
# bin/, lib/ (Wine plus the dylibs it loads) and share/wine/{mono,gecko}.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

CX_VERSION=26.3.0
CX_SHA256=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872
# Bumped when the runner changes without a new CrossOver release.
REVISION="${NP_WINE_REVISION:-1}"
NAME="notproton-wine-cx$CX_VERSION-$REVISION"

WORK="${NP_WINE_WORK:-$repo/scratch/cxwine}"
DL="$WORK/downloads"
SRC="$WORK/src"
DEPS="$WORK/deps"
DEPS_WORK="$WORK/deps-work"
BUILD="$WORK/wine-build"
INSTALL="$WORK/wine-install"
DIST="$WORK/dist/Wine"
OUT="$WORK/out"
JOBS="$(sysctl -n hw.ncpu)"

export MACOSX_DEPLOYMENT_TARGET=14.0
# The bison macOS ships is too old for Wine.
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CCACHE_DIR="${CCACHE_DIR:-$WORK/ccache}"
# Only the private x86_64 prefix: Homebrew's arm64 .pc files must never be picked up.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export PKG_CONFIG_PATH=""

log() { printf '\n==> %s\n' "$*"; }
die() { printf '==> %s\n' "$*" >&2; exit 1; }

fetch() { # url sha256 [file]
    local out="$DL/${3:-${1##*/}}"
    mkdir -p "$DL"
    if [ ! -f "$out" ]; then
        curl -fsSL --retry 3 -o "$out.part" "$1"
        mv "$out.part" "$out"
    fi
    echo "$2  $out" | shasum -a 256 -c - >/dev/null || die "checksum mismatch: $out"
}

done_stage() { [ -f "$WORK/.done-$1" ]; }
mark_stage() { touch "$WORK/.done-$1"; }

stage_tools() {
    local missing="" tool
    for tool in make bison flex pkg-config nasm cmake ninja ccache i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    [ -z "$missing" ] || die "missing tools:$missing (brew install mingw-w64 bison flex nasm pkg-config cmake ninja ccache)"
    arch -x86_64 /usr/bin/true 2>/dev/null || die "Rosetta is not installed (softwareupdate --install-rosetta)"
}

stage_fetch() {
    log "fetching sources"
    fetch "https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX_VERSION.tar.gz" "$CX_SHA256"
    # The CrossOver drop of nettle has no Makefile.in files, so the release it is cut from.
    fetch https://ftpmirror.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz \
        fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5
    fetch https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz \
        5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
    fetch https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar \
        f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e MoltenVK-1.4.2-macos.tar
    fetch https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz \
        de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f
    # The versions dlls/appwiz.cpl/addons.c asks for, so wineboot never offers to download them.
    fetch https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.tar.xz \
        a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb
    fetch https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86.msi \
        26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6
    fetch https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86_64.msi \
        e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f

    if [ ! -f "$SRC/wine/VERSION" ]; then
        log "unpacking CrossOver $CX_VERSION sources"
        rm -rf "$SRC" && mkdir -p "$SRC"
        tar -xzf "$DL/crossover-sources-$CX_VERSION.tar.gz" -C "$SRC" --strip-components=1 \
            sources/wine sources/freetype sources/gnutls
    fi
    grep -q 'Wine version 11\.' "$SRC/wine/VERSION" || die "expected a Wine 11 tree, got: $(cat "$SRC/wine/VERSION")"
}

# Every dylib gets an @rpath id and @rpath references to its siblings, so the runner can carry
# them all in its lib/, which Wine's unix modules find through their @loader_path rpath.
fix_ids() {
    local f dep
    for f in "$DEPS"/lib/*.dylib; do
        [ -L "$f" ] && continue
        install_name_tool -id "@rpath/${f##*/}" "$f"
        for dep in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep "^$DEPS/lib/" || true); do
            install_name_tool -change "$dep" "@rpath/${dep##*/}" "$f"
        done
        install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true
        codesign -f -s - "$f" 2>/dev/null
    done
}

fresh() { # name source-dir: a pristine copy to build in
    rm -rf "${DEPS_WORK:?}/$1"
    mkdir -p "$DEPS_WORK"
    # -p keeps mtimes, or automake decides configure is stale and reruns it.
    cp -Rp "$2" "$DEPS_WORK/$1"
    cd "$DEPS_WORK/$1"
}

unpack() { # name archive
    rm -rf "${DEPS_WORK:?}/$1"
    mkdir -p "$DEPS_WORK/$1"
    tar -xf "$DL/$2" -C "$DEPS_WORK/$1" --strip-components=1
    cd "$DEPS_WORK/$1"
}

autotools_cross() { # configure options...
    ./configure --prefix="$DEPS" --host=x86_64-apple-darwin --build=aarch64-apple-darwin \
        --enable-shared --disable-static "$@"
}

dep_gmp() {
    fresh gmp "$SRC/gnutls/gmp"
    autotools_cross --disable-assembly
    make -j"$JOBS" && make install
}

dep_nettle() {
    unpack nettle nettle-3.10.2.tar.gz
    autotools_cross --libdir="$DEPS/lib" \
        --disable-documentation --disable-openssl --disable-assembler
    make -j"$JOBS" && make install
}

dep_gnutls() {
    fresh gnutls "$SRC/gnutls/gnutls"
    # Single words on purpose: CrossOver's m4/hooks.m4 tests x$NETTLE_LIBS unquoted, and a
    # value with a space quietly turns the nettle backend off.
    autotools_cross \
        --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn \
        --without-brotli --without-zstd --without-tpm --without-tpm2 --disable-doc \
        --disable-tests --disable-tools --disable-cxx --disable-nls --disable-guile \
        --disable-libdane --disable-full-test-suite --disable-gost \
        GMP_LIBS=-lgmp NETTLE_LIBS=-lnettle HOGWEED_LIBS=-lhogweed
    make -j"$JOBS" && make install
}

cmake_x86_64() { # cmake options...
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS" \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" "$@"
}

dep_freetype() {
    fresh freetype "$SRC/freetype"
    cmake_x86_64 -DBUILD_SHARED_LIBS=ON \
        -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
        -DFT_REQUIRE_ZLIB=ON
    cmake --build build && cmake --install build
}

dep_sdl2() {
    unpack sdl2 SDL2-2.32.10.tar.gz
    cmake_x86_64 -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF
    cmake --build build && cmake --install build
}

dep_moltenvk() {
    rm -rf "${DEPS_WORK:?}/moltenvk" && mkdir -p "$DEPS_WORK/moltenvk"
    tar -xf "$DL/MoltenVK-1.4.2-macos.tar" -C "$DEPS_WORK/moltenvk"
    local dylib
    dylib="$(find "$DEPS_WORK/moltenvk" -path '*dynamic/dylib/macOS/libMoltenVK.dylib' | head -1)"
    [ -n "$dylib" ] || die "no libMoltenVK.dylib in the MoltenVK release"
    lipo "$dylib" -verify_arch x86_64
    mkdir -p "$DEPS/lib"
    lipo "$dylib" -thin x86_64 -output "$DEPS/lib/libMoltenVK.dylib"
}

dep_ffmpeg() {
    # libavcodec, libavformat and libavutil, for winedmo's Media Foundation decoding.
    unpack ffmpeg ffmpeg-7.1.5.tar.xz
    ./configure --prefix="$DEPS" --enable-cross-compile --arch=x86_64 --target-os=darwin \
        --cc="clang -arch x86_64" --cxx="clang++ -arch x86_64" --x86asmexe="$(command -v nasm)" \
        --extra-cflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
        --extra-ldflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
        --enable-shared --disable-static --enable-pic --disable-programs --disable-doc \
        --disable-avdevice --disable-avfilter --disable-network --disable-debug \
        --disable-autodetect --enable-videotoolbox --enable-audiotoolbox \
        --install-name-dir=@rpath
    make -j"$JOBS" && make install
}

stage_deps() {
    local dep
    for dep in gmp nettle gnutls freetype sdl2 moltenvk ffmpeg; do
        done_stage "dep-$dep" && continue
        log "building $dep"
        (
            export CC="clang -arch x86_64" CXX="clang++ -arch x86_64"
            export CFLAGS="-O2" CXXFLAGS="-O2" CPPFLAGS="-I$DEPS/include"
            export LDFLAGS="-L$DEPS/lib -Wl,-headerpad_max_install_names"
            "dep_$dep"
        )
        fix_ids
        mark_stage "dep-$dep"
    done
    local lib
    for lib in "$DEPS"/lib/*.dylib; do
        [ -L "$lib" ] || [ "$(lipo -archs "$lib")" = x86_64 ] || die "$lib is not x86_64"
    done
}

stage_wine() {
    mkdir -p "$BUILD"
    cd "$BUILD"
    if [ ! -f Makefile ]; then
        log "configuring Wine"
        # @loader_path/../.. from lib/wine/x86_64-unix is the runner's lib/, where the dylibs go.
        "$SRC/wine/configure" \
            --prefix="$INSTALL" --host=x86_64-apple-darwin \
            --enable-archs=i386,x86_64 --disable-tests \
            --with-coreaudio --with-freetype --with-gnutls --with-sdl --with-vulkan --with-ffmpeg \
            --without-alsa --without-capi --without-cups --without-dbus --without-fontconfig \
            --without-gphoto --without-gstreamer --without-krb5 --without-netapi --without-oss \
            --without-pcap --without-pulse --without-sane --without-udev --without-usb \
            --without-v4l2 --without-wayland --without-x --without-inotify \
            CC="ccache clang -arch x86_64" CXX="ccache clang++ -arch x86_64" OBJC="ccache clang -arch x86_64" \
            i386_CC="ccache i686-w64-mingw32-gcc" x86_64_CC="ccache x86_64-w64-mingw32-gcc" \
            CFLAGS="-O2 -g0" CROSSCFLAGS="-O2 -g0" \
            CPPFLAGS="-I$DEPS/include" \
            LDFLAGS="-L$DEPS/lib -Wl,-rpath,@loader_path/../.. -Wl,-headerpad_max_install_names" \
            FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
            SDL2_CFLAGS="-I$DEPS/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$DEPS/lib -lSDL2" \
            GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
            FFMPEG_CFLAGS="-I$DEPS/include" FFMPEG_LIBS="-L$DEPS/lib -lavformat -lavcodec -lavutil"
    fi
    # A cross configure that falls back to the host compiler builds arm64 unix modules that
    # only fail at the link, and optional features are turned off without a word.
    grep -q '^host_cpu = x86_64' config.status || grep -q 'host_cpu=.x86_64' config.status \
        || die "configure did not take the x86_64 host"
    local need
    for need in SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBSDL2 SONAME_LIBVULKAN; do
        grep -q "#define $need " include/config.h || die "configure left out $need"
    done
    grep -q '#define HAVE_FFMPEG 1' include/config.h || die "configure left out FFmpeg"
    grep -E '#define SONAME_LIB(FREETYPE|GNUTLS|SDL2|VULKAN) ' include/config.h

    log "building Wine"
    make -j"$JOBS"
    rm -rf "$INSTALL"
    make install-lib
    [ -x "$INSTALL/bin/wineserver" ] || die "no bin/wineserver after install"
    [ -x "$INSTALL/lib/wine/x86_64-unix/wine" ] || die "no lib/wine/x86_64-unix/wine after install"
}

stage_assemble() {
    log "assembling $DIST"
    rm -rf "$WORK/dist"
    mkdir -p "$DIST"
    cp -R "$INSTALL/" "$DIST/"
    rm -rf "$DIST/include" "$DIST/share/man" "$DIST/share/applications"
    # -a keeps the version symlinks (libnettle.8.dylib -> libnettle.8.10.dylib) the ids name.
    cp -a "$DEPS"/lib/*.dylib "$DIST/lib/"

    mkdir -p "$DIST/share/wine/mono" "$DIST/share/wine/gecko"
    tar -xJf "$DL/wine-mono-10.4.1-x86.tar.xz" -C "$DIST/share/wine/mono"
    cp "$DL/wine-gecko-2.47.4-x86.msi" "$DL/wine-gecko-2.47.4-x86_64.msi" "$DIST/share/wine/gecko/"

    # Nothing may point into this machine's build folders.
    local leaks
    leaks="$(otool -L "$DIST"/lib/*.dylib "$DIST"/lib/wine/x86_64-unix/*.so "$DIST"/lib/wine/x86_64-unix/wine \
        | grep -F "$WORK" || true)"
    [ -z "$leaks" ] || die "absolute build paths left: $leaks"

    find "$DIST/lib" -maxdepth 1 -name '*.dylib' -type f -exec codesign -f -s - {} \; 2>/dev/null || true

    cat > "$DIST/notproton-wine.json" <<EOF
{
  "name": "$NAME",
  "crossover": "$CX_VERSION",
  "wine": "$(sed 's/^Wine version //' "$SRC/wine/VERSION")",
  "revision": $REVISION,
  "arch": "x86_64",
  "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

stage_package() {
    log "packaging $NAME"
    mkdir -p "$OUT"
    rm -f "$OUT/$NAME.tar.xz"
    tar -cJf "$OUT/$NAME.tar.xz" -C "$WORK/dist" Wine
    (cd "$OUT" && shasum -a 256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
    echo "$NAME" > "$OUT/name"
    du -h "$OUT/$NAME.tar.xz"
}

mkdir -p "$WORK"
[ $# -gt 0 ] || set -- tools fetch deps wine assemble package
for stage in "$@"; do
    "stage_$stage"
done
echo "==> done: $*"
