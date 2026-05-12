#!/bin/bash

source ../_release_common.sh

function generate_breaking_changes_markdown {
	local output_file="${5}"

	if [ -z "${output_file}" ]
	then
		lc_log ERROR "Output file is not set."

		return "${LIFERAY_COMMON_EXIT_CODE_BAD}"
	fi

	local repo_path="${1}"

	if [ ! -d "${repo_path}" ]
	then
		lc_log ERROR "${repo_path} is not a directory."

		return "${LIFERAY_COMMON_EXIT_CODE_BAD}"
	fi

	local breaking_change_keyword="# breaking"
	local amendments_file="${repo_path}/readme/BREAKING_CHANGES_AMENDMENTS.md"
	local work_dir=$(mktemp --directory)

	mkdir --parents "${work_dir}/messages"
	mkdir --parents "${work_dir}/records"
	mkdir --parents "${work_dir}/amendments"

	local hashes_file="${work_dir}/hashes.txt"
	local current_dir="${PWD}"

	lc_cd "${repo_path}"

	local repo_branch="${2}"

	lc_log INFO "Checkout ${repo_branch} and pull."

	if ! git checkout "${repo_branch}" ||
	   ! git fetch --all ||
	   ! git reset --hard "origin/${repo_branch}"
	then
		lc_log ERROR "Unable to checkout ${repo_branch}."

		rm --force --recursive "${work_dir}"

		return "${LIFERAY_COMMON_EXIT_CODE_BAD}"
	fi

	lc_log INFO "Retrieving git info."

	local end_hash="${4:-HEAD}"
	local start_hash="${3}"

	if ! git log "${start_hash}..${end_hash}" --grep="${breaking_change_keyword}" --pretty=tformat:%H > "${hashes_file}"
	then
		lc_log ERROR "Unable to retrieve git log between ${start_hash} and ${end_hash}."

		lc_cd "${current_dir}"

		rm --force --recursive "${work_dir}"

		return "${LIFERAY_COMMON_EXIT_CODE_BAD}"
	fi

	if [ -f "${amendments_file}" ]
	then
		_parse_breaking_changes_amendments "${amendments_file}" "${work_dir}/amendments"

		if [ -f "${work_dir}/amendments/list.txt" ]
		then
			local amend_hash

			while IFS= read -r amend_hash
			do
				[ -z "${amend_hash}" ] && continue

				if grep -qx "${amend_hash}" "${hashes_file}" 2>/dev/null
				then
					continue
				fi

				if git merge-base --is-ancestor "${start_hash}" "${amend_hash}" 2>/dev/null &&
				   ! git merge-base --is-ancestor "${end_hash}" "${amend_hash}" 2>/dev/null
				then
					echo "${amend_hash}" >> "${hashes_file}"
				else
					rm --force "${work_dir}/amendments/${amend_hash}.msg"
				fi
			done < "${work_dir}/amendments/list.txt"
		fi
	fi

	lc_log INFO "Processing git info."

	local commit_index=0
	local git_hash

	while IFS= read -r git_hash
	do
		[ -z "${git_hash}" ] && continue

		commit_index=$((commit_index + 1))

		local commit_index_padded
		printf -v commit_index_padded '%04d' "${commit_index}"

		local message_file="${work_dir}/messages/${commit_index_padded}.msg"

		if [ -f "${work_dir}/amendments/${git_hash}.msg" ]
		then
			cp "${work_dir}/amendments/${git_hash}.msg" "${message_file}"

			lc_log INFO "Amending: ${git_hash}"
		else
			git show --no-patch --format=%B "${git_hash}" > "${message_file}"
		fi

		_parse_breaking_changes_commit_message "${git_hash}" "$(git show --no-patch --format=%ct "${git_hash}")" "${commit_index_padded}" "${message_file}" "${work_dir}/records" "${breaking_change_keyword}"
	done < "${hashes_file}"

	lc_cd "${current_dir}"

	lc_log INFO "Generating output."

	_format_breaking_changes_report "${work_dir}/records" "${output_file}" "${work_dir}/order.txt"

	rm --force --recursive "${work_dir}"

	lc_log INFO "Wrote ${output_file}."
}

function generate_checksum_files {
	lc_cd "${_BUILD_DIR}"/release

	for file in *
	do
		if [ -f "${file}" ]
		then

			#
			# TODO Remove *.MD5 in favor of *.sha512.
			#

			md5sum "${file}" | sed --expression "s/ .*//" > "${file}.MD5"

			sha512sum "${file}" | sed --expression "s/ .*//" > "${file}.sha512"
		fi
	done
}

function generate_release_properties_file {
	local date_key="release.date"

	if (is_7_4_u_release && is_later_product_version_than "7.4.13-u145") ||
	   (is_quarterly_release && is_equals_or_later_product_version_than "2026.q1.0-lts")
	then
		date_key="general.availability.date"
	fi

	local tomcat_version=$(grep --extended-regexp --only-matching "Apache Tomcat Version [0-9]+\.[0-9]+\.[0-9]+" "${_BUNDLES_DIR}/tomcat/RELEASE-NOTES")

	tomcat_version=$(echo "${tomcat_version}" | sed "s/Apache Tomcat Version //")

	if [ -z "${tomcat_version}" ]
	then
		lc_log DEBUG "Unable to determine the Tomcat version."

		return "${LIFERAY_COMMON_EXIT_CODE_BAD}"
	fi

	local bundle_file_name="liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tomcat-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.7z"

	local product_version=$(echo "${_PRODUCT_VERSION}" | tr "[:lower:]" "[:upper:]")

	product_version=$(echo "DXP ${product_version}" | sed "s/-/ /")

	(
		echo "${date_key}=${LIFERAY_RELEASE_GENERAL_AVAILABILITY_DATE}"
		echo "app.server.tomcat.version=${tomcat_version}"
		echo "build.timestamp=${_BUILD_TIMESTAMP}"
		echo "bundle.checksum.sha512=$(cat "${bundle_file_name}.sha512")"
		echo "bundle.url=https://releases-cdn.liferay.com/${LIFERAY_RELEASE_PRODUCT_NAME}/${_PRODUCT_VERSION}/${bundle_file_name}"
		echo "git.hash.liferay-docker=${_BUILDER_SHA}"
		echo "git.hash.${LIFERAY_PORTAL_REPOSITORY_NAME}=${_GIT_SHA}"
		echo "git.tag=$(get_product_version_without_lts_suffix)"
		echo "liferay.docker.image=liferay/${LIFERAY_RELEASE_PRODUCT_NAME}:${_PRODUCT_VERSION}"
		echo "liferay.docker.tags=${_PRODUCT_VERSION}"
		echo "liferay.product.version=${product_version}"
		echo "target.platform.version=$(get_target_platform_version)"
	) | sort > release.properties
}

function install_patching_tool {
	trap 'return ${LIFERAY_COMMON_EXIT_CODE_BAD}' ERR

	lc_cd "${_BUNDLES_DIR}"

	if [ -e "patching-tool" ]
	then
		lc_log INFO "Patching Tool is already installed."

		return "${LIFERAY_COMMON_EXIT_CODE_SKIPPED}"
	fi

	local latest_version=$(lc_curl https://releases.liferay.com/tools/patching-tool/LATEST-4.0.txt)

	lc_log info "Installing Patching Tool ${latest_version}."

	lc_download https://releases.liferay.com/tools/patching-tool/patching-tool-"${latest_version}".zip patching-tool-"${latest_version}".zip

	unzip -q patching-tool-"${latest_version}".zip

	rm --force patching-tool-"${latest_version}".zip

	lc_cd patching-tool

	./patching-tool.sh auto-discovery

	rm --force logs/*
}

function package_boms {
	lc_cd "${_BUILD_DIR}/boms"

	cp --archive ./*.pom "${_BUILD_DIR}/release"

	cp "release.${LIFERAY_RELEASE_PRODUCT_NAME}.distro-${_ARTIFACT_RC_VERSION}.jar" "${_BUILD_DIR}/release"

	touch .touch

	jar cvfm "${_BUILD_DIR}/release/release.${LIFERAY_RELEASE_PRODUCT_NAME}.api-${_ARTIFACT_RC_VERSION}.jar" .touch -C api-jar .
	jar cvfm "${_BUILD_DIR}/release/release.${LIFERAY_RELEASE_PRODUCT_NAME}.api-${_ARTIFACT_RC_VERSION}-sources.jar" .touch -C api-sources-jar .

	rm --force .touch
}

function package_release {
	rm --force --recursive "${_BUILD_DIR}/release"

	local package_dir="${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"

	mkdir --parents "${package_dir}"

	cp --archive "${_BUNDLES_DIR}"/* "${package_dir}"

	echo "${_GIT_SHA}" > "${package_dir}"/.githash
	echo "${_PRODUCT_VERSION}" > "${package_dir}"/.liferay-version

	touch "${package_dir}"/.liferay-home

	lc_cd "${_BUILD_DIR}/release"

	_package_portal_dependencies

	if [ "$(get_release_output)" == "nightly" ]
	then
		_package_nightly_release
	else
		_package_common_release
	fi
}

function _emit_breaking_changes_record {
	local rec_file="${1}"
	local out_file="${2}"

	local jira_ticket=$(grep -m1 '^JIRA_TICKET=' "${rec_file}" | cut --delimiter='=' --fields=2-)

	printf '\n    * __Date:__ %s\n    * __Ticket:__ [%s](https://liferay.atlassian.net/browse/%s)\n    * __What changed:__ %s\n    * __Reason:__ %s\n                ' \
		"$(grep -m1 '^DATE=' "${rec_file}" | cut --delimiter='=' --fields=2-)" \
		"${jira_ticket}" \
		"${jira_ticket}" \
		"$(awk '/^<<<WHAT_INFO$/{flag=1;next} /^WHAT_INFO>>>$/{flag=0} flag' "${rec_file}")" \
		"$(awk '/^<<<WHY_INFO$/{flag=1;next} /^WHY_INFO>>>$/{flag=0} flag' "${rec_file}")" >> "${out_file}"

	if [ "$(grep -m1 '^HAS_ALTERNATIVES=' "${rec_file}" | cut --delimiter='=' --fields=2-)" = "1" ]
	then
		printf '\n    * __Alternatives:__ %s\n                    ' \
			"$(awk '/^<<<ALTERNATIVES$/{flag=1;next} /^ALTERNATIVES>>>$/{flag=0} flag' "${rec_file}")" >> "${out_file}"
	fi

	printf '\n    &nbsp;\n                ' >> "${out_file}"
}

function _format_breaking_changes_report {
	local order_file="${3}"

	: > "${order_file}"

	local rec_file
	local records_dir="${1}"

	for rec_file in "${records_dir}"/*.rec
	do
		[ -f "${rec_file}" ] || continue

		printf '%s\t%s\t%s\n' \
			"$(grep -m1 '^FIRST_LEVEL=' "${rec_file}" | cut --delimiter='=' --fields=2-)" \
			"$(grep -m1 '^AFFECTED_FILE_PATH=' "${rec_file}" | cut --delimiter='=' --fields=2-)" \
			"${rec_file}" >> "${order_file}"
	done

	local out_file="${2}"

	: > "${out_file}"

	[ -s "${order_file}" ] || return

	local fl

	while IFS= read -r fl
	do
		[ -z "${fl}" ] && continue

		local afp

		while IFS= read -r afp
		do
			[ -z "${afp}" ] && continue

			printf '\n    # %s\n              \n    %s `%s`\n            ' "${afp}" "$(basename "${afp}")" "${afp}" >> "${out_file}"

			local r

			while IFS= read -r r
			do
				[ -z "${r}" ] && continue

				_emit_breaking_changes_record "${r}" "${out_file}"
			done < <(awk -F'\t' -v fl="${fl}" -v afp="${afp}" '$1 == fl && $2 == afp {print $3}' "${order_file}")
		done <<< "$(awk -F'\t' -v fl="${fl}" '$1 == fl && !seen[$2]++ {print $2}' "${order_file}")"
	done <<< "$(awk -F'\t' '!seen[$1]++ {print $1}' "${order_file}")"
}

function _generate_javadocs {
	if (is_7_4_u_release || is_ai_hub_release)
	then
		lc_log INFO "Javadocs should not be generated for internal and AI Hub releases."

		return "${LIFERAY_COMMON_EXIT_CODE_SKIPPED}"
	fi

	if is_quarterly_release
	then
		if is_early_product_version_than "2025.q3.0" || [[ "$(get_release_patch_version)" -ne 0 ]]
		then
			lc_log INFO "Javadocs should not be generated for ${_PRODUCT_VERSION}."

			return "${LIFERAY_COMMON_EXIT_CODE_SKIPPED}"
		fi
	fi

	if [ -z "${LIFERAY_RELEASE_TEST_MODE}" ]
	then
		lc_log INFO "Generating javadocs for ${_PRODUCT_VERSION}."

		git reset --hard && git clean -dfx

		git fetch --no-tags upstream "refs/tags/${_PRODUCT_VERSION}:refs/tags/${_PRODUCT_VERSION}"

		git checkout "tags/${_PRODUCT_VERSION}"

		ant \
			-Ddist.dir="${_BUILD_DIR}/release" \
			-Dliferay.product.name="liferay-${LIFERAY_RELEASE_PRODUCT_NAME}" \
			-Dlp.version="${_PRODUCT_VERSION}" \
			-Dpatch.doc="true" \
			-Dportal.dir="${_PROJECTS_DIR}/${LIFERAY_PORTAL_REPOSITORY_NAME}" \
			-Dportal.release.edition.private="true" \
			-Dtstamp.value="${_BUILD_TIMESTAMP}" \
			-file "${_PROJECTS_DIR}/liferay-release-tool-ee/build-service-pack.xml" patch-doc

		if [ "${?}" -ne 0 ]
		then
			lc_log ERROR "Unable to generate javadocs."

			return "${LIFERAY_COMMON_EXIT_CODE_BAD}"
		fi
	fi
}

function _package_common_release {
	7z a "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tomcat-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.7z" liferay-${LIFERAY_RELEASE_PRODUCT_NAME}

	echo "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tomcat-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.7z" > "${_BUILD_DIR}"/release/.lfrrelease-tomcat-bundle

	tar \
		--create \
		--file "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tomcat-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.tar.gz" \
		--gzip \
		"liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"

	zip -qr "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tomcat-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.zip" "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"

	lc_cd "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"

	zip -qr "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-osgi-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.zip" osgi

	lc_cd tomcat/webapps/ROOT

	if is_7_3_release
	then
		cp "${_PROJECTS_DIR}/${LIFERAY_PORTAL_REPOSITORY_NAME}/lib/portal/ccpp.jar" WEB-INF/lib
	fi

	_package_wars

	lc_cd "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"

	zip -qr "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tools-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.zip" tools

	lc_cd "${_PROJECTS_DIR}/${LIFERAY_PORTAL_REPOSITORY_NAME}"

	cp --archive sql liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-sql

	zip -qr "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-sql-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.zip" "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-sql" -i "*.sql"

	rm --force --recursive "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-sql"

	rm --force --recursive "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"

	_generate_javadocs
}

function _package_nightly_release {
	7z a "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tomcat-7.4.13.nightly-${_BUILD_TIMESTAMP}.7z" \
		"liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"

	echo "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tomcat-7.4.13.nightly-${_BUILD_TIMESTAMP}.7z" > "${_BUILD_DIR}"/release/.lfrrelease-tomcat-bundle

	tar \
		--create \
		--file "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tomcat-7.4.13.nightly-${_BUILD_TIMESTAMP}.tar.gz" \
		--gzip \
		"liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"

	zip -qr "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-tomcat-7.4.13.nightly-${_BUILD_TIMESTAMP}.zip" \
		"liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"

	rm --force --recursive "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}"
}

function _package_portal_dependencies {
	if is_7_3_release
	then

		#
		# Client
		#

		rm --force --recursive "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-client-${_PRODUCT_VERSION}"

		mkdir --parents "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-client-${_PRODUCT_VERSION}"

		for jar in \
			activation.jar \
			axis.jar \
			commons-discovery.jar \
			commons-logging.jar \
			jaxrpc.jar \
			mail.jar \
			portal-client.jar \
			saaj-api.jar \
			saaj-impl.jar \
			wsdl4j.jar
		do
			local jar_dir="portal"

			if [ "${jar}" == "activation.jar" ] || [ "${jar}" == "mail.jar" ]
			then
				jar_dir="development"
			fi

			cp "${_PROJECTS_DIR}/${LIFERAY_PORTAL_REPOSITORY_NAME}/lib/${jar_dir}/${jar}" "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-client-${_PRODUCT_VERSION}"
		done

		zip -qr "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-client-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.zip" "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-client-${_PRODUCT_VERSION}"

		rm --force --recursive "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-client-${_PRODUCT_VERSION}"

		#
		# Dependencies
		#

		rm --force --recursive "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-dependencies-${_PRODUCT_VERSION}"

		mkdir --parents "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-dependencies-${_PRODUCT_VERSION}"

		for jar in \
			com.liferay.petra.concurrent.jar \
			com.liferay.petra.executor.jar \
			com.liferay.petra.function.jar \
			com.liferay.petra.io.jar \
			com.liferay.petra.lang.jar \
			com.liferay.petra.memory.jar \
			com.liferay.petra.nio.jar \
			com.liferay.petra.process.jar \
			com.liferay.petra.reflect.jar \
			com.liferay.petra.sql.dsl.api.jar \
			com.liferay.petra.sql.dsl.spi.jar \
			com.liferay.petra.string.jar \
			com.liferay.petra.url.pattern.mapper.jar \
			com.liferay.registry.api.jar \
			hsql.jar \
			portal-kernel.jar \
			portlet.jar
		do
			cp "${_BUILD_DIR}"/release/liferay-"${LIFERAY_RELEASE_PRODUCT_NAME}"/tomcat/lib/ext/"${jar}" "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-dependencies-${_PRODUCT_VERSION}"
		done

		zip -qr "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-dependencies-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.zip" "liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-dependencies-${_PRODUCT_VERSION}"

		rm --force --recursive "${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-dependencies-${_PRODUCT_VERSION}"
	fi
}

function _package_wars {
	local tomcat_war_name="liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-${_PRODUCT_VERSION}-${_BUILD_TIMESTAMP}.war"

	zip -qr "${_BUILD_DIR}/release/${tomcat_war_name}" ./*

	if (is_quarterly_release && is_equals_or_later_product_version_than "2026.q1.0-lts")
	then
		ant \
			-Dapp.server.shielded-container-lib.portal.dir="${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}/tomcat/webapps/ROOT/WEB-INF/shielded-container-lib" \
			-Dapp.server.type=weblogic \
			-Dapp.server.weblogic.portal.dir="${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}/tomcat/webapps/ROOT" \
			-file "${_PROJECTS_DIR}/${LIFERAY_PORTAL_REPOSITORY_NAME}/build.xml" update-app-server-scripts

		zip \
			-q \
			-r \
			"${_BUILD_DIR}/release/liferay-${LIFERAY_RELEASE_PRODUCT_NAME}-${_PRODUCT_VERSION}-weblogic-${_BUILD_TIMESTAMP}.war" ./* \
			-x "${tomcat_war_name}"
	fi
}

function _parse_breaking_changes_amendments {
	local amendments_file="${1}"
	local out_dir="${2}"

	awk -v out_dir="${out_dir}" '
	BEGIN {
		state = 0
		current_hash = ""
		pending_hash = ""
		msg_file = ""
		list_file = out_dir "/list.txt"
		printf "" > list_file
	}
	state == 0 && /^#+[[:space:]]/ {
		pending_hash = $0
		sub(/^#+[[:space:]]+/, "", pending_hash)
		gsub(/[[:space:]]+$/, "", pending_hash)
		next
	}
	state == 0 && /^[[:space:]]*```/ {
		if (pending_hash != "") {
			current_hash = pending_hash
			msg_file = out_dir "/" current_hash ".msg"
			printf "" > msg_file
			state = 1
		} else {
			state = 2
		}
		pending_hash = ""
		next
	}
	state == 1 && /^[[:space:]]*```/ {
		print current_hash >> list_file
		close(msg_file)
		state = 0
		current_hash = ""
		msg_file = ""
		next
	}
	state == 1 {
		print > msg_file
	}
	state == 2 && /^[[:space:]]*```/ {
		state = 0
		next
	}
	state == 2 {
		next
	}
	' "${amendments_file}"
}

function _parse_breaking_changes_commit_message {
	local breaking_change_keyword="${6}"
	local committed_date="${2}"
	local commit_index_padded="${3}"
	local git_hash="${1}"
	local message_file="${4}"
	local records_dir="${5}"

	awk -v hash="${git_hash}" \
	    -v date="${committed_date}" \
	    -v cidx="${commit_index_padded}" \
	    -v outdir="${records_dir}" \
	    -v keyword="${breaking_change_keyword}" '
	{
		line = $0
		sub(/\r$/, "", line)
		lines[NR] = line
	}
	END {
		n = NR
		keyword_lc = tolower(keyword)
		keyword_len = length(keyword)

		first_breaking = 0
		for (i = 2; i <= n; i++) {
			if (tolower(substr(lines[i], 1, keyword_len)) == keyword_lc) {
				first_breaking = i
				break
			}
		}
		if (first_breaking == 0) exit

		jira_ticket = ""
		jira_ticket_title = ""
		for (i = 1; i < first_breaking; i++) {
			if (lines[i] != "") {
				pos = index(lines[i], " ")
				if (pos > 0) {
					jira_ticket = substr(lines[i], 1, pos - 1)
					jira_ticket_title = substr(lines[i], pos + 1)
				} else {
					jira_ticket = lines[i]
					jira_ticket_title = ""
				}
				break
			}
		}

		block_start = first_breaking
		change_idx = 0

		while (block_start <= n) {
			block_end = n + 1

			for (i = block_start; i <= n; i++) {
				if (substr(lines[i], 1, 4) == "----") {
					block_end = i
					break
				}
			}

			if (block_end > n) {
				for (i = block_start; i <= n; i++) {
					if (tolower(substr(lines[i], 1, keyword_len)) == keyword_lc) {
						block_end = i
						break
					}
				}
			}

			if (block_end - block_start > 1) {
				non_empty = 0

				for (i = block_start; i < block_end; i++) {
					line_trim = lines[i]
					gsub(/^[ \t]+|[ \t]+$/, "", line_trim)
					if (line_trim != "") {
						non_empty = 1
						break
					}
				}

				if (non_empty) {
					what_line = 0

					for (i = block_start; i < block_end; i++) {
						if (tolower(substr(lines[i], 1, 7)) == "## what") {
							what_line = i
							break
						}
					}

					if (what_line == 0) {
						block_start = block_end + 1
						continue
					}

					raw_what = lines[what_line]
					affected_file_path = ""

					if (substr(raw_what, 1, 8) == "## What ") {
						affected_file_path = substr(raw_what, 9)
					} else if (substr(raw_what, 1, 8) == "## what ") {
						affected_file_path = substr(raw_what, 9)
					}

					why_line = 0

					for (i = what_line + 1; i < block_end; i++) {
						if (tolower(substr(lines[i], 1, 6)) == "## why") {
							why_line = i
							break
						}
					}

					if (why_line == 0) {
						block_start = block_end + 1
						continue
					}

					alt_line = block_end

					for (i = why_line + 1; i < block_end; i++) {
						if (tolower(substr(lines[i], 1, 15)) == "## alternatives") {
							alt_line = i
							break
						}
					}

					what_info = ""
					for (i = what_line + 1; i < why_line; i++) {
						what_info = what_info (i > what_line + 1 ? "\n" : "") lines[i]
					}
					sub(/[\r\n]+$/, "", what_info)

					why_info = ""
					for (i = why_line + 1; i < alt_line; i++) {
						why_info = why_info (i > why_line + 1 ? "\n" : "") lines[i]
					}
					sub(/[\r\n]+$/, "", why_info)

					alternatives = ""
					has_alt = (alt_line < block_end) ? 1 : 0
					if (has_alt) {
						for (i = alt_line + 1; i < block_end; i++) {
							alternatives = alternatives (i > alt_line + 1 ? "\n" : "") lines[i]
						}
						sub(/[\r\n]+$/, "", alternatives)
					}

					first_level = "other"
					p1 = index(affected_file_path, "/")
					if (p1 == 1) {
						rest = substr(affected_file_path, 2)
						p2 = index(rest, "/")
						if (p2 > 0) {
							first_level = substr(rest, 1, p2 - 1)
						}
					} else if (p1 > 1) {
						first_level = substr(affected_file_path, 1, p1 - 1)
					}

					rec_file = sprintf("%s/%s_%04d.rec", outdir, cidx, change_idx)
					print "HASH=" hash > rec_file
					print "DATE=" date > rec_file
					print "JIRA_TICKET=" jira_ticket > rec_file
					print "JIRA_TICKET_TITLE=" jira_ticket_title > rec_file
					print "AFFECTED_FILE_PATH=" affected_file_path > rec_file
					print "FIRST_LEVEL=" first_level > rec_file
					print "HAS_ALTERNATIVES=" has_alt > rec_file
					print "<<<WHAT_INFO" > rec_file
					printf "%s\n", what_info > rec_file
					print "WHAT_INFO>>>" > rec_file
					print "<<<WHY_INFO" > rec_file
					printf "%s\n", why_info > rec_file
					print "WHY_INFO>>>" > rec_file
					if (has_alt) {
						print "<<<ALTERNATIVES" > rec_file
						printf "%s\n", alternatives > rec_file
						print "ALTERNATIVES>>>" > rec_file
					}
					close(rec_file)

					change_idx++
				}
			}

			block_start = block_end + 1
		}
	}
	' "${message_file}"
}