#!/bin/sh

if [ -z "$CIRRUS_RELEASE" ]; then
	CIRRUS_RELEASE=$CIRRUS_TAG
fi

if [ -z "$CIRRUS_RELEASE" ]; then
	echo "Not a release. No need to deploy!"
	# XXX
	CIRRUS_RELEASE="v0.1"
	# XXX exit 0
fi

if [ -z "$GITHUB_TOKEN" ]; then
	echo "Please provide GitHub access token via GITHUB_TOKEN environment variable!"
	exit 1
fi

file_content_type="application/octet-stream"
files_to_upload=(
	rpi/rpi.img.xz
	rpi/rpi.be.zfs.xz
)

for fpath in $files_to_upload; do
	echo "Uploading $fpath..."
	name=$(basename "$fpath")
	url_to_upload="https://uploads.github.com/repos/$CIRRUS_REPO_FULL_NAME/releases/$CIRRUS_RELEASE/assets?name=$name"
	curl -X POST \
	    --data-binary @$fpath \
	    --header "Authorization: token $GITHUB_TOKEN" \
	    --header "Content-Type: $file_content_type" \
	    $url_to_upload
done
