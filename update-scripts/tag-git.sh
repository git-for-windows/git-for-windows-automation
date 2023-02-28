#!/bin/sh

die () {
	echo "$*" >&2
	exit 1
}

git_git_dir=/usr/src/git/.git &&
build_extra_dir=/usr/src/build-extra &&
artifacts_dir= &&
while case "$1" in
--git-dir=*) git_git_dir="${1#*=}";;
--build-extra-dir=*) build_extra_dir="${1#*=}";;
--artifacts-dir=*) artifacts_dir="${1#*=}";;
*) break;;
esac; do shift; done

test $# = 1 ||
die "Usage: $0 [--git-dir=<dir>] [--build-extra-dir=<dir>] [--artifacts-dir=<dir>] <git-rev>"

git_rev="$1"

tag_name="$(git -C "$git_git_dir" describe --match 'v[0-9]*' "$git_rev")-$(date +%Y%m%d%H%M%S)" &&

mkdir -p "$artifacts_dir" &&
echo "prerelease-${tag_name#v}" >"$artifacts_dir"/ver &&
echo "${tag_name#v}" >"$artifacts_dir"/display_version &&
echo "$tag_name" >"$artifacts_dir"/next_version &&

git -C "$git_git_dir" tag $(test -z "$GPGKEY" || echo " -s") -m "Snapshot build" "$tag_name" "$git_rev" &&
git -C "$git_git_dir" bundle create "$artifacts_dir"/git.bundle origin/main.."$tag_name" &&
release_note=$(git -C "$git_git_dir" show -s  --pretty='tformat:%h (%s, %ad)' --date=short "$git_rev") &&

cd "$build_extra_dir" &&
node ./add-release-note.js --commit feature "Snapshot of $release_note" &&
git bundle create "$artifacts_dir"/build-extra.bundle origin/main..main