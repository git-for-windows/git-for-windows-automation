#!/bin/sh

die () {
  echo "$*" >&2
  exit 1
}

dry_run=
mingit=
while case "$1" in
--dry-run|-n) dry_run=1;;
--mingit) mingit=1;;
-*) die "Unknown option: $1";;
*) break;;
esac; do shift; done

test $# = 1 ||
die "Usage: $0 [--dry-run] [--mingit] <version> # e.g. 2.39.1"

version=${1#v}
if test -z "$mingit"
then
	case "$version" in
	*.*.*.windows.*)
		# major.minor.patch.windows.extra
		previous_version_prefix=${version%.windows.*}
		version="${version%.windows.*}.${version##*.windows.}"
		;;
	*.*.*\(*)
		# major.minor.patch(extra)
		previous_version_prefix=${version%(*}
		version="${version%(*}.${version##*(}"
		version=${version%)}
		;;
	*[!0-9.]*|*..*|.*|*.) die "Invalid version: '$version'";;
	*.*.*.*)
		# major.minor.patch.extra
		v0="${version#*.*.*.}"
		previous_version_prefix=${version%.$v0}
		;;
	*.*.*) previous_version_prefix=${version%.*}.$((${version##*.}-1));; # major.minor.patch
	*) die "Invalid version: '$version'";;
	esac
	branch_name=git-$version
else
	previous_version_prefix="$(expr "$version" : '\([0-9]\+\.[0-9]\+\)\.\{0,1\}[0-9]*$')"
	test -n "$previous_version_prefix" || die "Invalid version: '$version'"
	branch_name=mingit-$previous_version_prefix.x-releases
fi
grep_version_regex="$(echo "$previous_version_prefix" | sed 's/\./\\\\&/g')"

handle_repo () {
	name="$1"
	path="$2"
	args="$3"

	echo "### Handling $name ###" &&

	if test -e "$path/.git"
	then
		git_dir="$path/.git"
		main_refspec="refs/remotes/origin/main:refs/heads/main"
	else
		# To allow for running this script on Linux/macOS, fall back to cloning to pwd
		git_dir=${path##*/}.git &&
		if test ! -d "$git_dir"
		then
			# We only need a partial clone
			git clone --bare --filter=blob:none \
				https://github.com/git-for-windows/$name "$git_dir"
		fi
		main_refspec="refs/heads/main:refs/heads/main"
	fi &&

	# ensure that the `embargoed-git-for-windows-builds` remote is set
	remote_url=https://github.com/embargoed-git-for-windows-builds/$name &&
	case "$(git --git-dir "$git_dir" remote show -n embargoed-git-for-windows-builds)" in
	*"Fetch URL: $remote_url"*"Push  URL: $remote_url"*) ;; # okay
	*) git --git-dir "$git_dir" remote add embargoed-git-for-windows-builds $remote_url;;
	esac &&

	# if `embargoed-git-for-windows-builds` already has the branch, everything's fine already
	revision=$(git --git-dir "$git_dir" ls-remote embargoed-git-for-windows-builds refs/heads/$branch_name | cut -f 1) &&
	if test -n "$revision"
	then
		echo "$name already has $branch_name @$revision"
	else
		git --git-dir "$git_dir" fetch origin main &&
		revision="$(eval git --git-dir "\"$git_dir\"" rev-list -1 FETCH_HEAD $args)" &&
		if test -z "$revision"
		then
			die "No matching revision for $args in $name"
		fi &&
		echo "Creating $branch_name in $name @$revision" &&
		push_ref_spec="$revision:refs/heads/$branch_name $main_refspec" &&
		if test -n "$dry_run"
		then
			git --git-dir "$git_dir" show -s "$revision" &&
			echo "Would call 'git push embargoed-git-for-windows-builds $push_ref_spec'"
		else
			echo "git push embargoed-git-for-windows-builds $push_ref_spec" &&
			git --git-dir "$git_dir" push embargoed-git-for-windows-builds $push_ref_spec
		fi
	fi
}

handle_repo git-sdk-32 /c/git-sdk-32 \
	"\"--grep=mingw-w64-i686-git \".*\" -> $grep_version_regex\" -- cmd/git.exe" &&
handle_repo git-sdk-64 /c/git-sdk-64 \
	"\"--grep=mingw-w64-x86_64-git \".*\" -> $grep_version_regex\" -- cmd/git.exe" &&
handle_repo git-sdk-arm64 /c/git-sdk-arm64 \
	"\"--grep=mingw-w64-clang-aarch64-git \".*\" -> $grep_version_regex\" -- cmd/git.exe" &&
handle_repo build-extra /usr/src/build-extra \
	"-- versions/package-versions-$previous_version_prefix\\*-MinGit.txt" &&
handle_repo MINGW-packages /usr/src/MINGW-packages \
	"\"--grep=mingw-w64-git: new version .v$grep_version_regex\" -- mingw-w64-git/PKGBUILD"
