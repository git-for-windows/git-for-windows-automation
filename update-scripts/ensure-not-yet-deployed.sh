#!/bin/bash

die () {
	echo "$*" >&2
	exit 1
}

set -x
architecture=
while case "$1" in
--architecture=*)
	architecture=${1#*=}
	if test aarch64 = "$architecture"
	then
		MINGW_PACKAGE_PREFIX=mingw-w64-clang-aarch64
	else
		MINGW_PACKAGE_PREFIX=mingw-w64-$architecture
	fi
	;;
-*) die "Unhandled option: '$1'";;
*) break;
esac; do shift; done

test $# = 1 ||
die "Usage: $0 <directory-containing-PKGBUILD>"

cd "$1" ||
die "Could not switch to '$1'"

. ./PKGBUILD ||
die "No/invalid PKGBUILD in '$1'?"

# Via `. PKGBUILD`, the `$arch` variable is set. For MINGW packages, it must be
# `any` (so that e.g. i686 packages can be installed into an x86_64 setup), but
# for MSYS packages, the variable's value is a Bash array, and `$arch` refers to
# the first array item (typically `i686`).
#
# We want to use `$arch` below to construct the exact file name of the package,
# and therefore need to be careful when `--architecture` specifies an
# architecture other than the first item of the `$arch` array: The i686 variant
# of the package might already have deployed successfully while the x86_64
# variant might not have, and we do _not_ want this script to prevent the latter
# from being deployed.
#
# To that end, if `--architecture` was specified _and_ if `$arch` isn't `any`,
# let's assume that `$arch` refers to a Bash array and override it to refer to
# the intended architecture.

case "$arch,$architecture" in
any,*|*,) ;;
*) arch="$architecture";;
esac &&

# Git for Windows' Pacman repository offers the packages in subdirectories that
# correspond to the architecture. For i686/x86_64 MINGW packages (i.e. when
# `--architecture` specifies an empty value), we assume that this script is run
# in an x86_64 setup and therefore use that subdirectory.
#
# Note: The Pacman repository is hosted in an Azure Blobs container where
# directory names cannot contain underscores, hence we needed to replace that
# character with a dash.

subdir="${architecture:-$arch}" &&
case "$subdir" in
any|x86_64) subdir=x86-64;;
esac &&

case "$pkgname" in
git-extra)
	pkgname="$MINGW_PACKAGE_PREFIX-$pkgname"
	arch=any
esac &&

# See whether the package file was already uploaded to Git for Windows' Pacman
# repository. Error out if it was.

file="$pkgname-${epoch:+$epoch~}$pkgver-$pkgrel-$arch.pkg.tar.xz" &&
url="https://wingit.blob.core.windows.net/$subdir/$file" &&
echo "Looking at URL '$url'" >&2 &&
if curl -sfI "$url"
then
	die "Already deployed: '$file'"
fi &&
echo "$file not yet deployed, as expected" >&2