# shellcheck shell=bash
# Single source of truth for the published image name, tag suffix and
# variants, sourced by next-tag.sh and release-plan.sh.
#
# Each publish pushes one immutable tag per variant, all sharing one counter N:
#   default    <X-rN>-augmented.<N>                (the release name)
#   bwrap      <X-rN>-bwrap.<B>-augmented.<N>
#   ungoogled  <X-rN>-ungoogled.<U>-augmented.<N>
# where <X-rN>[-<variant>.<M>] is the upstream tag of that variant's base
# (ARG BASE_<VARIANT> in the Dockerfile), plus one moving tag per variant.
# Renaming the scheme? Change it here, then the docs and IMAGE in ci.yml
# (static-check.sh checks that ci.yml agrees with IMAGE_REPO).
# shellcheck disable=SC2034 # used by the scripts that source this file
IMAGE_REPO=louisremi/deepseek-harness-augmented
TAG_SUFFIX=augmented
VARIANTS=(default bwrap ungoogled)
declare -A MOVING_TAGS=([default]=latest [bwrap]=bwrap [ungoogled]=ungoogled)
