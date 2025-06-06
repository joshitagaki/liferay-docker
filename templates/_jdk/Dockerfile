FROM --platform=linux/arm64 liferay/@jdk_from_image_name@:latest AS liferay-@jdk_from_image_name@-arm64

ARG LABEL_ZULU_@jdk_version@_AMD64_VERSION
ARG LABEL_ZULU_@jdk_version@_ARM64_VERSION
ARG LABEL_ZULU_@jdk_version@_VERSION=${LABEL_ZULU_@jdk_version@_ARM64_VERSION}

FROM --platform=linux/amd64 liferay/@jdk_from_image_name@:latest AS liferay-@jdk_from_image_name@-amd64

ARG LABEL_ZULU_@jdk_version@_AMD64_VERSION
ARG LABEL_ZULU_@jdk_version@_ARM64_VERSION
ARG LABEL_ZULU_@jdk_version@_VERSION=${LABEL_ZULU_@jdk_version@_AMD64_VERSION}

FROM liferay-@jdk_from_image_name@-${TARGETARCH}

ARG LABEL_BUILD_DATE
ARG LABEL_NAME
ARG LABEL_VCS_REF
ARG LABEL_VCS_URL
ARG LABEL_VERSION
ARG TARGETARCH
ARG TARGETPLATFORM

COPY resources/etc/created-date /etc/created-date
COPY --chown=liferay:liferay resources/home/liferay/.bashrc /home/liferay/
COPY resources/usr/ /usr

ENV JAVA_VERSION=zulu@jdk_version@

LABEL org.label-schema.build-date="${LABEL_BUILD_DATE}"
LABEL org.label-schema.name="${LABEL_NAME}"
LABEL org.label-schema.schema-version="1.0"
LABEL org.label-schema.vcs-ref="${LABEL_VCS_REF}"
LABEL org.label-schema.vcs-url="${LABEL_VCS_URL}"
LABEL org.label-schema.vendor="Liferay, Inc."
LABEL org.label-schema.version="${LABEL_VERSION}"
LABEL org.label-schema.zulu@jdk_version@_version="${LABEL_ZULU_@jdk_version@_VERSION}"
LABEL org.label-schema.zulu@jdk_version@_arm64_version="${LABEL_ZULU_@jdk_version@_ARM64_VERSION}"
LABEL org.label-schema.zulu@jdk_version@_amd64_version="${LABEL_ZULU_@jdk_version@_AMD64_VERSION}"

RUN apt-get update && \
	apt-get install --no-install-recommends --yes jattach && \
	apt-get upgrade --yes && \
	apt-get clean && \
	curl -H 'accept: */*' -L -s -X 'GET' -o /tmp/jdk@jdk_version@.deb "https://api.azul.com/zulu/download/community/v1.0/bundles/latest/binary/?arch=${TARGETARCH}&bundle_type=jdk&ext=deb&hw_bitness=64&java_version=@jdk_version@.0&javafx=false&os=linux&zulu_version=${LABEL_ZULU_@jdk_version@_VERSION}" && \
	DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install --no-install-recommends --yes /tmp/jdk@jdk_version@.deb && \
	rm /tmp/jdk@jdk_version@.deb && \
	/usr/local/bin/set_java_version.sh