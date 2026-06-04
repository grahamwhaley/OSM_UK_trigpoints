#!/usr/bin/env Rscript
#
# Copyright Graham Whaley (M8WRW)
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Generate a list of all the unique tags used for OSM man_made=survey_point tagged nodes

version="v1.0"

library(tidyverse)
library(sf)
library(ggspatial)
library(units)
library(geosphere)
library(osbng)	# To convert British National Grid

# Types of 'trigpoint' to drop from the OSM data - not the 'pillar's that we are looking for
# Note - not currently filterting out:
#  'benchmark' - as that could be a pillar
#  'medallion' - as I've not figure out what that is yet
osm_drop_types = c(
	"beacon",
	"berntsen",
	"block",
	"bolt",
	"bracket",
	"cairn",
	"cut",
	"feno_marker",
	"ground_bolt",
	"hexagonal_bolt",
	"indented_pin",
	"metal_plate",
	"pin",
	"plaque"
	)

####################################################################################################### 
###################################### Global data type things ###################################
####################################################################################################### 
OSM_OSM_file="/data/data/gb_trigpoints.osm"

OSM_CONFIG_FILE="/data/my_osmconf.ini"	#GDAL osm read config file
READ_SF_OPTIONS="CONFIG_FILE=/data/my_osmconf.ini"


####################################################################################################### 
###################################### Read raw data ###############################################
####################################################################################################### 

message(">>> Reading OSM XML")
### NOTE - WARNING - the underlying GDAL library has a default set of columns it reads, and others
###  get placed in the other_tags as a set of string pairs. See:
###  https://github.com/r-spatial/sf/issues/1157
###  It might turn out we have to expand and search that other_tags list when processing...
###  Or apparently we might be able to construct our own local GDAL layer config file.
osm_sf <- read_sf(OSM_OSM_file, options=READ_SF_OPTIONS)

####################################################################################################### 
############################################# Now drop OSM items that are not pillars ################
####################################################################################################### 

osm_sf$drop <- osm_sf$survey_point %in% osm_drop_types
message(" dropping ", nrow(filter(osm_sf, drop==TRUE)), " non-pillar survey_point types")
osm_sf <- filter(osm_sf, drop==FALSE)

osm_sf$drop <- osm_sf$survey_point_structure %in% osm_drop_types
message(" dropping ", nrow(filter(osm_sf, drop==TRUE)), " non-pillar survey_point_structure types")
osm_sf <- filter(osm_sf, drop==FALSE)

osm_marked_pillars <- nrow(filter(osm_sf, survey_point=="pillar"))
message(" ", osm_marked_pillars, ", of survey_point==pillar")
message(" ", nrow(filter(osm_sf, survey_point_structure=="pillar")), " of survey_point_structure==pillar")
osm_marked_pillars <- osm_marked_pillars + nrow(filter(osm_sf, survey_point_structure=="pillar"))
message(" ", osm_marked_pillars, " total OSM marked 'pillar's")

message(" ", nrow(osm_sf), " OSM rows left")


####################################################################################################### 
############################################# Print out remaining unique survey_point types ###########
####################################################################################################### 

point_types <- unique(c(osm_sf$survey_point, osm_sf$survey_point_structure))
message("Remaining survey_point types are:")
print(point_types)

####################################################################################################### 
############################################# Now gather a list of unique tags ########################
####################################################################################################### 

message(" extracting all tag names")
osm_tag_names <- data.frame(names=names(osm_sf))
osm_tag_names <- filter(osm_tag_names, names!="other_tags")

# And now expand out the other_tags...
other_tags <- osm_sf %>% select(other_tags) %>% separate_rows(other_tags, sep='\",\"') %>% separate(other_tags, into=c("key", "value"), sep='\"=>\"')
yyy <- other_tags
other_tags <- other_tags %>% mutate(key = str_replace(key, '\"', ''))
zzz <- other_tags
# I don't know where we get an NA from, but there seems to be one in the list!
other_tags <- filter(other_tags, !is.na(key))
# unique() works, but count() gives us unique entries and their frequency!
#other_tags_list <- unique(other_tags$key)
osm_df <- data.frame(key=other_tags$key)
osm_tag_count <- osm_df |> count(key, sort=TRUE)

message(">>>>> all unique tags:")
print(osm_tag_count)
message(">>>>> top 30 tags:")
print(head(osm_tag_count,30))
message(" And we have ", nrow(osm_tag_count), " unique tags in the OSM data")
