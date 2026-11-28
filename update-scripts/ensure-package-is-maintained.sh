#!/bin/sh

test $# = 1 || {
	echo "Usage: $0 <package-to-build-or-update>" >&2
	exit 1
}

case "$1" in
bash|curl|git-extra|git-for-windows-keyring|\
msys2-runtime|msys2-runtime-3.3|openssh|openssl|pkgconf|\
mingw-w64-busybox|mingw-w64-curl|mingw-w64-cv2pdb|mingw-w64-git|\
mingw-w64-git-credential-manager|mingw-w64-git-lfs|mingw-w64-git-sizer|\
mingw-w64-openssl|mingw-w64-wintoast|mingw-w64-xpdf-tools)
	;;
*)
	echo "::error::Git for Windows does not maintain '$1' downstream." >&2
	exit 1
	;;
esac
