# Virto Commerce frontend (vc-frontend, Vue 3 SPA) served by nginx.
#
# Virto does not publish a Docker image for vc-frontend. The release zip is
# the official artifact, so we download it, check the SHA256 and copy the
# static files into an unprivileged nginx image. nginx also proxies the API
# paths (/graphql, /connect/token ...) to the platform, so the browser only
# talks to one origin and there are no CORS issues.

ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.30.6-alpine

FROM --platform=$BUILDPLATFORM alpine:3.22 AS download
ARG FRONTEND_VERSION=2.59.1
ARG FRONTEND_SHA256=1ee29552cf9c10760c078af626a3a521db3367a899613bb2f77f0695992d847f
RUN apk add --no-cache curl unzip
WORKDIR /src
RUN curl -fsSL --retry 5 --retry-all-errors -o frontend.zip \
      "https://github.com/VirtoCommerce/vc-frontend/releases/download/${FRONTEND_VERSION}/vc-frontend-${FRONTEND_VERSION}.zip" \
    && echo "${FRONTEND_SHA256}  frontend.zip" | sha256sum -c - \
    && unzip -q frontend.zip -d out \
    && test -f out/default/index.html \
    && find out/default -name '*.map' -delete

FROM ${NGINX_IMAGE}
ARG FRONTEND_VERSION=2.59.1

# Pull security fixes for the Alpine packages of the base image. Trivy in CI
# found CVE-2026-111497 (brotli-libs, CRITICAL, fixed in 1.2.1-r0) in
# nginx-unprivileged:1.30.6-alpine before upstream rebuilt it.
USER root
# hadolint ignore=DL3017
RUN apk upgrade --no-cache
USER 101
LABEL org.opencontainers.image.title="virto-frontend" \
      org.opencontainers.image.version="${FRONTEND_VERSION}"

# nginx renders /etc/nginx/templates/*.template with envsubst at startup,
# so the platform address comes from the PLATFORM_UPSTREAM env variable.
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=download /src/out/default/ /usr/share/nginx/html/

ENV PLATFORM_UPSTREAM=platform:8080 \
    NGINX_RESOLVER=127.0.0.11

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/nginx-health || exit 1
