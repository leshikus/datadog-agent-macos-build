#!/bin/bash -e

# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/)
# Copyright 2022-present Datadog, Inc.

# FIXME: Uncomment this once we fix the way we cache the builder setup
# in datadog-agent-macos-build, we have non-critical errors that make
# the script fail with set -e.
# set -e


# Does an omnibus build of the Agent.

# Prerequisites:
# - clone_agent.sh has been run
# - builder_setup.sh has been run
# - $VERSION contains the datadog-agent git ref to target
# - $RELEASE_VERSION contains the release.json version to package. Defaults to $VERSION
# - $AGENT_MAJOR_VERSION contains the major version to release
# - $PYTHON_RUNTIMES contains the included python runtimes
# - $SIGN set to true if signing is enabled
# - if $SIGN is set to true:
#   - $KEYCHAIN_NAME contains the keychain name. Defaults to login.keychain
#   - $KEYCHAIN_PWD contains the keychain password

export RELEASE_VERSION=${RELEASE_VERSION:-$VERSION}
export KEYCHAIN_NAME=${KEYCHAIN_NAME:-"login.keychain"}

# Load build setup vars
source ~/.build_setup
cd $GOPATH/src/github.com/DataDog/datadog-agent

# Install python deps (invoke, etc.)

# Python 3.12 changes default behavior how packages are installed.
# In particular, --break-system-packages command line option is
# required to use the old behavior or use a virtual env. https://github.com/actions/runner-images/issues/8615
python3 -m venv .venv
source .venv/bin/activate

DDA_VERSION="$(curl -s https://raw.githubusercontent.com/DataDog/datadog-agent-buildimages/main/dda.env | awk -F= '/^DDA_VERSION=/ {print $2}')"
python3 -m pip install "git+https://github.com/DataDog/datadog-agent-dev.git@${DDA_VERSION}"
dda -v self dep sync -f legacy-tasks

# Clean up previous builds
sudo rm -rf /opt/datadog-agent ./vendor ./vendor-new /var/cache/omnibus/src/* ./omnibus/Gemfile.lock

# Create target folders
sudo mkdir -p /opt/datadog-agent /var/cache/omnibus && sudo chown "$USER" /opt/datadog-agent /var/cache/omnibus

# Set bundler install path to cached folder
pushd omnibus && bundle config set --local path 'vendor/bundle' && popd

dda inv check-go-version || exit 1

# Update the INTEGRATION_CORE_VERSION if requested
if [ -n "$INTEGRATIONS_CORE_REF" ]; then
    export INTEGRATIONS_CORE_VERSION="$INTEGRATIONS_CORE_REF"
fi

INVOKE_TASK="omnibus.build"
if ! dda inv --list | grep -qF "$INVOKE_TASK"; then
    echo -e "\033[0;31magent.omnibus-build is deprecated. Please use omnibus.build!\033[0m"
    INVOKE_TASK="agent.omnibus-build"
fi

# Launch omnibus build
if [ "$SIGN" = "true" ]; then
    # Unlock the keychain to get access to the signing certificates
    security unlock-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN_NAME"
    dda inv -e $INVOKE_TASK --hardened-runtime --major-version "$AGENT_MAJOR_VERSION" --release-version "$RELEASE_VERSION" || exit 1
    # Lock the keychain once we're done
    security lock-keychain "$KEYCHAIN_NAME"
else
    dda inv -e $INVOKE_TASK --skip-sign --major-version "$AGENT_MAJOR_VERSION" --release-version "$RELEASE_VERSION" || exit 1
fi
