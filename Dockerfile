
FROM alpine:3.24

# ------------------------------------------------------------
# Build arguments
# ------------------------------------------------------------

ARG NGINX_VERSION=1.30.6
ARG MORE_SET_HEADER_VERSION=0.41
ARG FANCYINDEX=0.6.0
ARG SUBS_FILTER_COMMIT=e12e965ac1837ca709709f9a26f572a54d83430e
ARG OTEL_REF=main

# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

ENV PATH="/usr/local/bin:${PATH}"

WORKDIR /var/www/html

# ------------------------------------------------------------
# Build NGINX, third-party modules and OpenTelemetry
# ------------------------------------------------------------

RUN set -eux; \
    \
    # Create nginx user and group
    addgroup -S nginx; \
    adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx; \
    \
    # Install build dependencies
    apk add --no-cache --virtual .build-deps \
        alpine-sdk \
        bash \
        cmake \
        curl \
        git \
        gnupg \
        gd-dev \
        geoip-dev \
        libxslt-dev \
        linux-headers \
        openssl-dev \
        pcre2-dev \
        pax-utils \
        pkgconf \
        c-ares-dev \
        musl-dev \
        zlib-dev; \
    \
    # Download NGINX source and verify signature
    mkdir -p /usr/src; \
    cd /tmp; \
    curl -fsSLO "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    curl -fsSLO "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    curl -fsSL https://nginx.org/keys/pluknet.key -o /tmp/nginx-signing.key; \
    fingerprint="$(gpg --batch --with-colons --show-keys /tmp/nginx-signing.key | awk -F: '$1 == "fpr" {print $10; exit}')"; \
    test "$fingerprint" = "D6786CE303D9A9022998DC6CC8464D549AF75C0A"; \
    gpg --batch --import /tmp/nginx-signing.key; \
    gpg --batch --verify "nginx-${NGINX_VERSION}.tar.gz.asc" "nginx-${NGINX_VERSION}.tar.gz"; \
    rm -rf "$GNUPGHOME" /tmp/nginx-signing.key; \
    tar -xzf "nginx-${NGINX_VERSION}.tar.gz" -C /usr/src; \
    \
    # Download third-party modules
    cd /tmp; \
    git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module.git; \
    git -C ngx_http_substitutions_filter_module checkout -q "$SUBS_FILTER_COMMIT"; \
    \
    curl -fsSL \
        "https://github.com/openresty/headers-more-nginx-module/archive/v${MORE_SET_HEADER_VERSION}.tar.gz" \
        -o headers-more.tar.gz; \
    tar -xzf headers-more.tar.gz; \
    \
    curl -fsSL \
        "https://github.com/aperezdc/ngx-fancyindex/releases/download/v${FANCYINDEX}/ngx-fancyindex-${FANCYINDEX}.tar.xz" \
        -o fancyindex.tar.xz; \
    tar -xf fancyindex.tar.xz; \
    \
    # Configure NGINX
    cd "/usr/src/nginx-${NGINX_VERSION}"; \
    CONFIG="\
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-compat \
        --with-file-aio \
        --with-threads \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-http_auth_request_module \
        --with-http_slice_module \
        --with-http_xslt_module=dynamic \
        --with-http_image_filter_module=dynamic \
        --with-http_geoip_module=dynamic \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-stream_realip_module \
        --with-stream_geoip_module=dynamic \
        --with-mail \
        --with-mail_ssl_module \
        --add-module=/tmp/headers-more-nginx-module-${MORE_SET_HEADER_VERSION} \
        --add-module=/tmp/ngx-fancyindex-${FANCYINDEX} \
        --add-module=/tmp/ngx_http_substitutions_filter_module \
    "; \
    \
    ./configure $CONFIG; \
    \
    # Build OpenTelemetry against the exact NGINX build
    cd /tmp; \
    git clone --depth 1 --branch "$OTEL_REF" \
        https://github.com/nginx/nginx-otel.git; \
    cmake -S /tmp/nginx-otel -B /tmp/nginx-otel/build \
        -DNGX_OTEL_NGINX_BUILD_DIR="/usr/src/nginx-${NGINX_VERSION}/objs" \
        -DCMAKE_BUILD_TYPE=Release; \
    cmake --build /tmp/nginx-otel/build \
        --parallel "$(getconf _NPROCESSORS_ONLN)"; \
    \
    # Build and install NGINX
    cd "/usr/src/nginx-${NGINX_VERSION}"; \
    make -j"$(getconf _NPROCESSORS_ONLN)"; \
    make install; \
    \
    # Install OTel module
    install -m755 \
        /tmp/nginx-otel/build/ngx_otel_module.so \
        /usr/lib/nginx/modules/ngx_otel_module.so; \
    \
    # Prepare directories
    mkdir -p \
        /etc/nginx/conf.d \
        /var/log/nginx \
        /var/cache/nginx/client_temp \
        /var/cache/nginx/proxy_temp \
        /var/cache/nginx/fastcgi_temp \
        /var/cache/nginx/uwsgi_temp \
        /var/cache/nginx/scgi_temp \
        /var/run \
        /usr/share/nginx/html; \
    \
    # Install standard HTML files
    install -m644 html/index.html /usr/share/nginx/html/index.html; \
    install -m644 html/50x.html /usr/share/nginx/html/50x.html; \
    \
    # Make modules accessible from nginx.conf
    ln -sfn /usr/lib/nginx/modules /etc/nginx/modules; \
    \
    # Forward logs to Docker
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    \
    # Strip production binaries
    strip /usr/sbin/nginx; \
    find /usr/lib/nginx/modules -type f -name '*.so' -exec strip {} +; \
    \
    # Install envsubst
    apk add --no-cache --virtual .gettext gettext; \
    mv /usr/bin/envsubst /tmp/envsubst; \
    \
    # Determine required runtime libraries
    runDeps="$( \
        scanelf --needed --nobanner \
            /usr/sbin/nginx \
            /usr/lib/nginx/modules/*.so \
            /tmp/envsubst \
        | awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
        | sort -u \
        | xargs -r apk info --installed \
        | sort -u \
    )"; \
    \
    # Install runtime dependencies
    apk add --no-cache --virtual .nginx-rundeps \
        $runDeps \
        apache2-utils \
        curl; \
    \
    # Remove build dependencies
    apk del .build-deps .gettext; \
    \
    # Restore envsubst
    install -m755 /tmp/envsubst /usr/local/bin/envsubst; \
    \
    # Cleanup build files
    rm -rf \
        /tmp/* \
        /usr/src/nginx-${NGINX_VERSION}; \
    \
    # Set ownership
    chown -R nginx:nginx /var/cache/nginx /var/www/html

# ------------------------------------------------------------
# NGINX configuration
# ------------------------------------------------------------

COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY conf/nginx.vh.default.conf /etc/nginx/conf.d/default.conf

# ------------------------------------------------------------
# Validate configuration and modules
# ------------------------------------------------------------

RUN set -eux; \
    nginx -V; \
    test -s /usr/lib/nginx/modules/ngx_otel_module.so; \
    nginx -t

# ------------------------------------------------------------
# Container configuration
# ------------------------------------------------------------

EXPOSE 80 443

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
