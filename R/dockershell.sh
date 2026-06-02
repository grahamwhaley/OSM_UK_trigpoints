#!/bin/bash
#
# Copyright (c) 2026 Graham Whaley
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the docker image up to a shell prompt. This is primarily used
# as a debug/development tool. Once inside the image, execute:
#
#  # cd data
#  # R
#  > source('process.R')
#  > ^D
#  # exit
#

set -x

docker run --rm -it \
    -v $(pwd):/data \
    osm_trigpoints bash
