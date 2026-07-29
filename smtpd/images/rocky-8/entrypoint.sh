#!/bin/sh
set -e

/opt/halon/bin/halonctl license fetch --username ${HALON_REPO_USER} --password ${HALON_REPO_PASS} --path /license.key

if [ -d /src ]; then
    mkdir -p /etc/halon
    /opt/halon/bin/halonconfig --src-dir /src --dist-dir /etc/halon
fi

exec "$@"
