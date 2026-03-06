#!/bin/sh
set -eu

# Edit variables below to configure the build
COMPONENTS="api classifier clusterd dlpd expurgate policyd rated sasid savdid smtpd web"
TARGET_DISTRO="rocky-9"
PUSH_TO_ACR="true"
ACR_NAME="apprelaypoccontreg"

# Internal state (do not edit)
RESOLVED_IMAGE_TAG=""
RESOLVED_BUILD_CONTEXT=""
BUILT_IMAGE_TAGS=""
ACR_LOGIN_SERVER="${ACR_NAME:+$ACR_NAME.azurecr.io}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

restore_tty() {
	stty echo 2>/dev/null || true
}

trap 'restore_tty' EXIT INT TERM

prompt_repo_user() {
	while [ -z "${HALON_REPO_USER:-}" ]; do
		printf "Enter HALON_REPO_USER: "
		IFS= read -r HALON_REPO_USER || exit 1
		if [ -z "$HALON_REPO_USER" ]; then
			echo "HALON_REPO_USER cannot be empty." >&2
		fi
	done
	export HALON_REPO_USER
}

prompt_repo_pass() {
	while [ -z "${HALON_REPO_PASS:-}" ]; do
		printf "Enter HALON_REPO_PASS: "

		if [ -t 0 ] && command -v stty >/dev/null 2>&1; then
			stty -echo
			IFS= read -r HALON_REPO_PASS || {
				stty echo
				exit 1
			}
			stty echo
			printf "\n"
		else
			IFS= read -r HALON_REPO_PASS || exit 1
		fi

		if [ -z "$HALON_REPO_PASS" ]; then
			echo "HALON_REPO_PASS cannot be empty." >&2
		fi
	done
	export HALON_REPO_PASS
}

resolve_component_build_settings() {
	component="$1"
	component_dir="$REPO_ROOT/$component"
	readme="$component_dir/README.md"

	if [ ! -f "$readme" ]; then
		echo "ERROR: Missing README: $readme" >&2
		return 1
	fi

	RESOLVED_IMAGE_TAG=$(sed -n 's/^docker build -t \([^ ]*:[0-9][^ ]*\) .*/\1/p' "$readme" | head -n 1)
	if [ -z "$RESOLVED_IMAGE_TAG" ]; then
		echo "ERROR: No versioned image tag found in $readme" >&2
		echo "Expected a line like: docker build -t halon/$component:<version> ..." >&2
		return 1
	fi

	RESOLVED_BUILD_CONTEXT="$component_dir"

	# Some components (for example smtpd) document images/<distro> as build context.
	readme_context=$(sed -n 's/^[[:space:]]*\(images\/[^[:space:]]*\)[[:space:]]*$/\1/p' "$readme" | head -n 1)
	case "$readme_context" in
		images/*)
			RESOLVED_BUILD_CONTEXT="$component_dir/images/$TARGET_DISTRO"
			;;
	esac

	if [ ! -d "$RESOLVED_BUILD_CONTEXT" ]; then
		echo "ERROR: Missing build context directory: $RESOLVED_BUILD_CONTEXT" >&2
		return 1
	fi
}

ensure_azure_login() {
	if ! command -v az >/dev/null 2>&1; then
		echo "ERROR: Azure CLI (az) is required when PUSH_TO_ACR=true." >&2
		return 1
	fi

	if az account show >/dev/null 2>&1; then
		return 0
	fi

	echo "No active Azure session detected. Starting interactive az login..."
	az login || {
		echo "ERROR: Azure login failed." >&2
		return 1
	}
}

setup_acr_push() {
	if [ "$PUSH_TO_ACR" != "true" ]; then
		return 0
	fi

	if [ -z "$ACR_NAME" ]; then
		echo "ERROR: ACR_NAME must be set when PUSH_TO_ACR=true." >&2
		return 1
	fi

	if ! ensure_azure_login; then
		return 1
	fi

	echo "Authenticating Docker with ACR: $ACR_NAME"
	az acr login --name "$ACR_NAME" || {
		echo "ERROR: Failed to authenticate Docker to ACR: $ACR_NAME" >&2
		return 1
	}
}

record_built_image() {
	image_tag="$1"

	if [ -z "$BUILT_IMAGE_TAGS" ]; then
		BUILT_IMAGE_TAGS="$image_tag"
	else
		BUILT_IMAGE_TAGS="$BUILT_IMAGE_TAGS
$image_tag"
	fi
}

push_built_images_to_acr() {
	if [ "$PUSH_TO_ACR" != "true" ]; then
		return 0
	fi

	echo "Pushing built images to $ACR_LOGIN_SERVER"
	printf '%s\n' "$BUILT_IMAGE_TAGS" | while IFS= read -r local_tag; do
		if [ -z "$local_tag" ]; then
			continue
		fi

		remote_tag="$ACR_LOGIN_SERVER/$local_tag"
		echo "Tagging $local_tag as $remote_tag"
		docker tag "$local_tag" "$remote_tag"
		echo "Pushing $remote_tag"
		docker push "$remote_tag"
	done
}

prompt_repo_user
prompt_repo_pass

if ! setup_acr_push; then
	exit 1
fi

for component in $COMPONENTS; do
	component_dir="$REPO_ROOT/$component"
	dockerfile="$component_dir/images/$TARGET_DISTRO/Dockerfile"

	if [ ! -f "$dockerfile" ]; then
		echo "ERROR: Missing Dockerfile: $dockerfile" >&2
		exit 1
	fi

	if ! resolve_component_build_settings "$component"; then
		echo "ERROR: Failed to resolve README build settings for component: $component" >&2
		exit 1
	fi

	image_tag="$RESOLVED_IMAGE_TAG"
	build_context="$RESOLVED_BUILD_CONTEXT"

	echo "Building $component as $image_tag"
	docker build -t "$image_tag" -f "$dockerfile" \
		--build-arg "HALON_REPO_USER=$HALON_REPO_USER" \
		--build-arg "HALON_REPO_PASS=$HALON_REPO_PASS" \
		--platform=linux/amd64 \
		"$build_context"

	record_built_image "$image_tag"
done

if ! push_built_images_to_acr; then
	exit 1
fi

echo "All $TARGET_DISTRO image builds completed."
