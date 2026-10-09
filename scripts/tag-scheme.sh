# shellcheck shell=bash
# Single source of truth for the published image name and tag suffix, sourced
# by next-tag.sh and release-plan.sh. Tags are <upstream-tag>-${TAG_SUFFIX}.<N>.
# Renaming the scheme? Change it here, then the docs and IMAGE in ci.yml
# (static-check.sh checks that ci.yml agrees with IMAGE_REPO).
# shellcheck disable=SC2034 # used by the scripts that source this file
IMAGE_REPO=louisremi/deepseek-harness-augmented
TAG_SUFFIX=augmented
