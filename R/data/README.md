# Data file directory for OS trig conversion

This directory contains datafiles used by the OS trig conversion code.

Some files are included here by default (on github) so you don't have to find or generate them
yourself. Others you will need to source and place here, or will be automatically downloaded
when you run the code.

## **Necessary files**

The following files are needed to do any processing. They are the primary datafiles. They are not
supplied in this repository, and will need to be downloaded and placed in this directory before any
processing can be done.

### `CompleteTrigArchive.csv`

This is the primary trig datafile from the Ordnance Survey. You can get it
[from here](https://www.ordnancesurvey.co.uk/geodesy-positioning/legacy-data/trig-search)

### `CompleteBenchMarkArchive.csv`

This is the primary benchmark datafile from the Ordnance Survey. You can get it
[from here](https://www.ordnancesurvey.co.uk/geodesy-positioning/legacy-data/benchmark-search)

### `gb_trigpoints.osm`

This is the XML OSM datafile containing all the `man_made=survey_point` nodes for the U.K. I generate
mine by downloading the Great Britain OSM data in PBM format from
[geofabrik.de](https://download.geofabrik.de/europe/great-britain.html) and then use `osmosis`
to extract the required nodes:

```sh
osmosis --read-pbf ./great-britain-latest.osm.pbf --node-key-value keyValueList="man_made.survey_point" --write-xml gb_trigpoints.osm 
```

### `us_nga_egm96_15.tif`

This is a GeoTIFF Geodetic shift file used by `PROJ` when we are doing a height transformation from
(ODN ->) ETRS89 -> EGM96. The upstream version from `PROJ` comes in a 15' minutes of arc grid, which
does not quite give us the transform accuracy we are looking for. Thus, we carry our own higher
resolution version at 5' minutes of arc resolution. This was discussed and the file generated
[on the OSM forum](https://community.openstreetmap.org/t/import-import-proposal-proposed-import-of-ordnance-survey-pillar-trigpoints/145852/40).

A little strangely, we still name the file as if it were the 15 minutes file version, as that is what
`PROJ` is wired to look for by default, even though the file itself does contain 5' minutes data.
In theory we could get around that naming anomaly by coding our own `PROJ` pipeline transforms in the
code, but when I tried that previously I had trouble getting the pipelines running, and thus have gone
with the naming hack here.

### If you are filtering by area

If you are restricting the nodes processed by area (which is very useful during development to cut
down the runtime between cycles btw...), then you will need

`counties/CTYUA_DEC_2024_UK_BUC.shp`

This can be acquired from [this gov.uk site](https://ckan.publishing.service.gov.uk/dataset/counties-and-unitary-authorities-december-2024-boundaries-uk-buc/resource/7d535263-3fcc-4a14-ba37-d34f36381fa5)

## Automatically downloaded / optional files

If `PROJ` needs a datafile and cannot find it locally it can (and we have enabled this in the code)
download the fragments of the files it needs and cache them locally. We have set the paths in the
script so that cache is generated in this directory under `proj/cache.db`. This should help reduce
downloads in the event of multiple runs (such as during development).

After having done a run, examination of that database shows these additional files having fragments
downloaded:

* https://cdn.proj.org/uk_os_OSGM15_GB.tif

  [OS data](https://www.ordnancesurvey.co.uk/blog/ostn15-new-geoid-britain) derived geoid height model
  for converting from ETRS89 to ODN (or vice-versa), used as part of our ODN->WGS84->EGM96 height
  conversion path.

* https://cdn.proj.org/uk_os_OSTN15_NTv2_OSGBtoETRS.tif

  [OS data](https://www.ordnancesurvey.co.uk/blog/ostn15-new-geoid-britain) derived geoid coordinate
  model used to convert between OSGB36 and ETRS89.

If you expect to be running the code a lot you might want to consider obtaining both of those files
from the `PROJ` site and installing them in this directory.
