FROM docker.io/library/alpine:3.8

RUN apk add --no-cache \
    bash \
    bind \
    bind-tools \
    openssh-client \
    git \
    rsync

COPY *.sh /usr/local/bin/
COPY rsyncignore /etc/

WORKDIR /zones
