#!/bin/sh
#
# Copyright (c) 2026 Graham Whaley
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This script is run inside the docker container to run the actual R code

set -x
set -ev

# Run the code!
Rscript /data/process.R
