#!/bin/sh

# Azure Artifact Signing wrapper for use as `git signtool`.
#
# This replaces the osslsigncode-based signtool.sh from build-extra,
# using the pre-built sign tool from
# https://github.com/dscho/prebuilt-dotnet-sign-tool instead.
#
# It expects the following environment variables:
#   AZURE_CLIENT_ID                      - Azure AD app client ID
#   AZURE_CLIENT_SECRET                  - Azure AD app client secret
#   AZURE_TENANT_ID                      - Azure AD tenant ID
#   AZURE_SIGNING_ENDPOINT               - Azure Artifact Signing endpoint URL
#   AZURE_SIGNING_ACCOUNT                - Azure Artifact Signing account name
#   AZURE_SIGNING_CERTIFICATE_PROFILE    - certificate profile name

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
		--description "Git for Windows" \
		--description-url "https://gitforwindows.org" \
		-v information \
		--artifact-signing-endpoint "$AZURE_SIGNING_ENDPOINT" \
		--artifact-signing-account "$AZURE_SIGNING_ACCOUNT" \
		--artifact-signing-certificate-profile "$AZURE_SIGNING_CERTIFICATE_PROFILE"
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
