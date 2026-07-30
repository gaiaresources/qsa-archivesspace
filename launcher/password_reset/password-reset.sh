#!/bin/bash

export ASPACE_LAUNCHER_BASE="$("`dirname $0`"/find-base.sh 2>/dev/null)"
JRUBY_OPTS=""

if [ "$ASPACE_LAUNCHER_BASE" != "" ]; then
    # We're running from a dist build
    cd "$ASPACE_LAUNCHER_BASE/scripts"

    export GEM_HOME="../gems"
    export GEM_PATH=

    export JRUBY=
    for dir in ../gems/gems/jruby-*; do
        JRUBY="$JRUBY:$dir/lib/*"
    done
else
    # Running from a dev checkout
    cd "`dirname "$0"`"
    export ASPACE_LAUNCHER_BASE="`cd ../../; pwd`"
    cd - &>/dev/null

    export GEM_HOME="`cd "${ASPACE_LAUNCHER_BASE}/build/gems/jruby"/*/; pwd`"
    export GEM_PATH=

    export JRUBY=
    for dir in $GEM_HOME/gems/jruby-*; do
        JRUBY="$JRUBY:$dir/lib/*"
    done

    JRUBY_OPTS="-I${ASPACE_LAUNCHER_BASE}/common"
    export APPCONFIG_DATA_DIRECTORY="/tmp"
fi

java $JAVA_OPTS -cp "../lib/*$JRUBY" org.jruby.Main $JRUBY_OPTS ${ASPACE_LAUNCHER_BASE}/launcher/password_reset/lib/password-reset.rb ${1+"$@"}
