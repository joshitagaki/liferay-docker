#!/bin/bash

source _liferay_common.sh
source _releases_json.sh

function assert_equals {
    if [ "${1}" = 1 ] || [ "${1}" = true ]
    then
        echo "Test ${FUNCNAME[1]} passed"
    else
        echo "Test ${FUNCNAME[1]} failed"

        if [ -n "${2}" ]
        then
            echo "${2}"
        fi
    fi
}

function setup {
    export _RELEASE_ROOT_DIR="${PWD}"

    _process_product dxp &> /dev/null

    _promote_product_versions dxp &> /dev/null

    _merge_json_snippets &> /dev/null
}

function tear_down {
    unset _RELEASE_ROOT_DIR

    rm ./*.json
}

function test_merge_json_snipets {
    local earliest_url="$(jq -r '.[0].url' < "$(find ./20*dxp*.json | head -n 1)")"
    local latest_url="$(jq -r '.[0].url' < "$(find ./20*dxp*.json | tail -n 1)")"

    local earliest_count="$(grep -c "${earliest_url}" releases.json)"
    local latest_count="$(grep -c "${latest_url}" releases.json)"

    assert_equals $(echo $(( "${earliest_count}" == 1 && "${latest_count}" == 1 )))
}

function test_promote_product_versions {
    local product_name=${1}

    while read -r group_version || [ -n "${group_version}" ]
    do
        last_version=$(ls | grep "${product_name}-${group_version}" | tail -n 1 2>/dev/null)

        if [ -n "${last_version}" ]
        then
            assert_equals $(echo "$(jq -r '.[] | .promoted' "${last_version}")") "${last_version} should be promoted."
        fi
    done < "${_RELEASE_ROOT_DIR}/supported-${product_name}-versions.txt"
}

setup

test_merge_json_snipets dxp

test_promote_product_versions dxp

tear_down