#!/bin/sh

set -e

umask 0022
unset GREP_OPTIONS SED

_get_repo() {
	git clone "$2" "$1" 2>/dev/null || true
	git -C "$1" remote set-url origin "$2"
	git -C "$1" fetch origin
	git -C "$1" fetch origin --tags
	git -C "$1" checkout "origin/$3" -B "build" || git -C "$1" checkout "$3" -B "build"
}

OMR_DIST=${OMR_DIST:-openmptcprouter}
OMR_HOST=${OMR_HOST:-$(curl -sS ifconfig.co)}
OMR_PORT=${OMR_PORT:-8000}
OMR_REPO=${OMR_REPO:-http://$OMR_HOST:$OMR_PORT/release}
OMR_KEEPBIN=${OMR_KEEPBIN:-no}
OMR_IMG=${OMR_IMG:-yes}
OMR_UEFI=${OMR_UEFI:-yes}
OMR_TARGET=${OMR_TARGET:-x86_64}
OMR_TARGET_CONFIG="config-$OMR_TARGET"

OMR_FEED_URL="${OMR_FEED_URL:-https://github.com/ysurac/openmptcprouter-feeds}"
OMR_FEED_SRC="${OMR_FEED_SRC:-master}"

if [ ! -f "$OMR_TARGET_CONFIG" ]; then
	echo "Target $OMR_TARGET not found !"
	exit 1
fi

#_get_repo source https://github.com/ysurac/openmptcprouter-source "master"
_get_repo "$OMR_TARGET/source" https://github.com/lede-project/source.git "master"
_get_repo feeds/packages https://github.com/openwrt/packages "master"
#_get_repo feeds/luci https://github.com/openwrt/luci "lede-17.01"
_get_repo feeds/luci https://github.com/openwrt/luci "master"

if [ -z "$OMR_FEED" ]; then
	OMR_FEED=feeds/openmptcprouter
	_get_repo "$OMR_FEED" "$OMR_FEED_URL" "$OMR_FEED_SRC"
fi

if [ -n "$1" ] && [ -f "$OMR_FEED/$1/Makefile" ]; then
	OMR_DIST=$1
	shift 1
fi

if [ "$OMR_KEEPBIN" = "no" ]; then 
	rm -rf "$OMR_TARGET/source/bin"
fi
rm -rf "$OMR_TARGET/source/files" "$OMR_TARGET/source/tmp"
cp -rf root/* "$OMR_TARGET/source"

cat >> "$OMR_TARGET/source/package/base-files/files/etc/banner" <<EOF
-----------------------------------------------------
 PACKAGE:     $OMR_DIST
 VERSION:     $(git -C "$OMR_FEED" describe --tag --always)

 BUILD REPO:  $(git config --get remote.origin.url)
 BUILD DATE:  $(date -u)
-----------------------------------------------------
EOF

cat > "$OMR_TARGET/source/feeds.conf" <<EOF
src-link packages $(readlink -f feeds/packages)
src-link luci $(readlink -f feeds/luci)
src-link openmptcprouter $(readlink -f "$OMR_FEED")
EOF

cat "$OMR_TARGET_CONFIG" config -> "$OMR_TARGET/source/.config" <<EOF
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="$OMR_DIST"
CONFIG_VERSION_REPO="$OMR_REPO"
CONFIG_VERSION_NUMBER="$(git -C "$OMR_FEED" describe --tag --always)"
CONFIG_PACKAGE_${OMR_DIST}-full=y
EOF

if [ "$OMR_IMG" = "yes" ] && [ "$OMR_TARGET" = "x86_64" ]; then 
	echo 'CONFIG_VDI_IMAGES=y' >> "$OMR_TARGET/source/.config"
	echo 'CONFIG_VMDK_IMAGES=y' >> "$OMR_TARGET/source/.config"
fi


cd "$OMR_TARGET/source"

echo "Checking if UEFI patch is set or not"
if [ "$OMR_UEFI" = "yes" ] && [ "$OMR_TARGET" = "x86_64" ]; then 
	if ! patch -Rf -N -p1 -s --dry-run < ../../patches/uefi.patch; then
		patch -N -p1 -s < ../../patches/uefi.patch
	fi
else
	if ! patch -Nf -p1 -s --dry-run < ../../patches/uefi.patch; then
		patch -N -R -p1 -s < ../../patches/uefi.patch
	fi
fi
echo "Done"

echo "Set to kernel 4.9 for all arch"
find target/linux/ -type f -name Makefile -exec sed -i 's%KERNEL_PATCHVER:=4.14%KERNEL_PATCHVER:=4.9%g' {} \;
echo "Done"

echo "Update feeds index"
cp .config .config.keep
scripts/feeds clean
scripts/feeds update -a
scripts/feeds install -a -d y -f -p openmptcprouter
cp .config.keep .config
echo "Done"

echo "Building $OMR_DIST for the target $OMR_TARGET"
make defconfig
make "$@"
echo "Done"
