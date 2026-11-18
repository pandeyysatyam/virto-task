# Virto Commerce Platform image with the module bundle baked in.
#
# The official platform image only ships the platform host. The storefront
# needs the commerce modules (catalog, cart, xAPI and so on), so they are
# downloaded at build time from a pinned lock file (modules.lock).
# Baking modules into the image means every container started from the same
# tag runs the exact same code, which is what we want on ECS later.
#
# Why not vc-build? It was the first attempt. It also downloads the whole
# platform again and uses a fixed 100 second HTTP timeout per file, which
# failed on a slow connection (see docs/troubleshooting.md, issue 1).

ARG PLATFORM_IMAGE=ghcr.io/virtocommerce/platform:3.1076.13

# Stage 1: download and unpack modules (runs natively, modules are plain zips)
FROM --platform=$BUILDPLATFORM alpine:3.22 AS modules

RUN apk add --no-cache curl unzip

WORKDIR /build
COPY modules.lock ./modules.lock

# 6 downloads in parallel, each retried, then unzip every module into
# modules/<ModuleId>/ which is the layout the platform expects.
RUN mkdir -p zips modules \
    && grep -v '^#' modules.lock | awk 'NF==3 {print $1" "$3}' \
       | xargs -P 6 -n 2 sh -c 'curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
            --connect-timeout 30 -o "zips/$0.zip" "$1" && echo "downloaded $0"' \
    && for z in zips/*.zip; do \
         id=$(basename "$z" .zip); \
         unzip -q "$z" -d "modules/$id" || exit 1; \
       done \
    && expected=$(grep -cv '^#' modules.lock) \
    && actual=$(ls modules | wc -l) \
    && echo "modules installed: $actual of $expected" \
    && [ "$actual" -eq "$expected" ]

# Stage 2: runtime
FROM ${PLATFORM_IMAGE}

USER root

# curl is only used by the container health check
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/virtocommerce/platform

COPY --from=modules /build/modules ./modules

# Same step as the official Virto Dockerfile: native linux-x64 libraries
# shipped inside modules must sit in the probing folder to be loaded.
RUN mkdir -p app_data/modules app_data/lucene wwwroot/cms-content wwwroot/assets \
    && (find ./modules -path "*/bin/runtimes/linux-x64/**/*" -type f \
         -exec cp "{}" ./app_data/modules/ \; || true) \
    && chown -R 1654:1654 /opt/virtocommerce/platform

# Run as the non-root "app" user (uid 1654) from the .NET base image.
# Non-root cannot bind port 80, so the platform listens on 8080 inside the container.
USER 1654

ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=5 \
  CMD curl -fsS http://localhost:8080/health || exit 1

ENTRYPOINT ["dotnet", "VirtoCommerce.Platform.Web.dll"]
