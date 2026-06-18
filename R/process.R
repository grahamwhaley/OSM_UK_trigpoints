#!/usr/bin/env Rscript
#
# Copyright (c) 2026 Graham Whaley
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# An R script that imports the OrdananceSurvey and OpenStreetMap lists of 'trigpoints' and
# benchmark data in the UK and tries to find/merge duplicates and generate a submission list
# of additions/updates for OSM

version="v1.0"

# We are mostly handling WGS84 lat/lon. We'd like to see them as 7 decimal places, as that is what
# OSM stores - so this is a max of 3 digits for integer degrees (eg. 180), plus 7 digits for the
# decimal places. Of course, for most of the UK work we only have 2 digits integer, so we will end
# up getting 8 decimal digits. But, this is better than the R default of 'digits=7', as it gets
# *very* confusing during debug when you only see 5 digits on a position, but when you later dump
# it to a file or the XML, you get 13 decimal places!
#
# Mostly this is for helping when debugging, as we will hard wire the 7 decimal plasces into the
# XML code generation, to match OSM
options(digits=3+7)

library(tidyverse)
library(sf)
library(mapview)
library(ggplot2)
library(ggspatial)
library(units)
library(XML)
library(geosphere)
library(stringdist)
library(osbng)

debug = FALSE		#debugging prints - mostly useful for restricted runs

trim_dataset = 0	#Geographically trim down the data to aid development and analysis
generate_osc = 1	#Produce OsmChangeset files or not

# Note - we only generate js if we are also generating osc
# (but, that could be trivially fixed in the code if need be)
generate_js = 1		#Produce slippy map leaflet javascript files

# If we set this before we've imported, all 'good' nodes fail
check_ref_os = 0	#Check if ref:os tags match - indicating known 'good' nodes

# If we set this before we've imported, 60 out of 66 good nodes fail
check_pillar = 0	#Check if structure=='pillar', and fail if not

max_snap_distance = set_units(15, "m")	#How near a neighbour will we consider to be 'the same'
min_snap_distance = set_units(1	,"m")   #At what distance do we not bother to 'snap' co-ordinates?
osb_max_distance = set_units(15, "m")   #And test for OSB neighbour matching

#Number of decimal places to generate output in. Generally applying to the coordinates.
OSM_DIGITS = 7

#Number of decimal digits to show when storing distances, such as distance between two nodes
DIST_DIGITS = 2

####################################################################################################### 
###################################### Global data type things ###################################
####################################################################################################### 
OS_csv_file="/data/data/CompleteTrigArchive.csv"
OSM_OSM_file="/data/data/gb_trigpoints.osm"

OSM_CONFIG_FILE="/data/my_osmconf.ini"	#GDAL osm read config file
READ_SF_OPTIONS="CONFIG_FILE=/data/my_osmconf.ini"

OS_csv_file="/data/data/CompleteTrigArchive.csv"
OS_benchmark_csv_file="/data/data/CompleteBenchMarkArchive.csv"

# These are the OSM survey_point and survey_point_structure entries that we are happy to drop as
# being 'not pillars'
osm_drop_types = c(
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

# These are the types that indicate maybe the OSM node is a pillar
osm_good_types = c(
	"pillar",
	"pillar;trig_point",
	"triangulation_pillar",
	"trig_point"
	)

####################################################################################################### 
###################################### functions ######################################################
####################################################################################################### 

# Try to clean up an OSB description field to just leave the name. Possibly non-trivial!
#  Note - strings should be all lower by the time they reach here
clean_osb_desc <- function(s) {
	os <- s

	## Strip out things we don't want
	s <- gsub(" tp", " ", s)
	s <- gsub("tp ", " ", s)
	s <- gsub("fl br ", " ", s)
	s <- gsub(" nbm ", " ", s)
	s <- gsub("^nbm ", " ", s)
	s <- gsub(" no s[0-9]{3,5}", " ", s)
	s <- gsub(" s[0-9]{3,5}", " ", s)
	s <- gsub("^s[0-9]{3,5}", " ", s)

	# Note - some of the ordering here matters, such as we get things like ' sw face$',
	# so we need to be careful about matching the spaces. It might make sense when we match
	# something surrounded by spaces *or* at the end of a line to leave a space in its place
	# to aid further matches. Also, look at the 'fedmatch' package string_clean as an option.

	s <- gsub(" n ", " ", s)
	s <- gsub(" s ", " ", s)
	s <- gsub(" e ", " ", s)
	s <- gsub(" w ", " ", s)

	s <- gsub(" nw ", " ", s)
	s <- gsub(" ne ", " ", s)
	s <- gsub(" sw ", " ", s)
	s <- gsub(" se ", " ", s)

	s <- gsub(" face", "", s)

	# And we should not have any series of numbers should we? ... anywhere
	s <- gsub("[0-9]{1,6}", " ", s)

	## Now some translations of what is left
	## First, stick a space on the end of the string... to simplify the number of scans
	s <- gsub("$", " ", s)
	s <- gsub(" rd ", " road ", s)
	s <- gsub(" fm ", " farm ", s)
	s <- gsub(" mtn", " mountain ", s)
	s <- gsub(" resr", " reservoir", s)

	# And handle the remaining spaces
	s <- gsub(" +", " ", s)		## drop multiple spaces
	s <- gsub("^ +", "", s)		## clean the front
	s <- gsub(" +$", "", s)		## clean the back
	#message("  clean_osb_desc: [", os, "] -> [", s, "]")

	return(s)
}

# Try to clean up OS 'names' - see if we can find some common idioms that cause us name
# match problems.
#  Note - strings should be all lower by the time they reach here
clean_os_desc <- function(s) {
	os <- s

	s <- gsub(" \\([0-9]{4}\\)", " ", s)	# Some names have ()'d year addition

	## Now some translations of what is left
	## First, stick a space on the end of the string... to simplify the number of scans
	s <- gsub("$", " ", s)
	s <- gsub(" rd ", " road ", s)
	s <- gsub(" fm ", " farm ", s)
	s <- gsub(" resr", " reservoir", s)

	# There are a number of hyphenated names - turn those into spaces
	s <- gsub("-", " ", s)

	# And handle the remaining spaces
	s <- gsub(" +", " ", s)		## drop multiple spaces
	s <- gsub("^ +", "", s)		## clean the front
	s <- gsub(" +$", "", s)		## clean the back
	#message("  clean_os_desc: [", os, "] -> [", s, "]")

	return(s)
}

#Fuzzy string matching - try and work out if we think string 'm' might contain (a corrupted
# form of) string 's'
fuzzywuzzy <- function(s, m) {
	# Looking at the failed matches, 0.18 is definitely too high - it matches things that should fail
	# 1.7 might be a touch optimistic, but is looking pretty good...
	jw_cutoff = 0.1

	jw = stringdist(s, m, method=c("jw"))

	# If you want to diagnose and try to improve the fuzzy matching, uncomment the below
	# messages(), capture and filter them by the word 'FAIL' into a file. Sort them by score
	# (I stick them in a spreadsheet), and then stare at the data to see if there are any
	# common easy to fix bad matches.
	if( jw <= jw_cutoff ) {
		#message(" jw score: [", s, "] [", m, "] ", jw, " PASS")
		return(TRUE)
	} else {
		#message(" jw score: [", s, "] [", m, "] ", jw, " FAIL")
		return(FALSE)
	}
}

node_compare_html <- function(os_r, osb_r, osm_r) {
	s = paste(sep="",
		"\"",
		"<table style='border:1px solid black;'>",
			"<tr><th>Item</th><th>OS</th><th>OSM</th></tr>",
			"<tr><td>Name</td>",
				"<td>", os_r$Trig.Name, "</td>",
				"<td>", osm_r$name, "</td></tr>",
			"<tr><td>ele</td>",
				"<td>", os_r$HEIGHT, "</td>",
				"<td>", osm_r$ele, "</td></tr>",
			"<tr><td>FB/ref</td>",
				"<td>", osb_r$FB, "</td>",
				"<td>", osm_r$ref, "</td></tr>",
			"<tr><td>Structure</td>",
				"<td>", os_r$TYPE.OF.MARK, "</td>",
				"<td>", osm_r$survey_point_structure, "</td></tr>",
		"</table><br>"
		)

	if( os_r$distance > max_snap_distance )
		s = paste(sep="", s,
			"<span style='color: red'>",
			"OSM <a href=\\\"http://openstreetmap.org/node/", osm_r$osm_id, "\\\">",
			osm_r$osm_id, "</a> is ",
			round(os_r$distance, digits=DIST_DIGITS), " m away<br>",
			"</span>" )
	else
		s = paste(sep="", s,
			"OSM <a href=\\\"http://openstreetmap.org/node/", osm_r$osm_id, "\\\">",
			osm_r$osm_id, "</a> is ",
			round(os_r$distance, digits=DIST_DIGITS), " m away<br>" )

	s = paste(sep="", s, "\" ],")

	return(s)
}

####################################################################################################### 
###################################### Read raw data ###############################################
####################################################################################################### 
message(">>> Reading OS CSV")
OS_csv <- read.csv(OS_csv_file, header=TRUE)
os_sf_27700 <- st_as_sf(OS_csv, coords=c("EASTING", "NORTHING"), crs=27700)
os_sf_4326 <- os_sf_27700 %>% st_transform(crs=4326)

# FIXME - just a naming bodge due to re-arranging things below - fix it properly
# sometime!
os_sf <- os_sf_4326

message(">>> Reading OSM XML")
### NOTE - WARNING - the underlying GDAL library has a default set of columns it reads, and others
###  get placed in the other_tags as a set of string pairs. See:
###  https://github.com/r-spatial/sf/issues/1157
###  It might turn out we have to expand and search that other_tags list when processing...
###  Or apparently we might be able to construct our own local GDAL layer config file.
osm_sf <- read_sf(OSM_OSM_file, options=READ_SF_OPTIONS)

# Try and work out if we want to keep (a pillar) or drop (a cut mark etc.) a row
osm_sf$keep = FALSE		#Any evidence this is a real pillar?
osm_sf$drop = FALSE		#Any evidence this is *not* a pillar?
osm_sf$score = 0		#Try to score how sure we are this is a real pillar entry
osm_sf$protected = FALSE	#If the node is marked as 'do not move', then protect it!

# Collect a list of all ref's we can find so we can try some compares later
osm_ref_list <- c()
osm_ref_list_count <- 1

message(">>> Reading OS benchmark CSV")
# This is a *big* file - half a million lines!
OS_benchmark_csv <- read.csv(OS_benchmark_csv_file, header=TRUE,
	colClasses=c("EASTING"="character", "NORTHING"="character") )
message(" Benchmark file has ", nrow(OS_benchmark_csv), " entries")
# Now, see if we can filter this down to just trigpoints, which have the abbrv 'TP'
# But... also appear with extra spacing, such as 'TP $' and ' T P [$]'
# Staring at the acronym decoder for the dataset, 'P' on its own can stand for 'pillar/pole/post',
# but there is nothing for 'T' on its own, so I'm currently taking forms of 'T P' to be a badly
# typed version of 'TP'???
# Note - " TP$" excludes accidentally picking up " GTP$" entries
os_b_df <- subset(OS_benchmark_csv, grepl(" TP$| TP | T P ", OS_benchmark_csv$DESCRIPTION))
message(" Benchmark trimmed to trigpoints has ", nrow(os_b_df), " entries")
# Now let's translate their positions to WSG84

message(" translating from BNG to WGS84")
# The easting/northing looks different in this dataset - oh oh, they are in national grid!
os_b_df$BNG <- as_bng_reference(paste(os_b_df$NG.LETTERS, os_b_df$EASTING, os_b_df$NORTHING))
#os_b_df$nEASTING <- gsub(" ", "", paste(os_b_df$NG.LETTERS, os_b_df$EASTING))
#os_b_df$nNORTHING <- gsub(" ", "", paste(os_b_df$NG.LETTERS, os_b_df$NORTHING))

new_coords <- bng_to_xy(os_b_df$BNG, "centre")
new_coords <- data.frame(new_coords)
colnames(new_coords) <- c("nEASTING", "nNORTHING")

os_b_df <- cbind(os_b_df, new_coords)

os_b_sf_27700 <- st_as_sf(os_b_df, coords=c("nEASTING", "nNORTHING"), crs=27700)
os_b_sf <- os_b_sf_27700 %>% st_transform(crs=4326)

####################################################################################################### 
###################### Reduce the dataset if needed - helps with speed of development ###########
####################################################################################################### 

# Reduce the data to a subset to make it easier to view whislt debugging
if(trim_dataset) {
	# Backup the full datasets to aid debugging!
	os_sf_org = os_sf
	os_b_sf_org = os_b_sf
	osm_sf_org = osm_sf

	org_num_os = nrow(os_sf_4326)
	org_num_os_b = nrow(os_b_sf)
	org_num_osm = nrow(osm_sf)

	message(">>> Reducing processing area...to aid development speed")

	# WGS84 for Leeds
	if(0) {
		sub_name = "leeds"
		sub_lat = -1.549
		sub_lon = 53.799
		sub_span = 10000
		chosen_zoom=10
	}

	# near Ilkley - about 6 good points
	if(0) {
		# WGS84 for Ilkley
		sub_name = "ilkley"
		sub_lat = -1.82442
		sub_lon = 53.92567
		sub_span = 7000
		chosen_zoom=12
	}

	filter_by_shape <- FALSE

	# county shapefiles
	if(1) {
		#subdivision_name="Isle of Wight"		# pretty small
		#subdivision_name="Rutland"				# pretty small
		#subdivision_name="Bristol, City of"	# pretty small
		#subdivision_name="Torbay"				#Has 'goodish' nodes, 1.5m away from their refs.
		subdivision_name="West Lothian"			#Has all 4 types! including 'good'

		message("Loading county shapefile")
		#subdivision_name="Isle of Wight"

		# Shapefile acquired from data.gov.uk. As we are not pushing any of the
		# actual data from this shapefile into OSM, licensing should be fine. We are
		# merely using this data to filter our main data down into subsets to make it
		# easier to evaluate or do a number of smaller controlled OSM updates - we are
		# *not* using it to change, enhance or add to our base OS/OSM data...
		county_shapefile="/data/data/counties/CTYUA_DEC_2024_UK_BUC.shp"
		# FIXME - we should proabaly do a 'file exists' check and handle it gracefully
		# if it does not. At present we fall on our face.
		county_shapes=read_sf(county_shapefile)

		filter_shape = filter(county_shapes, CTYUA24NM==subdivision_name)
		# And transform from OSGB36 into WGS85
		sub_poly <- filter_shape %>% st_transform(crs=4326)
		message(" Filtering to shape of [", subdivision_name, "]")
		filter_by_shape <- TRUE
	}

	# further around Ilkley
	if(1) {
		# WGS84 for Ilkley
		sub_name = "ilkley"
		sub_lat = -1.82442
		sub_lon = 53.92567
		sub_span = 20000
		chosen_zoom=10
	}

	if( filter_by_shape == FALSE ) {
		# Create the poly shape by applying a 'distance buffer' around the chosen centre point
		sub_point <- data.frame(place = sub_name, lat = sub_lat, lon = sub_lon) %>% st_as_sf(coords = c('lat', 'lon')) %>% st_set_crs(4326)
		sub_poly <- st_buffer(sub_point, sub_span)
	}
  
	message(">>>  Applying sub poly filter")
	os_sf <- st_intersection(os_sf, sub_poly)
	os_b_sf <- st_intersection(os_b_sf, sub_poly)
	osm_sf <- st_intersection(osm_sf, sub_poly)

	new_num_os = nrow(os_sf)
	new_num_os_b = nrow(os_b_sf)
	new_num_osm = nrow(osm_sf)

	message(" Trimmed OS from " , org_num_os , " to " , new_num_os)
	message(" Trimmed OSB from " , org_num_os_b , " to " , new_num_os_b)
	message(" Trimmed OSM from " , org_num_osm , " to " , new_num_osm)
} else {
	chosen_zoom=6
}

####################################################################################################### 
###################### Extract the Flush Bracket numbers from the OS benchmark data ####### ###########
####################################################################################################### 

## And let's try to extract the flush bracket data into its own column
message(" extracting FB numbers from OS benchmarks")
os_b_sf$FB <- NA

# I guess in theory we might only need to do this for OSB entries that are nearest neighbours
# to an OS entry, but it's not too arduous to do them all right now
for(i in 1:nrow(os_b_sf)) {
	r <- os_b_sf[i,]

	# flush bracket numbers seem to come in the form of Snnnn or nnnnn
	# Ah, but some appear as 'S nnnn' and some nnnn
	# Sigh, and some like:
	# - 'FLBR'
	# - 'FL BK'
	# - 'NOnnnnn'
	# - 'NO S nnnn'
	# - 'FB'  		# which, has to be said, makes it look like a FootBridge!
	# - 'FL BKT'
	# - 'QL BR'		# a typo?
	# - 'FL BR <name> TP Snnnn' 	# eg Devils Dyke
	# - Some have Gnnnn instead of Snnnn ?
	# - 'F B S ?nnnn'
	# - 'S.nnnn'
	# - 'BR Snnnn'
	# - 'FL BRSnnnn'
	# - 'FL BR NOSnn nn'	# Wheeb hill
	# - 'TP Snnnn'			# Burton Overy, Inkpen Hill
	# - 'TP Snnnn FL BR'	# Botley Down
	# - 'TP Snnnn FL BR'	# Botley Down
	# - 'Snnnn TP'			# Hungerford Waterworks
	# - 'Snnnn TP'			# Hungerford Waterworks
	# - 'FL BR nnn nn'		# Kempshott
	# - 'S6456 FL BR'		# Canada (?)

	# This matches 3461 out of 3957
	#matches <- regexec("FL BR ([S0-9] ?[0-9]{3,4})", r$DESCRIPTION)

	# This matches 3594 out of 3957
	#matches <- regexec("FL ?B[RK] N?O? ?([S0-9] ?[0-9]{3,4})", r$DESCRIPTION)

	# This matches 3602 out of 3957
	#matches <- regexec("FL ?B[RK]T? N?O? ?([S0-9] ?[0-9]{3,4})", r$DESCRIPTION)

	# This matches 3690 out of 3957
	matches <- regexec("[QF]L? ?BR?K?T? ?N?O? ?([SG0-9] ?.?[0-9]{3,4})", r$DESCRIPTION)

	#If that failed, try an 'FB Snnnn' type pattern
	if( length(matches[[1]]) != 2 ) {	## 2 matches - the full string and the bracket number
		# with this we match 3671 out of 3957
		matches <- regexec("FB ([S0-9] ?[0-9]{3,4})", r$DESCRIPTION)
	}

	#If that failed, try an 'BR Snnnn' type pattern
	if( length(matches[[1]]) != 2 ) {	## 2 matches - the full string and the bracket number
		matches <- regexec("BR ([S0-9] ?[0-9]{3,4})", r$DESCRIPTION)
	}

	#If that failed, try an 'FL BR NOSnn nn' type pattern
	if( length(matches[[1]]) != 2 ) {	## 2 matches - the full string and the bracket number
		matches <- regexec("FL BR NO([S0-9]{1,3} [0-9]{1,3})", r$DESCRIPTION)
	}

	#If that failed, try an 'TP Snnnn' type pattern
	if( length(matches[[1]]) != 2 ) {	## 2 matches - the full string and the bracket number
		matches <- regexec("TP ([S0-9][0-9]{3,4})", r$DESCRIPTION)
	}

	#If that failed, try an 'Snnnn TP' type pattern
	if( length(matches[[1]]) != 2 ) {	## 2 matches - the full string and the bracket number
		matches <- regexec("([S0-9][0-9]{3,4}) TP", r$DESCRIPTION)
	}

	#If that failed, try an 'Snnnn FL BR' type pattern
	if( length(matches[[1]]) != 2 ) {	## 2 matches - the full string and the bracket number
		matches <- regexec("([S0-9][0-9]{3,4}) FL BR", r$DESCRIPTION)
	}

	#If that failed, try an 'FL BR nnn nn' type pattern
	if( length(matches[[1]]) != 2 ) {	## 2 matches - the full string and the bracket number
		matches <- regexec("FL BR  ([0-9]{2} [0-9]{3})", r$DESCRIPTION)
	}

	#If that failed, try an 'FL BR <other text> Snnnn' type pattern
	if( length(matches[[1]]) != 2 ) {	## 2 matches - the full string and the bracket number
		matches <- regexec("FL BR [A-Z]?([S0-9][0-9]{3,4})", r$DESCRIPTION)
	}

	### NOTE - after all of that, we will still have some with no bracket numbers. If you look
	### at their descriptions you will find that many of them are:
	### - BOLTs (24 of)
	### - RIVETs (135 of)
	### - WALL (62)
	### - GTP (Gatepost) (161)
	###  If we remove all of those from the benchmark entries that did not produce a flush bracket
	###   number then we end up with 42 entries that *potentially* could be TP's with no associated
	###   flush bracket numbers. Now, afaik, not all TPs do have flush brackets, so maybe this is OK

	xxx <- matches

	# Only process if we matched a number
	if( length(matches[[1]]) == 2 ) {	## 2 matches - the full string and the bracket number
		idx <- matches[[1]][2]
		len <- attr(matches[[1]], "match.length")[2]
		result <- substring(r$DESCRIPTION, idx, idx+len-1)

		os_b_sf[i,]$FB <- gsub(" ", "", result)
		if(debug) message("FB match [", os_b_sf[i,]$FB, "] from [", r$DESCRIPTION, "]")
	} else {
		if(debug) message("FB fail match from [", r$DESCRIPTION, "]")
	}
}

message(" Found ", sum(!is.na(os_b_sf$FB)), " FB's. Got ", sum(is.na(os_b_sf$FB)), " empty entries")

####################################################################################################### 
############################################# Drop OSM items that are not pillars #####################
####################################################################################################### 

message(" Dropping OSM non-pillar items")

osm_sf$drop <- FALSE

for(i in 1:nrow(osm_sf)) {
	osm_row <- osm_sf[i,]
	if( osm_row$survey_point %in% osm_drop_types ) {
		osm_sf[i,]$drop <- TRUE
	}

	if( osm_row$survey_point_structure %in% osm_drop_types ) {
		osm_sf[i,]$drop <- TRUE
	}

	# FIXME - if we find a 'not move' note, we should accomodate that in or processing
	#if( grepl("not move", tolower(d$note)) ) {
	#message(" >> PROTECTED")
}

message(" Drop ", sum(osm_sf$drop == TRUE), " OSM nodes as not pillars")
osm_sf <- filter(osm_sf, drop==FALSE)
message(">>  After dropping drops we have ", nrow(osm_sf), " rows of osm")

####################################################################################################### 
############################################# Drop deleted and non-pillar OS items  ###################
####################################################################################################### 
# Drop OS items very early if we are not going to use them, as having them in the dataset
# vastly increases the compute cost of neighbour calcs for instance.
if( 1 ) {
	message(" OS full data has ", nrow(os_sf), " entries")
	message(" OSM trigpoint data has ", nrow(osm_sf), " entries")
	## Drop any destroyed items in the OS data
	# first, save off the ones we are going to delete!
	os_sf_destroyed <- os_sf[(which(os_sf$DESTROYED.MARK.INDICATOR %in% "1")),]
	os_sf <- os_sf[-(which(os_sf$DESTROYED.MARK.INDICATOR %in% "1")),]
	new_num_os = nrow(os_sf)
	new_num_os_destroyed = nrow(os_sf_destroyed)
	message(" destroyed OS items: ", new_num_os_destroyed)
	message(" After deleting destroyed OS items we have: ", new_num_os)

	## Drop anything that is not a PILLAR!
	os_sf_not_pillar <- os_sf[-(which(os_sf$TYPE.OF.MARK %in% "PILLAR")),]
	os_sf <- os_sf[(which(os_sf$TYPE.OF.MARK %in% "PILLAR")),]
	new_num_os = nrow(os_sf)
	new_num_os_not_pillar = nrow(os_sf_not_pillar)
	message(" dropped OS items not pillars: ", new_num_os_not_pillar)
	message(" With only PILLARs we have: ", new_num_os)
}


####################################################################################################### 
############################################# Find nearest OSM neighbour for each OS ##################
####################################################################################################### 
## Calculate the nearest points between the sets
if(1) {
	# find the nearest OSM points to each OS point - use if trying to 'snap' OSM to OS points
	#nearest_points = st_nearest_points(os_sf, osm_sf)
	nearest_id = st_nearest_feature(os_sf, osm_sf)
	nearest_point <- osm_sf[nearest_id,]
	nearest_dist <- st_distance(os_sf, osm_sf[nearest_id,], by_element = TRUE)
	# And store those back into the df
	os_sf$nearest_osm_id = nearest_id
	os_sf$distance = nearest_dist
	nearest_lines <- cbind(os_sf, osm_sf[nearest_id,])
} else {
	# find the nearest OS points to each OSM point
	#nearest_points = st_nearest_points(osm_sf, os_sf)
	nearest_id = st_nearest_feature(osm_sf, os_sf)
	# And store that back to the df
	osm_sf$distance = nearest_dist
	nearest_point <- os_sf[nearest_id,]
	nearest_dist <- st_distance(osm_sf, os_sf[nearest_id,], by_element = TRUE)
	nearest_lines <- cbind(osm_sf, os_sf[nearest_id,])
}

if(debug) {
	for(i in 1:nrow(os_sf)) {
		r <- os_sf[i,]
		osm_r <- osm_sf[r$nearest_osm_id,]
		message(" OS node [", r$Trig.Name, "] matched at distance ", r$distance,
		  "to OSM [", osm_r$name, "]")
	}
}

shortest_snap=min(nearest_dist)
longest_snap=max(nearest_dist)
message(" Shortest snap distance is ", shortest_snap, "m. Longest snap is ", longest_snap, "m.")

####################################################################################################### 
############################################# And find nearest Benchmark to each OS trigpoint ########
####################################################################################################### 
message(" Calculate nearest Benchmark to each OS trigpoint")
# And try calculating the nearest OS Benchmark for each OS Trigpoint
osb_nearest_id = st_nearest_feature(os_sf, os_b_sf)
osb_nearest_point <- os_b_sf[osb_nearest_id,]
osb_nearest_dist <- st_distance(os_sf, os_b_sf[osb_nearest_id,], by_element = TRUE)
# And store those back into the df
os_sf$nearest_osb_id = osb_nearest_id
os_sf$osb_distance = osb_nearest_dist

if(debug) {
	for(i in 1:nrow(os_sf)) {
		r <- os_sf[i,]
		osb_r <- os_b_sf[r$nearest_osb_id,]
		message(" OS node [", r$Trig.Name, "] matched at distance ", r$osb_distance,
		  "to OSB [", osb_r$DESCRIPTION, "]")
	}
}

shortest_osb_snap=min(osb_nearest_dist)
longest_osb_snap=max(osb_nearest_dist)
message(" Shortest snap distance (from OS point to OS benchmark nearest neighbour) is ", shortest_osb_snap, "m.")
message(" Longest snap distance (from OS point to OS benchmark nearest neighbour) is ", longest_osb_snap, "m.")

####################################################################################################### 
############################################# Separate snappable from not ############################
####################################################################################################### 
## OK, now iterate the list of OS points and check how well, or not, their chose OSM neighbours
dist_df <- data.frame(distances=as.vector(nearest_dist))
dist_df$distances <- set_units(dist_df$distances, "m")
snappable <- nrow(filter(dist_df, distances<max_snap_distance))
un_snappable = nrow(dist_df) - snappable
message(" Snappable points < ", max_snap_distance, "m : ", snappable, ". Unsnappable (new) points: ", un_snappable)

# Turn the pairs of points into lines so we can plot them
lines = st_sfc(mapply(function(a,b){st_cast(st_union(a,b),"LINESTRING")}, nearest_lines$geometry, nearest_lines$geometry.1, SIMPLIFY=FALSE))
# and set them back to WGS84
lines <- st_set_crs(lines, 4326)

## Let's get and print some stats
os_total_points = nrow(os_sf)
osm_total_points = nrow(osm_sf)

####################################################################################################### 
############################## Try to match OS trigpoints to OS benchmark flush bracket data ##########
####################################################################################################### 
message("Trying to match OS trigpoints to OS benchmarks and OSM trigpoints")

os_sf$osb_name_match = FALSE
os_sf$osm_name_match = FALSE
os_sf$osb_fb_match = FALSE

fuzzymatches_osb = 0
fuzzymatches_osm = 0

for(i in 1:nrow(os_sf)) {
	r <- os_sf[i,]

	if( r$osb_distance <= osb_max_distance ) {
		osm_r <- osm_sf[r$nearest_osm_id,]
		osb_r <- os_b_sf[r$nearest_osb_id,]

		# Check if the OS name appears in the OSB description...
		x = tolower(r$Trig.Name)
		s = tolower(osb_r$DESCRIPTION)
		if( !is.na(x) && !is.na(s) ) {
			if( grepl(x, s, fixed=TRUE) == TRUE ) {
				os_sf[i,]$osb_name_match = TRUE
			} else {
				s = clean_osb_desc(tolower(s))
				x = clean_os_desc(tolower(x))
				#message(" try fuzzywuzzy OSB on [", x, "] [", s, "]")
				if( fuzzywuzzy(x, s) == TRUE ) {
					os_sf[i,]$osb_name_match = TRUE
					fuzzymatches_osb <- fuzzymatches_osb + 1
				}
			}
		}

		# Check if the OS name matches the OSM name
		s = tolower(osm_r$name)
		if( !is.na(x) && !is.na(s) ) {
			if( grepl(x, s, fixed=TRUE) == TRUE ) {
				os_sf[i,]$osm_name_match = TRUE
			} else {
				x = clean_os_desc(tolower(x))
				#message(" try fuzzywuzzy OSM on [", x, "] [", s, "]")
				if( fuzzywuzzy(x, s) == TRUE ) {
					os_sf[i,]$osm_name_match = TRUE
					fuzzymatches_osm <- fuzzymatches_osm + 1
				}
			}
		}

		# Check if the OSM ref 'FB' name matches the OSB FB data
		#  Just be aware, we are comparing the OSM and OSB neighbours of the current
		#  OS here, and storing the result in the OS sf - it's not quite obvious!
		if( identical(tolower(osm_r$ref), tolower(osb_r$FB)) ) {
			os_sf[i,]$osb_fb_match = TRUE
		}
	}
}

message("matching OSM names: ", nrow(filter(os_sf, osm_name_match==TRUE)) )
message("matching OSB names: ", nrow(filter(os_sf, osb_name_match==TRUE)) )
message("matching OSB FBs: ", nrow(filter(os_sf, osb_fb_match==TRUE)) )
message(" got ", fuzzymatches_osb, " extra OSB matches due to fuzzing")
message(" got ", fuzzymatches_osm, " extra OSM matches due to fuzzing")

####################################################################################################### 
############################################# And generate some plots #################################
####################################################################################################### 
message(">>> Plotting")

if(1) {
	osm_sf$source="OSM"
	os_sf$source="OS"

	# We now generate a better version of this later on once we have collected all the points
	# into a single df
	if(0) {
		p <- ggplot(data = osm_sf) +
	  	annotation_map_tile(zoom=chosen_zoom, forcedownload=FALSE) +
	  	geom_sf(data=osm_sf, color = "darkgreen", size = 1, aes(color=source), show.legend = "point") +
	  	geom_sf(data=os_sf,  color = "blue", size = 0.5, aes(color=source), show.legend = "point") +
	  	geom_sf(data=os_sf_destroyed,  color = "orange", size = 0.1, aes(color=source), show.legend = "point") +
	  	geom_sf(data=lines, fill = "gray90", color = "red", size = 0.1) +
	  	#theme_minimal(legend.position="bottom") +
	  	#theme(legend.position="bottom") +
	  	ggtitle("Map of the United Kingdom") +
	  	coord_sf(crs = 4326) # Uses standard WGS84 coordinates

		ggsave("/data/plot.jpg", plot=p)
	}

	# Plot a distribution of our nearest neighbour distances to help guide 'match and snap'
	# only plot things within 40km - removes outliers and makes the graph scale nicer.
	dist_df <- filter(dist_df, distances<set_units(40000, "m"))
	p_distr = ggplot(data = dist_df) +
	  geom_histogram((aes(distances)))

	ggsave("/data/OS_to_OSM_distance.jpg", plot=p_distr)

	## And zoom in - remove any distance larger than 100m
	dist_df <- filter(dist_df, distances<set_units(100, "m"))

	p_distr = ggplot(data = dist_df) +
	  geom_histogram((aes(distances)))

	ggsave("/data/OS_to_OSM_distance_zoom.jpg", plot=p_distr)
}

## Now, in order to make a 'better' graph (that is, the easiest way I can think to get an index
#  added), we should try and get the data in a 'tidy' format containing all snappable/new/deleted
#  points... 

# And the OSM points
full_df <- data.frame(
	geometry = osm_sf$geometry,
	type = "OSM",
	dotsize = 1.0)
# snappable
full_df <- rbind(full_df, data.frame(
	geometry = filter(os_sf, distance<=set_units(max_snap_distance, "m"))$geometry,
	type = "snappable",
	dotsize = 0.5))
# new
full_df <- rbind(full_df, data.frame(
	geometry = filter(os_sf, distance>set_units(max_snap_distance, "m"))$geometry,
	type = "new",
	dotsize = 0.5))
# destroyed
full_df <- rbind(full_df, data.frame(
	geometry = os_sf_destroyed$geometry,
	type = "destroyed",
	dotsize = 0.1))

full_sf <- st_as_sf(full_df)

# And generate a plot from the 'full' data
p2 <- ggplot(data = full_sf) +
  annotation_map_tile(zoom=chosen_zoom, forcedownload=FALSE) +
  geom_sf(aes(color=type, size=dotsize), show.legend = "point") +
  scale_size_continuous(range=c(0.1,1)) +
  geom_sf(data=lines, fill = "gray90", color = "red", size = 0.1) +
  ggtitle("Map of the United Kingdom") +
  coord_sf(crs = 4326) # Uses standard WGS84 coordinates
ggsave("/data/plot2.jpg", plot=p2)

## Make a 'polar' plot of snap distance and bearings so we can try to judge if there is a pattern
#  to the errors (which might indicate a problem with our mapping translations), or if they are
#  fairly random, in which case it is probably just mapping/accuracy problems.

os_sf$bearing <- NA
snappable_df <- filter(os_sf, distance<=set_units(max_snap_distance, "m"))
for(i in 1:nrow(snappable_df)) {
	os_row <- snappable_df[i,]
	osm_coords=st_coordinates(osm_sf[os_row$nearest_osm_id,])
	os_coords=st_coordinates(os_row$geometry)
	snappable_df[i,]$bearing <- bearing(osm_coords, os_coords)
}

## Make a 'polar' plot of snap distance and bearings so we can try to judge if there is a pattern
#  to the errors (which might indicate a problem with our mapping translations), or if they are
#  fairly random, in which case it is probably just mapping/accuracy problems.
p_polar <- ggplot(data = snappable_df, aes(bearing, drop_units(distance))) +
	geom_segment(aes(xend=bearing, yend=0.1)) +
	geom_point() +
	scale_x_continuous(limits = c(-180, 180), breaks = seq(-180, 180, 90)) +
	scale_y_continuous(limits = c(0, drop_units(max(snappable_df$distance)) )) +
	coord_polar(start=pi)

ggsave("/data/polar_snap.jpg", plot=p_polar)

####################################################################################################### 
############################################# Generate the OsmChange files ############################
####################################################################################################### 

# Try to figure out what is a 'new node', and what is a 'snap/merge' node...
# We have a number of factors to consider:
#
# - If the snap distance is larger than the threshold then they are new nodes
# - if the snap distance is below the threshold, BUT, we have failed to match
#   the OS name to the OSM name AND the OSM name is not 'NA', then this moved
#   into being a new node
# - If we have qualified on the snap distance and the name matching BUT the
#   osm ref looks like flush bracket number AND we fail to match that to any
#   FB we matched from the OSB data... then this will be a new node
#
#  And after all that, we should end up with a list of new and a list of merge nodes
#  Phew.
#
# And then... it occurs to me we should end up with *four* different categories:
#
# - new nodes - OS pillars that are not near any OSM nodes
# - 'good' nodes - where the OS data matches near enough an existing OSM node - nothing to do!
# - 'updatable' nodes - where an OS pillar 'matches' an OSM node, but we can update or add to it
# - 'reviewable' nodes - where an OS pillar is near an OSM node, but they do not match - so we should
#    probably do a manual check of why, and see if there are any corrections to be done

# Process the nodes!
{
	message(" Filtering new nodes according to name and FB matches")
	# presume all are new nodes by default
	os_sf$new_node = TRUE

	for(i in 1:nrow(os_sf) ) {
		r <- os_sf[i,]

		### Is the snap too big?
		if( r$distance > set_units(max_snap_distance, "m") ) {
			# Is a new node - nothing to do here!
		} else {
			# Extract the matching OSM row
			osm_r <- osm_sf[r$nearest_osm_id,]

			### Check if we have matched the OS and OSM names...
			if( !is.na(osm_r$name) ) {
				if( r$osm_name_match != TRUE ) {
					# Names did not match - leave it as new node
				} else {
					# We have a name match and are in distance between OS/OSM
					# Now check if we have a pair of FB numbers, and see if they can be
					# matched? *BUT*, we should check that the BM FB is within distance!

					if( r$osb_distance <= osb_max_distance ) {
						osb_r <- os_b_sf[r$nearest_osb_id,]

						osm_fb <- osm_r$ref
						osb_fb <- osb_r$FB
						if( !is.na(osm_fb) && !is.na(osb_fb) ) {
							# Is the osb fb string a substring of the osm ref?
							if( grepl(tolower(osb_fb), tolower(osm_fb), fixed=TRUE) == TRUE ) {
								# We got a match?
								os_sf[i,]$new_node = FALSE
							} else {
								# We failed the ref/FB check - so implicitly this stays as a
								# new node
							}
						} else {
							# OK, so one or the other of the OSM ref or OSB FB was 'NA' - so we can
							# still merge these...
							os_sf[i,]$new_node = FALSE
						}

					} else {
						#The FB is not within a reasonable distance to check against, so we
						# can default to the name matches, and leave this as a merge node
						# (new == FALSE)
						os_sf[i,]$new_node = FALSE
					}
				}
			}

			# Are we checking ref:os yet?
			if( check_ref_os ) {
				# If we get here and a node is qualifying as 'good', then finally check if
				# it has a matching ref:os - which is the ultimate indicator that we have
				# already 'fixed' this node in the past, and it needs no further attention
				if( os_sf[i,]$new_node == FALSE && r$distance <= min_snap_distance) {
					if( !is.na(osm_r$ref_os) ) {
						if( osm_r$ref_os != r$New.Name ) {
							message("*** Good node gone bad: [", osm_r$ref_os, "] [", r$New.Name, "]")
							# ref:os failure, so force this to be a new node, which as it is at a close
							# distance, should force it into the review list...
							os_sf[i,]$new_node = TRUE
						} else {
							message("*** Good node matches: [", osm_r$ref_os, "] [", r$New.Name, "]")
						}
					} else
					{
						message("*** Good node has NA ref:os - mark as bad")
						os_sf[i,]$new_node = TRUE
					}
				}
			}

			# Are we checking 'pillar' yet?
			if( check_pillar ) {
				# If we get here and a node is qualifying as 'good', then check if it has a
				# 'pillar' tag. We are really looking for 'survey_point:structure', and not just
				# 'survey_point' as found in some nodes...
				if( os_sf[i,]$new_node == FALSE && r$distance <= min_snap_distance) {
					if( !is.na(osm_r$survey_point_structure) ) {
						if( osm_r$survey_point_structure != "pillar" ) {
							message("*** Good node gone bad: [", osm_r$survey_point_struture, "] != [pillar]")
							# pillar failure, so force this to be a new node, which as it is at a close
							# distance, should force it into the review list...
							os_sf[i,]$new_node = TRUE
						} else {
							message("*** Good node matches: [", osm_r$survey_point_structure, "] == [pillar]")
						}
					} else
					{
						message("*** Good node has NA survey_point:structure - mark as bad")
						os_sf[i,]$new_node = TRUE
					}
				}
			}
		}
	}

	if( !check_ref_os ) { message(">>> SKIPPED ref:os matching stage") }
	if( !check_pillar ) { message(">>> SKIPPED survey_point:structure matching stage") }
}


if( generate_osc ) {
	# We have four categories to work out...
	#
	# 'good' nodes - good match between OS and OSM, and small snap distance
	# 'edit' nodes - good match between OS and OSM, and snappable distance
	# 'new' nodes  - no OSM match for OS trigpoint, so create a new OSM node
	# 'review' nodes - good match between OS and OSM position, but failed other matches,
	#   so qualify for a human review to see what's going on...

	# Now filter them....

	# The easy one - we've already done the processing for these - they are either too far
	#  away from a neighbour or they failed some sanity checks. But the ones that failed
	#  the sanity checks will fall into the 'review' category, so filter here on distance.
	newnode_df = filter(os_sf, new_node == TRUE & distance > max_snap_distance)

	# If we have marked a node as new, but it is within snappable distance, then it must
	#  have failed some sanity checks - so give it a human review
	reviewnode_df = filter(os_sf, new_node == TRUE & distance <= max_snap_distance)

	# If this is not a new node (so, it is near and passed sanity checks), but it is very
	# near its neighbour, then consider it already 'OK', and thus leave it alone? But, tbh,
	# they could do with human review in the first instance, and we could probably code it up
	# fairly easily to add any missing information like the FB numbers or elevations.
	# So, FIXME, and make it add any extra fields that are missing!
	goodnode_df = filter(os_sf, new_node == FALSE & distance <= min_snap_distance)

	# And that leaves us with nodes that are not new, but are not very near their neighbours
	#  and have passed their sanity checks
	editnode_df = filter(os_sf, new_node == FALSE & distance <= max_snap_distance )
	editnode_df = filter(editnode_df, distance >= min_snap_distance )

	num_new_nodes = nrow(newnode_df)
	num_review_nodes = nrow(reviewnode_df)
	num_good_nodes = nrow(goodnode_df)
	num_edit_nodes = nrow(editnode_df)

	message("Node count: New: ", num_new_nodes,
		" Review: ", num_review_nodes,
		" Good: ", num_good_nodes,
		" Edit: ", num_edit_nodes
		)
	message(" That should add up to (total)",
		num_new_nodes + num_review_nodes + num_good_nodes + num_edit_nodes,
		" == (nrow OS) ", nrow(os_sf) )

	############################ NEW NODES ###################################
	# Now generate the new elements XML
	message(">>> Generate new node OSC file")
	newnode_doc = newXMLDoc()
	attrs = c(
		version="0.6",
		generator="github.com/grahamwhaley/OSM_UK_trigpoints"
	)
	root = newXMLNode("osmChange", attrs=attrs, doc=newnode_doc)

	cmt = paste(sep=" ", "OSM new Nodes. Generated on:", Sys.Date())
	newXMLCommentNode(cmt, parent=root)
	cmt = paste(sep=" ", nrow(newnode_df), "nodes to process")
	newXMLCommentNode(cmt, parent=root)

	for(i in 1:nrow(newnode_df)) {
		os_row <- newnode_df[i,]
		osm_row <- osm_sf[os_row$nearest_osm_id,]
		osb_row <- os_b_sf[os_row$nearest_osb_id,]

		mod = newXMLNode("create", parent=root)
		os_coords=st_coordinates(os_row$geometry)
		attrs = c(
			id=-i,	#New node
			changeset="1",		#FIXME - what should this be??
			version="1",		#FIXME - what should this be??
			lat=round(as.double(os_coords[,"Y"]), digits=OSM_DIGITS),
			lon=round(as.double(os_coords[,"X"]), digits=OSM_DIGITS)
			)
		node = newXMLNode("node", attrs=attrs, parent=mod)

		cmt = paste(sep=" ", "OS Name", os_row$Trig.Name, "OS New Name", os_row$New.Name)
		newXMLCommentNode(cmt, parent=node)

		# As this is a new node, we can add all our trigpoint defined fields
		attrs = c( k="man_made", v="survey_point")
		newXMLNode("tag", attrs=attrs, parent=node)
		attrs = c( k="name", v=os_row$Trig.Name)
		newXMLNode("tag", attrs=attrs, parent=node)
		attrs = c( k="ele", v=os_row$HEIGHT)
		newXMLNode("tag", attrs=attrs, parent=node)
		attrs = c( k="survey_point:structure", v="pillar")
		newXMLNode("tag", attrs=attrs, parent=node)

		if( !is.na(osb_row$FB) ) {
			if( os_row$osb_distance <= osb_max_distance ) {
				cmt = paste(sep=" ", "Nearest FB is at", round(os_row$osb_distance, digits=DIST_DIGITS), "m")
				newXMLCommentNode(cmt, parent=node)
				attrs = c( k="ref", v=osb_row$FB)
				newXMLNode("tag", attrs=attrs, parent=node)
			} else {
				cmt = paste(sep=" ", "FB too far away to add at", round(os_row$osb_distance, digits=DIST_DIGITS), "m")
				newXMLCommentNode(cmt, parent=node)
			}
		} else {
			cmt = paste(sep=" ", "No Flush Bracket name to add as a ref")
			newXMLCommentNode(cmt, parent=node)
		}

		attrs = c( k="ref:os", v=os_row$New.Name)
		newXMLNode("tag", attrs=attrs, parent=node)

		cmt = paste(sep=" ", " Distance to nearest OSM node", osm_row$osm_id, "is", round(os_row$distance, digits=DIST_DIGITS), "m")
		newXMLCommentNode(cmt, parent=node)
	}
	saveXML(newnode_doc, file="/data/newnodes.osc")

	############################ REVIEW NODES ###################################
	# Now generate the review elements XML
	message(">>> Generate review node OSC file")
	reviewnode_doc = newXMLDoc()
	attrs = c(
		version="0.6",
		generator="github.com/grahamwhaley/OSM_UK_trigpoints"
	)
	root = newXMLNode("osmChange", attrs=attrs, doc=reviewnode_doc)

	cmt = paste(sep=" ", "OSM Nodes for potential review. Generated on:", Sys.Date())
	newXMLCommentNode(cmt, parent=root)
	cmt = paste(sep=" ", nrow(reviewnode_df), "nodes to process")
	newXMLCommentNode(cmt, parent=root)

	for(i in 1:nrow(reviewnode_df)) {
		os_row <- reviewnode_df[i,]
		osm_row <- osm_sf[os_row$nearest_osm_id,]
		osb_row <- os_b_sf[os_row$nearest_osb_id,]

		# Let's try to make a comment?
		mod = newXMLNode("create", parent=root)
		osm_coords=st_coordinates(osm_sf[os_row$nearest_osm_id,])
		os_coords=st_coordinates(os_row$geometry)
		attrs = c(
			id=osm_sf[os_row$nearest_osm_id,]$osm_id,
			changeset="1",		#FIXME - what should this be??
			version="1",		#FIXME - what should this be??
			# We could use either OS or OSM co-ords here. Using the OSM ones should
			# show the point to review directly on top of the one in the OSM layer you are
			# comparing against. Lets at least drop a comment about where the new coords
			# might be...
			lat=round(as.double(osm_coords[,"Y"]), digits=OSM_DIGITS),
			lon=round(as.double(osm_coords[,"X"]), digits=OSM_DIGITS)
			)
		node = newXMLNode("node", attrs=attrs, parent=mod)

		cmt = paste(sep=" ", "OS Name", os_row$Trig.Name, "OS New Name", os_row$New.Name)
		newXMLCommentNode(cmt, parent=node)

		# Add comments describing what the OS co-ords are
		cmt = paste(sep=" ", "OS node co-ords are", round(as.double(os_coords[,"Y"]), digits=OSM_DIGITS),
			",", round(as.double(os_coords[,"X"]), digits=OSM_DIGITS) )
		newXMLCommentNode(cmt, parent=node)
		cmt = paste(sep=" ", "That is", round(os_row$distance, digits=DIST_DIGITS), "m from its nearest OSM node")
		newXMLCommentNode(cmt, parent=node)
		if( !is.na(osm_row$name) ) {
			cmt = paste(sep=" ", "OS node called [", os_row$Trig.Name, "] vs OSM [", osm_row$name, "]")
		} else {
			cmt = paste(sep=" ", "OS node called [", os_row$Trig.Name, "]. OSM node has no name") 
		}
		newXMLCommentNode(cmt, parent=node)

		if( is.na(osm_row$ele) ) {
			# We can fill the ele slot
			cmt = paste(sep=" ", "Add new ele:", os_row$HEIGHT)
			newXMLCommentNode(cmt, parent=node)
		} else {
			cmt = paste(sep=" ", "ele field already set:", osm_row$ele)
			newXMLCommentNode(cmt, parent=node)
		}

		# Just note if 'survey_point' is set or not - we don't generate those
		if( is.na(osm_row$survey_point) )
			cmt = paste(sep=" ", "survey_point tag is empty (good)")
		else
			cmt = paste(sep=" ", "survey_point tag not empty (good)", osm_row$survey_point)
		newXMLCommentNode(cmt, parent=node)

		if( is.na(osm_row$survey_point_structure) ) {
			# We can fill the survey_point:structure
			cmt = paste(sep=" ", "Add new survey_point:structure: pillar")
			newXMLCommentNode(cmt, parent=node)
		} else {
			cmt = paste(sep=" ", "survey_point:structure field already set:", osm_row$survey_point_structure)
			newXMLCommentNode(cmt, parent=node)
		}

		if (!is.na(osm_row$ref) ) {
			cmt = paste(sep=" ", "OSM ref is:", osm_row$ref)
		} else {
			cmt = paste(sep=" ", "OSM node has no ref")
		}
		newXMLCommentNode(cmt, parent=node)

		if (!is.na(osm_row$ref_os) ) {
			cmt = paste(sep=" ", "OSM ref:os is:", osm_row$ref_os)
		} else {
			cmt = paste(sep=" ", "OSM node has no ref:os")
		}
		newXMLCommentNode(cmt, parent=node)

		#Not necessary, but can help with debugging
		#cmt = paste(sep=" ", "Nearest FB ref is", round(os_row$osb_distance, digits=DIST_DIGITS), "m away")
		#newXMLCommentNode(cmt, parent=node)

		if (!is.na(osb_row$FB) ) {
			if( os_row$osb_distance <= osb_max_distance ) {
				cmt = paste(sep=" ", "OS FB is", osb_row$FB, "at", round(os_row$osb_distance, digits=DIST_DIGITS), "m away")
			} else {
				cmt = paste(sep=" ", "OS FB is too far away at", round(os_row$osb_distance, digits=DIST_DIGITS), "m")
			}
		} else {
			cmt = paste(sep=" ", "OS node has no FB")
		}
		newXMLCommentNode(cmt, parent=node)
	}
	saveXML(reviewnode_doc, file="/data/reviewnodes.osc")

	############################ GOOD NODES ###################################
	# Now generate the new elements XML
	message(">>> Generate good node OSC file")
	goodnode_doc = newXMLDoc()
	attrs = c(
		version="0.6",
		generator="github.com/grahamwhaley/OSM_UK_trigpoints"
	)
	root = newXMLNode("osmChange", attrs=attrs, doc=goodnode_doc)

	cmt = paste(sep=" ", "OSM Nodes that already look 'good' on OSM. Generated on:", Sys.Date())
	newXMLCommentNode(cmt, parent=root)
	cmt = paste(sep=" ", nrow(goodnode_df), "nodes to process")
	newXMLCommentNode(cmt, parent=root)

	if( nrow(goodnode_df) != 0 ) {
		for(i in 1:nrow(goodnode_df)) {
			os_row <- goodnode_df[i,]
			osb_row <- os_b_sf[os_row$nearest_osb_id,]
			osm_row <- osm_sf[os_row$nearest_osm_id,]

			mod = newXMLNode("create", parent=root)
			os_coords=st_coordinates(os_row$geometry)
			osm_coords=st_coordinates(osm_sf[os_row$nearest_osm_id,])
			attrs = c(
				id=osm_row$osm_id,	#Actual OSM node
				changeset="1",		#FIXME - what should this be??
				version="1",		#FIXME - what should this be??
				# Use OSM co-ords, as we are not intending to edit this OSM node.
				lat=round(as.double(osm_coords[,"Y"]), digits=OSM_DIGITS),
				lon=round(as.double(osm_coords[,"X"]), digits=OSM_DIGITS)
				)
			node = newXMLNode("node", attrs=attrs, parent=mod)

			cmt = paste(sep=" ", "Lat: OSM:", round(as.double(osm_coords[,"Y"]), digits=OSM_DIGITS), "OS",
				round(as.double(os_coords[,"Y"]), digits=OSM_DIGITS) )
			newXMLCommentNode(cmt, parent=node)
			cmt = paste(sep=" ", "Lon: OSM:",
				round(as.double(osm_coords[,"X"]), digits=OSM_DIGITS), "OS",
				round(as.double(os_coords[,"X"]), digits=OSM_DIGITS) )
			newXMLCommentNode(cmt, parent=node)
			cmt = paste(sep=" ", "Separation distance:", round(os_row$distance, digits=DIST_DIGITS), "m")
			newXMLCommentNode(cmt, parent=node)

			cmt = paste(sep=" ", "Name: OSM:", osm_row$name, "OS:", os_row$Trig.Name)
			newXMLCommentNode(cmt, parent=node)
			cmt = paste(sep=" ", "Ele: OSM:", osm_row$ele, "OS:", os_row$HEIGHT)
			newXMLCommentNode(cmt, parent=node)
			cmt = paste(sep=" ", "Type: OSM:", osm_row$survey_point,
				"/", osm_row$survey_point_structure,
				"OS:", os_row$TYPE.OF.MARK)
			newXMLCommentNode(cmt, parent=node)
			if( os_row$osb_distance <= osb_max_distance ) {
				cmt = paste(sep=" ", "FB: OSM:", osm_row$ref, "OS:", osb_row$FB)
			} else {
				cmt = paste(sep=" ", "FB: OSM:", osm_row$ref, "OS: FB too far at",
					os_row$osb_diatnce, "m")
			}
			newXMLCommentNode(cmt, parent=node)

			# FIXME - add ref:os code here!
		}
	}

	saveXML(goodnode_doc, file="/data/goodnodes.osc")

	############################ EDIT NODES ###################################
	# Now generate the new elements XML
	message(">>> Generate edit node OSC file")
	editnode_doc = newXMLDoc()
	attrs = c(
		version="0.6",
		generator="github.com/grahamwhaley/OSM_UK_trigpoints"
	)
	root = newXMLNode("osmChange", attrs=attrs, doc=editnode_doc)

	cmt = paste(sep=" ", "OSM Nodes for potential edit/merge. Generated on:", Sys.Date())
	newXMLCommentNode(cmt, parent=root)
	cmt = paste(sep=" ", nrow(editnode_df), "nodes to process")
	newXMLCommentNode(cmt, parent=root)

	if( nrow(editnode_df) != 0 ) {
		for(i in 1:nrow(editnode_df)) {
			os_row <- editnode_df[i,]
			mod = newXMLNode("modify", parent=root)
			osm_coords=st_coordinates(osm_sf[os_row$nearest_osm_id,])
			os_coords=st_coordinates(os_row$geometry)
			attrs = c(
				id=osm_sf[os_row$nearest_osm_id,]$osm_id,
				changeset="1",		#FIXME - what should this be??
				version="1",		#FIXME - what should this be??
				# Unclear if we should use the old OSM co-ords here, or the new OS ones?
				# *BUT* - using the updated OS ones makes the new point show up in the right
				# (moved) place in JSOM when I load the OSC file as a layer!
				# lat=round(as.double(osm_coords[,"Y"]), digits=OSM_DIGITS),
				# lon=round(as.double(osm_coords[,"X"]), digits=OSM_DIGITS)
				lat=round(as.double(os_coords[,"Y"]), digits=OSM_DIGITS),
				lon=round(as.double(os_coords[,"X"]), digits=OSM_DIGITS)
				)
			node = newXMLNode("node", attrs=attrs, parent=mod)

			# Add comments describing what we know
			cmt = paste(sep=" ", "OS Name", os_row$Trig.Name, "OS New Name", os_row$New.Name)
			newXMLCommentNode(cmt, parent=node)
			b = snappable_df[i,]$bearing <- bearing(osm_coords, os_coords)
			cmt = paste(sep=" ", "Move bearing", b, "degrees for", round(os_row$distance, digits=DIST_DIGITS), "m")
			newXMLCommentNode(cmt, parent=node)
			cmt = paste(sep=" ", " from lat:", round(as.double(osm_coords[,"Y"]), digits=OSM_DIGITS),
				"lon:", round(as.double(osm_coords[,"X"]), digits=OSM_DIGITS) )
			newXMLCommentNode(cmt, parent=node)

			osm_row <- osm_sf[os_row$nearest_osm_id,]
			osb_row <- os_b_sf[os_row$nearest_osb_id,]

			if( is.na(osm_row$name) ) {
				# We can fill the name slot
				cmt = paste(sep=" ", "Add new name:", os_row$New.Name)
				newXMLCommentNode(cmt, parent=node)
				attrs = c( k="name", v=os_row$New.Name)
				newXMLNode("tag", attrs=attrs, parent=node)
			} else {
				cmt = paste(sep=" ", "Name field already set:", osm_row$name)
				newXMLCommentNode(cmt, parent=node)
			}

			if( is.na(osm_row$ref) ) {
				# No ref - do we have a new FB?
				if( !is.na(osb_row$FB) ) {
					# We have a new FB to add - make comment and create field
					cmt = paste(sep=" ", "Add new FB ref:", osb_row$FB)
					newXMLCommentNode(cmt, parent=node)
					attrs = c( k="ref", v=osb_row$FB)
					newXMLNode("tag", attrs=attrs, parent=node)
				}
			} else {
				cmt = paste(sep=" ", "Ref field already set:", osm_row$ref)
				newXMLCommentNode(cmt, parent=node)
			}

			if( is.na(osm_row$ref_os) ) {
				# We need to set the ref:os
				cmt = paste(sep=" ", "Add new ref:os:", os_row$New.Name)
				newXMLCommentNode(cmt, parent=node)
				attrs = c( k="ref:os", v=os_row$New.Name)
				newXMLNode("tag", attrs=attrs, parent=node)
			} else {
				if( osm_row$ref_os == os_row$New.Name ) {
					cmt = paste(sep=" ", "ref:os field already set:", osm_row$ref_os)
				} else {
					cmt = paste(sep=" ", "ref:os field already set, but wrong:",
						osm_row$ref_os, "!=", os_row$New.Name)
				}
				newXMLCommentNode(cmt, parent=node)
			}

			if( is.na(osm_row$ele) ) {
				# We can fill the ele slot
				cmt = paste(sep=" ", "Add new ele:", os_row$HEIGHT)
				newXMLCommentNode(cmt, parent=node)
				attrs = c( k="ele", v=os_row$HEIGHT)
				newXMLNode("tag", attrs=attrs, parent=node)
			} else {
				cmt = paste(sep=" ", "ele field already set:", osm_row$ele)
				newXMLCommentNode(cmt, parent=node)
			}

			if( is.na(osm_row$survey_point_structure) && is.na(osm_row$survey_point) ) {
				# We can fill the structure slot
				cmt = paste(sep=" ", "Add new structure: pillar")
				newXMLCommentNode(cmt, parent=node)
				attrs = c( k="survey_point:structure", v="pillar")
				newXMLNode("tag", attrs=attrs, parent=node)
			} else {
				cmt = paste(sep=" ", "survey_point[_structure] field already set:",
					osm_row$survey_point,
					"/", osm_row$survey_point_structure)
				newXMLCommentNode(cmt, parent=node)
			}

			# And store that bearing for later
			snappable_df[i,]$bearing <- b
		}
	}

	saveXML(editnode_doc, file="/data/editnodes.osc")

	###############################################################################
	############################ JS generation ###################################
	###############################################################################

	if( generate_js ) {
		message(">>> Generating slippy leaflet JS files")

		############################ NEW NODES ###################################
		newnode_file = "/data/newnodes.js"
		message(">>>  generate new nodes js")

		write(paste("var newnode_array = ["), file=newnode_file, append=FALSE)

		for(i in 1:nrow(newnode_df)) {
			os_row <- newnode_df[i,]
			osm_row <- osm_sf[os_row$nearest_osm_id,]
			osb_row <- os_b_sf[os_row$nearest_osb_id,]

			os_coords=st_coordinates(os_row$geometry)
			write(paste(sep="", "\t[",
				round(as.double(os_coords[,"Y"]), digits=OSM_DIGITS), ",",
				lon=round(as.double(os_coords[,"X"]), digits=OSM_DIGITS), ",",
				node_compare_html(os_row, osb_row, osm_row) ),
				file=newnode_file,append=TRUE)
		}
		write(paste("];"), file=newnode_file, append=TRUE)

		############################ REVIEW NODES ###################################
		reviewnode_file = "/data/reviewnodes.js"
		message(">>>  generate review nodes js")

		write(paste("var reviewnode_array = ["), file=reviewnode_file, append=FALSE)

		for(i in 1:nrow(reviewnode_df)) {
			os_row <- reviewnode_df[i,]
			osm_row <- osm_sf[os_row$nearest_osm_id,]
			osb_row <- os_b_sf[os_row$nearest_osb_id,]

			os_coords=st_coordinates(os_row$geometry)
			write(paste(sep="", "\t[",
				round(as.double(os_coords[,"Y"]), digits=OSM_DIGITS), ",",
				lon=round(as.double(os_coords[,"X"]), digits=OSM_DIGITS), ",",
				node_compare_html(os_row, osb_row, osm_row) ),
				file=reviewnode_file,append=TRUE)
		}
		write(paste("];"), file=reviewnode_file, append=TRUE)

		############################ GOOD NODES ###################################
		goodnode_file = "/data/goodnodes.js"
		message(">>>  generate good nodes js")

		write(paste("var goodnode_array = ["), file=goodnode_file, append=FALSE)

		for(i in 1:nrow(goodnode_df)) {
			os_row <- goodnode_df[i,]
			osm_row <- osm_sf[os_row$nearest_osm_id,]
			osb_row <- os_b_sf[os_row$nearest_osb_id,]

			os_coords=st_coordinates(os_row$geometry)
			write(paste(sep="", "\t[",
				round(as.double(os_coords[,"Y"]), digits=OSM_DIGITS), ",",
				lon=round(as.double(os_coords[,"X"]), digits=OSM_DIGITS), ",",
				node_compare_html(os_row, osb_row, osm_row) ),
				file=goodnode_file,append=TRUE)
		}
		write(paste("];"), file=goodnode_file, append=TRUE)

		############################ EDIT NODES ###################################
		editnode_file = "/data/editnodes.js"
		message(">>>  generate edit nodes js")

		write(paste("var editnode_array = ["), file=editnode_file, append=FALSE)

		for(i in 1:nrow(editnode_df)) {
			os_row <- editnode_df[i,]
			osm_row <- osm_sf[os_row$nearest_osm_id,]
			osb_row <- os_b_sf[os_row$nearest_osb_id,]

			os_coords=st_coordinates(os_row$geometry)
			write(paste(sep="", "\t[",
				round(as.double(os_coords[,"Y"]), digits=OSM_DIGITS), ",",
				lon=round(as.double(os_coords[,"X"]), digits=OSM_DIGITS), ",",
				node_compare_html(os_row, osb_row, osm_row) ),
				file=editnode_file,append=TRUE)
		}
		write(paste("];"), file=editnode_file, append=TRUE)

		############################ STATUS text ###################################
		# Also dump some status text into a js var so we can load and display that
		status_file = "/data/statustext.js"
		message(">>>  generate status text js")

		txt = paste(sep=" ", "Data gathered on:", Sys.Date(), "<br>")
		txt = paste(sep=" ", txt,
			"Total nodes:", nrow(os_sf),
			"New:", num_new_nodes,
			"Review:", num_review_nodes,
			"Good:", num_good_nodes,
			"Edit:", num_edit_nodes
			)
		write(
			paste(
				"var status_text = \"",
				txt,
				"\""
			),
			file=status_file, append=FALSE)
	}
} else {
	message(" Skipping OSC file generation")
	message("  Found ", nrow(newnode_df), " New OSM trigpoints")
	message("  Found ", nrow(reviewnode_df), " Reviewable OSM trigpoints")
	message("  Found ", nrow(goodnode_df), " Good (already matched) OSM trigpoints")
	message("  Found ", nrow(editnode_df), " editable (snapable) OSM trigpoints")
}

