#!/usr/bin/env bash
set -euo pipefail

workdir="$(mktemp -d "${TMPDIR:-/tmp}/takeform-component-sources.XXXXXX")"

cleanup() {
	rm -rf "$workdir"
}
trap cleanup EXIT

inspect() {
	local repo="$1"
	local sha="$2"
	local files="$3"
	local destination="$workdir/${repo//\//_}"

	echo "repo: $repo"
	echo "sha: $sha"
	git init --quiet "$destination"
	git -C "$destination" fetch --quiet --depth=1 "https://github.com/$repo.git" "$sha"
	git -C "$destination" cat-file -e "$sha^{commit}"

	local file
	IFS=',' read -r -a inspected <<< "$files"
	for file in "${inspected[@]}"; do
		git -C "$destination" cat-file -e "$sha:$file"
		echo "path: $file"
	done
}

inspect "heygen-com/hyperframes-vercel-template" "e577e0a33ef4a9fde9bf6b51b8204392391d6871" "README.md,package.json,lib/preview.test.ts,LICENSE"
inspect "heygen-com/hyperframes-cloudflare-template" "310f06d47a783d3a73e54d0c6978ad8082ebdccc" "README.md,package.json,src/lib/generation.test.ts,LICENSE"
inspect "heygen-com/hyperframes-modal-template" "88bb269e19e7ac9acbf55941ac8c18e214a8de58" "README.md,pyproject.toml,LICENSE"
inspect "heygen-com/liveavatar-web-sdk" "1e64e060c4e35b3274a7ccafc97e66053f506897" "packages/js-sdk/README.md,packages/js-sdk/package.json,packages/js-sdk/src/LiveAvatarSession/LiveAvatarSession.test.ts,packages/js-sdk/LICENSE"
inspect "heygen-com/liveavatar-gpt-live-demos" "daa8cc92ab34c75c0bbed201c94fb98360da2179" "README.md,package.json,LICENSE,THIRD_PARTY_NOTICES.md"
inspect "heygen-com/TAVR" "42b9935ac502d1d5fb9be220fd1f9c0ff5ee2a9f" "README.md,LICENSE"
inspect "OpenCut-app/opencut-classic" "cf5e79e919144200294fb9fed22a222592a0aeea" "README.md,package.json,apps/web/src/timeline/placement/__tests__/resolve.test.ts,apps/web/src/retime/__tests__/split.test.ts,LICENSE"
