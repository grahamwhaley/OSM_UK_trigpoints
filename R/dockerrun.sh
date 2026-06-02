#!/bin/bash
#
# Copyright (c) 2026 Graham Whaley
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the build script inside the docker container to do a build

set -x

docker run --rm -it \
    -v $(pwd):/data \
    osm_trigpoints data/build.sh
