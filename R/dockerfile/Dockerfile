# Copyright (c) 2026 Graham Whaley
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Dockerfile containing all the 'R' needed to process
# the trigpoint data

# 'rocker' images give us a good R base to start from
FROM rocker/geospatial

LABEL DOCKERFILE_VERSION="1.1"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update
RUN apt-get -y install libudunits2-dev libproj-dev

RUN install2.r --error --deps TRUE \
	osmextract osmdata XML sf ggspatial osbng
