#!/bin/sh

die () {
	echo "$*" >&2
	exit 1
}

git_git_dir=/usr/src/git/.git &&
build_extra_dir=/usr/src/build-extra &&
artifacts_dir= &&
release_branch=main &&
snapshot_version=t &&
while case "$1" in
--git-dir=*) git_git_dir="${1#*=}";;
--build-extra-dir=*) build_extra_dir="${1#*=}";;
--artifacts-dir=*) artifacts_dir="${1#*=}";;
--release-branch=*) release_branch="${1#*=}";;
--full|--full-version|--no-snapshot|--no-snapshot-version) snapshot_version=;;
*) break;;
esac; do shift; done ||
die "Could not parse command-line options: $*"

test $# = 1 ||
die "Usage: $0 [--no-snapshot-version] [--git-dir=<dir>] [--build-extra-dir=<dir>] [--artifacts-dir=<dir>] <git-rev>"

git_rev="$1"

test "refs/heads/$release_branch" = "$(git -C "$build_extra_dir" symbolic-ref HEAD)" ||
die "Need the current branch in '$build_extra_dir' to be '$release_branch'"

# This function was copied from `git-update-git-for-windows` in
# the `mingw-w64-git-extra` package.
version_compare () {
        a="$1"
        b="$2"

        while true
        do
                test -n "$b" || { echo 1; return; }
                test -n "$a" || { echo -1; return; }

                # Get the first numbers (if any)
                a1="$(expr "$a" : '^\([0-9]*\)')"; a="${a#$a1}"
                b1="$(expr "$b" : '^\([0-9]*\)')"; b="${b#$b1}"

                if test -z "$b1"
                then
                        test -z "$a1" || { echo 1; return; }
                        a1=0
                        b1=0
                fi
                test -n "$a1" || { echo -1; return; }
                test $a1 -le $b1 || { echo 1; return; }
                test $b1 -le $a1 || { echo -1; return; }

                # Skip non-numeric prefixes
                a1="$(expr "$a" : '^\([^0-9]\+\)')"; a="${a#$a1}"
                b1="$(expr "$b" : '^\([^0-9]\+\)')"; b="${b#$b1}"

                case "$a1,$b1" in
                [.-]rc,[.-]rc) ;; # both are -rc versions
                [.-]rc,*) echo -1; return;;
                *,[.-]rc) echo 1; return;;
                esac
        done
}

mkdir -p "$artifacts_dir" &&
if test -n "$snapshot_version"
then
	tag_name="$(git --git-dir "$git_git_dir" describe --match 'v[0-9]*' --exclude='*-[0-9]*' "$git_rev")-$(date +%Y%m%d%H%M%S)" &&
	tag_message="Snapshot build" &&
	release_note="Snapshot of $(git --git-dir "$git_git_dir" show -s --pretty='tformat:%h (%s, %ad)' --date=short "$git_rev")" &&
	(cd "$build_extra_dir" && node ./add-release-note.js --commit feature "$release_note") &&
	display_version=${tag_name#v} &&
	ver=prerelease-${tag_name#v}
else
	if ! type w3m
	then
		die "Need 'w3m' to render release notes"
	fi

	desc="$(git --git-dir "$git_git_dir" describe --match 'v[0-9]*[0-9]' --exclude='*-[0-9]*' --exclude='*.windows.*' "$git_rev")" &&
	base_tag=${desc%%-[1-9]*} &&
	desc2="$(git --git-dir "$git_git_dir" describe --match 'v[0-9]*[0-9]' --exclude='*-[0-9]*' "$git_rev")" &&
	base_tag2=${desc2%%-[1-9]*} &&
	# If there is a candidate Git tag _and_ a candidate Git for Windows tag, compare versions
	if test "$base_tag" != "$base_tag2" && test $(version_compare "$base_tag" "$base_tag2") -lt 0
	then
		base_tag="$base_tag2"
	fi &&
	case "$base_tag" in
	"$desc") die "Revision '$git_rev' already tagged as $base_tag";;
	*.windows.*)
		tag_name=${base_tag%.windows.*}.windows.$((${base_tag##*.windows.}+1)) &&
		display_version="${base_tag%.windows.*}(${tag_name##*.windows.})" &&
		display_version=${display_version#v}
		;;
	*)
		tag_name=$base_tag.windows.1 &&
		display_version=${base_tag#v} &&
		if ! grep -q "^\\* Comes with \\[Git $base_tag\\]" "$build_extra_dir"/ReleaseNotes.md
		then
			url=https://github.com/git/git/blob/$base_tag &&
			case "$base_tag" in
			v2.43.7|v2.44.4|v2.45.4|v2.46.4|v2.47.3|v2.48.2|v2.49.1) ext=txt;;
			*) ext=adoc;;
			esac &&
			adoc="$(echo "${base_tag#v}" | sed 's/-rc[0-9]*$//').$ext" &&
			url=$url/Documentation/RelNotes/$adoc &&
			release_note="Comes with [Git $base_tag]($url)." &&
			(cd "$build_extra_dir" && node ./add-release-note.js --commit feature "$release_note")
		fi
		;;
	esac &&
	ver="$(echo "${tag_name#v}" | sed -n \
		's/^\([0-9]*\.[0-9]*\.[0-9]*\(-rc[0-9]*\)\?\)\.windows\(\.1\|\(\.[0-9]*\)\)$/\1\4/p')" &&

	release_date="$(LC_ALL=C date +"%B %-d %Y" |
		sed -e 's/\( [2-9]\?[4-90]\| 1[0-9]\) /\1th /' \
			-e 's/1 /1st /' -e 's/2 /2nd /' -e 's/3 /3rd /'
	)" &&
	sed -i -e "1s/.*/# Git for Windows v$display_version Release Notes/" \
		-e "2s/.*/Latest update: $release_date/" \
		"$build_extra_dir"/ReleaseNotes.md &&
	git -C "$build_extra_dir" commit -s \
		-m "Prepare release notes for v$display_version" ReleaseNotes.md &&

	raw_notes="$(sed -n "/^## Changes since/,\${:1;p;n;/^## Changes/q;b1}" \
			<"$build_extra_dir"/ReleaseNotes.md)" &&
	notes="$(echo "$raw_notes" |
		sed '1s/^## Changes since.*/&:/' |
		markdown |
		LC_CTYPE=C w3m -dump -cols 72 -T text/html)" &&
	tag_message="$(printf "%s\n\n%s" \
		"$(sed -n '1s/.*\(Git for Windows v[^ ]*\).*/\1/p' \
		<"$build_extra_dir"/ReleaseNotes.md)" "$notes")" &&

	cat >"$artifacts_dir"/release-notes-$display_version <<-EOF &&
	${raw_notes#\## }

	Filename | SHA-256
	-------- | -------
	@@CHECKSUMS@@
	EOF

	case "$display_version" in
	prerelease-*)
		url=https://gitforwindows.org/git-snapshots/
		;;
	*-rc*)
		url=https://github.com/git-for-windows/git/releases/tag/$tag_name
		;;
	*)
		url=https://gitforwindows.org/
		;;
	esac &&
	cat >"$artifacts_dir"/announce-$display_version <<-EOF
	From ${tag_name#v} Mon Sep 17 00:00:00 2001
	From: $(git var GIT_COMMITTER_IDENT | sed -e 's/>.*/>/')
	Date: $(date -R)
	To: git@vger.kernel.org, git-packagers@googlegroups.com
	Subject: [ANNOUNCE] Git for Windows $display_version
	Content-Type: text/plain; charset=UTF-8
	Content-Transfer-Encoding: 8bit
	MIME-Version: 1.0
	Fcc: Sent

	Dear Git users,

	I hereby announce that Git for Windows $display_version is available from:

	    $url

	Changes ${tag_message#*Changes }

	@@CHECKSUMS@@

	Ciao,
	$(git var GIT_COMMITTER_IDENT | sed -e 's/ .*//')
	EOF
fi &&

echo "$ver" >"$artifacts_dir"/ver &&
echo "$display_version" >"$artifacts_dir"/display_version &&
echo "$tag_name" >"$artifacts_dir"/next_version &&
echo "$tag_message" >"$artifacts_dir"/tag-message &&
git --git-dir "$git_git_dir" rev-parse --verify "$git_rev"^0 >"$artifacts_dir"/git-commit-oid &&

git --git-dir "$git_git_dir" tag $(test -z "$GPGKEY" || echo " -s") -m "$tag_message" "$tag_name" "$git_rev" &&
git --git-dir "$git_git_dir" bundle create "$artifacts_dir"/git.bundle origin/$release_branch.."$tag_name" &&

git -C "$build_extra_dir" bundle create "$artifacts_dir"/build-extra.bundle origin/$release_branch..$release_branch