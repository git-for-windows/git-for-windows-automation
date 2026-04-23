#!/bin/sh

# Azure Artifact Signing wrapper for use as `git signtool`.
#
# This replaces the osslsigncode-based signtool.sh from build-extra,
# using the pre-built sign tool from
# https://github.com/dscho/prebuilt-dotnet-sign-tool instead.
#
# It expects the Azure CLI to be authenticated (via `azure/login` with
# OIDC) and the following environment variable:
#   AZURE_SIGNING_OPTS - command-line arguments for the sign tool, e.g.
#     --artifact-signing-endpoint <url>
#     --artifact-signing-account <account>
#     --artifact-signing-certificate-profile <profile>

die () {
	echo "$*" >&2
	exit 1
}

# Locate the sign tool, downloading it if necessary
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGN_TOOL_DIR="$SCRIPT_DIR/.sign-tool"
sign_exe="$SIGN_TOOL_DIR/sign"

if ! test -x "$sign_exe" && ! test -x "$sign_exe.exe"
then
	echo "Downloading pre-built sign tool..." >&2
	sysdir="${SYSTEMROOT:-${WINDIR:-/proc/fake-non-existent}}/System32" &&
	mkdir -p "$SIGN_TOOL_DIR" &&
	url="https://github.com/dscho/prebuilt-dotnet-sign-tool/releases/latest/download/sign-tool.zip" &&
	zip_path="$SIGN_TOOL_DIR/sign-tool.zip" &&
	"$sysdir/curl.exe" -sLo "$(cygpath -aw "$zip_path")" "$url" &&
	"$sysdir/tar.exe" -xf "$(cygpath -aw "$zip_path")" -C "$(cygpath -aw "$SIGN_TOOL_DIR")" &&
	rm -f "$zip_path" ||
	die "Failed to download and extract sign tool"

	test -x "$sign_exe" || test -x "$sign_exe.exe" ||
	die "sign.exe not found in $SIGN_TOOL_DIR after extraction"
fi

s () {
	"$sign_exe" code artifact-signing \
		"$1" \
		--azure-credential-type azure-cli \
		--description "Git for Windows" \
		--description-url "https://gitforwindows.org" \
		-v information \
		$AZURE_SIGNING_OPTS
}

for f in "$@"
do
	s "$f" || {
		echo "Retrying after 5 seconds..." >&2
		sleep 5 && s "$f" || {
			sleep 10 && s "$f" || {
				sleep 20 && s "$f" || {
					sleep 40 && s "$f"
				}
			}
		}
	} || exit
done
