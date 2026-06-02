#!/bin/bash
#
# Copyright (c) 2026 Graham Whaley
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the required docker image from the dockerfile that has all the
# R parts we need to run the code

set -x

docker build --label "osm_trigpoints" --tag "osm_trigpoints" dockerfile
