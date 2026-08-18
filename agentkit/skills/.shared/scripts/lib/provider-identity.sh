#!/usr/bin/env bash
# Shared exact forge-provider identity predicates for shell callers and jq.
# shellcheck disable=SC2034  # consumed by the jq callers that source this file

PROVIDER_IDENTITY_DIR=${BASH_SOURCE[0]%/*}
[[ $PROVIDER_IDENTITY_DIR != "${BASH_SOURCE[0]}" ]] || PROVIDER_IDENTITY_DIR=.
# shellcheck source=review-provider-catalog.sh
source "$PROVIDER_IDENTITY_DIR/review-provider-catalog.sh"

readonly PROVIDER_IDENTITY_JQ='
  def is_coderabbit_login:
    . == "coderabbitai" or . == "coderabbitai[bot]";
  def is_code_quality_login:
    . == "github-code-quality" or . == "github-code-quality[bot]";
  def known_provider_login:
    is_coderabbit_login or is_code_quality_login;
'

is_coderabbit_login() {
    [[ $(review_provider_from_login "$1" 2>/dev/null) == coderabbit ]]
}

is_code_quality_login() {
    [[ $(review_provider_from_login "$1" 2>/dev/null) == github-code-quality ]]
}
