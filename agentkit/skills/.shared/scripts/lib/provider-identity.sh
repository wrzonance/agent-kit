#!/usr/bin/env bash
# Shared exact forge-provider identity predicates for shell callers and jq.
# shellcheck disable=SC2034  # consumed by the jq callers that source this file

readonly PROVIDER_IDENTITY_JQ='
  def is_coderabbit_login:
    . == "coderabbitai" or . == "coderabbitai[bot]";
  def is_code_quality_login:
    . == "github-code-quality" or . == "github-code-quality[bot]";
  def known_provider_login:
    is_coderabbit_login or is_code_quality_login;
'

is_coderabbit_login() {
    case ${1,,} in
        coderabbitai|coderabbitai\[bot\]) return 0;;
        *) return 1;;
    esac
}

is_code_quality_login() {
    case ${1,,} in
        github-code-quality|github-code-quality\[bot\]) return 0;;
        *) return 1;;
    esac
}
