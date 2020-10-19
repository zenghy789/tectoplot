#!/bin/bash
# set -x
# Uncomment the above line for an ultimate debugging experience
#
# Script to make nice seismotectonic plots with integrated plate motions and
# earthquake kinematics, plus cross sections, primarily using GMT.
#
# Kyle Bradley, Nanyang Technological University, August 2020
# Prefers GS 9.26 (and no later) for transparency

# NOTES
# On OSX, filenames on HFS+ filesystems are case insensitive. This causes problems
# with using filenames as tags for various data.
# e.g. NB_1.pldat == nb_1.pldat and files will always get overwritten rather than created.
# This is important for plate models like MORVEL56 with identical plate names nb/NB

# TO DO:
# add a box-and-whisker option to the -mprof command, taking advantage of our quantile calculations and gmt psxy -E
# Update seismicity for legend plot using SEISSTRETCH
# Try to match scale of seismicity with pscmeca
# Option to remove seismicity that matches CMT mechanisms to avoid double-plotting
# Check behavior for plots with areas that cross the Lon=0/360 meridian.
# Change CPT behavior to generate new CPT files and not replace ones in CPT folder
# Update script to apply gmt.conf at start and also at various other points
# Option to scale siesmicity with magnitude
# Add option to not plot the grid and instead output a georeferenced TIFF raster
# Update commands to use --GMT_HISTORY=false when necessary, rather than using extra tmp dirs
# Add ability to make swath profile automatically from the displayed grid.
# Option to add produced dataset (e.g. ANSS data downloaded) as a swath data file
# (Can just copy the input -mprof control file and append $ .... command with relevant options)?
# Add option to plot Euler poles of rotation with confidence ellipses
# Ability to highlight data from a given time period? (e.g. by increasing transparency of all other layers?)
# Option to exaggerate focal mechanism size difference?
# Add options for controlling CPT of focal mechanisms beyond coloring with depth?
# Add color and scaling options for -kg
# Perform GPS velocity calculations from Kreemer2014 ITRF08 to any reference frame
# using Kreemer2014 Euler poles OR from other data using Model/ModelREF - ModelREF-ITRF08?
#
# Find way to make accurate distance buffers (without contouring a distance grid...)
#
# Develop a better system for default scaling of map elements (line widths, arrow sizes, etc).
# 1 point = 1/72 inches = 0.01388888... inches
#
# Evolve to a more function-oriented script as much as possible
#
# Enable repeated options for all plotting commands to allow multiple plots?
# e.g. -t customgrid.grd customgrid.cpt -t customgrid2.grd customgrid2.cpt
# using bash arrays and a counter system.
#
# Design a tectoplot control file format?
#
# tectoplot.control
# volcano { VOLC_FILL red VOLC_EDGE white VOLC_SIZE 3.0p }
# gisline { /path/to/data/ LINEWIDTH 1.0 LINECOLOR red }
# volcano { VOLC_FILL white }
#

################################################################################
# Messaging and debugging routines

_ERR_HDR_FMT="%.23s %s[%s]: "
_ERR_MSG_FMT="${_ERR_HDR_FMT}%s\n"

function error_msg() {
  printf "$_ERR_MSG_FMT" $(date +%F.%T.%N) ${BASH_SOURCE[1]##*/} ${BASH_LINENO[0]} "${@}"
}

function info_msg() {
  if [[ $narrateflag -eq 1 ]]; then
    printf "TECTOPLOT %05s: " ${BASH_LINENO[0]}
    printf "${@}\n"
  fi
}

################################################################################
# Define paths and defaults

THISDIR=$(pwd)

TECTOPLOT_VERSION="TECTOPLOT 0.1, August 2020"
GMTREQ="6"
RJOK="-R -J -O -K"

# TECTOPLOTDIR should be an absolute path where the script resides
TECTOPLOTDIR="/Users/kylebradley/Dropbox/scripts/tectoplot/"
DEFDIR=$TECTOPLOTDIR"tectoplot_defs/"

# These files are sourced using . command, so they should be valid bash scripts

TECTOPLOT_DEFAULTS_FILE=$DEFDIR"tectoplot.defaults"
TECTOPLOT_PATHS_FILE=$DEFDIR"tectoplot.paths"
TECTOPLOT_PATHS_MESSAGE=$DEFDIR"tectoplot.paths.message"

################################################################################
# Load default file stored in the same directory as tectoplot

if [[ -e $TECTOPLOT_DEFAULTS_FILE ]]; then
  . $TECTOPLOT_DEFAULTS_FILE
else
  # No defaults file exists! Warn and exit.
  error_msg "Defaults file does not exist: $TECTOPLOT_DEFAULTS_FILE"
  exit 1
fi

if [[ -e $TECTOPLOT_PATHS_FILE ]]; then
  . $TECTOPLOT_PATHS_FILE
else
  # No paths file exists! Warn and exit.
  error_msg "Paths file does not exist: $TECTOPLOT_PATHS_FILE"
  exit 1
fi

function formats() {
cat <<-EOF
$TECTOPLOT_VERSION
DATA FORMATS

A plate file contains all closed polygon data in this format (GMT).
Longitudes are [-180:180]. Use block_360_to_180.sh to convert blocks/poles.
There are no headers in the file. It starts with > ID.
The plate file does not have an empty header > line at the end.

Plate IDs must be unique and must be case insensitive, because OSX filesystems
do not support case sensitivity and we name files after each plate ID. Do not
use 'NB' and 'nb' for New Bismarck and Nubia.

Plate File
----------
> ID_1
Lon1 Lat1
Lon2 Lat2
...
LonN LatN
Lon1 Lat1
> NA_1
Lon1 Lat1
Lon1 Lat2
...
LonN LatN
Lon1 Lat1

Polygons should ideally be oriented Clockwise (use gmt spatial -Q+h to check),
(but we do change the orientation during loading).

There can be multiple polygons representing different areas of the same plate.
They should be named ID_1 ID_2 ID_3 etc and are associated with Euler Pole ID
in the Euler Pole file.

Euler Pole files have the form ID Lat Lon W format

All poles are relative to a common reference frame
The reference frame doesn't matter unless no reference plate is selected,
in which case velocities will be in that reference frame

Pole FILE (W is in deg/Myr)
-------------
ID Lat Lon W
NA Lat Lon W
...
EOF
}

function usage() {
cat <<-EOF
  $TECTOPLOT_VERSION
  Kyle Bradley, Nanyang Technological University
  kbradley@ntu.edu.sg

  This script uses GMT and custom code to make seismotectonic maps based on
  relative motions of plates with Euler poles. It can load and interpret
  TDEFNODE model results.

  Developed for OSX Catalina

  REQUIRES: GMT${GMTREQ} gdal gawk geod ps2pdf Preview(or equivalent)

  USAGE: tectoplot [...]

    'tectoplot remake' will re-calculate using the last tectoplot command
     executed in the current directory.

    'tectoplot remake file.txt' will use the first line of file.txt to re-run a
     saved command. The *.history file produced by tectoplot works with this.

  Map layers are generally plotted in the order they are specified.
  All options are case sensitive (SRTM15 vs srtm15)

  Default variables are stored in $TECTOPLOTDIR/tectoplot.defaults
  File paths are defined in $TECTOPLOTDIR/tectoplot.paths

  User-defined default variable values can be loaded from a file with --loaddef.
  Variables are loaded when --loaddef is called and don't affect earlier command
  parsing.

  Optional arguments:
  [opt] is required if the flag is present
  [[opt]] if not specified will assume a default value or will not be used

GMT control
  -gmtvars         [{VARIABLE value ...}]              set GMT default variables before plotting happens
  -pos X Y         Set X Y position of plot origin     (GMT format -X$VAL -Y$VAL; e.g -Xc -Y1i etc)
  -RJ              [{ -Retc -Jetc }]                   provide custom R, J GMT strings
  -B               [{ -Betc -Betc }]                   provide custom B strings
  -pss             [size]                              PS page size in inches (8)
  -psr             [0-1]                               scale factor of map ofs pssize
  -psm             [size]                              PS margin in inches (0.5)
  -pgs             [gridline spacing]                  override map gridline spacing
  -pgo                                                 turn grid lines off
  -cpts                                                remake default CPT files

Plotting/control commands:
  --data                                               list data sources and exit
  --defaults                                           print default values and exit.
                                                          Can edit and load using -vars
  -e|--execute     [bash script file]                  runs a script using source command
  --formats                                            print information on data formats and exit
  -h|--help                                            print this message and exit
  -i|--vecscale    [value]                             scale all vectors (0.02)
  -ips             [filename]                          plot on top of an unclosed .ps file
  --keepopenps                                         don't close the PS file
  --legend         [[width]]                           plot legend above the map area (color bar width=2i)
  -n|--narrate                                         echo a lot of information during processing
  -o|--out         [filename]                          name of output file
  -op|--overplot   [X Y]                               plot over previous output (save map.ps only)
                    X,Y are horizontal and vertical offset in inches
  --open           [[program]]                         open PDF file at end using program
  -r|--range       [MinLon MaxLon MinLat MaxLat]       area of interest, degrees
  -tm|--tempdir    [tempdir]                           use tempdir as temporary directory
  --verbose                                            set gmt -V flag for all calls
  -mprof           [control_file] A B X Y              multiple swath profile
                      [A,B] = -JXAi/Bi    [X,Y] = position of profile relative to current origin
  -mgrid           [topo | mag | grav | custom]        mprof uses specified grid instead of control file grid
  -vars            [variables file]                    set variable values using bash source function
  -setvars         { VAR1 VAL1 VAR2 VAL2 }             set variable values

Topography/bathymetry:
  -t|--topo        [[SRTM30 | SRTM15 | SRTM1S | GEBCO20 | GEBCO1 | filename]]
                                                       plot shaded relief (inc. custom grid)
  -ts                                                  don't plot shaded relief/topo grid
  -tn              [interval (m)]                      plot topographic contours
  -tc|--cpt        [cptfile]                           use custom cpt file for grid
  -tt|--topotrans  [transparency%]                     transparency of topo grid

Additional map layers:
  -a|--coast       [[a,f,h,i,l,c]] { gmtargs }         plot coastlines
  -ac              [[landcolor]] [[seacolor]]          fill coastlines/sea (requires subsequent -a command)
  -af                                                  plot GEM active fault lines
  -b|--slab2       [[layers string: czm]]              plot Slab2 data; default is c
        c: slab contours    z: seismic catalog   m: compiled focal mechanisms  d: declustering
  -g|--gps         [[RefPlateID]]                      plot GPS data from Kreemer 2014 / rel. to RefPlateID
  -l|--line        [filename] [color]                  plot data file as color line
  -gg|--extragps   [filename]                          plot a GPS file additionally
  -im|--image      [filename] { gmtargs }              plot a RBG GeoTiff file
  -m|--mag         [[transparency%]]                   plot EMAG2 crustal magnetization
  -s|--srcmod                                          plot fused SRCMOD EQ slip
  -sv|--slipvector [filename]                          plot data file of slip vector azimuths [Lon Lat Az]
  -v|--gravity     [[FA | BG | IS]] [transparency%] [rescale]            rescale=rescale colors to min/max
                    plot WGM12 gravity. FA = free air | BG == Bouguer | IS = Isostatic
  -vc|--volc                                           plot Pleistocene volcanoes
  -pt|--point      [filename] [cptfile]                plot point dataset as circles
  -pp|--cities     [[min population]]                  plot cities with minimum population, color by population
  -ppl             [[min population]]                  label cities with a minimum population
  -z|--seis        [[scale]]                           plot seismic epicenters (download from ANSS)

Focal mechanisms:
  -c|--cmt         [[scale]]                           plot scaled focal mechanisms
  -cd|--cmtdepth   [depth]                             maximum depth of CMTs, km
  -cm|--cmtmag     [minmag maxmag]                     magnitude bounds for cmt
  -cw                                                  plot CMTs with white compressive quads
  -ct|--cmttype    [nts | nt | ns | n | t | s]         sets earthquake types to plot CMTs
  -zr1|--eqrake1   [[scale]]                           color focal mechs by N1 rake
  -zr2|--eqrake2   [[scale]]                           color focal mechs by N2 rake

Focal mechanism kinematics (CMT):
  -kg|--kingeo                                         plot strike and dip of nodal planes
  -kl|--nodalplane [1 | 2]                             plot only NP1 (lower dip) or NP2
  -km|--kinmag     [minmag maxmag]                     magnitude bounds for kinematics
  -kt|--kintype    [nts | nt | ns | n | t | s]         select types of EQs to plot kin data
  -ks|--kinscale   [scale]                             scale kinematic elements
  -kv|--slipvec                                        plot slip vectors

Plate models (require a plate motion model specified by -p or --tdefpm)
  -f|--refpt       [Lon/Lat]                           reference point location
  -p|--plate       [[GBM | MORVEL | GSRM]] [[refplate]] select plate motion model, relative to stationary refplate
  -pe|--plateedge  [[GBM | MORVEL | GSRM]]             plot plate model polygons
  -pf|--fibsp      [km spacing]                        Fibonacci spacing of plate motion vectors; turns on vector plot
  -px|--gridsp     [Degrees]                           Gridded spacing of plate motion vectors; turns on vector plot
  -pl                                                  label plates
  -ps              [[GBM | MORVEL | GSRM]]             list plates and exit. If -r is set, list plates in region
  -pr                                                  plot plate rotations as small circles with arrows
  -pz              [[scale]]                           plot plate boundary azimuth differences (does edge computations)
                                                       histogram is plotted into az_histogram.pdf
  -pv              [cutoff distance]                   plot plate boundary relative motion vectors (does edge computations)
                                                       cutoff distance dictates spacing between plotted velocity pairs
  -w|--euler       [Lat] [Lon] [Omega]                 plots vel. from Euler Pole (grid)
  -wp|--eulerplate [PlateID] [RefplateID]              plots vel. of PlateID wrt RefplateID
                   (requires -p or --tdefpm)
  -wg              [residual scale]                    plots -w or -wp at GPS sites (plot scaled residuals only)
  -pvg             [rescale]                           plots a plate motion velocity grid. rescale=rescale colors to min/max

TDEFNODE block model
  --tdefnode       [folder path] [lbsovrfet ]          plot TDEFNODE output data.
        l=locking b=blocks s=slip o=observed gps vectors v=modeled gps vectors
        r=residual gps vectors; f=fault slip rates; a=block name labels
        e=elastic component of velocity; t=block rotation component of velocity
        y=fault midpoint sliprates, spaced
  --tdefpm         [folder path] [RefPlateID]          use TDEFNODE results as plate model
  --tdeffaults     [1,2,3,5,...]                       select faults for coupling plotting and contouring

Common variables to modify using -vars [file] and -setvars { VAR value ... }

Topography:     TOPOTRANS [$TOPOTRANS]

Earthquakes:    EQMAXDEPTH [$EQMAXDEPTH] - SEISSIZE [$SEISSIZE] - SEISSCALE [$SEISSCALE] - SEISSYMBOL [$SEISSYMBOL]
                SCALEEQS [$SCALEEQS] - SEISSTRETCH [$SEISSTRETCH] - SEISSTRETCH_REFMAG [$SEISSTRETCH_REFMAG]

Plate model:    PLATEARROW_COLOR [$PLATEARROW_COLOR] - PLATEARROW_TRANS [$PLATEARROW_TRANS]
                PLATEVEC_COLOR [$PLATEVEC_COLOR] - PLATEVEC_TRANS [$PLATEVEC_TRANS]
                LATSTEPS [$LATSTEPS] - GRIDSTEP [$GRIDSTEP] - AZDIFFSCALE [$AZDIFFSCALE]
                PLATELINE_COLOR [$PLATELINE_COLOR] - PLATELINE_WIDTH [$PLATELINE_WIDTH]
                PLATELABEL_COLOR [$PLATELABEL_COLOR] - PLATELABEL_SIZE [$PLATELABEL_SIZE]
                PDIFFCUTOFF [$PDIFFCUTOFF]

CMT focal mech: CMTSCALE [$CMTSCALE] - CMT_MAXDEPTH [$CMT_MAXDEPTH]
                CMT_NORMALCOLOR [$CMT_NORMALCOLOR] - CMT_SSCOLOR [$CMT_SSCOLOR] - CMT_THRUSTCOLOR [$CMT_THRUSTCOLOR]

CMT kinematics: KINSCALE [$KINSCALE] - NP1_COLOR [$NP1_COLOR] - NP2_COLOR [$NP2_COLOR]
                RAKE1SCALE [$RAKE1SCALE] - RAKE2SCALE [$RAKE2SCALE]

Active faults:  GEMLINECOLOR [$GEMLINECOLOR] - GEMLINEWIDTH [$GEMLINEWIDTH]

Volcanoes:      V_FILL [$V_FILL] - V_SIZE [$V_SIZE] - V_LINEW [$V_LINEW]

Coastlines:     COAST_QUALITY [$COAST_QUALITY] - COAST_LINEWIDTH [$COAST_LINEWIDTH] - COAST_LINECOLOR [$COAST_LINECOLOR] - COAST_KM2 [$COAST_KM2]

Gravity:        GRAV_RESCALE [$GRAVRESCALE]

Magnetics:      MAG_RESCALE [$MAG_RESCALE]

EOF
}

# Update if TECTOPLOT_PATHS file is
function datamessage() {
  . $TECTOPLOT_PATHS_MESSAGE
}

function defaultsmessage() {
  cat $TECTOPLOT_DEFAULTS_FILE
}

# Flags that start with a value of zero
calccmtflag=0
customgridcptflag=0
defnodeflag=0
defaultrefflag=0
doplateedgesflag=0
dontplottopoflag=0
euleratgpsflag=0
eulervecflag=0
filledcoastlinesflag=0
gpsoverride=0
keepopenflag=0
legendovermapflag=0
makelegendflag=0
makegridflag=0
makelatlongridflag=0
manualrefplateflag=0
narrateflag=0
openflag=0
outflag=0
outputplatesflag=0
overplotflag=0
overridegridlinespacing=0
platerotationflag=0
plotcmt=0
plotcustomtopo=0
ploteulerobsresflag=0
plotgrav=0
plotmag=0
plotplateazdiffsonly=0
plotplates=0
plotshiftflag=0
plotslab2eq=0
plotsrcmod=0
plottopo=0
psscaleflag=0
refptflag=0
remakecptsflag=0
replotflag=0
strikedipflag=0
svflag=0
tdeffaultlistflag=0
tdefnodeflag=0
twoeulerflag=0
usecustombflag=0
usecustomgmtvars=0
usecustomrjflag=0

# Flags that start with a value of 1

cmtnormalflag=1
cmtssflag=1
cmtthrustflag=1
isdefaultregionflag=1
kinnormalflag=1
kinssflag=1
kinthrustflag=1
normalstyleflag=1
np1flag=1
np2flag=1
platediffvcutoffflag=1

###### The list of things to plot starts empty

plots=()

# Argument arrays that are slurped

customtopoargs=()
imageargs=()
topoargs=()

# The full command is output into the ps file and .history file
COMMAND="${0} ${@}"

# Exit if no arguments are given
if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

# If only one argument is given and it is 'remake', rerun command in file
# tectoplot.last and exit
if [[ $# -eq 1 && ${1} =~ "remake" ]]; then
  info_msg "Rerunning last tectoplot command executed in this directory"
  cat tectoplot.last
  . tectoplot.last
  exit 1
fi

if [[ $# -eq 2 && ${1} =~ "remake" ]]; then
  if [[ ! -e ${2} ]]; then
    info_msg "Error: no file ${2}"
    exit 1
  fi
  head -n 1 ${2} > tectoplot.cmd
  info_msg "Rerunning last tectoplot command from first line in file ${2}"
  cat tectoplot.cmd
  . tectoplot.cmd
  exit 1
fi

echo $COMMAND > tectoplot.last
rm -f tectoplot.sources
rm -f tectoplot.shortsources

# Parse the arguments and set up flags, variables, and command set
while [[ $# -gt 0 ]]
do
  key="${1}"
  case ${key} in
  -a) # args: none || string
    plotcoastlines=1
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-a]: No quality specified. Using a"
			COAST_QUALITY="-Da"
		else
			COAST_QUALITY="-D${2}"
			shift
		fi
    plots+=("coasts")
    echo $COASTS_SHORT_SOURCESTRING >> tectoplot.shortsources
    echo $COASTS_SOURCESTRING >> tectoplot.sources
    ;;
  -ac) # args: landcolor seacolor
    filledcoastlinesflag=1
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-ac]: No land/sea color specified. Using defaults"
      FILLCOASTS="-G${LANDCOLOR} -S${SEACOLOR}"
    else
      LANDCOLOR="${2}"
      shift
      if [[ ${2:0:1} == [-] || -z $2 ]]; then
        info_msg "[-ac]: No sea color specified. Not filling sea areas"
        FILLCOASTS="-G${LANDCOLOR}"
      else
        SEACOLOR="${2}"
        shift
        FILLCOASTS="-G$LANDCOLOR -S$SEACOLOR"
      fi
    fi
    ;;
  -af) # args: string string
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-af]: No line width specified. Using $GEMLINEWIDTH"
    else
      GEMLINEWIDTH="${2}"
      shift
      if [[ ${2:0:1} == [-] || -z $2 ]]; then
        info_msg "[-af]: No line color specified. Using $GEMLINECOLOR"
      else
        GEMLINECOLOR="${2}"
        shift
      fi
    fi
    plots+=("gemfaults")
    ;;
	-b|--slab2) # args: none || strong
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-b]: Slab2 control string not specified. Using c"
			SLAB2STR="c"
		else
			SLAB2STR="${2}"
			shift
		fi
    plotslab2eq=1
		plots+=("slab2")
    echo $SLAB2_SHORT_SOURCESTRING >> tectoplot.shortsources
    echo $SLAB2_SOURCESTRING >> tectoplot.sources
		;;
  -B) # args: { ... }
    if [[ ${2:0:1} == [{] ]]; then
      info_msg "[-B]: B argument string detected"
      shift
      while : ; do
          [[ ${2:0:1} != [}] ]] || break
          bj+=("${2}")
          shift
      done
      shift
      BSTRING="${bj[@]}"
    fi
    usecustombflag=1
    info_msg "[-B]: Custom map frame string: ${BSTRING[@]}"
    ;;
	-c|--cmt) # args: none || number
		calccmtflag=1
		plotcmt=1
    # Select focal mechanisms from GCMT, ISC, GCMT+ISC, SLAB2, etc
    # ISC_GCMT_ORIGIN
    # ISC_GCMT_CENTROID
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-c]: No scaling for CMTs specified... using default $CMTSCALE"
		else
			CMTSCALE="${2}"
			info_msg "[-c]: CMT scale updated to $CMTSCALE"
			shift
		fi
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-c]: No source of CMTs indicated. Using ISC+GCMT, origin."
      CMTFILE=$ISC_GCMT_ORIGIN
      echo $GCMT_SHORT_SOURCESTRING >> tectoplot.shortsources
      echo $GCMT_SOURCESTRING >> tectoplot.sources
      echo $ISC_SHORT_SOURCESTRING >> tectoplot.shortsources
      echo $ISC_SOURCESTRING >> tectoplot.sources
    else
      CMTTYPE="${2}"
      shift
      case ${CMTTYPE} in
        GCMT_ORIGIN)
          info_msg "[-c]: Using GCMT solutions, origin"
          CMTFILE=$GCMTORIGIN
          echo $GCMT_SHORT_SOURCESTRING >> tectoplot.shortsources
          echo $GCMT_SOURCESTRING >> tectoplot.sources
        ;;
        GCMT_CENTROID)
          info_msg "[-c]: Using GCMT solutions, centroid"
          CMTFILE=$GCMTCENTROID
          echo $GCMT_SHORT_SOURCESTRING >> tectoplot.shortsources
          echo $GCMT_SOURCESTRING >> tectoplot.sources
        ;;
        ISC_ORIGIN)
          info_msg "[-c]: Using non-GCMT solutions from ISC, origin"
          CMTFILE=$ISC_ORIGIN
          echo $ISC_SHORT_SOURCESTRING >> tectoplot.shortsources
          echo $ISC_SOURCESTRING >> tectoplot.sources
        ;;
        # ISC_CENTROID)
        #   info_msg "[-c]: Using non-GCMT solutions from ISC, origin"
        #   CMTFILE=$ISC_CENTROID
        # ;;
        GCMT_ISC_ORIGIN)
          info_msg "[-c]: Using combined ISC and GCMT, origin"
          CMTFILE=$ISC_GCMT_ORIGIN
          echo $GCMT_SHORT_SOURCESTRING >> tectoplot.shortsources
          echo $GCMT_SOURCESTRING >> tectoplot.sources
          echo $ISC_SHORT_SOURCESTRING >> tectoplot.shortsources
          echo $ISC_SOURCESTRING >> tectoplot.sources
        ;;
        *)
          info_msg "[-c]: Unknown CMT source. Using GCMT, origin"
          CMTFILE=$ISC_GCMT_ORIGIN
          echo $GCMT_SHORT_SOURCESTRING >> tectoplot.shortsources
          echo $GCMT_SOURCESTRING >> tectoplot.sources
          echo $ISC_SHORT_SOURCESTRING >> tectoplot.shortsources
          echo $ISC_SOURCESTRING >> tectoplot.sources
        ;;
      esac
    fi
		plots+=("cmt")
	  ;;
  -cd|--cmtdepth)  # args: number
    CMT_MAXDEPTH="${2}"
    shift
    ;;
  -cm|--cmtmag) # args: number number
    CMT_MINMAG="${2}"
    CMT_MAXMAG="${3}"
    shift
    shift
    ;;
  -cpts)
    remakecptsflag=1
    ;;
  -ct|--cmttype) # args: string
		calccmtflag=1
		cmtnormalflag=0
		cmtthrustflag=0
		cmtssflag=0
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-ct]: CMT eq type string is malformed"
		else
			[[ "${2}" =~ .*n.* ]] && cmtnormalflag=1
			[[ "${2}" =~ .*t.* ]] && cmtthrustflag=1
			[[ "${2}" =~ .*s.* ]] && cmtssflag=1
			shift
		fi
		;;
  -cw) # args: none
    CMT_THRUSTCOLOR="gray100"
    CMT_NORMALCOLOR="gray100"
    CMT_SSCOLOR="gray100"
    ;;
  --defaults)
    defaultsmessage
		exit 1
		;;
  --data)
    datamessage
    exit 1
    ;;
  -e|--execute) # args: file
    EXECUTEFILE=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
    shift
    plots+=("execute")
    ;;
  # -eqd) # args: number
  #   if [[ ${2:0:1} == [-] || -z $2 ]]; then
  #     info_msg "[-eqd]: EQ max depth not specified"
  #     exit 1
  #   else
  #     EQMAXDEPTH="${2}"
  #     shift
  #   fi
  #   ;;
	-f|--refpt)   # args: number number
		refptflag=1
		REFPTLON="${2}"
		REFPTLAT="${3}"
		shift
		shift
		info_msg "[-f]: Reference point is ${REFPTLON}/${REFPTLAT}"
	   ;;
  --formats)
    formats
    exit 1
    ;;
	-g|--gps) # args: none || string
		plotgps=1
		info_msg "[-g]: Plotting GPS velocities"
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-g]: No override GPS reference plate specified"
		else
			GPSID="${2}"
			info_msg "[-g]: Ovveriding GPS plate ID = ${GPSID}"
			gpsoverride=1
			GPS_FILE=`echo $GPS"/GPS_$GPSID.gmt"`
			shift
      echo $GPS_SOURCESTRING >> tectoplot.sources
      echo $GPS_SHORT_SOURCESTRING >> tectoplot.shortsources
		fi
		plots+=("gps")
		;;
  -gg|--extragps) # args: file
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-gg]: No extra GPS file given. Exiting"
      exit 1
    else
      EXTRAGPS=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
      info_msg "[-gg]: Plotting GPS velocities from $EXTRAGPS"
      shift
    fi
    plots+=("extragps")
    ;;
  -gmtvars)
    if [[ ${2:0:1} == [{] ]]; then
      info_msg "[-gmtvars]: GMT argument string detected"
      shift
      while : ; do
          [[ ${2:0:1} != [}] ]] || break
          gmtv+=("${2}")
          shift
      done
      shift
      GMTVARS="${gmtv[@]}"
    fi
    usecustomgmtvars=1
    info_msg "[-gmtvars]: Custom GMT variables: ${GMVARS[@]}"
    ;;
  -gridlabels) # args: string (quoted)
    GRIDCALL="${2}"
    shift
    ;;
  -h|--help)
    usage
		exit 1
    ;;
  -i|--vecscale) # args: number
    VELSCALE=$(echo "${2} * $VELSCALE" | bc -l)
    info_msg "[-i]: Vectors scaled by factor of ${2}, result is ${VELSCALE}"
    shift
    ;;
  -im|--image) # args: file { arguments }
    IMAGENAME=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
    shift
    # Args come in the form $ { -t50 -cX.cpt }
    if [[ ${2:0:1} == [{] ]]; then
      info_msg "[-im]: image argument string detected"
      shift
      while : ; do
          [[ ${2:0:1} != [}] ]] || break
          imageargs+=("${2}")
          shift
      done
      shift
      info_msg "[-gg]: Found image args ${imageargs[@]}"
      IMAGEARGS="${imageargs[@]}"
    fi
    plots+=("image")
    ;;
  -ips) # args: file
    overplotflag=1
    PLOTFILE=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
    shift
    info_msg "[-ips]: Plotting over previous PS file: $PLOTFILE"
    ;;
  --keepopenps) # args: none
    keepopenflag=1
    KEEPOPEN="-K"
    ;;
	-kg|--kingeo) # args: none
		calccmtflag=1
		strikedipflag=1
		plots+=("kingeo")
		;;
  -kl|--nodalplane) # args: string
		calccmtflag=1
		np1flag=1
		np2flag=1
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-kl]: Nodal plane selection string is malformed"
		else
			[[ "${2}" =~ .*1.* ]] && np2flag=0
			[[ "${2}" =~ .*2.* ]] && np1flag=0
			shift
		fi
		;;
  -km|--kinmag) # args: number number
    KIN_MINMAG="${2}"
    KIN_MAXMAG="${3}"
    shift
    shift
    ;;
	-ks|--kinscale)  # args: number
		calccmtflag=1
		KINSCALE="${2}"
		shift
    info_msg "[-ks]: CMT kinematics scale updated to $KINSCALE"
	  ;;
	-kt|--kintype) # args: string
		calccmtflag=1
		kinnormalflag=0
		kinthrustflag=0
		kinssflag=0
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-kt]: kinematics eq type string is malformed"
		else
			[[ "${2}" =~ .*n.* ]] && kinnormalflag=1
			[[ "${2}" =~ .*t.* ]] && kinthrustflag=1
			[[ "${2}" =~ .*s.* ]] && kinssflag=1
			shift
		fi
		;;
 	-kv|--kinsv)  # args: none
 		calccmtflag=1
 		svflag=1
		plots+=("kinsv")
 		;;
  -l|--line) # args: file color
      GISLINEFILE=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
      GISLINECOLOR="${3}"
      GISLINEWIDTH="${4}"
      shift
      shift
      shift
      plots+=("gisline")
    ;;
  --legend) # args: none
    makelegendflag=1
    legendovermapflag=1
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[--legend]: No width specified. Using $LEGEND_WIDTH"
    else
      LEGEND_WIDTH="${2}"
      shift
      info_msg "[--legend]: Legend width is $LEGEND_WIDTH"
    fi
    ;;
	-m|--mag) # args: transparency%
		plotmag=1
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-m]: No magnetism transparency set. Using default"
		else
			MAGTRANS="${2}"
			shift
		fi
		info_msg "[-m]: Magnetic data to plot is ${MAGMODEL}, transparency is ${MAGTRANS}"
		plots+=("mag")
    echo $MAG_SOURCESTRING >> tectoplot.sources
    echo $MAG_SHORT_SOURCESTRING >> tectoplot.shortsources
	    ;;
  -mprof)
    MPROFFILE=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")

    # PROFILE_WIDTH_IN
    # PROFILE_HEIGHT_IN
    # PROFILE_X
    # PROFILE_Z

    PROFILE_WIDTH_IN="${3}"
    PROFILE_HEIGHT_IN="${4}"
    PROFILE_X="${5}"
    PROFILE_Y="${6}"
    shift
    shift
    shift
    shift
    shift
    plots+=("mprof")
    ;;
	-n|--narrate)
		narrateflag=1
	    ;;
	-o|--out)
		outflag=1
		MAPOUT="${2}"
		shift
		info_msg "[-o]: Output file is ${MAPOUT}"
	    ;;
  --open)
    openflag=1
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[--open]: Opening with default program ${OPENPROGRAM}"
    else
      OPENPROGRAM="${2}"
      shift
    fi
    ;;
	-p|--plate) # args: string
		plotplates=1
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-p]: No plate model specified. Assuming MORVEL"
			POLESRC=$MORVELSRC
			PLATES=$MORVELPLATES
      MIDPOINTS=$MORVELMIDPOINTS
			POLES=$MORVELPOLES
			DEFREF="NNR"
      echo $MORVEL_SHORT_SOURCESTRING >> tectoplot.shortsources
      echo $MORVEL_SOURCESTRING >> tectoplot.sources
		else
			PLATEMODEL="${2}"
      shift
	  	case $PLATEMODEL in
			MORVEL)
				POLESRC=$MORVELSRC
				PLATES=$MORVELPLATES
				POLES=$MORVELPOLES
        MIDPOINTS=$MORVELMIDPOINTS
        EDGES=$MORVELPLATEEDGES
				DEFREF="NNR"
        echo $MORVEL_SHORT_SOURCESTRING >> tectoplot.shortsources
        echo $MORVEL_SOURCESTRING >> tectoplot.sources
				;;
			GSRM)
				POLESRC=$KREEMERSRC
				PLATES=$KREEMERPLATES
				POLES=$KREEMERPOLES
        MIDPOINTS=$KREEMERMIDPOINTS
        EDGES=$KREEMERPLATEEDGES
				DEFREF="ITRF08"
        echo $GSRM_SHORT_SOURCESTRING >> tectoplot.shortsources
        echo $GSRM_SOURCESTRING >> tectoplot.sources
				;;
			GBM)
				POLESRC=$GBMSRC
				PLATES=$GBMPLATES
				POLES=$GBMPOLES
				DEFREF="ITRF08"
        EDGES=$GBMPLATEEDGES
        MIDPOINTS=$GBMMIDPOINTS
        echo $GBM_SHORT_SOURCESTRING >> tectoplot.shortsources
        echo $GBM_SOURCESTRING >> tectoplot.sources
        ;;
			*) # Unknown plate model
				info_msg "[-p]: Unknown plate model $PLATEMODEL... using MORVEL56 instead"
				PLATEMODEL="MORVEL"
				POLESRC=$MORVELSRC
				PLATES=$MORVELPLATES
				POLES=$MORVELPOLES
        MIDPOINTS=$MORVELMIDPOINTS
				DEFREF="NNR"
				;;
			esac
      # Check for a reference plate ID
      if [[ ${2:0:1} == [-] || -z $2 ]]; then
  			info_msg "[-p]: No manual reference plate specified."
      else
        MANUALREFPLATE="${2}"
        shift
        if [[ $MANUALREFPLATE =~ $DEFREF ]]; then
          manualrefplateflag=1
          info_msg "[-p]: Using default reference frame $DEFREF"
          defaultrefflag=1
        else
          info_msg "[-p]: Manual reference plate $MANUALREFPLATE specified. Checking."
          isthere=$(grep $MANUALREFPLATE $POLES | wc -l)
          if [[ $isthere -eq 0 ]]; then
            info_msg "[-p]: Could not find manually specified reference plate $MANUALREFPLATE in plate file $POLES."
            exit
          fi
          manualrefplateflag=1
        fi
      fi
		fi
		info_msg "[-p]: Plate tectonic model is ${PLATEMODEL}"
	  ;;
  -pe|--plateedge)  # args: none
    plots+=("plateedge")
    ;;
  -pf|--fibsp) # args: number
    gridfibonacciflag=1
    makegridflag=1
    FIB_KM="${2}"
    FIB_N=$(echo "510000000 / ( $FIB_KM * $FIB_KM - 1 ) / 2" | bc)
    shift
    plots+=("grid")
    ;;
  -pgo)
    GRIDLINESON=0
    ;;
  -pl) # args: none
    plots+=("platelabel")
    ;;
  -pp|--cities)
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-pp]: No minimum population specified. Using ${CITIES_MINPOP}"
    else
      CITIES_MINPOP="${2}"
      shift
    fi
    plots+=("cities")
    echo $CITIES_SHORT_SOURCESTRING >> tectoplot.shortsources
    echo $CITIES_SOURCESTRING >> tectoplot.sources
    ;;
  -ppl)
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-pp]: No minimum population for labeling specified. Using ${CITIES_LABEL_MINPOP}"
    else
      CITIES_LABEL_MINPOP="${2}"
      shift
    fi
    citieslabelflag=1
    ;;
  -pt|--point)
    info_msg "[-p]: defaults: POINTCOLOR=$POINTCOLOR POINTSIZE=$POINTSIZE POINTLINECOLOR=$POINTLINECOLOR POINTLINEWIDTH=$POINTLINEWIDTH"
    POINTDATAFILE=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
    shift
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-p]: No cpt specified. Using POINTCOLOR for -G"
      pointdatafillflag=1
    else
      POINTDATACPT=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
      shift
      info_msg "[-p]: Using CPT file $POINTDATACPT"
      pointdatacptflag=1
    fi
    plots+=("points")
    ;;
  -pr) # args: number
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-pr]: No colatitude step specified: using ${LATSTEPS}"
    else
      LATSTEPS="${2}"
      shift
    fi
    plots+=("platerotation")
    platerotationflag=1
    ;;
  -ps)
    outputplatesflag=1
    ;;
  -pv) # args: none
    doplateedgesflag=1
    plots+=("platediffv")
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-pv]: No cutoff value specified. Disabling."
      platediffvcutoffflag=0
    else
      PDIFFCUTOFF="${2}"
      info_msg "[-pv]: Cutoff is $PDIFFCUTOFF"
      shift
      platediffvcutoffflag=1
    fi
    ;;
  -pz) # args: number
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-pz]: No azimuth difference scale indicated. Using default: ${AZDIFFSCALE}"
    else
      AZDIFFSCALE="${2}"
      shift
    fi
    doplateedgesflag=1
    plots+=("plateazdiff")
    ;;
	# -pac) # args: string
	# 	PLATEARROW_COLOR="${2}"
	# 	shift
	# 	;;
	# -pat) # args: number
	# 	PLATEARROW_TRANS="${2}"
	# 	shift
	# 	;;
	# -pgc)  # args: string
	# 	PLATEVEC_COLOR="${2}"
	# 	shift
	# 	;;
  -pgs) # args: number
    overridegridlinespacing=1
    OVERRIDEGRID="${2}"
    shift
    ;;
  # -pgt) # args: number
  #   PLATEVEC_TRANS="${2}"
  #   shift
  #   ;;
	# -plc) # args: string
	# 	PLATELINE_COLOR="${2}"
	# 	shift
	# 	;;
  # -pn1) # args: string
  # 	NP1_COLOR="${2}"
  # 	shift
  # 	;;
  # -pn2) # args: string
  #   NP2_COLOR="${2}"
  #   shift
  #   ;;
  -pos) # args: string string (e.g. 5i)
    plotshiftflag=1
    PLOTSHIFTX="${2}"
    PLOTSHIFTY="${3}"
    shift
    shift
    ;;
  -pss) # args: string
    # Set size of the postscript page
    PSSIZE="${2}"
    shift
    ;;
  -psr) # args: number
    # Set scaling of map versus postscript page size $PSSIZE (factor 1=$PSSIZE, 0=0)
    psscaleflag=1
    PSSCALE="${2}"
    shift
    ;;
  -psm) # args: number
    MARGIN="${2}"
    shift
    ;;
  # -pvf) # args: color
  #   V_FILL="${2}"
  #   shift
  #   ;;
  # -pvs) # args: number
  #   V_LINEW="${2}"
  #   shift
  #   ;;
  # -pvz) # args: number
  #   V_SIZE="${2}"
  #   shift
  #   ;;
  -pvg)
    platevelgridflag=1
    plots+=("platevelgrid")
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-pvg]: No rescaling of gravity CPT specified"
    elif [[ ${2} =~ "rescale" ]]; then
      rescaleplatevecsflag=1
      info_msg "[-pvg]: Rescaling gravity CPT to AOI"
      shift
    else
      info_msg "[-pvg]: Unrecognized option ${2}"
      shift
    fi
    ;;
  -px|--gridsp) # args: number
    makelatlongridflag=1
    makegridflag=1
		GRIDSTEP="${2}"
		shift
    plots+=("grid")
		info_msg "[-px]: Plate model grid step is ${GRIDSTEP}"
	  ;;
	-r|--range) # args: number number number number
	  if ! [[ $2 =~ ^[-+]?[0-9]*.*[0-9]+$ || $2 =~ ^[-+]?[0-9]+$ ]]; then
			echo "MinLon is malformed: $2"
			exit 1
		fi
    if ! [[ $3 =~ ^[-+]?[0-9]*.*[0-9]+$ || $3 =~ ^[-+]?[0-9]+$ ]]; then
			echo "MaxLon is malformed: $3"
			exit 1
		fi
    if ! [[ $4 =~ ^[-+]?[0-9]*.*[0-9]+$ || $4 =~ ^[-+]?[0-9]+$ ]]; then
			echo "MinLat is malformed: $4"
			exit 1
		fi
    if ! [[ $5 =~ ^[-+]?[0-9]*.*[0-9]+$ || $5 =~ ^[-+]?[0-9]+$ ]]; then
			echo "MaxLat is malformed: $5"
			exit 1
		fi
    MINLON="${2}"
		MAXLON="${3}"
		MINLAT="${4}"
    MAXLAT="${5}"
    shift # past argument
    shift # past value
    shift # past value
    shift # past value
    # Rescale longitudes if necessary to match the -180:180 convention used in this script
		info_msg "[-r]: Range is $MINLON $MAXLON $MINLAT $MAXLAT"
    [[ $(echo "$MAXLON > 180 && $MAXLON <= 360" | bc -l) -eq 1 ]] && MAXLON=$(echo "$MAXLON - 360" | bc -l)
    [[ $(echo "$MINLON > 180 && $MINLON <= 360" | bc -l) -eq 1 ]] && MINLON=$(echo "$MINLON - 360" | bc -l)
    if [[ $(echo "$MAXLAT > 90 || $MAXLAT < -90 || $MINLAT > 90 || $MINLAT < -90"| bc -l) -eq 1 ]]; then
    	echo "Latitude out of range"
    	exit
    fi
  	if [[ $(echo "$MAXLON > 360 || $MAXLON< -180 || $MINLON > 360 || $MINLON < -180"| bc -l) -eq 1 ]]; then
    	echo "Longitude out of range"
    	exit
  	fi
  	if [[ $(echo "$MAXLON <= $MINLON"| bc -l) -eq 1 ]]; then
    	echo "Longitudes out of order"
    	exit
  	fi
  	if [[ $(echo "$MAXLAT <= $MINLAT"| bc -l) -eq 1 ]]; then
    	echo "Latitudes out of order"
    	exit
  	fi
		info_msg "[-r]: Map region is -R${MINLON}/${MAXLON}/${MINLAT}/${MAXLAT}"
    isdefaultregionflag=0
    ;;
  -RJ) # args: { ... }
    if [[ ${2:0:1} == [{] ]]; then
      info_msg "[-RJ]: RJ argument string detected"
      shift
      while : ; do
          [[ ${2:0:1} != [}] ]] || break
          rj+=("${2}")
          shift
      done
      shift
      RJSTRING="${rj[@]}"
    fi
    usecustomrjflag=1
    info_msg "[-RJ]: Custom region and projection string is: ${RJSTRING[@]}"

    # Need to calculate the AOI using the RJSTRING. Otherwise, have to specify a
    # region manually using -r which may not be so obvious.

    # How?

    ;;
	-s|--srcmod) # args: none
		plotsrcmod=1
		info_msg "[-s]: Plotting SRCMOD fused slip data"
		plots+=("srcmod")
    echo $SRCMOD_SHORT_SOURCESTRING >> tectoplot.shortsources
    echo $SRCMOD_SOURCESTRING >> tectoplot.sources
	  ;;
  -setvars) # args: { VAR1 val1 VAR2 val2 VAR3 val3 }
    if [[ ${2:0:1} != [{] ]]; then
      info_msg "[-setvars]: { VAR1 val1 VAR2 val2 VAR3 val3 }"
      exit 1
    else
      shift
      while : ; do
        [[ ${2:0:1} != [}] ]] || break
        VARIABLE="${2}"
        shift
        VAL="${2}"
        shift
        # echo exporting $VARIABLE=$VAL
        export $VARIABLE=$VAL
        # env | grep $VARIABLE
      done
      shift
    fi
    ;;
  -sv|--slipvector) # args: filename
    plots+=("slipvecs")
    SVDATAFILE=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
    shift
    ;;
  -t|--topo) # args: ID | filename { args }
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-t]: No topo file specified: SRTM30 assumed"
			BATHYMETRY="SRTM30"
      echo $SRTM_SHORT_SOURCESTRING >> tectoplot.shortsources
      echo $SRTM_SOURCESTRING >> tectoplot.sources
		else
			BATHYMETRY="${2}"
			shift
		fi
		case $BATHYMETRY in
			SRTM30)
			  plottopo=1
				GRIDDIR=$SRTM30DIR
				GRIDFILE=$SRTM30FILE
				plots+=("topo")
        echo $SRTM_SHORT_SOURCESTRING >> tectoplot.shortsources
        echo $SRTM_SOURCESTRING >> tectoplot.sources
				;;
			SRTM15)
		    plottopo=1
				GRIDDIR=$SRTM15DIR
				GRIDFILE=$SRTM15FILE
				plots+=("topo")
        echo $SRTM_SHORT_SOURCESTRING >> tectoplot.shortsources
        echo $SRTM_SOURCESTRING >> tectoplot.sources
				;;
      SRTM1S)
        plottopo=1
        GRIDDIR=$SRTM1SDIR
				GRIDFILE=$SRTM1SFILE
        remotetileget=1
        plots+=("topo")
        echo $SRTM_SHORT_SOURCESTRING >> tectoplot.shortsources
        echo $SRTM_SOURCESTRING >> tectoplot.sources
        ;;
      GEBCO20)
        plottopo=1
        GRIDDIR=$GEBCO20DIR
        GRIDFILE=$GEBCO20FILE
        plots+=("topo")
        echo $GEBCO_SHORT_SOURCESTRING >> tectoplot.shortsources
        echo $GEBCO_SOURCESTRING >> tectoplot.sources
        ;;
      GEBCO1)
        plottopo=1
        GRIDDIR=$GEBCO1DIR
        GRIDFILE=$GEBCO1FILE
        plots+=("topo")
        echo $GEBCO_SHORT_SOURCESTRING >> tectoplot.shortsources
        echo $GEBCO_SOURCESTRING >> tectoplot.sources
        ;;
      *)
        plotcustomtopo=1
        info_msg "Making custom grid"
        CUSTOMGRIDFILE="${1}"   # We already shifted
        plots+=("customtopo")
        ;;
    esac
    if [[ ${2:0:1} == [{] ]]; then
      info_msg "[-t]: Topo args detected... slurping"
      shift
      while : ; do
        [[ ${2:0:1} != [}] ]] || break
        topoargs+=("${2}")
        shift
      done
      shift
      info_msg "[-t]: Found topo args ${imageargs[@]}"
      TOPOARGS="${imageargs[@]}"
    fi
    ;;
  -tc|--cpt) # args: filename
    customgridcptflag=1
    CUSTOMCPT=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
    shift
    ;;
  --tdeffaults)
    # Expects a comma-delimited list of numbers
    tdeffaultlistflag=1
    FAULTIDLIST="${2}"
    shift
    ;;
	--tdefnode) # args: filename
		tdefnodeflag=1
		TDPATH="${2}"
		TDSTRING="${3}"
		plots+=("tdefnode")
		shift
		shift
		;;
	--tdefpm)
		plotplates=1
    tdefnodeflag=1
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[--tdefpm]: No path specified for TDEFNODE results folder"
			exit 2
		else
			TDPATH="${2}"
			TDFOLD=$(echo $TDPATH | xargs -n 1 dirname)
			TDMODEL=$(echo $TDPATH | xargs -n 1 basename)
			BASENAME="${TDFOLD}/${TDMODEL}/${TDMODEL}"
			! [[ -e "${BASENAME}_blk.gmt" ]] && echo "TDEFNODE block file does not exist... exiting" && exit 2
			! [[ -e "${BASENAME}.poles" ]] && echo "TDEFNODE pole file does not exist... exiting" && exit 2
      ! [[ -d "${TDFOLD}/${TDMODEL}/"def2tecto_out/ ]] && mkdir "${TDFOLD}/${TDMODEL}/"def2tecto_out/
			rm -f "${TDFOLD}/${TDMODEL}/"def2tecto_out/*.dat
			# echo "${TDFOLD}/${TDMODEL}/"def2tecto_out/
			str1="G# P# Name      Lon.      Lat.     Omega     SigOm    Emax    Emin      Az"
			str2="Relative poles"
			cat "${BASENAME}.poles" | sed '1,/G# P# Name      Lon.      Lat.     Omega     SigOm    Emax    Emin      Az     VAR/d;/ Relative poles/,$d' | sed '$d' | awk '{print $3, $5, $4, $6}' | grep '\S' > ${TDPATH}/def2tecto_out/poles.dat
			cat "${BASENAME}_blk.gmt" | awk '{ if ($1 == ">") print $1, $6; else print $1, $2 }' > ${TDPATH}/def2tecto_out/blocks.dat
			POLESRC="TDEFNODE"
			PLATES="${TDFOLD}/${TDMODEL}/"def2tecto_out/blocks.dat
			POLES="${TDFOLD}/${TDMODEL}/"def2tecto_out/poles.dat
	  	info_msg "[--tdefpm]: TDEFNODE block model is ${PLATEMODEL}"
	  	TDEFRP="${3}"
			DEFREF=$TDEFRP
	    shift
	  	shift
		fi
		;;
  -title) # args: string
    PLOTTITLE="${2}"
    shift
    ;;
# Relative temporary directory placed into pwd
  -tm|--tempdir)
    TMP="${2}"
    info_msg "[-tm]: Temporary directory: ${THISDIR}/${2}"
    shift
    ;;
  # -tt|--topotrans) # args: number
  #   TOPOTRANS="${2}"
  #   shift
  #   ;;
  -tn)
    CONTOUR_INTERVAL="${2}"
    shift
    info_msg "[-tn]: Plotting topo contours at interval $CONTOUR_INTERVAL"
    plots+=("contours")
    #
    # if [[ ${2:0:1} != [{] ]]; then
    #   info_msg "[-setvars]: { VAR1 val1 VAR2 val2 VAR3 val3 }"
    #   exit 1
    # else
    #   shift
    #   while : ; do
    #     [[ ${2:0:1} != [}] ]] || break
    #     VARIABLE="${2}"
    #     shift
    #     VAL="${2}"
    #     shift
    #     # echo exporting $VARIABLE=$VAL
    #     export $VARIABLE=$VAL
    #     # env | grep $VARIABLE
    #   done
    #   shift
    # fi
    ;;
  -ts)
    dontplottopoflag=1
    ;;
	-v|--gravity) # args: string number
		plotgrav=1
		GRAVMODEL="${2}"
		GRAVTRANS="${3}"
		shift
		shift
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-v]: No rescaling of gravity CPT specified"
		elif [[ ${2} =~ "rescale" ]]; then
      rescalegravflag=1
			info_msg "[-v]: Rescaling gravity CPT to AOI"
			shift
    else
      info_msg "[-v]: Unrecognized option ${2}"
      shift
		fi
		case $GRAVMODEL in
			FA)
				GRAVDATA=$WGMFREEAIR
				GRAVCPT=$WGMFREEAIR_CPT
				;;
			BG)
				GRAVDATA=$WGMBOUGUER
				GRAVCPT=$WGMBOUGUER_CPT
				;;
			IS)
				GRAVDATA=$WGMISOSTATIC
				GRAVCPT=$WGMISOSTATIC_CPT
				;;
			*)
				echo "Gravity model not recognized."
				exit 1
				;;
		esac

		info_msg "[-v]: Gravity data to plot is ${GRAVDATA}, transparency is ${GRAVTRANS}"
		plots+=("grav")
    echo $GRAV_SHORT_SOURCESTRING >> tectoplot.shortsources
    echo $GRAV_SOURCESTRING >> tectoplot.sources
	  ;;
  -vars) # argument: filename
    VARFILE=$(echo "$(cd "$(dirname "$2")"; pwd)/$(basename "$2")")
    shift
    info_msg "[-vars]: Sourcing variable assignments from $VARFILE"
    . $VARFILE
    ;;
  -vc|--volc) # args: none
    plots+=("volcanoes")
    echo $VOLC_SHORT_SOURCESTRING >> tectoplot.shortsources
    echo $VOLC_SOURCESTRING >> tectoplot.sources
    ;;
  --verbose) # args: none
    VERBOSE="-V"
    ;;
  -w|--euler) # args: number number number
    eulervecflag=1
    eulerlat="${2}"
    eulerlon="${3}"
    euleromega="${4}"
    shift
    shift
    shift
    plots+=("euler")
    ;;
  -wg) # args: number
    euleratgpsflag=1
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-wg]: No residual scaling specified... not plotting residuals"
		else
      ploteulerobsresflag=1
			WRESSCALE="${2}"
			info_msg "[-wg]: Plotting only residuals with scaling factor $WRESSCALE"
			shift
		fi
    ;;
  -wp) # args: string string
    twoeulerflag=1
    plotplates=1
    eulerplate1="${2}"
    eulerplate2="${3}"
    plots+=("euler")
    shift
    shift
    ;;
	-z|--seis) # args: number
		plotseis=1
    if [[ $USEANSS_DATABASE -eq 1 ]]; then
      info_msg "[-z]: Using ANSS database $EQ_DATABASE"
    fi
		if [[ ${2:0:1} == [-] || -z $2 ]]; then
			info_msg "[-z]: No scaling for seismicity specified... using default $SEISSIZE"
		else
			SEISSCALE="${2}"
			info_msg "[-z]: Seismicity scale updated to $SEIZSIZE * $SEISSCALE"
			shift
		fi
		plots+=("seis")
		;;
  -zr1|--eqrake1) # args: number
    if [[ ${2:0:1} == [-] || -z $2 ]]; then
      info_msg "[-zr]:  No rake color scale indicated. Using default: ${RAKE1SCALE}"
    else
      RAKE1SCALE="${2}"
      shift
    fi
    plots+=("seisrake1")
    ;;
  -zr2|--eqrake2) # args: number
      if [[ ${2:0:1} == [-] || -z $2 ]]; then
        info_msg "[-zr]:  No rake color scale indicated. Using default: ${RAKE2SCALE}"
      else
        RAKE2SCALE="${2}"
        shift
      fi
      plots+=("seisrake2")
      ;;
	*)    # unknown option.
		echo "Unknown argument encountered: ${1}" 1>&2
    exit 1
    ;;
  esac
  shift
done

MSG=$(echo ">>>>>>>>> Plotting order is ${plots[@]} <<<<<<<<<<<<<")
# echo $MSG
[[ $narrateflag -eq 1 ]] && echo $MSG

# Check GMT version (modified code from Mencin/Vernant 2015 p_tdefnode.bash)
if [ `which gmt` ]; then
	GMT_VERSION=$(gmt --version)
	if [ ${GMT_VERSION:0:1} != $GMTREQ ]; then
		echo "GMT version $GMTREQ is required"
		exit 1
	fi
else
	echo "$name: Cannot call gmt"
	exit 1
fi

##### Define the output filename for the map, in PDF
if [[ $outflag == 0 ]]; then
	MAPOUT="tectomap_"$MINLAT"_"$MAXLAT"_"$MINLON"_"$MAXLON".pdf"
  MAPOUTLEGEND="tectomap_"$MINLAT"_"$MAXLAT"_"$MINLON"_"$MAXLON"_legend.pdf"
  info_msg "Output file is $MAPOUT, legend is $MAPOUTLEGEND"
else
  info_msg "Output file is $MAPOUT, legend is legend.pdf"
  MAPOUTLEGEND="legend.pdf"
fi

# Scaling of the kinematic vectors from focal mechanisms
# Length of slip vector azimuth
SYMSIZE1=$(echo "${KINSCALE} * 3.5" | bc -l)
# Length of dip line
SYMSIZE2=$(echo "${KINSCALE} * 1" | bc -l)
# Length of strike line
SYMSIZE3=$(echo "${KINSCALE} * 3.5" | bc -l)
# Size of background seismicity symbols

# Delete and remake the temporary directory where interim files will be stored
# Only delete the temporary directory if it is a subdirectory of the current directory to prevent accidents

# First copy the .ps base file, which can be in the temporary folder.
OVERLAY=""
if [[ $overplotflag -eq 1 ]]; then
   info_msg "Overplotting onto ${PLOTFILE} as copy. Ensure base ps is not closed using --keepopenps"
   cp "${PLOTFILE}" "${THISDIR}"tmpmap.ps
   OVERLAY="-O"
fi

# Check whether the temporary directory is an absolute path
if [[ ${TMP::1} == "/" ]]; then
  info_msg "Temporary directory path ${TMP} is an absolute path from root."
  if [[ -d $TMP ]]; then
    info_msg "Not deleting absolute path ${TMP}. Using ./tempfiles_to_delete/"
    TMP="tempfiles_to_delete/"
  fi
else
  if [[ -d $TMP ]]; then
    info_msg "Temp dir $TMP exists. Deleting."
    rm -rf "${TMP}"
  fi
  info_msg "Creating temporary directory $TMP."
fi
mkdir "${TMP}"

if [[ $overplotflag -eq 1 ]]; then
   info_msg "Copying basemap ps into temporary directory"
   mv "${THISDIR}"tmpmap.ps "${TMP}map.ps"
fi

cd "${TMP}"

################################################################################
##### Create CPT files for coloring grids and data

# Seismic data is colored by depth. Use neis2.cpt to color, neis_psscale.cpt to make legend
# [[ ! -e $CPTDIR"neis2.cpt" || $remakecptsflag -eq 1 ]] &&
# [[ ! -e $CPTDIR"neis2trans.cpt" || $remakecptsflag -eq 1 ]] &&

# [[ ! $EQMAXDEPTH -eq 660 ]] && EQPLUSCHAR="+"

# Remake the seismic CPTs as EQMAXDEPTH is likely to change often
gmt makecpt -Cseis -Do -T0/"${EQMAXDEPTH}"/10 -N "${VERBOSE}" > $CPTDIR"neis2.cpt"
cp $CPTDIR"neis2.cpt" $CPTDIR"neis2_psscale.cpt"
echo "${EQMAXDEPTH}	0/17.937/216.21	6000	0/0/255" >> $CPTDIR"neis2.cpt"
# echo "660	0/17.937/216.21	6500	0/0/255" >> $CPTDIR"neis2.cpt"

gmt makecpt -Cseis -Do -T0/"${EQMAXDEPTH}"/10 -N -A50 "${VERBOSE}" > $CPTDIR"neis2trans.cpt"

# The other CPTs are less likely to change and can be remade on command
[[ ! -e $CPTDIR"mag.cpt" || $remakecptsflag -eq 1 ]] && gmt makecpt -Crainbow -Z -Do -T-250/250/10 "${VERBOSE}" > $CPTDIR"mag.cpt"

# Population CPT
[[ ! -e $CPTDIR"population.cpt" || $remakecptsflag -eq 1 ]] && gmt makecpt -C${CITIES_CPT} -I -Do -T0/1000000/100000 -N "${VERBOSE}" > $CPTDIR"population.cpt"

# Color slip only between minimum and maximum values
[[ ! -e $CPTDIR"faultslip.cpt" || $remakecptsflag -eq 1 ]] && gmt makecpt -Chot -I -Do -T$SLIPMINIMUM/$SLIPMAXIMUM/0.1 -N "${VERBOSE}" > $CPTDIR"faultslip.cpt"
BATHYCPT=$CPTDIR"mby3.cpt"

# Make a bathymetry cpt in km for legend plot
[[ ! -e $CPTDIR"faultslip.cpt" || $remakecptsflag -eq 1 ]] && gmt makecpt -C$BATHYCPT -Do -T-10.773/8.682/0.01 -N "${VERBOSE}" > $CPTDIR"mby3_km.cpt"
[[ ! -e $CPTDIR"cycleaz.cpt" || $remakecptsflag -eq 1 ]] && gmt makecpt -Cred,yellow,green,blue,orange,purple,brown,plum4,thistle1,palegreen1,cadetblue1,navajowhite1,red -T-180/180/1 -Z "${VERBOSE}" > $CPTDIR"cycleaz.cpt"

[[ customgridcptflag -eq 1 ]] && BATHYCPT=$CUSTOMCPT

################################################################################
###### Calculate some sizes for the final map document based on AOI aspect ratio

LATSIZE=$(echo "$MAXLAT - $MINLAT" | bc -l)
LONSIZE=$(echo "$MAXLON - $MINLON" | bc -l)

# For a standard run, we want something like this. For other projections, unlikely to be sufficient
# We want a page that is PSSIZE wide with a MARGIN. It scales vertically based on the
# aspect ratio of the map region

PSSIZEH=$(echo "$PSSIZE * $PSSCALE" | bc -l)
PSSIZEV=$(echo "$LATSIZE / $LONSIZE * $PSSIZEH + 2" | bc -l)
INCH=$(echo "$PSSIZEH - $MARGIN * 2" | bc -l)


# Forget about that... just make a giant page and trim it later

gmt gmtset PS_MEDIA 100ix100i

# PSSIZEH=$PSSIZE
# PSSIZEV=$(echo "$LATSIZE / $LONSIZE * $PSSIZE + 2" | bc -l)
# INCH=$(echo "$PSSIZE - $MARGIN * 2" | bc -l)

##### Create the grid of lat/lon points to resolve as plate motion vectors
# Default is a lat/lon spaced grid

if [[ $gridfibonacciflag -eq 1 ]]; then
  FIB_PHI=1.618033988749895
  echo "" | awk -v n=$FIB_N  -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" 'function asin(x) { return atan2(x, sqrt(1-x*x)) } BEGIN {
    phi=1.618033988749895;
    pi=3.14159265358979;
    phi_inv=1/phi;
    ga = 2 * phi_inv * pi;
  } END {
    for (i=-n; i<=n; i++) {
      longitude = ((ga * i)*180/pi)%360;
      if (longitude < -180) {
        longitude=longitude+360;
      }
      if (longitude > 180) {
        longitude=longitude-360
      }
      latitude = asin((2 * i)/(2*n+1))*180/pi;
      if ((longitude <= maxlon) && (longitude >= minlon) && (latitude <= maxlat) && (latitude >= minlat)) {
        print longitude, latitude
      }
    }
  }' > gridfile.txt
  awk < gridfile.txt '{print $2 $1}' > gridswap.txt
fi

if [[ $makelatlongridflag -eq 1 ]]; then
  for i in $(seq $MINLAT $GRIDSTEP $MAXLAT); do
  	for j in $(seq $MINLON $GRIDSTEP $MAXLON); do
  		echo $j $i >> gridfile.txt
  		echo $i $j >> gridswap.txt
  	done
  done
fi

################################################################################
##### Check if the reference point is within the data frame

if [[ $(echo "$REFPTLAT > $MINLAT && $REFPTLAT < $MAXLAT && $REFPTLON < $MAXLON && $REFPTLON > $MINLON" | bc -l) -eq 0 ]]; then
  info_msg "Reference point $REFPTLON $REFPTLAT falls outside the frame. Moving to center of frame."
	REFPTLAT=$(echo "($MINLAT + $MAXLAT) / 2" | bc -l)
	REFPTLON=$(echo "($MINLON + $MAXLON) / 2" | bc -l)
  info_msg "Reference point moved to $REFPTLON $REFPTLAT"
fi

################################################################################
##### Set up the GMT print options now that we have a paper size defined

gmt gmtset MAP_FRAME_TYPE fancy
gmt gmtset PS_PAGE_ORIENTATION portrait
gmt gmtset FONT_ANNOT_PRIMARY 10 FONT_LABEL 10 MAP_FRAME_WIDTH 0.12c FONT_TITLE 18p,Palatino-BoldItalic
gmt gmtset FORMAT_GEO_MAP=D

GRIDSP=$(echo "($MAXLON - $MINLON)/6" | bc -l)

info_msg "Initial grid spacing = $GRIDSP"

if [[ $(echo "$GRIDSP > 30" | bc) -eq 1 ]]; then
  GRIDSP=30
elif [[ $(echo "$GRIDSP > 10" | bc) -eq 1 ]]; then
  GRIDSP=10
elif [[ $(echo "$GRIDSP > 5" | bc) -eq 1 ]]; then
	GRIDSP=5
elif [[ $(echo "$GRIDSP > 2" | bc) -eq 1 ]]; then
	GRIDSP=2
elif [[ $(echo "$GRIDSP > 1" | bc) -eq 1 ]]; then
	GRIDSP=1
elif [[ $(echo "$GRIDSP > 0.5" | bc) -eq 1 ]]; then
	GRIDSP=0.5
elif [[ $(echo "$GRIDSP > 0.2" | bc) -eq 1 ]]; then
	GRIDSP=0.2
elif [[ $(echo "$GRIDSP > 0.1" | bc) -eq 1 ]]; then
	GRIDSP=0.1
else
	GRIDSP=0.01
fi

info_msg "updated grid spacing = $GRIDSP"

if [[ $overridegridlinespacing -eq 1 ]]; then
  GRIDSP=$OVERRIDEGRID
  info_msg "Override spacing of map grid is $GRIDSP"
fi

if [[ $GRIDLINESON -eq 1 ]]; then
  GRIDSP_LINE="g${GRIDSP}"
else
  GRIDSP_LINE=""
fi

##########################################################################################
#####
##### Create bathymetry/topography grids and hillshades
#####
##### To save time, we store the grids in the source data directory and check if they exist
##### already when we run this script.

if [[ $plottopo -eq 1 ]]; then
	info_msg "Making basemap $BATHYMETRY"
  info_msg "Using grid $GRIDFILE"

	name=$GRIDDIR"${BATHYMETRY}_${MINLON}_${MAXLON}_${MINLAT}_${MAXLAT}.tif"
	# hs=$GRIDDIR"${BATHYMETRY}_${MINLON}_${MAXLON}_${MINLAT}_${MAXLAT}_hs.tif"
	# hist=$GRIDDIR"${BATHYMETRY}_${MINLON}_${MAXLON}_${MINLAT}_${MAXLAT}_hist.tif"
	# int=$GRIDDIR"${BATHYMETRY}_${MINLON}_${MAXLON}_${MINLAT}_${MAXLAT}_int.tif"
	# map=$GRIDDIR"${BATHYMETRY}_${MINLON}_${MAXLON}_${MINLAT}_${MAXLAT}_map.ps"
	# mappdf=$GRIDDIR"${BATHYMETRY}_${MINLON}_${MAXLON}_${MINLAT}_${MAXLAT}_map.pdf"

	if [[ -e $name ]]; then
		info_msg "DEM file $name already exists"
	else
    case $BATHYMETRY in
      SRTM15|SRTM30|SRTM1S|GEBCO20|GEBCO1)
        # echo gmt grdcut $GRIDFILE -G${name} -R${MINLON}/${MAXLON}/${MINLAT}/${MAXLAT} "${VERBOSE}"
        gmt grdcut $GRIDFILE -G${name} -R${MINLON}/${MAXLON}/${MINLAT}/${MAXLAT} "${VERBOSE}"
      ;;
    esac
	fi
	BATHY=$name
fi

if [[ $plotcustomtopo -eq 1 ]]; then

	info_msg "Making custom basemap $BATHYMETRY"

	name="custom_dem.tif"
	hs="custom_hs.tif"
	hist="custom_hist.tif"
	int="custom_int.tif"

  info_msg "Cutting ${CUSTOMGRIDFILE}"

  gmt grdcut $CUSTOMGRIDFILE -G${name} -R${MINLON}/${MAXLON}/${MINLAT}/${MAXLAT} "${VERBOSE}"

	gmt grdgradient $name -G$hs -A320 -Ne0.6 "${VERBOSE}"
	gmt grdhisteq $hs -G$hist -N "${VERBOSE}"
	gmt grdmath "${VERBOSE}" $hist 5.5 DIV = $int    # 5.5 is just a common value
	rm -f $hs
	rm -f $hist

	CUSTOMBATHY=$name
	CUSTOMINTN=$int
fi

# Set up the clipping polygon defining our ROI. Used by gmt spatial

echo $MINLON $MINLAT > clippoly.txt
echo $MINLON $MAXLAT >> clippoly.txt
echo $MAXLON $MAXLAT >> clippoly.txt
echo $MAXLON $MINLAT >> clippoly.txt
echo $MINLON $MINLAT >> clippoly.txt

echo $MINLON $MINLAT 0 > gridcorners.txt
echo $MINLON $MAXLAT 0 >> gridcorners.txt
echo $MAXLON $MAXLAT 0 >> gridcorners.txt
echo $MAXLON $MINLAT 0 >> gridcorners.txt

##########################################################################################
##### Download or extract seismicity data from online or local catalogs

# Currently in LAT LON DEPTH (+km) MAG
if [[ $plotseis -eq 1 ]]; then

	#This code downloads EQ data from ANSS catalog in the study area saves them in a file to avoid reloading
	EQANSSFILE=$EQUSGS"ANSS_"$MINLAT"_"$MAXLAT"_"$MINLON"_"$MAXLON".csv"
	EQANSSFILETXT=$EQUSGS"ANSS_"$MINLAT"_"$MAXLAT"_"$MINLON"_"$MAXLON"_proc.txt"

	QMARK="https://earthquake.usgs.gov/fdsnws/event/1/query?format=csv&starttime=1900-01-01&endtime=2020-03-21&minlatitude="$MINLAT"&maxlatitude="$MAXLAT"&minlongitude="$MINLON"&maxlongitude="$MAXLON

	if [[ -e $EQANSSFILETXT ]]; then
		info_msg "Processed earthquake data already exists, not retrieving new data"
	else
    if [[ $USEANSS_DATABASE -eq 1 ]]; then
      info_msg "Using scraped ANSS database as source of earthquake data, may not be up to date!"
      awk < $EQ_DATABASE -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" '{
          if ($1 < maxlon && $1 > minlon && $2 < maxlat && $2 > minlat) {
           print
          }
        }' > $EQANSSFILETXT
    else
  		info_msg "Downloading ANSS data if possible"
  		curl $QMARK > $EQANSSFILE
  		# Format is lat lon depth magnitude
  		cat $EQANSSFILE  | awk -F, '{print $3, $2, $4, $5}' > $EQANSSFILETXT
    fi
	fi
  echo $ANSS_SHORT_SOURCESTRING >> tectoplot.shortsources
  echo $ANSS_SOURCESTRING >> tectoplot.sources
fi # if [[ $plotseis -eq 1 ]]

if [[ $plotslab2eq -eq 1 ]]; then
  EQSLAB2FILE=$EQSLAB2"ALL_EQ_121819.csv"
	EQSLAB2FILETXT=$EQSLAB2"SLAB2_"$MINLAT"_"$MAXLAT"_"$MINLON"_"$MAXLON"_proc.txt"
	EQSLAB2MECATXT=$EQSLAB2"SLAB2_"$MINLAT"_"$MAXLAT"_"$MINLON"_"$MAXLON"_proc.meca"
  EQSLAB2FILETXT_ETAS=$EQSLAB2"SLAB2_"$MINLAT"_"$MAXLAT"_"$MINLON"_"$MAXLON"_proc_etas.txt"
  EQSLAB2FILETXT_SEDA=$EQSLAB2"SLAB2_"$MINLAT"_"$MAXLAT"_"$MINLON"_"$MAXLON"_proc_seda.txt"

	#
	if [[ -e $EQSLAB2FILETXT ]]; then
		info_msg "SLAB2 database extract already exists"
	else
		info_msg "Extracting SLAB2 earthquake data from database"
	#
	#	# SLAB2 database is in 0 to 360 longitude format. So we have to add 360 to data where longitude is lower than 0
	 cat $EQSLAB2FILE | awk -F, -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" '{
      if ($4 > 180) {
        lon=$4-360;
        if (lon < maxlon && lon > minlon && $3 < maxlat && $3 > minlat){
          print lon, $3, $5, $6;
        }
      } else {
        if ($4 < maxlon && $4 > minlon && $3 < maxlat && $3 > minlat){
          print $4, $3, $5, $6;
        }
      }
    }' > $EQSLAB2FILETXT
	fi

  if [[ ${SLAB2STR} =~ .*d.* ]]; then
    info_msg "Outputting SLAB2 data suitable for ETAS declustering: Date Time Lon Lat Mag Depth"

    # usp00046wv,1990-03-21 16:46:05.450,-31.092,180.907,144.8,6.6  4=lat 5=lon 6= depth 7=mag
    # date, time, longitude, latitude and magnitude, depth
    echo "time,lat,long,z,magn1" > $EQSLAB2FILETXT_ETAS
    # Use seconds since 1900 AD since some of our earthquakes occur before 1970 in some catalogs...
    cat $EQSLAB2FILE | awk -F'[,]' -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" 'BEGIN {OFS=","} {
       if ($5 < 100 && $6 >= 4.5) {
         gsub("-", " ", $2);
         gsub(":", " ", $2);
         split($2,dd,".");
         dt=mktime(dd[1])+2209013725;
         if ($4 > 180) {
           lon=$4-360;
           if (lon < maxlon && lon > minlon && $3 < maxlat && $3 > minlat){
             print dt, $3, lon, $5, $6;
           }
         } else {
           if ($4 < maxlon && $4 > minlon && $3 < maxlat && $3 > minlat){
             print dt, $3, $4, $5, $6;
           }
         }
       }
     }' >> $EQSLAB2FILETXT_ETAS

     cat $EQSLAB2FILE | awk -F'[,]' -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" 'BEGIN {OFS=" "} {
        if ($5 < 100 && $6 >= 4.5) {
          gsub("-", " ", $2);
          gsub(":", " ", $2);
          split($2,dd,".");
          if ($4 > 180) {
            lon=$4-360;
            if (lon < maxlon && lon > minlon && $3 < maxlat && $3 > minlat){
              print dd[1], $3, lon, $5, $6;
            }
          } else {
            if ($4 < maxlon && $4 > minlon && $3 < maxlat && $3 > minlat){
              print dd[1], $3, $4, $5, $6;
            }
          }
        }
      }' > $EQSLAB2FILETXT_SEDA
  fi
fi # if [[ $plotslab2eq -eq 1 ]]

##########################################################################################
##### Calculate style and kinematic vectors from CMT focal mechanisms

if [[ $calccmtflag -eq 1 ]]; then
	# We want to plot CMTs using catalog origin locations
	if [[ -e $GCMTORIGIN ]]; then
		info_msg "GCMT focal mechanisms already extracted and converted to origin locations"
	else
		info_msg "Extracting GCMT focal mechanisms from NDK to PSMECA format, 14 fields, origin locations"
		gawk -E $NDK2MECA_AWK $GCMTNDK > $GCMTCENTROIDTXT
		echo "# lonc latc depth str1 dip1 rake1 str2 dip2 rake2 MA ME lon lat ID" > $GCMTORIGIN
		# first case should always fail with output from ndk2meca.
		cat $GCMTCENTROIDTXT | awk '{ if ($12 < 0) print $12, $13, $3, $4, $5, $6, $7, $8, $9, $10, $11, $1, $2, $14; else if ($12 > 180) print $12-360, $13, $3, $4, $5, $6, $7, $8, $9, $10, $11, $1-360, $2, $14; else print $12, $13, $3, $4, $5, $6, $7, $8, $9, $10, $11, $1, $2, $14}' >> $GCMTORIGIN
	fi

	if [[ -e $GCMTCENTROID ]]; then
		info_msg "GCMT focal mechanisms already extracted and converted to centroid locations"
	else
		info_msg "Extracting GCMT focal mechanisms from NDK to PSMECA format, 14 fields, centroid locations"
		gawk -E $NDK2MECA_AWK $GCMTNDK > $GCMTCENTROIDTXT
		echo "# lonc latc depth str1 dip1 rake1 str2 dip2 rake2 MA ME lon lat ID" > $GCMTCENTROID
		# first case should always fail with output from ndk2meca.
		cat $GCMTCENTROIDTXT | awk '{ if ($12 < 0) print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14; else if ($12 > 180) print $1-360, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12-360, $13, $14; else print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14}' >> $GCMTCENTROID
	fi

  # filter CMT and ISC by CMT_MINMAG and CMT_MAXMAG
  awk < $CMTFILE -v maxdepth="${CMT_MAXDEPTH}" -v minmag="${CMT_MINMAG}" -v maxmag="${CMT_MAXMAG}" -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" '{
    lm0 = $11 + log($10)/log(10);
    mw = 2/3*lm0-10.7;
    if (mw < maxmag && mw > minmag && $3 < maxdepth && $1 < maxlon && $1 > minlon && $2 < maxlat && $2 > minlat) {
      print
    }
  }' > cmt.dat

  # filter CMT by KIN_MINMAG and KIN_MAXMAG
  awk < $CMTFILE -v maxdepth="${CMT_MAXDEPTH}" -v minmag="${KIN_MINMAG}" -v maxmag="${KIN_MAXMAG}" -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" '{
    lm0 = $11 + log($10)/log(10);
    mw = 2/3*lm0-10.7;
    if (mw < maxmag && mw > minmag && $3 < maxdepth && $1 < maxlon && $1 > minlon && $2 < maxlat && $2 > minlat) {
      print
    }
  }' > kin.dat

	echo "# lonc latc depth str1 dip1 rake1 str2 dip2 rake2 MA ME lat lon ID" > cmt_thrust.txt
	echo "# lonc latc depth str1 dip1 rake1 str2 dip2 rake2 MA ME lat lon ID" > cmt_strikeslip.txt
	echo "# lonc latc depth str1 dip1 rake1 str2 dip2 rake2 MA ME lat lon ID" > cmt_normal.txt
  echo "# lonc latc depth str1 dip1 rake1 str2 dip2 rake2 MA ME lat lon ID" > kin_thrust.txt
	echo "# lonc latc depth str1 dip1 rake1 str2 dip2 rake2 MA ME lat lon ID" > kin_strikeslip.txt
	echo "# lonc latc depth str1 dip1 rake1 str2 dip2 rake2 MA ME lat lon ID" > kin_normal.txt

  # Select CMT in AOI and filter focal mechanisms by rake of Nodal Plane 1 to output CMT psmeca files for CMT plot
  # Rake is in range -180:180. 90±45 = thrust (45:135), -180±45 = normal (-135:-45), 0:45, 315:360 = strike slip 1, 45:135 = strike slip 2

	awk < cmt.dat -v rakemin=45 -v rakemax=135 '($6 > rakemin && $6 < rakemax) {print}' >> cmt_thrust.txt
	awk < cmt.dat -v rakemin=-45 -v rakemax=45 '($6 >= rakemin && $6 <= rakemax) {print}' >> cmt_strikeslip.txt
	awk < cmt.dat -v rakemin=-180 '($6 >= rakemin && $6 <= rakemax) {print}' >> cmt_strikeslip.txt
	awk < cmt.dat -v rakemin=135 -v rakemax=180 '($6 >= rakemin && $6 <= rakemax) {print}' >> cmt_strikeslip.txt
  awk < cmt.dat -v rakemin=-135 -v rakemax=-45 '($6 > rakemin && $6 < rakemax) {print}' >> cmt_normal.txt

  # Select CMT data in AOI for kinematic plotting. Can have different magnitude range.

  awk < kin.dat -v rakemin=45 -v rakemax=135 '($6 > rakemin && $6 < rakemax) {print}' >> kin_thrust.txt
	awk < kin.dat -v rakemin=-45 -v rakemax=45 '($6 >= rakemin && $6 <= rakemax) {print}' >> kin_strikeslip.txt
	awk < kin.dat -v rakemin=-180 -v rakemax=-135 '($6 >= rakemin && $6 <= rakemax) {print}' >> kin_strikeslip.txt
	awk < kin.dat -v rakemin=135 -v rakemax=180 '($6 >= rakemin && $6 <= rakemax) {print}' >> kin_strikeslip.txt
  awk < kin.dat -v rakemin=-135 -v rakemax=-45 '($6 > rakemin && $6 < rakemax) {print}' >> kin_normal.txt

	# Generate the kinematic vectors
	# For thrust faults, take the slip vector associated with the shallower dipping nodal plane

	awk 'NR > 1' kin_thrust.txt | awk -v symsize=$SYMSIZE1 '{if($8 > 45) print $1, $2, ($7+270) % 360, symsize; else print $1, $2, ($4+270) % 360, symsize;  }' > thrust_gen_slip_vectors_np1.txt
	awk 'NR > 1' kin_thrust.txt | awk -v symsize=$SYMSIZE2 '{if($8 > 45) print $1, $2, ($4+90) % 360, symsize; else print $1, $2, ($7+90) % 360, symsize;  }' > thrust_gen_slip_vectors_np1_downdip.txt
	awk 'NR > 1' kin_thrust.txt | awk -v symsize=$SYMSIZE3 '{if($8 > 45) print $1, $2, ($4) % 360, symsize / 2; else print $1, $2, ($7) % 360, symsize / 2;  }' > thrust_gen_slip_vectors_np1_str.txt

	awk 'NR > 1' kin_thrust.txt | awk -v symsize=$SYMSIZE1 '{if($8 > 45) print $1, $2, ($4+270) % 360, symsize; else print $1, $2, ($7+270) % 360, symsize;  }' > thrust_gen_slip_vectors_np2.txt
	awk 'NR > 1' kin_thrust.txt | awk -v symsize=$SYMSIZE2 '{if($8 > 45) print $1, $2, ($7+90) % 360, symsize; else print $1, $2, ($4+90) % 360, symsize ;  }' > thrust_gen_slip_vectors_np2_downdip.txt
	awk 'NR > 1' kin_thrust.txt | awk -v symsize=$SYMSIZE3 '{if($8 > 45) print $1, $2, ($7) % 360, symsize / 2; else print $1, $2, ($4) % 360, symsize / 2;  }' > thrust_gen_slip_vectors_np2_str.txt

	awk 'NR > 1' kin_strikeslip.txt | awk -v symsize=$SYMSIZE1 '{ print $1, $2, ($7+270) % 360, symsize }' > strikeslip_slip_vectors_np1.txt
	awk 'NR > 1' kin_strikeslip.txt | awk -v symsize=$SYMSIZE1 '{ print $1, $2, ($4+270) % 360, symsize }' > strikeslip_slip_vectors_np2.txt

	awk 'NR > 1' kin_normal.txt | awk -v symsize=$SYMSIZE1 '{ print $1, $2, ($7+270) % 360, symsize }' > normal_slip_vectors_np1.txt
	awk 'NR > 1' kin_normal.txt | awk -v symsize=$SYMSIZE1 '{ print $1, $2, ($4+270) % 360, symsize }' > normal_slip_vectors_np2.txt
fi # if [[ $calccmtflag -eq 1 ]]


#################################################################################
#####  Plate tectonics from database of plate polygons and associated Euler poles

# Calculates relative plate motion along plate boundaries - most time consuming!
# Calculates plate edge midpoints and plate edge azimuths
# Calculates relative motion of grid points within plates
# Calculates reference plate from reference point location
# Calculates small circle rotations for display

if [[ $plotplates -eq 1 ]]; then
  # MORVEL, GBM, and GSRM plate data are sanitized for CW polygons cut at the anti-meridian and
  # with pole cap plates extended to 90 latitude. TDEFNODE plates are expected to
  # satisfy the same criteria but can be CCW oriented; we cut the plates by the ROI
  # and then change their CW/CCW direction anyway.

  # Euler poles are searched for using the ID component of any plate called ID_N.
  # This allows us to have multiple clean polygons for a given Euler pole.

  # We calculate plate boundary segment azimuths on the fly to infer tectonic setting

  # We should probably pre-process things because global datasets can have a lot of points
  # and take up a lot of time to determine plate pairs, etc. But exactly how to deal with
  # clipped data is a problem.

  # STEP 1: Identify the plates that fall within the AOI and extract their polygons and Euler poles

  # Cut the plate file by the ROI.
  gmt spatial $PLATES -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -C "${VERBOSE}" | awk '{print $1, $2}' > map_plates_clip_a.txt

  # Ensure CW orientation of clipped polygons.
  # GMT spatial strips out the header labels for some reason.
  gmt spatial map_plates_clip_a.txt -E+n "${VERBOSE}" > map_plates_clip_orient.txt

  # Check the special case that there are no polygon boundaries within the region
  numplates=$(grep ">" map_plates_clip_a.txt | wc -l)
  numplatesorient=$(grep ">" map_plates_clip_orient.txt | wc -l)

  if [[ $numplates -eq 1 && $numplatesorient -eq 0 ]]; then
    grep ">" map_plates_clip_a.txt > new.txt
    cat map_plates_clip_orient.txt >> new.txt
    cp new.txt map_plates_clip_orient.txt
  fi

  grep ">" map_plates_clip_a.txt > map_plates_clip_ids.txt

  IFS=$'\n' read -d '' -r -a pids < map_plates_clip_ids.txt
  i=0

  # Now read through the file and replace > with the next value in the pids array. This replaces names that GMT spatial stripped out for no good reason at all...
  while read p; do
    if [[ ${p:0:1} == '>' ]]; then
      printf  "%s\n" "${pids[i]}" >> map_plates_clip.txt
      i=$i+1
    else
      printf "%s\n" "$p" >> map_plates_clip.txt
    fi
  done < map_plates_clip_orient.txt

  grep ">" map_plates_clip.txt | uniq | awk '{print $2}' > plate_id_list.txt

  if [[ $isdefaultregionflag -eq 1 && $outputplatesflag -eq 1 ]]; then
    echo $DEFREF
    awk < $POLES '{print $1}'
    exit
  fi

  if [[ $isdefaultregionflag -eq 0 && $outputplatesflag -eq 1 ]]; then
    cat plate_id_list.txt
    exit
  fi

  info_msg "Found plates ..."
  [[ $narrateflag -eq 1 ]] && cat plate_id_list.txt
  info_msg "Extracting the full polygons of intersected plates..."

  v=($(cat plate_id_list.txt | tr ' ' '\n'))
  i=0
  j=1;
  rm -f plates_in_view.txt
  echo "> END" >> map_plates_clip.txt

  # STEP 2: Calculate midpoint locations and azimuth of segment for plate boundary segments

	# Calculate the azimuth between adjacent line segment points (assuming clockwise oriented polygons)
	rm -f plateazfile.txt

  # We are too clever by half and just shift the whole plate file one line down and then calculate the azimuth between points:
	sed 1d < map_plates_clip.txt > map_plates_clip_shift1.txt
	paste map_plates_clip.txt map_plates_clip_shift1.txt | grep -v "\s>" > geodin.txt

  # Script to return azimuth and midpoint between a pair of input points.
  # Comes within 0.2 degrees of geod() results over large distances, while being symmetrical which geod isn't
  # We need perfect symmetry in order to create exact point pairs in adjacent polygons

  awk < geodin.txt '{print $1, $2, $3, $4}' | awk 'function acos(x) { return atan2(sqrt(1-x*x), x) }
      {
        if ($1 == ">") {
          print $1, $2;
        }
        else {
          lon1 = $1*3.14159265358979/180;
          lat1 = $2*3.14159265358979/180;
          lon2 = $3*3.14159265358979/180;
          lat2 = $4*3.14159265358979/180;
          Bx = cos(lat2)*cos(lon2-lon1);
          By = cos(lat2)*sin(lon2-lon1);
          latMid = atan2(sin(lat1)+sin(lat2), sqrt((cos(lat1)+Bx)*(cos(lat1)+Bx)+By*By));
          lonMid = lon1+atan2(By, cos(lat1)+Bx);
          theta = atan2(sin(lon2-lon1)*cos(lat2), cos(lat1)*sin(lat2)-sin(lat1)*cos(lat2)*cos(lon2-lon1));
          d = acos(sin(lat1)*sin(lat2) + cos(lat1)*cos(lat2)*cos(lon2-lon1) ) * 6371;
          printf "%.5f %.5f %.3f %.3f\n", lonMid*180/3.14159265358979, latMid*180/3.14159265358979, (theta*180/3.14159265358979+360-90)%360, d;
        };
      }' > plateazfile.txt

  # plateazfile.txt now contains midpoints with azimuth and distance of segments. Multiple
  # headers per plate are possible if multiple disconnected lines were generated
  # outfile is midpointlon midpointlat azimuth

  cat plateazfile.txt | awk '{if (!/^>/) print $1, $2}' > halfwaypoints.txt
  # output is lat1 lon1 midlat1 midlon1 az backaz distance

	cp plate_id_list.txt map_ids_end.txt
	echo "END" >> map_ids_end.txt

  # Extract the Euler poles for the map_ids.txt plates
  # We need to match XXX from XXX_N
  v=($(cat plate_id_list.txt | tr ' ' '\n'))
  i=0
  while [[ $i -lt ${#v[@]} ]]; do
      pid="${v[$i]%_*}"
      repid="${v[$i]}"
      info_msg "Looking for pole $pid and replacing with $repid"
      grep "$pid\s" < $POLES | sed "s/$pid/$repid/" >> polesextract_init.txt
      i=$i+1
  done

  # Extract the unique Euler poles
  awk '!seen[$1]++' polesextract_init.txt > polesextract.txt

  # Define the reference plate (zero motion plate) either manually or using reference point (reflon, reflat)
  if [[ $manualrefplateflag -eq 1 ]]; then
    REFPLATE=$(grep ^$MANUALREFPLATE polesextract.txt | head -n 1 | awk '{print $1}')
    info_msg "Manual reference plate is $REFPLATE"
  else
    # We use a tiny little polygon to clip the map_plates and determine the reference polygon.
    # Not great but GMT spatial etc don't like the map polygon data...
    REFWINDOW=0.001

    Y1=$(echo "$REFPTLAT-$REFWINDOW" | bc -l)
    Y2=$(echo "$REFPTLAT+$REFWINDOW" | bc -l)
    X1=$(echo "$REFPTLON-$REFWINDOW" | bc -l)
    X2=$(echo "$REFPTLON+$REFWINDOW" | bc -l)

    nREFPLATE=$(gmt spatial map_plates_clip.txt -R$X1/$X2/$Y1/$Y2 -C "${VERBOSE}"  | grep "> " | head -n 1 | awk '{print $2}')
    info_msg "Automatic reference plate is $nREFPLATE"

    if [[ -z "$nREFPLATE" ]]; then
        info_msg "Could not determine reference plate from reference point"
        REFPLATE=$DEFREF
    else
        REFPLATE=$nREFPLATE
    fi
  fi

  # Set Euler pole for reference plate
  if [[ $defaultrefflag -eq 1 ]]; then
    info_msg "Using Euler pole $DEFREF = [0 0 0]"
    reflat=0
    reflon=0
    refrate=0
  else
  	info_msg "Defining reference pole from $POLESRC | $REFPLATE vs $DEFREF pole"
  	info_msg "Looking for reference plate $REFPLATE in pole file $POLES"

  	# Have to search for lines beginning with REFPLATE with a space after to avoid matching e.g. both Burma and BurmanRanges
  	reflat=`grep "^$REFPLATE\s" < polesextract.txt | awk '{print $2}'`
  	reflon=`grep "^$REFPLATE\s" < polesextract.txt | awk '{print $3}'`
  	refrate=`grep "^$REFPLATE\s" < polesextract.txt | awk '{print $4}'`

  	info_msg "Found reference plate Euler pole $REFPLATE vs $DEFREF $reflat $reflon $refrate"
  fi

	# Set the GPS to the reference plate if not overriding it from the command line

	if [[ $gpsoverride -eq 0 ]]; then
    if [[ $defaultrefflag -eq 1 ]]; then
      # ITRF08 is likely similar to other reference frames.
      GPS_FILE=$(echo $GPS"/GPS_ITRF08.gmt")
    else
      # REFPLATE now ends in a _X code to accommodate multiple subplates with the same pole.
      # This will break if _X becomes _XX (10 or more sub-plates)
      RGP=${REFPLATE::${#REFPLATE}-2}
      if [[ -e $GPS"/GPS_${RGP}.gmt" ]]; then
        GPS_FILE=$(echo $GPS"/GPS_${RGP}.gmt")
      else
        info_msg "No GPS file $GPS/GPS_${RGP}.gmt exists. Keeping default"
      fi
    fi
  fi

  # Iterate over the plates. We create plate polygons, identify Euler poles, etc.

  # Slurp the plate IDs from map_plates_clip.txt
  v=($(grep ">" map_plates_clip.txt | awk '{print $2}' | tr ' ' '\n'))
	i=0
	j=1
	while [[ $i -lt ${#v[@]}-1 ]]; do

    # Create plate files .pldat
    info_msg "Extracting between ${v[$i]} and ${v[$j]}"
		sed -n '/^> '${v[$i]}'$/,/^> '${v[$j]}'$/p' map_plates_clip.txt | sed '$d' > "${v[$i]}.pldat"
		echo " " >> "${v[$i]}.pldat"
		# PLDAT files now contain the X Y coordinates and segment azimuth with a > PL header line and a single empty line at the end

		# Calculate the true centroid of each polygon and output it to the label file
		sed -e '2,$!d' -e '$d' "${v[$i]}.pldat" | awk '{
			x[NR] = $1;
			y[NR] = $2;
		}
		END {
		    x[NR+1] = x[1];
		    y[NR+1] = y[1];

			  SXS = 0;
		    SYS = 0;
		    AS = 0;
		    for (i = 1; i <= NR; ++i) {
		    	J[i] = (x[i]*y[i+1]-x[i+1]*y[i]);
		    	XS[i] = (x[i]+x[i+1]);
		    	YS[i] = (y[i]+y[i+1]);
		    }
		    for (i = 1; i <= NR; ++i) {
		    	SXS = SXS + (XS[i]*J[i]);
		    	SYS = SYS + (YS[i]*J[i]);
		    	AS = AS + (J[i]);
			}
			AS = 1/2*AS;
			CX = 1/(6*AS)*SXS;
			CY = 1/(6*AS)*SYS;
			print CX "," CY
		}' > "${v[$i]}.centroid"
    cat "${v[$i]}.centroid" >> map_centroids.txt

    # Calculate Euler poles relative to reference plate
    pllat=`grep "^${v[$i]}\s" < polesextract.txt | awk '{print $2}'`
    pllon=`grep "^${v[$i]}\s" < polesextract.txt | awk '{print $3}'`
    plrate=`grep "^${v[$i]}\s" < polesextract.txt | awk '{print $4}'`
    # Calculate resultant Euler pole
    info_msg "Euler poles ${v[$i]} vs $DEFREF: $pllat $pllon $plrate vs $reflat $reflon $refrate"

    echo $pllat $pllon $plrate $reflat $reflon $refrate | awk -f $EULERADD_AWK  > ${v[$i]}.pole

    # Calculate motions of grid points from their plate's Euler pole

    if [[ $makegridflag -eq 1 ]]; then
    	# gridfile is in lat lon
    	# gridpts are in lon lat
      # Select the grid points within the plate amd calculate plate velocities at the grid points
      cat gridfile.txt | gmt select -: -F${v[$i]}.pldat "${VERBOSE}" | awk '{print $2, $1}' > ${v[$i]}_gridpts.txt
  		awk -f $EULERVEC_AWK -v eLat_d1=$pllat -v eLon_d1=$pllon -v eV1=$plrate -v eLat_d2=$reflat -v eLon_d2=$reflon -v eV2=$refrate ${v[$i]}_gridpts.txt > ${v[$i]}_velocities.txt
    	paste -d ' ' ${v[$i]}_gridpts.txt ${v[$i]}_velocities.txt | awk '{print $2, $1, $3, $4, 0, 0, 1, "ID"}' > ${v[$i]}_platevecs.txt
    fi

    # Small circles for showing plate relative motions. Not the greatest or worst concept.

    if [[ $platerotationflag -eq 1 ]]; then

      polelat=$(cat ${v[$i]}.pole | awk '{print $1}')
      polelon=$(cat ${v[$i]}.pole | awk '{print $2}')
      polerate=$(cat ${v[$i]}.pole | awk '{print $3}')

      if [[ $(echo "$polerate == 0" | bc -l) -eq 1 ]]; then
        info_msg "Not generating small circles for reference plate"
        touch ${v[$i]}.smallcircles
      else
        centroidlat=`cat ${v[$i]}.centroid | awk -F, '{print $1}'`
        centroidlon=`cat ${v[$i]}.centroid | awk -F, '{print $2}'`
        info_msg "Generating small circles around pole $polelat $polelon"

        # Calculate the minimum and maximum colatitudes of points in .pldat file relative to Euler Pole
        #cos(AOB)=cos(latA)cos(latB)cos(lonB-lonA)+sin(latA)sin(latB)
        grep -v ">" ${v[$i]}.pldat | grep "\S" | awk -v plat=$polelat -v plon=$polelon 'function acos(x) { return atan2(sqrt(1-x*x), x) }
          BEGIN {
            maxdeg=0; mindeg=180;
          }
          {
            lon1 = plon*3.14159265358979/180;
            lat1 = plat*3.14159265358979/180;
            lon2 = $1*3.14159265358979/180;
            lat2 = $2*3.14159265358979/180;

            degd = 180/3.14159265358979*acos( cos(lat1)*cos(lat2)*cos(lon2-lon1)+sin(lat1)*sin(lat2) );
            if (degd < mindeg) {
              mindeg=degd;
            }
            if (degd > maxdeg) {
              maxdeg=degd;
            }
          }
          END {
            maxdeg=maxdeg+1;
            if (maxdeg >= 179) { maxdeg=179; }
            mindeg=mindeg-1;
            if (mindeg < 1) { mindeg=1; }
            printf "%.0f %.0f\n", mindeg, maxdeg
        }' > ${v[$i]}.colatrange.txt
        colatmin=$(cat ${v[$i]}.colatrange.txt | awk '{print $1}')
        colatmax=$(cat ${v[$i]}.colatrange.txt | awk '{print $2}')

        # Find the antipode for GMT project
        poleantilat=$(echo "0 - (${polelat})" | bc -l)
        poleantilon=$(echo "$polelon" | awk '{if ($1 < 0) { print $1+180 } else { print $1-180 } }')
        info_msg "Pole $polelat $polelon has antipode $poleantilat $poleantilon"

        # Generate small circle paths in colatitude range of plate
        rm -f ${v[$i]}.smallcircles
        for j2 in $(seq $colatmin $LATSTEPS $colatmax); do
          echo "> -Z${j2}" >> ${v[$i]}.smallcircles
          gmt project -T${polelon}/${polelat} -C${poleantilon}/${poleantilat} -G0.5/${j2} -L-360/0 "${VERBOSE}" | awk '{print $1, $2}' >> ${v[$i]}.smallcircles
        done

        # Clip the small circle paths by the plate polygon
        gmt spatial ${v[$i]}.smallcircles -T${v[$i]}.pldat "${VERBOSE}" | awk '{print $1, $2}' > ${v[$i]}.smallcircles_clip_1

        # We have trouble with gmt spatial giving us two-point lines segments. Remove all two-point segments by building a sed script
        grep -n ">" ${v[$i]}.smallcircles_clip_1 | awk -F: 'BEGIN { oldval=0; oldline=""; }
        {
          val=$1;
          diff=val-oldval;
          if (NR>1) {
            if (diff != 3) {
              print oldval ", " val-1 " p";
            }
          }
          oldval=val;
          oldline=$0
        }' > lines_to_extract.txt

        # Execute sed commands to build sanitized small circle file
        sed -n -f lines_to_extract.txt < ${v[$i]}.smallcircles_clip_1 > ${v[$i]}.smallcircles_clip

        # GMT plot command that exports label locations for points at a specified interval distance along small circles.
        # These X,Y locations are used as inputs to the vector arrowhead locations.
        cat ${v[$i]}.smallcircles_clip | gmt psxy -O -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i -W0p -Sqd0.25i:+t"${v[$i]}labels.txt"+l" " "${VERBOSE}" >> /dev/null

        # Reformat points
        awk < ${v[$i]}labels.txt '{print $2, $1}' > ${v[$i]}_smallcirc_gridpts.txt

        # Calculate the plate velocities at the points
        awk -f $EULERVEC_AWK -v eLat_d1=$pllat -v eLon_d1=$pllon -v eV1=$plrate -v eLat_d2=$reflat -v eLon_d2=$reflon -v eV2=$refrate ${v[$i]}_smallcirc_gridpts.txt > ${v[$i]}_smallcirc_velocities.txt

        # Transform to psvelo format for later plotting
        paste -d ' ' ${v[$i]}_smallcirc_gridpts.txt ${v[$i]}_smallcirc_velocities.txt | awk '{print $1, $2, $3*100, $4*100, 0, 0, 1, "ID"}' > ${v[$i]}_smallcirc_platevecs.txt
      fi # small circles
    fi

	  i=$i+1
	  j=$j+1
  done # while (Iterate over plates calculating pldat, centroids, and poles

  # Create the plate labels at the centroid locations
	paste -d ',' map_centroids.txt plate_id_list.txt > map_labels.txt

  # EDGE CALCULATIONS. Determine the relative motion of each plate pair for each plate edge segment
  # by extracting the two Euler poles and calculating predicted motions at the segment midpoint.
  # This calculation is time consuming for large areas because my implementation is... algorithmically
  # poor. So, intead we load the data from a global results file if it exists.

  if [[ $doplateedgesflag -eq 1 ]]; then
    # Load pre-calculated data if it exists - MUCH faster but may need to recalc if things change
    # To re-build, use a global region -r -180 180 -90 90 and copy id_pts_euler.txt to $MIDPOINTS file

    if [[ -e $MIDPOINTS ]]; then
      awk < $MIDPOINTS -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" '{
        if ($1 >= minlon && $1 <= maxlon && $2 >= minlat && $2 <= maxlat) {
          print
        }
      }' > id_pts_euler.txt
    else
      echo "Midpoints file $MIDPOINTS does not exist"
      if [[ $MINLAT -eq "-90" && $MAXLAT -eq "90" && $MINLON -eq "-180" && $MAXLON -eq "180" ]]; then
        echo "Your region is global. After this script ends, you can copy id_pts_euler.txt and define it as a MIDPOINT file."
      fi

    	# Create a file with all points one one line beginning with the plate ID only
      # The sed '$d' deletes the 'END' line
      awk < plateazfile.txt '{print $1, $2 }' | tr '\n' ' ' | sed -e $'s/>/\\\n/g' | grep '\S' | tr -s '\t' ' ' | sed '$d' > map_plates_oneline.txt

    	# Create a list of unique block edge points.  Not sure I actually need this
    	awk -F" " '!_[$1][$2]++' plateazfile.txt | awk '($1 != ">") {print $1, $2}' > map_plates_uniq.txt

      # Primary output is id_pts.txt, containing properties of segment midpoints
      # id_pts.txt
      # lon lat seg_az seg_dist plate1_id plate2_id p1lat p1lon p1rate p2lat p2lon p2rate
      # > nba_1
      # -0.23807 -54.76466 322.920 32.154 nba_1 an_1 65.42 -118.11 0.25 47.68 -68.44 0.292
      # 0.20267 -54.56424 321.234 39.964 nba_1 an_1 65.42 -118.11 0.25 47.68 -68.44 0.292
      # 0.70278 -54.64178 51.803 54.065 nba_1 an_1 65.42 -118.11 0.25 47.68 -68.44 0.292
      # 1.33194 -54.61605 314.609 67.286 nba_1 an_1 65.42 -118.11 0.25 47.68 -68.44 0.292
      # 2.02896 -54.21846 317.316 59.072 nba_1 an_1 65.42 -118.11 0.25 47.68 -68.44 0.292
      # 2.69403 -53.84446 315.736 61.200 nba_1 an_1 65.42 -118.11 0.25 47.68 -68.44 0.292
      # 3.19663 -53.74262 42.110 30.427 nba_1 an_1 65.42 -118.11 0.25 47.68 -68.44 0.292
      # 3.66147 -53.98086 40.562 50.346 nba_1 an_1 65.42 -118.11 0.25 47.68 -68.44 0.292

      while read p; do
        if [[ ${p:0:1} == '>' ]]; then  # We encountered a plate segment header. All plate pairs should be referenced to this plate
          curplate=$(echo $p | awk '{print $2}')
          echo $p >> id_pts.txt
          pole1=($(grep "${curplate}\s" < polesextract.txt))
          info_msg "Current plate is $curplate with pole ${pole1[1]} ${pole1[2]} ${pole1[3]}"
        else
          q=$(echo $p | awk '{print $1, $2}')
          resvar=($(grep -n -- "${q}" < map_plates_oneline.txt | awk -F" " '{printf "%s\n", $2}'))
          numres=${#resvar[@]}
          if [[ $numres -eq 2 ]]; then   # Point is between two plates
            if [[ ${resvar[0]} == $curplate ]]; then
              plate1=${resvar[0]}
              plate2=${resvar[1]}
            else
              plate1=${resvar[1]} # $curplate
              plate2=${resvar[0]}
            fi
          else                          # Point is not between plates or is triple point
              plate1=${resvar[0]}
              plate2=${resvar[0]}
          fi
          pole2=($(grep "${plate2}\s" < polesextract.txt))
          info_msg " Plate 2 is $plate2 with pole ${pole2[1]} ${pole2[2]} ${pole2[3]}"
          echo -n "${p} " >> id_pts.txt
          echo ${plate1} ${plate2} ${pole2[1]} ${pole2[2]} ${pole2[3]} ${pole1[1]} ${pole1[2]} ${pole1[3]} | awk '{printf "%s %s ", $1, $2; print $3, $4, $5, $6, $7, $8}' >> id_pts.txt
        fi
      done < plateazfile.txt

      # Do the plate relative motion calculations all at once.
      awk -f $EULERVECLIST_AWK id_pts.txt > id_pts_euler.txt

    fi

  	grep "^[^>]" < id_pts_euler.txt | awk '{print $1, $2, $3, 0.5}' >  paz1.txt
  	grep "^[^>]" < id_pts_euler.txt | awk '{print $1, $2, $15, 0.5}' >  paz2.txt

    grep "^[^>]" < id_pts_euler.txt | awk '{print $1, $2, $3-$15}' >  azdiffpts.txt
    #grep "^[^>]" < id_pts_euler.txt | awk '{print $1, $2, $3-$15, $4}' >  azdiffpts_len.txt

    # Right now these values don't go from -180:180...
    grep "^[^>]" < id_pts_euler.txt | awk '{
        val = $3-$15
        if (val > 180) { val = val - 360 }
        if (val < -180) { val = val + 360 }
        print $1, $2, val, $4
      }' >  azdiffpts_len.txt


  	# currently these kinematic arrows are all the same scale. Can scale to match psvelo... but how?

    grep "^[^>]" < id_pts_euler.txt |awk 'function abs(v) {return v < 0 ? -v : v} function ddiff(u) { return u > 180 ? 360 - u : u} {
      diff=$15-$3;
      if (diff > 180) { diff = diff - 360 }
      if (diff < -180) { diff = diff + 360 }
      if (diff >= 20 && diff <= 70) { print $1, $2, $15, sqrt($13*$13+$14*$14) }}' >  paz1thrust.txt

    grep "^[^>]" < id_pts_euler.txt |awk 'function abs(v) {return v < 0 ? -v : v} function ddiff(u) { return u > 180 ? 360 - u : u} {
      diff=$15-$3;
      if (diff > 180) { diff = diff - 360 }
      if (diff < -180) { diff = diff + 360 }
      if (diff > 70 && diff < 110) { print $1, $2, $15, sqrt($13*$13+$14*$14) }}' >  paz1ss1.txt

    grep "^[^>]" < id_pts_euler.txt |awk 'function abs(v) {return v < 0 ? -v : v} function ddiff(u) { return u > 180 ? 360 - u : u} {
      diff=$15-$3;
      if (diff > 180) { diff = diff - 360 }
      if (diff < -180) { diff = diff + 360 }
      if (diff > -90 && diff < -70) { print $1, $2, $15, sqrt($13*$13+$14*$14) }}' > paz1ss2.txt

    grep "^[^>]" < id_pts_euler.txt |awk 'function abs(v) {return v < 0 ? -v : v} function ddiff(u) { return u > 180 ? 360 - u : u} {
      diff=$15-$3;
      if (diff > 180) { diff = diff - 360 }
      if (diff < -180) { diff = diff + 360 }
      if (diff >= 110 || diff <= -110) { print $1, $2, $15, sqrt($13*$13+$14*$14) }}' > paz1normal.txt
  fi #  if [[ $doplateedgesflag -eq 1 ]]; then
fi # if [[ $plotplates -eq 1 ]]

# Not sure why we do this here?
if [[ ${SLAB2STR} =~ .*c.* ]]; then
  gmt spatial ${SLAB2CLIPDIR}slab2clippolys.dat -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -C "${VERBOSE}" | awk '($1 == ">") {print $2}' > slab2_ids.txt
fi

##########################################################################################
##### Plot the postscript file by calling the sections listed in $plots[@]

# We could replace $plots[@] with a command file to allow multiple calls to the same plot command?
# We can slurp variables from { a a a } arrays.

# Add a PS comment with the command line used to invoke tectoplot. Use >> as we might be adding to an existing PS file
echo "%TECTOPLOT: ${COMMAND}" >> map.ps

# Set up values of the basemap
gmt gmtset FONT_ANNOT_PRIMARY 7 FONT_LABEL 7 MAP_FRAME_WIDTH 0.15c FONT_TITLE 18p,Palatino-BoldItalic
gmt gmtset MAP_FRAME_PEN 0.5p,black

# Can be part of a command file, multiple runs can be made
if [[ $usecustomgmtvars -eq 1 ]]; then
  info_msg "gmt gmtset ${GMTVARS[@]}"
  gmt gmtset ${GMTVARS[@]}
fi



info_msg "Plotting grid and keeping PS file open for legend"


if [[ $usecustomrjflag -eq 1 ]]; then
  # Special flag to plot using a custom string containing -R -J -B
  if [[ $usecustombflag -eq 1 ]]; then
    gmt psbasemap -X$PLOTSHIFTX -Y$PLOTSHIFTY ${RJSTRING[@]} "${VERBOSE}" ${BSTRING[@]} > base_fake.ps
  else
    if [[ $PLOTTITLE == "BlankMapTitle" ]]; then
      gmt psbasemap -X$PLOTSHIFTX -Y$PLOTSHIFTY ${RJSTRING[@]} "${VERBOSE}" -Bxa"$GRIDSP""$GRIDSP_LINE" -Bya"$GRIDSP""$GRIDSP_LINE" -B"${GRIDCALL}" > base_fake.ps
    else
      gmt psbasemap -X$PLOTSHIFTX -Y$PLOTSHIFTY ${RJSTRING[@]} "${VERBOSE}" -Bxa"$GRIDSP""$GRIDSP_LINE" -Bya"$GRIDSP""$GRIDSP_LINE" -B"${GRIDCALL}"+t"${PLOTTITLE}" > base_fake.ps
    fi
  fi
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY "${VERBOSE}" -K ${RJSTRING[@]} > kinsv.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY "${VERBOSE}" -K ${RJSTRING[@]} > plate.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY "${VERBOSE}" -K ${RJSTRING[@]} > mecaleg.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY "${VERBOSE}" -K ${RJSTRING[@]} > velarrow.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY "${VERBOSE}" -K ${RJSTRING[@]} > velgps.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY "${VERBOSE}" -K ${RJSTRING[@]} >> map.ps
else
  if [[ $usecustombflag -eq 1 ]]; then

    # SHOULD PROBABLY UPDATE TO AN AVERAGE LONGITUDE INSTEAD OF -JQ$MINLON

    gmt psbasemap -X$PLOTSHIFTX -Y$PLOTSHIFTY -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i  "${VERBOSE}" ${BSTRING[@]} > base_fake.ps
  else
    if [[ $PLOTTITLE == "BlankMapTitle" ]]; then
      gmt psbasemap -X$PLOTSHIFTX -Y$PLOTSHIFTY -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i  "${VERBOSE}" -Bxa"$GRIDSP""$GRIDSP_LINE" -Bya"$GRIDSP""$GRIDSP_LINE" -B"${GRIDCALL}" > base_fake.ps
    else
      gmt psbasemap -X$PLOTSHIFTX -Y$PLOTSHIFTY -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i  "${VERBOSE}" -Bxa"$GRIDSP""$GRIDSP_LINE" -Bya"$GRIDSP""$GRIDSP_LINE" -B"${GRIDCALL}"+t"${PLOTTITLE}" > base_fake.ps
    fi
  fi
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY -K "${VERBOSE}"  > kinsv.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY -K "${VERBOSE}"  > plate.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY -K "${VERBOSE}"  > mecaleg.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY -K "${VERBOSE}"  > velarrow.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY -K "${VERBOSE}"  > velgps.ps
  echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -JQ$MINLON/${INCH}i -X$PLOTSHIFTX -Y$PLOTSHIFTY $OVERLAY -K "${VERBOSE}"  >> map.ps
fi

MAP_PS_DIM=$(gmt psconvert base_fake.ps -Te -A0.01i -V 2> >(grep Width) | awk -F'[ []' '{print $10, $17}')
MAP_PS_WIDTH_IN=$(echo $MAP_PS_DIM | awk '{print $1/2.54}')
MAP_PS_HEIGHT_IN=$(echo $MAP_PS_DIM | awk '{print $2/2.54}')
# echo "Map dimensions (cm) are W: $MAP_PS_WIDTH_IN, H: $MAP_PS_HEIGHT_IN"

for plot in ${plots[@]} ; do
	case $plot in
    cities)
      info_msg "Plotting cities with minimum population ${CITIES_MINPOP}"
      # Sort the cities so that dense areas plot on top of less dense areas
      awk < $CITIES -F, -v minpop=${CITIES_MINPOP} '($4>=minpop) {print $1, $2, $4}' | sort -n -k 3 |  gmt psxy -S${CITIES_SYMBOL}${CITIES_SYMBOL_SIZE} -W${CITIES_SYMBOL_LINEWIDTH},${CITIES_SYMBOL_LINECOLOR} -C$CPTDIR"population.cpt" $RJOK $VERBOSE >> map.ps
      if [[ $citieslabelflag -eq 1 ]]; then
        awk < $CITIES -F, -v minpop=${CITIES_LABEL_MINPOP} '($4>=minpop) {print $1, $2, $3}' | gmt pstext -F+f${CITIES_LABEL_FONTSIZE},${CITIES_LABEL_FONT},${CITIES_LABEL_FONTCOLOR}+jLM $RJOK $VERBOSE >> map.ps
      fi
      ;;
    cmt)
      # if [[ cmtthrustflag -eq 1 ]]; then
      #   if [[ $SCALEEQS -eq 1 ]]; then
      #     awk < cmt_thrust.txt -v str=$SEISSTRETCH -v sref=$SEISSTRETCH_REFMAG {
      #       lm0 = $11 + log($10)/log(10);
      #       mw = 2/3*lm0-10.7;
      #       newmw = (mw^str)/(sref^(str-1))
      #       newlm0 = ...
      #     }
      #     awk < eqs.txt -v str=$SEISSTRETCH -v sref=$SEISSTRETCH_REFMAG '{print $1, $2, $3, ($4^str)/(sref^(str-1)), $5, $6}' | gmt psxy -C$CPTDIR"neis2.cpt" -i0,1,2,3+s${SEISSCALE} -S${SEISSYMBOL} $RJOK "${VERBOSE}" >> map.ps
      #
      #   else
      #     gmt psmeca -E"${CMT_THRUSTCOLOR}" -Z$CPTDIR"neis2.cpt" -Sc"$CMTSCALE"i/0 cmt_thrust.txt $RJOK "${VERBOSE}" >> map.ps
      #   fi
      # fi
      info_msg "Plotting focal mechanisms"
      if [[ cmtthrustflag -eq 1 ]]; then
        gmt psmeca -E"${CMT_THRUSTCOLOR}" -Z$CPTDIR"neis2.cpt" -Sc"$CMTSCALE"i/0 cmt_thrust.txt -L0.25p,black $RJOK "${VERBOSE}" >> map.ps
      fi
      if [[ cmtnormalflag -eq 1 ]]; then
        gmt psmeca -E"${CMT_NORMALCOLOR}" -Z$CPTDIR"neis2.cpt" -Sc"$CMTSCALE"i/0 cmt_normal.txt -L0.25p,black $RJOK "${VERBOSE}" >> map.ps
      fi
      if [[ cmtssflag -eq 1 ]]; then
        gmt psmeca -E"${CMT_SSCOLOR}" -Z$CPTDIR"neis2.cpt" -Sc"$CMTSCALE"i/0 cmt_strikeslip.txt -L0.25p,black $RJOK "${VERBOSE}" >> map.ps
      fi
      ;;

    coasts)
      info_msg "Plotting coastlines"
      gmt pscoast $COAST_QUALITY -W1/$COAST_LINEWIDTH,$COAST_LINECOLOR $FILLCOASTS -A$COAST_KM2 $RJOK "${VERBOSE}" >> map.ps
      ;;

    contours)
      info_msg "Plotting topographic contours using $BATHY and contour options ${CONTOUROPTSTRING[@]}"
      gmt grdcontour $BATHY  -C$CONTOUR_INTERVAL -Q$CONTOUR_MINLEN -W$CONTOUR_LINEWIDTH,$CONTOUR_LINECOLOR $RJOK "${VERBOSE}" >> map.ps

      ;;
    customtopo)
      if [[ $dontplottopoflag -eq 0 ]]; then
        info_msg "Plotting custom topography $CUSTOMBATHY"
        gmt grdimage $CUSTOMBATHY -I+d -C$BATHYCPT $RJOK "${VERBOSE}" >> map.ps
      else
        info_msg "Custom topo image plot suppressed using -ts"
      fi
      ;;

    execute)
      info_msg "Executing script $EXECUTEFILE"
      source $EXECUTEFILE
      ;;

    extragps)
      info_msg "Plotting extra GPS dataset $EXTRAGPS"
      gmt psvelo $EXTRAGPS -W${EXTRAGPS_LINEWIDTH},${EXTRAGPS_LINECOLOR} -G${EXTRAGPS_FILLCOLOR} -A${ARROWFMT} -Se$VELSCALE/${GPS_ELLIPSE}/0 -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
      # gmt psvelo $EXTRAGPS -W0.02p,black -A0 -Se$VELSCALE/${GPS_ELLIPSE}/0 -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
      # Generate XY data
      awk -v gpsscalefac=$VELSCALE '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4)*gpsscalefac; else print $1, $2, az+360, sqrt($3*$3+$4*$4)*gpsscalefac; }' $EXTRAGPS > extragps.xy
      # gmt psxy -SV$ARROWFMT  extragps.xy $RJOK "${VERBOSE}" >> map.ps
      ;;

    euler)
      info_msg "Plotting Euler pole derived velocities"

      # Plots Euler Pole velocities as requested. Either on the XY spaced grid or at GPS points.
      # Requires polesextract.txt to be present.
      # Requires gridswap.txt if we are not plotting at GPS stations
      # eulergrid.txt needs to be in lat lon order
      # currently uses full global datasets?

      if [[ $euleratgpsflag -eq 1 ]]; then    # If we are looking at GPS data (-wg)
        if [[ $plotgps -eq 1 ]]; then         # If the GPS data are regional
          cat $GPS_FILE | awk '{print $2, $1}' > eulergrid.txt   # lon lat -> lat lon
          cat $GPS_FILE > gps.obs
        fi
        if [[ $tdefnodeflag -eq 1 ]]; then    # If the GPS data are from a TDEFNODE model
          awk '{ if ($5==1 && $6==1) print $8, $9, $12, $17, $15, $20, $27, $1 }' ${TDPATH}${TDMODEL}.vsum > ${TDMODEL}.obs   # lon lat order
          awk '{ if ($5==1 && $6==1) print $9, $8 }' ${TDPATH}${TDMODEL}.vsum > eulergrid.txt  # lat lon order
          cat ${TDMODEL}.obs > gps.obs
        fi
      else
        cp gridswap.txt eulergrid.txt  # lat lon order
      fi

      if [[ $eulervecflag -eq 1 ]]; then   # If we specified our own Euler Pole on the command line
        awk -f $EULERVEC_AWK -v eLat_d1=$eulerlat -v eLon_d1=$eulerlon -v eV1=$euleromega -v eLat_d2=0 -v eLon_d2=0 -v eV2=0 eulergrid.txt > gridvelocities.txt
      fi
      if [[ $twoeulerflag -eq 1 ]]; then   # If we specified two plates (moving plate vs ref plate) via command line
        lat1=`grep "^$eulerplate1\s" < polesextract.txt | awk '{print $2}'`
      	lon1=`grep "^$eulerplate1\s" < polesextract.txt | awk '{print $3}'`
      	rate1=`grep "^$eulerplate1\s" < polesextract.txt | awk '{print $4}'`

        lat2=`grep "^$eulerplate2\s" < polesextract.txt | awk '{print $2}'`
      	lon2=`grep "^$eulerplate2\s" < polesextract.txt | awk '{print $3}'`
      	rate2=`grep "^$eulerplate2\s" < polesextract.txt | awk '{print $4}'`
        [[ $narrateflag -eq 1 ]] && echo Plotting velocities of $eulerplate1 [ $lat1 $lon1 $rate1 ] relative to $eulerplate2 [ $lat2 $lon2 $rate2 ]
        # Should add some sanity checks here?
        awk -f $EULERVEC_AWK -v eLat_d1=$lat1 -v eLon_d1=$lon1 -v eV1=$rate1 -v eLat_d2=$lat2 -v eLon_d2=$lon2 -v eV2=$rate2 eulergrid.txt > gridvelocities.txt
      fi

      # gridvelocities.txt needs to be multiplied by 100 to return mm/yr which is what GPS files are in

      # If we are plotting only the residuals of GPS velocities vs. estimated site velocity from Euler pole (gridvelocities.txt)
      if [[ $ploteulerobsresflag -eq 1 ]]; then
         info_msg "plotting residuals of block motion and gps velocities"
         paste gps.obs gridvelocities.txt | awk '{print $1, $2, $10-$3, $11-$4, 0, 0, 1, $8 }' > gpsblockres.txt   # lon lat order, mm/yr
         # Scale at print is OK
         awk -v gpsscalefac=$(echo "$VELSCALE * $WRESSCALE" | bc -l) '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4)*gpsscalefac; else print $1, $2, az+360, sqrt($3*$3+$4*$4)*gpsscalefac; }' gpsblockres.txt > grideulerres.pvec
         gmt psxy -SV$ARROWFMT -W0p,green -Ggreen grideulerres.pvec $RJOK "${VERBOSE}" >> map.ps  # Plot the residuals
      fi

      paste -d ' ' eulergrid.txt gridvelocities.txt | awk '{print $2, $1, $3, $4, 0, 0, 1, "ID"}' > gridplatevecs.txt
      # Scale at print is OK
      cat gridplatevecs.txt | awk -v gpsscalefac=$VELSCALE '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4)*gpsscalefac; else print $1, $2, az+360, sqrt($3*$3+$4*$4)*gpsscalefac; }'  > grideuler.pvec
      gmt psxy -SV$ARROWFMT -W0p,red -Gred grideuler.pvec $RJOK "${VERBOSE}" >> map.ps
      ;;

    gemfaults)
      info_msg "Plotting GEM active faults"
      gmt psxy $GEMFAULTS -W$GEMLINEWIDTH,$GEMLINECOLOR $RJOK "${VERBOSE}" >> map.ps
      ;;

    gisline)
      info_msg "Plotting GIS line data $GISLINEFILE"
      gmt psxy $GISLINEFILE -W$GISLINEWIDTH,$GISLINECOLOR $RJOK "${VERBOSE}" >> map.ps
      ;;

    gps)
      info_msg "Plotting GPS"
		  ##### Plot GPS velocities if possible (requires Kreemer plate to have same ID as model reference plate, or manual specification)
      if [[ $tdefnodeflag -eq 0 ]]; then
  			if [[ -e $GPS_FILE ]]; then
  				info_msg "GPS data is taken from $GPS_FILE and are plotted relative to plate $REFPLATE in that model"

          awk < $GPS_FILE -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" '{
            if ($1>180) { lon=$1-360 } else { lon=$1 }
            if (lon >= minlon && lon <= maxlon && $2 >= minlat && $2 <= maxlat) {
              print
            }
          }' > gps.txt
  				gmt psvelo gps.txt -W${GPS_LINEWIDTH},${GPS_LINECOLOR} -G${GPS_FILLCOLOR} -A${ARROWFMT} -Se$VELSCALE/${GPS_ELLIPSE}/0 -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
          # generate XY data
          awk '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4); else print $1, $2, az+360, sqrt($3*$3+$4*$4); }' < gps.txt > gps.xy
          GPSMAXVEL=$(awk < gps.xy 'BEGIN{ maxv=0 } {if ($4>maxv) { maxv=$4 } } END {print maxv}')
    		else
  				info_msg "No relevant GPS data available for given plate model"
  				GPS_FILE="None"
  			fi
      fi
			;;

    grav)
      if [[ $rescalegravflag -eq 1 ]]; then
        gmt grdcut $GRAVDATA -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -Ggravtmp.nc
        MINZ=$(gmt grdinfo gravtmp.nc | grep z_min | awk '{ print int($3/100)*100 }')
        MAXZ=$(gmt grdinfo gravtmp.nc | grep z_min | awk '{print int($5/100)*100}')
        echo MINZ MAXZ $MINZ $MAXZ
        gmt makecpt -C$GRAVCPT -T$MINZ/$MAXZ -Z > gravtmp.cpt
        gmt grdimage $GRAVDATA -Cgravtmp.cpt -t$GRAVTRANS $RJOK "${VERBOSE}" >> map.ps
      else
        gmt grdimage $GRAVDATA -C$GRAVCPT -t$GRAVTRANS $RJOK "${VERBOSE}" >> map.ps
      fi
      ;;

    grid)
      # Plot the gridded plate velocity field
      # Requires *_platevecs.txt to plot velocity field
      # Input data are in mm/yr
      info_msg "Plotting grid arrows"

      LONDIFF=$(echo "$MAXLON - $MINLON" | bc -l)
      pwnum=$(echo "5p" | awk '{print $1+0}')
      POFFS=$(echo "$LONDIFF/8*1/72*$pwnum*3/2" | bc -l)
      GRIDMAXVEL=0

      if [[ $plotplates -eq 1 ]]; then
        for i in *_platevecs.txt; do
          # Use azimuth/velocity data in platevecs.txt to infer VN/VE
          awk < $i '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4); else print $1, $2, az+360, sqrt($3*$3+$4*$4); }' > ${i}.pvec
          GRIDMAXVEL=$(awk < ${i}.pvec -v prevmax=$GRIDMAXVEL 'BEGIN {max=prevmax} {if ($4 > max) {max=$4} } END {print max}' )
          gmt psvelo ${i} -W0p,$PLATEVEC_COLOR@$PLATEVEC_TRANS -G$PLATEVEC_COLOR@$PLATEVEC_TRANS -A${ARROWFMT} -Se$VELSCALE/${GPS_ELLIPSE}/0 -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
          [[ $PLATEVEC_TEXT_PLOT -eq 1 ]] && awk < ${i}.pvec -v poff=$POFFS '($4 != 0) { print $1 - sin($3*3.14159265358979/180)*poff, $2 - cos($3*3.14159265358979/180)*poff, sprintf("%d", $4) }' | gmt pstext -F+f${PLATEVEC_TEXT_SIZE},${PLATEVEC_TEXT_FONT},${PLATEVEC_TEXT_COLOR}+jCM $RJOK "${VERBOSE}"  >> map.ps
        done
      fi
      ;;

    image)
      info_msg "gmt grdimage $IMAGENAME ${IMAGEARGS} $RJOK ${VERBOSE} >> map.ps"
      gmt grdimage "$IMAGENAME" "${IMAGEARGS}" $RJOK "${VERBOSE}" >> map.ps
      ;;

    kinsv)
      # Plot the slip vectors for focal mechanism nodal planes
      info_msg "Plotting kinematic slip vectors"

      if [[ kinthrustflag -eq 1 ]]; then
        [[ np1flag -eq 1 ]] && gmt psxy -SV0.05i+jb+e -W0.4p,${NP1_COLOR} -G${NP1_COLOR} thrust_gen_slip_vectors_np1.txt $RJOK "${VERBOSE}" >> map.ps
        [[ np2flag -eq 1 ]] && gmt psxy -SV0.05i+jb+e -W0.4p,${NP2_COLOR} -G${NP2_COLOR} thrust_gen_slip_vectors_np2.txt $RJOK "${VERBOSE}" >> map.ps
      fi
      if [[ kinnormalflag -eq 1 ]]; then
        [[ np1flag -eq 1 ]] && gmt psxy -SV0.05i+jb+e -W0.7p,green -Ggreen normal_slip_vectors_np1.txt $RJOK "${VERBOSE}" >> map.ps
        [[ np2flag -eq 1 ]] && gmt psxy -SV0.05i+jb+e -W0.5p,green -Ggreen normal_slip_vectors_np2.txt $RJOK "${VERBOSE}" >> map.ps
      fi
      if [[ kinssflag -eq 1 ]]; then
        [[ np1flag -eq 1 ]] && gmt psxy -SV0.05i+jb+e -W0.7p,blue -Gblue strikeslip_slip_vectors_np1.txt $RJOK "${VERBOSE}" >> map.ps
        [[ np2flag -eq 1 ]] && gmt psxy -SV0.05i+jb+e -W0.5p,blue -Gblue strikeslip_slip_vectors_np2.txt $RJOK "${VERBOSE}" >> map.ps
      fi
      ;;

    kingeo)
      info_msg "Plotting kinematic data"
      # Currently only plotting strikes and dips of thrust mechanisms
      if [[ kinthrustflag -eq 1 ]]; then
        # Plot dip line of NP1
        [[ np1flag -eq 1 ]] && gmt psxy -SV0.05i+jb -W0.5p,white -Gwhite thrust_gen_slip_vectors_np1_downdip.txt $RJOK "${VERBOSE}" >> map.ps
        # Plot strike line of NP1
        [[ np1flag -eq 1 ]] && gmt psxy -SV0.05i+jb -W0.5p,white -Gwhite thrust_gen_slip_vectors_np1_str.txt $RJOK "${VERBOSE}" >> map.ps
        # Plot dip line of NP2
        [[ np2flag -eq 1 ]] && gmt psxy -SV0.05i+jb -W0.5p,gray -Ggray thrust_gen_slip_vectors_np2_downdip.txt $RJOK "${VERBOSE}" >> map.ps
        # Plot strike line of NP2
        [[ np2flag -eq 1 ]] && gmt psxy -SV0.05i+jb -W0.5p,gray -Ggray thrust_gen_slip_vectors_np2_str.txt $RJOK "${VERBOSE}" >> map.ps
      fi
      plottedkinsd=1
      ;;

    mag)
      info_msg "Plotting magnetic data"
      # gmt grdimage $EMAG_V2 -C$EMAG_V2_CPT -t$MAGTRANS $RJOK "${VERBOSE}" >> map.ps
      gmt grdimage $EMAG_V2 -C$CPTDIR"mag.cpt" -t$MAGTRANS $RJOK -Q "${VERBOSE}" >> map.ps
      ;;

    mprof)
      info_msg "Drawing profile(s)"

      PSFILE=$(echo "$(cd "$(dirname "map.ps")"; pwd)/$(basename "map.ps")")

      cp gmt.history gmt.history.preprofile
      . $MPROFILE_SH_SRC
      cp gmt.history.preprofile gmt.history

      # Plot the profile lines with the assigned color on the map
      k=$(wc -l < $MPROFFILE | awk '{print $1}')
      for ind in $(seq 1 $k); do
        FIRSTWORD=$(head -n ${ind} $MPROFFILE | tail -n 1 | awk '{print $1}')
        if [[ ${FIRSTWORD:0:1} != "#" && ${FIRSTWORD:0:1} != "$" && ${FIRSTWORD:0:1} != "%" && ${FIRSTWORD:0:1} != "^" && ${FIRSTWORD:0:1} != "@"  && ${FIRSTWORD:0:1} != ":"  && ${FIRSTWORD:0:1} != ">" ]]; then
          COLOR=$(head -n ${ind} $MPROFFILE | tail -n 1 | awk '{print $2}')
          # echo $FIRSTWORD $ind $k
          # head -n ${ind} $MPROFFILE | tail -n 1 | cut -f 5- -d ' ' | xargs -n 2 | gmt psxy $RJOK -W1.5p,${COLOR} >> map.ps
          head -n ${ind} $MPROFFILE | tail -n 1 | cut -f 5- -d ' ' | xargs -n 2 | gmt psxy -S~D50k/0:+s-0.05i+a0 $RJOK -W1.5p,${COLOR} >> map.ps
        fi
      done

      # Plot the gridtrack tracks, for debugging
      # for track_file in *_profiletable.txt; do
      #    echo $track_file
      #   gmt psxy $track_file -W0.15p,black $RJOK "${VERBOSE}" >> map.ps
      # done

      # for proj_pts in projpts*;  do
      #   gmt psxy $proj_pts -Sc0.03i -Gred -W0.15p,black $RJOK "${VERBOSE}" >> map.ps
      # done

      # Plot the buffers around the polylines, for debugging
      if [[ -e buf_poly.txt ]]; then
        gmt psxy buf_poly.txt -W0.5p,red $RJOK "${VERBOSE}" >> map.ps
      fi

      # Plot the intersection point of the profile with the 0-distance datum line as triangle
      if [[ -e all_intersect.txt ]]; then
        gmt psxy xy_intersect.txt -W0.5p,black $RJOK "${VERBOSE}" >> map.ps
        gmt psxy all_intersect.txt -St0.1i -Gwhite -W0.7p,black $RJOK "${VERBOSE}" >> map.ps
      fi
      ;;

    plateazdiff)
      info_msg "Drawing plate azimuth differences"

      # This should probably be changed to obliquity
      # Plot the azimuth of relative plate motion across the boundary
      # azdiffpts_len.txt should be replaced with id_pts_euler.txt
      [[ $plotplates -eq 1 ]] && awk < azdiffpts_len.txt -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" '{
        if ($1 != minlon && $1 != maxlon && $2 != minlat && $2 != maxlat) {
          print $1, $2, $3
        }
      }' | gmt psxy -C$CPTDIR"cycleaz.cpt" -t0 -Sc${AZDIFFSCALE}/0 $RJOK "${VERBOSE}" >> map.ps

      mkdir az_histogram
      cd az_histogram
        awk < ../azdiffpts_len.txt '{print $3, $4}' | gmt pshistogram -C$CPTDIR"cycleaz.cpt" -JX5i/2i -R-180/180/0/1 -Z0+w -T2 -W0.1p -I -Ve > azdiff_hist_range.txt
        ADR4=$(awk < azdiff_hist_range.txt '{print $4*1.1}')
        awk < ../azdiffpts_len.txt '{print $3, $4}' | gmt pshistogram -C$CPTDIR"cycleaz.cpt" -JX5i/2i -R-180/180/0/$ADR4 -BNESW+t"$POLESRC $MINLON/$MAXLON/$MINLAT/$MAXLAT" -Bxa30f10 -Byaf -Z0+w -T2 -W0.1p > ../az_histogram.ps
      cd ..
      gmt psconvert -Tf -A0.3i az_histogram.ps
      ;;

    platediffv)
      # Plot velocity across plate boundaries
      # Excludes plotting of adjacent points closer than a cutoff distance (Degrees).
      # Plots any point with [lat,lon] values that have already been plotted.
      # input data are in what m/yr

      info_msg "Drawing plate relative velocities"
      info_msg "velscale=$VELSCALE"
      MINVV=0.15

        awk -v cutoff=$PDIFFCUTOFF 'BEGIN {dist=0;lastx=9999;lasty=9999} {
          # If we haven not seen this point before
          if (seenx[$1,$2] == 0) {
              seenx[$1,$2]=1
              newdist = ($1-lastx)*($1-lastx)+($2-lasty)*($2-lasty);
              if (newdist > cutoff) {
                lastx=$1
                lasty=$2
                doprint[$1,$2]=1
                print
              }
            } else {   # print any point that we have already printed
              if (doprint[$1,$2]==1) {
                print
              }
            }
          }' < paz1normal.txt > paz1normal_cutoff.txt

        awk -v cutoff=$PDIFFCUTOFF 'BEGIN {dist=0;lastx=9999;lasty=9999} {
          # If we haven not seen this point before
          if (seenx[$1,$2] == 0) {
              seenx[$1,$2]=1
              newdist = ($1-lastx)*($1-lastx)+($2-lasty)*($2-lasty);
              if (newdist > cutoff) {
                lastx=$1
                lasty=$2
                doprint[$1,$2]=1
                print
              }
            } else {   # print any point that we have already printed
              if (doprint[$1,$2]==1) {
                print
              }
            }
          }' < paz1thrust.txt > paz1thrust_cutoff.txt

          awk -v cutoff=$PDIFFCUTOFF 'BEGIN {dist=0;lastx=9999;lasty=9999} {
            # If we haven not seen this point before
            if (seenx[$1,$2] == 0) {
                seenx[$1,$2]=1
                newdist = ($1-lastx)*($1-lastx)+($2-lasty)*($2-lasty);
                if (newdist > cutoff) {
                  lastx=$1
                  lasty=$2
                  doprint[$1,$2]=1
                  print
                }
              } else {   # print any point that we have already printed
                if (doprint[$1,$2]==1) {
                  print
                }
              }
            }' < paz1ss1.txt > paz1ss1_cutoff.txt

            awk -v cutoff=$PDIFFCUTOFF 'BEGIN {dist=0;lastx=9999;lasty=9999} {
              # If we haven not seen this point before
              if (seenx[$1,$2] == 0) {
                  seenx[$1,$2]=1
                  newdist = ($1-lastx)*($1-lastx)+($2-lasty)*($2-lasty);
                  if (newdist > cutoff) {
                    lastx=$1
                    lasty=$2
                    doprint[$1,$2]=1
                    print
                  }
                } else {   # print any point that we have already printed
                  if (doprint[$1,$2]==1) {
                    print
                  }
                }
              }' < paz1ss2.txt > paz1ss2_cutoff.txt

        # If the scale is too small, normal opening will appear to be thrusting due to arrowhead offset...!
        # Set a minimum scale for vectors to avoid improper plotting of arrowheads

        LONDIFF=$(echo "$MAXLON - $MINLON" | bc -l)
        pwnum=$(echo $PLATELINE_WIDTH | awk '{print $1+0}')
        POFFS=$(echo "$LONDIFF/8*1/72*$pwnum*3/2" | bc -l)

        # Old formatting works but isn't exactly great

        # We plot the half-velocities across the plate boundaries instead of full relative velocity for each plate

        awk < paz1normal_cutoff.txt -v poff=$POFFS -v minv=$MINVV -v gpsscalefac=$VELSCALE '{ if ($4<minv && $4 != 0) {print $1 + sin($3*3.14159265358979/180)*poff, $2 + cos($3*3.14159265358979/180)*poff, $3, $4*gpsscalefac/2} else {print $1 + sin($3*3.14159265358979/180)*poff, $2 + cos($3*3.14159265358979/180)*poff, $3, $4*gpsscalefac/2}}' | gmt psxy -SV"${PVFORMAT}" -W0p,$PLATEARROW_COLOR@$PLATEARROW_TRANS -G$PLATEARROW_COLOR@$PLATEARROW_TRANS $RJOK "${VERBOSE}" >> map.ps
        awk < paz1thrust_cutoff.txt -v poff=$POFFS -v minv=$MINVV -v gpsscalefac=$VELSCALE '{ if ($4<minv && $4 != 0) {print $1 - sin($3*3.14159265358979/180)*poff, $2 - cos($3*3.14159265358979/180)*poff, $3, $4*gpsscalefac/2} else {print $1 - sin($3*3.14159265358979/180)*poff, $2 - cos($3*3.14159265358979/180)*poff, $3, $4*gpsscalefac/2}}' | gmt psxy -SVh"${PVFORMAT}" -W0p,$PLATEARROW_COLOR@$PLATEARROW_TRANS -G$PLATEARROW_COLOR@$PLATEARROW_TRANS $RJOK "${VERBOSE}" >> map.ps
        # awk < paz1normal_cutoff.txt -v minv=$MINVV '{ if ($4 != 0) {print $1, $2, $3, minv} }' | gmt psxy -SV"${PVFORMAT}" -W0p,$PLATEARROW_COLOR@$PLATEARROW_TRANS -G$PLATEARROW_COLOR@$PLATEARROW_TRANS $RJOK "${VERBOSE}" >> map.ps
        # awk < paz1thrust_cutoff.txt -v minv=$MINVV '{ if ($4 != 0) {print $1, $2, $3, minv} }' | gmt psxy -SVh"${PVFORMAT}" -W0p,$PLATEARROW_COLOR@$PLATEARROW_TRANS -G$PLATEARROW_COLOR@$PLATEARROW_TRANS $RJOK "${VERBOSE}" >> map.ps

        # Shift symbols based on azimuth of line segment to make nice strike-slip half symbols
        awk < paz1ss1_cutoff.txt -v poff=$POFFS -v gpsscalefac=$VELSCALE '{ if ($4!=0) { print $1 + cos($3*3.14159265358979/180)*poff, $2 - sin($3*3.14159265358979/180)*poff, $3, 0.1/2}}' | gmt psxy -SV"${PVHEAD}"+r+jb+m+a33+h0 -W0p,red@$PLATEARROW_TRANS -Gred@$PLATEARROW_TRANS $RJOK "${VERBOSE}" >> map.ps
        awk < paz1ss2_cutoff.txt -v poff=$POFFS -v gpsscalefac=$VELSCALE '{ if ($4!=0) { print $1 - cos($3*3.14159265358979/180)*poff, $2 - sin($3*3.14159265358979/180)*poff, $3, 0.1/2 }}' | gmt psxy -SV"${PVHEAD}"+l+jb+m+a33+h0 -W0p,yellow@$PLATEARROW_TRANS -Gyellow@$PLATEARROW_TRANS $RJOK "${VERBOSE}" >> map.ps
      ;;

    plateedge)
      info_msg "Drawing plate edges"

      # Plot edges of plates
      #[[ $plotplates -eq 1 ]] && gmt psxy $PLATES -W$PLATELINE_WIDTH,$PLATELINE_COLOR -L $RJOK "${VERBOSE}" >> map.ps
      gmt psxy $EDGES -W$PLATELINE_WIDTH,$PLATELINE_COLOR $RJOK "${VERBOSE}" >> map.ps
      ;;

    platelabel)
      info_msg "Labeling plates"

      # Label the plates if we calculated the centroid locations
      # Remove the trailing _N from all plate labels
      [[ $plotplates -eq 1 ]] && awk < map_labels.txt -F, '{print $1, $2, substr($3, 1, length($3)-2)}' | gmt pstext -C0.1+t -F+f$PLATELABEL_SIZE,Helvetica,$PLATELABEL_COLOR+jCB $RJOK "${VERBOSE}"  >> map.ps
      ;;

    platerotation)
      info_msg "Plotting small circle rotations"

      # Plot small circles and little arrows for plate rotations
      for i in *_smallcirc_platevecs.txt; do
        cat $i | awk -v scalefac=0.01 '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, scalefac; else print $1, $2, az+360, scalefac; }'  > ${i}.pvec
        gmt psxy -SV0.0/0.12/0.06 -: -W0p,$PLATEVEC_COLOR@70 -G$PLATEVEC_COLOR@70 ${i}.pvec -t70 $RJOK "${VERBOSE}" >> map.ps
      done
      for i in *smallcircles_clip; do
       info_msg "Plotting small circle file ${i}"
       cat ${i} | gmt psxy -W1p,${PLATEVEC_COLOR}@50 -t70 $RJOK "${VERBOSE}" >> map.ps
      done
      ;;

    platevelgrid)
      # Move the calculation to the calculation zone
      # Plot a colored plate velocity grid
      info_msg "Calculating plate velocity grids"
      mkdir pvdir
      MAXV_I=0
      MINV_I=99999

      for i in *.pole; do
        LEAD=${i%.pole*}
        info_msg "Calculating $LEAD velocity raster"
        awk < $i '{print $2, $1}' > pvdir/pole.xy
        POLERATE=$(awk < $i '{print $3}')
        cd pvdir
        cat "../$LEAD.pldat" | sed '1d' > plate.xy
        # # Determine the extent of the polygon within the map extent
        pl_max_x=$(grep "^[-*0-9]" plate.xy | sort -n -k 1 | tail -n 1 | awk -v mx=$MAXLON '{print ($1>mx)?mx:$1}')
        pl_min_x=$(grep "^[-*0-9]" plate.xy | sort -n -k 1 | head -n 1 | awk -v mx=$MINLON '{print ($1<mx)?mx:$1}')
        pl_max_y=$(grep "^[-*0-9]" plate.xy | sort -n -k 2 | tail -n 1 | awk -v mx=$MAXLAT '{print ($2>mx)?mx:$2}')
        pl_min_y=$(grep "^[-*0-9]" plate.xy | sort -n -k 2 | head -n 1 | awk -v mx=$MINLAT '{print ($2<mx)?mx:$2}')
        info_msg "Polygon region $pl_min_x/$pl_max_x/$pl_min_y/$pl_max_y"
        # this approach requires a final GMT grdblend command
        # echo platevelres=$PLATEVELRES
        gmt grdmath ${VERBOSE} -R$pl_min_x/$pl_max_x/$pl_min_y/$pl_max_y -fg -I$PLATEVELRES pole.xy PDIST 6378.13696669 DIV SIN $POLERATE MUL 6378.13696669 MUL .01745329251944444444 MUL = "$LEAD"_velraster.nc
        gmt grdmask plate.xy ${VERBOSE} -R"$LEAD"_velraster.nc -fg -NNaN/1/1 -Gmask.nc
        info_msg "Calculating $LEAD masked raster"
        gmt grdmath -fg ${VERBOSE} "$LEAD"_velraster.nc mask.nc MUL = "$LEAD"_masked.nc
        MAXV_I=$(gmt grdinfo ${LEAD}_velraster.nc 2>/dev/null | grep "z_max" | awk -v max=$MAXV_I '{ if ($5 > max) { print $5 } else { print max } }')
        MINV_I=$(gmt grdinfo ${LEAD}_velraster.nc 2>/dev/null | grep "z_max" | awk -v min=$MINV_I '{ if ($3 < min) { print $3 } else { print min } }')
        # gmt grdedit -fg -A -R$pl_min_x/$pl_max_x/$pl_min_y/$pl_max_y "$LEAD"_masked.nc -G"$LEAD"_masked_edit.nc
        # echo "${LEAD}_masked_edit.nc -R$pl_min_x/$pl_max_x/$pl_min_y/$pl_max_y 1" >> grdblend.cmd
        cd ../
      done
      info_msg "Merging velocity rasters"

      PVRESNUM=$(echo "" | awk -v v=$PLATEVELRES 'END {print v+0}')
      info_msg "gdal_merge.py -o plate_velocities.nc -of NetCDF -ps $PVRESNUM $PVRESNUM -ul_lr $MINLON $MAXLAT $MAXLON $MINLAT *_masked.nc"
      cd pvdir
        gdal_merge.py -o plate_velocities.nc -q -of NetCDF -ps $PVRESNUM $PVRESNUM -ul_lr $MINLON $MAXLAT $MAXLON $MINLAT *_masked.nc
      cd ..
      # info_msg "Creating zero raster"
      # gmt grdmath ${VERBOSE} -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -fg -I$PLATEVELRES 0 = plate_velocities.nc
      # for i in pvdir/*_masked.nc; do
      #   info_msg "Adding $LEAD to plate velocity raster"
      #   gmt grdmath ${VERBOSE} -fg plate_velocities.nc $i 0 AND ADD = plate_velocities.nc
      # done

      # cd pvdir
      # echo blending
      # gmt grdblend grdblend.cmd -fg -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -Gplate_velocities.nc -I$PLATEVELRES ${VERBOSE}

      # This isn't working because I can't seem to read the max values from this raster this way or with gdalinfo
      if [[ $rescaleplatevecsflag -eq 1 ]]; then
        echo MINV_I MAXV_I $MINV_I $MAXV_I
        MINV=$(echo $MINV_I | awk '{ print int($1/10)*10 }')
        MAXV=$(echo $MAXV_I | awk '{ print int($1/10)*10 +10 }')
        echo MINV MAXV $MINV $MAXV

        gmt makecpt -C$CPTDIR"platevel_one.cpt" -T0/$MAXV -Z > pv.cpt
        # Whatever
        # gmt makecpt -T0/100/1 -C$CPTDIR"platevel_one.cpt" -Z ${VERBOSE} > pv.cpt  #-C$CPTDIR"platevel.cpt"

      else
        gmt makecpt -T0/100/1 -C$CPTDIR"platevel_one.cpt" -Z ${VERBOSE} > pv.cpt  #-C$CPTDIR"platevel.cpt"
      fi

      # cd ..
      info_msg "Plotting velocity raster."
      gmt grdimage -Cpv.cpt ./pvdir/plate_velocities.nc $RJOK "${VERBOSE}" >> map.ps
      info_msg "Plotted velocity raster."
      ;;

    points)
      if [[ $pointdatacptflag == 1 ]]; then
        gmt psxy $POINTDATAFILE -W$POINTLINEWIDTH,$POINTLINECOLOR -C$POINTDATACPT -G+z -Sc$POINTSIZE $RJOK "${VERBOSE}" >> map.ps
      else
        gmt psxy $POINTDATAFILE -G$POINTCOLOR -W$POINTLINEWIDTH,$POINTLINECOLOR -Sc$POINTSIZE $RJOK "${VERBOSE}" >> map.ps
      fi
      ;;

    refpoint)
      info_msg "Plotting reference point"

      if [[ $refptflag -eq 1 ]]; then
      # Plot the reference point as a circle around a triangle
        echo $REFPTLON $REFPTLAT| gmt psxy -W0.1,black -Gblack -St0.05i $RJOK "${VERBOSE}" >> map.ps
        echo $REFPTLON $REFPTLAT| gmt psxy -W0.1,black -Sc0.1i $RJOK "${VERBOSE}" >> map.ps
      fi

      ;;
    seis)
      info_msg "Plotting seismicity; should include options for CPT/fill color"
      awk < $EQANSSFILETXT -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" '($1 < maxlon && $1 > minlon && $2 < maxlat && $2 > minlat) {print}' > eqs.txt
		  # Plot the seismicity catalog
      # x y [ z ] [ size ] [ symbol-parameters ] [ symbol ]
      OLD_PROJ_LENGTH_UNIT=$(gmt gmtget PROJ_LENGTH_UNIT -Vn)
      gmt gmtset PROJ_LENGTH_UNIT p
      # Magnitude ranges from 0 to 10 (0 p to 10p)


      if [[ $SCALEEQS -eq 1 ]]; then
        awk < eqs.txt -v str=$SEISSTRETCH -v sref=$SEISSTRETCH_REFMAG '{print $1, $2, $3, ($4^str)/(sref^(str-1)), $5, $6}' | gmt psxy -C$CPTDIR"neis2.cpt" -i0,1,2,3+s${SEISSCALE} -S${SEISSYMBOL} $RJOK "${VERBOSE}" >> map.ps
      else
        gmt psxy -C$CPTDIR"neis2.cpt" -i0,1,2 -S${SEISSYMBOL}${SEISSIZE} eqs.txt $RJOK "${VERBOSE}" >> map.ps
      fi
      gmt gmtset PROJ_LENGTH_UNIT $OLD_PROJ_LENGTH_UNIT

			;;

    seisrake1)
      info_msg "Seis rake 1"

      # Plot the rake of the N1 nodal plane
      # lonc latc depth str1 dip1 rake1 str2 dip2 rake2 M lon lat ID
      awk < $CMTFILE '($6 > 45 && $6 < 135) { print $1, $2, $4-($6-180) }' | awk '{ if ($3 > 180) { print $1, $2, $3-360;} else {print $1,$2,$3} }' > eqaz1.txt
      gmt psxy -C$CPTDIR"cycleaz.cpt" -St${RAKE1SCALE}/0 eqaz1.txt $RJOK "${VERBOSE}" >> map.ps
      ;;

    seisrake2)
      ;;

    slab2)
      info_msg "Slab 2"

			if [[ ${SLAB2STR} =~ .*c.* ]]; then
				info_msg "Plotting SLAB2 contours"
				if ! [[ -f ${SLAB2CLIPDIR}slab2clippolys.dat ]]; then
					for i in ${SLAB2CLIPDIR}*.csv; do
						name=$(echo $i | xargs -n 1 basename)
						echo "> $name" | awk -F_ '{print $1}' >> ${SLAB2CLIPDIR}slab2clippolys.dat
						cat $i >> ${SLAB2CLIPDIR}slab2clippolys.dat
					done
				else
					info_msg "Slab2 unified clip polygon file exists... not creating"
				fi
#       Now done above to avoid problems with -R. Should use -R$proj always anyway...
#				gmt spatial ${SLAB2CLIPDIR}slab2clippolys.dat -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -C "${VERBOSE}" | awk '($1 == ">") {print $2}' > slab2_ids.txt
				# gmt makecpt -Cseis -Do -T-200/0/10 -N "${VERBOSE}" > $CPTDIR"neis2rev.cpt"

        # for i in $(cat slab2_ids.txt); do
        #   info_msg "processing Slab2 Contour File $i"
        #   SID=$(ls -1a ${SLAB2CONTOURDIR} | grep ^${i} | grep dep)
        #
        #   awk < ${SLAB2CONTOURDIR}${SID} '{
        #     if ($1 == ">") {
        #       print $1, "-Z" 0-$2
        #     } else {
        #       print $1, $2, 0 - $3
        #     }}' | gmt psxy -C$CPTDIR"neis2.cpt" -W0.5p+z $RJOK "${VERBOSE}" >> map.ps
				# done
        for slabcfile in $(ls -1a ${SLAB2CONTOURDIR} | grep dep); do
          info_msg "processing Slab2 Contour File $slabcfile"

          awk < ${SLAB2CONTOURDIR}${slabcfile} '{
            if ($1 == ">") {
              print $1, "-Z" 0-$2
            } else {
              print $1, $2, 0 - $3
            }}' | gmt psxy -C$CPTDIR"neis2.cpt" -W0.5p+z $RJOK "${VERBOSE}" >> map.ps
        done
			fi
			if [[ ${SLAB2STR} =~ .*z.* ]]; then
				# Use the SLAB2 compiled data... can't separate out mechanisms yet...
				gmt psxy $EQSLAB2FILETXT -C$CPTDIR"neis2.cpt" -Sc0.03 $RJOK "${VERBOSE}"  >> map.ps
			fi
			if [[ ${SLAB2STR} =~ .*m.* ]]; then
				# Use the SLAB2 compiled data... can't separate out mechanisms yet...
				gmt psmeca $EQSLAB2MECATXT -Z$CPTDIR"neis2.cpt" -Sd{$CMTSCALE}/0 -L0.25p,black $RJOK "${VERBOSE}"  >> map.ps
			fi
			;;

    slipvecs)
      info_msg "Slip vectors"
      # Plot a file containing slip vector azimuths
      awk < ${SVDATAFILE} '($1 != "end") {print $1, $2, $3, 0.2}' | gmt psxy -SV0.05i+jc -W1.5p,red $RJOK "${VERBOSE}" >> map.ps
      ;;

		srcmod)
      info_msg "SRCMOD"

			##########################################################################################
			##########################################################################################
			# Calculate and plot a 'fused' large earthquake slip distribution from SRCMOD events
			# We need to determine a resolution for gmt surface, but in km. Use width of image
			# in degrees

			# NOTE that SRCMODFSPLOCATIONS needs to be generated using extract_fsp_locations.sh

			if [[ -e $SRCMODFSPLOCATIONS ]]; then
				info_msg "SRCMOD FSP data file exists"
			else
				# Extract locations of earthquakes and output filename,Lat,Lon to a text file
				info_msg "Building SRCMOD FSP location file"
				comeback=$(pwd)
				cd ${SRCMODFSPFOLDER}
				eval "grep -H 'Loc  :' *" | awk -F: '{print $1, $3 }' | awk '{print $7 "	" $4 "	" $1}' > $SRCMODFSPLOCATIONS
				cd $comeback
			fi

			info_msg "Identifying SRCMOD results falling within the AOI"
			awk < $SRCMODFSPLOCATIONS -v minlat="$MINLAT" -v maxlat="$MAXLAT" -v minlon="$MINLON" -v maxlon="$MAXLON" '($1 < maxlon-1 && $1 > minlon+1 && $2 < maxlat-1 && $2 > minlat+1) {print $3}' > srcmod_eqs.txt
			[[ $narrateflag -eq 1 ]] && cat srcmod_eqs.txt

			SLIPRESOL=300

			LONDIFF=$(echo $MAXLON - $MINLON | bc -l)
			LONKM=$(echo "$LONDIFF * 110 * c( ($MAXLAT - $MINLAT) * 3.14159265358979 / 180 / 2)"/$SLIPRESOL | bc -l)
			info_msg "LONDIFF is $LONDIFF"
			info_msg "LONKM is $LONKM"

			# Add all earthquake model slips together into a fused slip raster.
			# Create an empty 0 raster with a resolution of LONKM
			#echo | gmt xyz2grd -di0 -R -I"$LONKM"km -Gzero.nc

			gmt grdmath "${VERBOSE}" -R -I"$LONKM"km 0 = slip.nc
			#rm -f slip2.nc

			NEWR=$(echo $MINLON-1|bc -l)"/"$(echo $MAXLON+1|bc -l)"/"$(echo $MINLAT-1|bc -l)"/"$(echo $MAXLAT+1|bc -l)

			v=($(cat srcmod_eqs.txt | tr ' ' '\n'))
			i=0
			while [[ $i -lt ${#v[@]} ]]; do
				info_msg "Plotting points from EQ ${v[$i]}"
				grep "^[^%;]" "$SRCMODFSPFOLDER"${v[$i]} | awk '{print $2, $1, $6}' > temp1.xyz
				gmt blockmean temp1.xyz -I"$LONKM"km "${VERBOSE}" -R > temp.xyz
				gmt triangulate temp.xyz -I"$LONKM"km -Gtemp.nc -R "${VERBOSE}"
				gmt grdmath "${VERBOSE}" temp.nc ISNAN 0 temp.nc IFELSE = slip2.nc
				gmt grdmath "${VERBOSE}" slip2.nc slip.nc MAX = slip3.nc
				mv slip3.nc slip.nc
				i=$i+1
			done

			if [[ -e slip2.nc ]]; then
				gmt grdmath "${VERBOSE}" slip.nc $SLIPMINIMUM GT slip.nc MUL = slipfinal.grd
				gmt grdmath "${VERBOSE}" slip.nc $SLIPMINIMUM LE 1 NAN = mask.grd
				#This takes the logical grid file from the previous step (mask.grd)
				#and replaces all of the 1s with the original conductivies from interpolated.grd
				gmt grdmath "${VERBOSE}" slip.nc mask.grd OR = slipfinal.grd
				gmt grdimage slipfinal.grd -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -C$CPTDIR"faultslip.cpt" -t40 -Q -J -O -K "${VERBOSE}" >> map.ps
				gmt grdcontour slipfinal.grd -C$SLIPCONTOURINTERVAL $RJOK "${VERBOSE}" >> map.ps
			fi
			;;

		tdefnode)
			info_msg "TDEFNODE folder is at $TDPATH"
			TDMODEL=$(echo $TDPATH | xargs -n 1 basename | awk -F. '{print $1}')
			info_msg "$TDMODEL"

      if [[ ${TDSTRING} =~ .*a.* ]]; then
        # BLOCK LABELS
        info_msg "TDEFNODE block labels"
        awk < ${TDPATH}${TDMODEL}_blocks.out '{ print $2,$3,$1 }' | gmt pstext -F+f8,Helvetica,orange+jBL $RJOK "${VERBOSE}" >> map.ps
      fi
      if [[ ${TDSTRING} =~ .*b.* ]]; then
        # BLOCKS ############
        info_msg "TDEFNODE blocks"
        gmt psxy ${TDPATH}${TDMODEL}_blk.gmt -W1p,black -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
      fi

      if [[ ${TDSTRING} =~ .*g.* ]]; then
        # Faults, nodes, etc.
        # Find the number of faults in the model
        info_msg "TDEFNODE faults, nodes, etc"
        numfaults=$(awk 'BEGIN {min=0} { if ($1 == ">" && $3 > min) { min = $3} } END { print min }' ${TDPATH}${TDMODEL}_flt_atr.gmt)
        gmt makecpt -Ccategorical -T0/$numfaults/1 "${VERBOSE}" > $CPTDIR"faultblock.cpt"
        awk '{ if ($1 ==">") printf "%s %s%f\n",$1,$2,$3; else print $1,$2 }' ${TDPATH}${TDMODEL}_flt_atr.gmt | gmt psxy -L -C$CPTDIR"faultblock.cpt" $RJOK "${VERBOSE}" >> map.ps
        gmt psxy ${TDPATH}${TDMODEL}_blk3.gmt -Wfatter,red,solid $RJOK "${VERBOSE}" >> map.ps
        gmt psxy ${TDPATH}${TDMODEL}_blk3.gmt -Wthickest,black,solid $RJOK "${VERBOSE}" >> map.ps
        #gmt psxy ${TDPATH}${TDMODEL}_blk.gmt -L -R -J -Wthicker,black,solid -O -K "${VERBOSE}"  >> map.ps
        awk '{if ($4==1) print $7, $8, $2}' ${TDPATH}${TDMODEL}.nod | gmt pstext -F+f10p,Helvetica,lightblue $RJOK "${VERBOSE}" >> map.ps
        awk '{print $7, $8}' ${TDPATH}${TDMODEL}.nod | gmt psxy -Sc.02i -Gblack $RJOK "${VERBOSE}" >> map.ps
      fi
			# if [[ ${TDSTRING} =~ .*l.* ]]; then
      #   # Coupling. Not sure this is the best way, but it seems to work...
      #   info_msg "TDEFNODE coupling"
			# 	gmt makecpt -Cseis -Do -I -T0/1/0.01 -N > $CPTDIR"srd.cpt"
			# 	awk '{ if ($1 ==">") print $1 $2 $5; else print $1, $2 }' ${TDPATH}${TDMODEL}_flt_atr.gmt | gmt psxy -L -C$CPTDIR"srd.cpt" $RJOK "${VERBOSE}" >> map.ps
			# fi
      if [[ ${TDSTRING} =~ .*l.* || ${TDSTRING} =~ .*c.* ]]; then
        # Plot a dashed line along the contour of coupling = 0
        info_msg "TDEFNODE coupling"
        gmt makecpt -Cseis -Do -I -T0/1/0.01 -N > $CPTDIR"srd.cpt"
        awk '{
          if ($1 ==">") {
            carat=$1
            faultid=$3
            z=$2
            val=$5
            getline
            p1x=$1; p1y=$2
            getline
            p2x=$1; p2y=$2
            getline
            p3x=$1; p3y=$2
            geline
            p4x=$1; p4y=$2
            xav=(p1x+p2x+p3x+p4x)/4
            yav=(p1y+p2y+p3y+p4y)/4
            print faultid, xav, yav, val
          }
        }' ${TDPATH}${TDMODEL}_flt_atr.gmt > tdsrd_faultids.xyz

        if [[ $tdeffaultlistflag -eq 1 ]]; then
          echo $FAULTIDLIST | awk '{
            n=split($0,groups,":");
            for(i=1; i<=n; i++) {
               print groups[i]
            }
          }' | tr ',' ' ' > faultid_groups.txt
        else # Extract all fault IDs as Group 1 if we don't specify faults/groups
          awk < tdsrd_faultids.xyz '{
            seen[$1]++
            } END {
              for (key in seen) {
                printf "%s ", key
            }
          } END { printf "\n"}' > faultid_groups.txt
        fi

        groupd=1
        while read p; do
          echo "Processing fault group $groupd"
          awk < tdsrd_faultids.xyz -v idstr="$p" 'BEGIN {
              split(idstr,idarray," ")
              for (i in idarray) {
                idcheck[idarray[i]]
              }
            }
            {
              if ($1 in idcheck) {
                print $2, $3, $4
              }
          }' > faultgroup_$groupd.xyz
          # May wish to process grouped fault data here

          mkdir tmpgrd
          cd tmpgrd
            gmt nearneighbor ../faultgroup_$groupd.xyz -S0.2d -R$MINLON/$MAXLON/$MINLAT/$MAXLAT -I0.1d -Gout.grd
          cd ..

          if [[ ${TDSTRING} =~ .*c.* ]]; then
            gmt psxy faultgroup_$groupd.xyz -Sc0.015i -C$CPTDIR"srd.cpt" $RJOK "${VERBOSE}" >> map.ps
          fi

          if [[ ${TDSTRING} =~ .*l.* ]]; then
            gmt grdcontour tmpgrd/out.grd -S5 -C+0.7 -W0.1p,black,- $RJOK "${VERBOSE}" >> map.ps
          fi
          # gmt contour faultgroup_$groupd.xyz -C+0.1 -W0.25p,black,- $RJOK "${VERBOSE}" >> map.ps

          # May wish to process grouped fault data here
          groupd=$(echo "$groupd+1" | bc)
        done < faultid_groups.txt
      fi


			if [[ ${TDSTRING} =~ .*X.* ]]; then
				# FAULTS ############
        info_msg "TDEFNODE faults"
				gmt psxy ${TDPATH}${TDMODEL}_blk0.gmt -R -J -W1p,red -O -K "${VERBOSE}" >> map.ps 2>/dev/null
				awk < ${TDPATH}${TDMODEL}_blk0.gmt '{ if ($1 == ">") print $3,$4, $5 " (" $2 ")" }' | gmt pstext -F+f8,Helvetica,black+jBL $RJOK "${VERBOSE}" >> map.ps

				# PSUEDOFAULTS ############
				gmt psxy ${TDPATH}${TDMODEL}_blk1.gmt -R -J -W1p,green -O -K "${VERBOSE}" >> map.ps 2>/dev/null
				awk < ${TDPATH}${TDMODEL}_blk1.gmt '{ if ($1 == ">") print $3,$4,$5 }' | gmt pstext -F+f8,Helvetica,brown+jBL $RJOK "${VERBOSE}" >> map.ps
			fi
			if [[ ${TDSTRING} =~ .*s.* ]]; then
				# SLIP VECTORS ######
        info_msg "TDEFNODE slip vectors (observed and predicted)"
				awk < ${TDPATH}${TDMODEL}.svs -v size=$SVBIG '(NR > 1) {print $1, $2, $3, size}' > ${TDMODEL}.svobs
				awk < ${TDPATH}${TDMODEL}.svs -v size=$SVSMALL '(NR > 1) {print $1, $2, $5, size}' > ${TDMODEL}.svcalc
				gmt psxy -SV"${PVHEAD}"+jc -W"${SVBIGW}",black ${TDMODEL}.svobs $RJOK "${VERBOSE}" >> map.ps
				gmt psxy -SV"${PVHEAD}"+jc -W"${SVSMALLW}",lightgreen ${TDMODEL}.svcalc $RJOK "${VERBOSE}" >> map.ps
			fi
			if [[ ${TDSTRING} =~ .*o.* ]]; then
				# GPS ##############
				# observed vectors
        # lon, lat, ve, vn, sve, svn, xcor, site
        # gmt psvelo $GPS_FILE -W${GPS_LINEWIDTH},${GPS_LINECOLOR} -G${GPS_FILLCOLOR} -A${ARROWFMT} -Se$VELSCALE/${GPS_ELLIPSE}/0 -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
        info_msg "TDEFNODE observed GPS velocities"
				echo "" | awk '{ if ($5==1 && $6==1) print $8, $9, $12, $17, $15, $20, $27, $1 }' ${TDPATH}${TDMODEL}.vsum > ${TDMODEL}.obs
				gmt psvelo ${TDMODEL}.obs -W${TD_OGPS_LINEWIDTH},${TD_OGPS_LINECOLOR} -G${TD_OGPS_FILLCOLOR} -Se$VELSCALE/${GPS_ELLIPSE}/0 -A${ARROWFMT} -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
        # awk -v gpsscalefac=$VELSCALE '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4)*gpsscalefac; else print $1, $2, az+360, sqrt($3*$3+$4*$4)*gpsscalefac; }' ${TDMODEL}.obs > ${TDMODEL}.xyobs
        # gmt psxy -SV$ARROWFMT -W0.25p,white -Gblack ${TDMODEL}.xyobs $RJOK "${VERBOSE}" >> map.ps
			fi
			if [[ ${TDSTRING} =~ .*v.* ]]; then
				# calculated vectors  UPDATE TO PSVELO
        info_msg "TDEFNODE modeled GPS velocities"
				awk '{ if ($5==1 && $6==1) print $8, $9, $13, $18, $15, $20, $27, $1 }' ${TDPATH}${TDMODEL}.vsum > ${TDMODEL}.vec
        gmt psvelo ${TDMODEL}.vec -W${TD_VGPS_LINEWIDTH},${TD_VGPS_LINECOLOR} -D0 -G${TD_VGPS_FILLCOLOR} -Se$VELSCALE/${GPS_ELLIPSE}/0 -A${ARROWFMT} -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null

        #  Generate AZ/VEL data
        echo "" | awk '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4); else print $1, $2, az+360, sqrt($3*$3+$4*$4); }' ${TDMODEL}.vec > ${TDMODEL}.xyvec
        # awk '(sqrt($3*$3+$4*$4) <= 5) { print $1, $2 }' ${TDMODEL}.vec > ${TDMODEL}_smallcalc.xyvec
        # gmt psxy -SV$ARROWFMT -W0.25p,black -Gwhite ${TDMODEL}.xyvec $RJOK "${VERBOSE}" >> map.ps
        # gmt psxy -SC$SMALLRES -W0.25p,black -Gwhite ${TDMODEL}_smallcalc.xyvec $RJOK "${VERBOSE}" >> map.ps
			fi
			if [[ ${TDSTRING} =~ .*r.* ]]; then
				#residual vectors UPDATE TO PSVELO
        info_msg "TDEFNODE residual GPS velocities"
				awk '{ if ($5==1 && $6==1) print $8, $9, $14, $19, $15, $20, $27, $1 }' ${TDPATH}${TDMODEL}.vsum > ${TDMODEL}.res
        # gmt psvelo ${TDMODEL}.res -W${TD_VGPS_LINEWIDTH},${TD_VGPS_LINECOLOR} -G${TD_VGPS_FILLCOLOR} -Se$VELSCALE/${GPS_ELLIPSE}/0 -A${ARROWFMT} -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
        gmt psvelo ${TDMODEL}.obs -W${TD_OGPS_LINEWIDTH},${TD_OGPS_LINECOLOR} -G${TD_OGPS_FILLCOLOR} -Se$VELSCALE/${GPS_ELLIPSE}/0 -A${ARROWFMT} -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null

        #  Generate AZ/VEL data
        echo "" | awk '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4)*gpsscalefac; else print $1, $2, az+360, sqrt($3*$3+$4*$4)*gpsscalefac; }' ${TDMODEL}.res > ${TDMODEL}.xyres
        # gmt psxy -SV$ARROWFMT -W0.1p,black -Ggreen ${TDMODEL}.xyres $RJOK "${VERBOSE}" >> map.ps
        # awk '(sqrt($3*$3+$4*$4) <= 5) { print $1, $2 }' ${TDMODEL}.res > ${TDMODEL}_smallres.xyvec
        # gmt psxy -SC$SMALLRES -W0.25p,black -Ggreen ${TDMODEL}_smallres.xyvec $RJOK "${VERBOSE}" >> map.ps

			fi
			if [[ ${TDSTRING} =~ .*f.* ]]; then
        # Fault segment midpoint slip rates
        # CONVERT TO PSVELO ONLY
        info_msg "TDEFNODE fault midpoint slip rates - all "
				awk '{ print $1, $2, $3, $4, $5, $6, $7, $8 }' ${TDPATH}${TDMODEL}_mid.vec > ${TDMODEL}.midvec
        # gmt psvelo ${TDMODEL}.midvec -W${SLIP_LINEWIDTH},${SLIP_LINECOLOR} -G${SLIP_FILLCOLOR} -Se$VELSCALE/${GPS_ELLIPSE}/0 -A${ARROWFMT} -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
        gmt psvelo ${TDMODEL}.midvec -W${SLIP_LINEWIDTH},${SLIP_LINECOLOR} -G${SLIP_FILLCOLOR} -Se$VELSCALE/${GPS_ELLIPSE}/0 -A${ARROWFMT} -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null

        # Generate AZ/VEL data
        awk '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4); else print $1, $2, az+360, sqrt($3*$3+$4*$4); }' ${TDMODEL}.midvec > ${TDMODEL}.xymidvec

        # Label
        awk '{ printf "%f %f %.1f\n", $1, $2, sqrt($3*$3+$4*$4) }' ${TDMODEL}.midvec > ${TDMODEL}.fsliplabel

		  	gmt pstext -F+f"${SLIP_FONTSIZE}","${SLIP_FONT}","${SLIP_FONTCOLOR}"+jBM $RJOK ${TDMODEL}.fsliplabel "${VERBOSE}" >> map.ps
			fi
      if [[ ${TDSTRING} =~ .*q.* ]]; then
        # Fault segment midpoint slip rates, only plot when the "distance" between the point and the last point is larger than a set value
        # CONVERT TO PSVELO ONLY
        info_msg "TDEFNODE fault midpoint slip rates - near cutoff = ${SLIP_DIST} degrees"

        awk -v cutoff=${SLIP_DIST} 'BEGIN {dist=0;lastx=9999;lasty=9999} {
            newdist = sqrt(($1-lastx)*($1-lastx)+($2-lasty)*($2-lasty));
            if (newdist > cutoff) {
              lastx=$1
              lasty=$2
              print $1, $2, $3, $4, $5, $6, $7, $8
            }
        }' < ${TDPATH}${TDMODEL}_mid.vec > ${TDMODEL}.midvecsel
        gmt psvelo ${TDMODEL}.midvecsel -W${SLIP_LINEWIDTH},${SLIP_LINECOLOR} -G${SLIP_FILLCOLOR} -Se$VELSCALE/${GPS_ELLIPSE}/0 -A${ARROWFMT} -L $RJOK "${VERBOSE}" >> map.ps 2>/dev/null
        # Generate AZ/VEL data
        awk '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4); else print $1, $2, az+360, sqrt($3*$3+$4*$4); }' ${TDMODEL}.midvecsel > ${TDMODEL}.xymidvecsel
        awk '{ printf "%f %f %.1f\n", $1, $2, sqrt($3*$3+$4*$4) }' ${TDMODEL}.midvecsel > ${TDMODEL}.fsliplabelsel
        gmt pstext -F+f${SLIP_FONTSIZE},${SLIP_FONT},${SLIP_FONTCOLOR}+jCM $RJOK ${TDMODEL}.fsliplabelsel "${VERBOSE}" >> map.ps
      fi
      if [[ ${TDSTRING} =~ .*y.* ]]; then
        # Fault segment midpoint slip rates, text on fault only, only plot when the "distance" between the point and the last point is larger than a set value
        info_msg "TDEFNODE fault midpoint slip rates, label only - near cutoff = 2"
        awk -v cutoff=${SLIP_DIST} 'BEGIN {dist=0;lastx=9999;lasty=9999} {
            newdist = sqrt(($1-lastx)*($1-lastx)+($2-lasty)*($2-lasty));
            if (newdist > cutoff) {
              lastx=$1
              lasty=$2
              print $1, $2, $3, $4, $5, $6, $7, $8
            }
        }' < ${TDPATH}${TDMODEL}_mid.vec > ${TDMODEL}.midvecsel
        awk '{ printf "%f %f %.1f\n", $1, $2, sqrt($3*$3+$4*$4) }' ${TDMODEL}.midvecsel > ${TDMODEL}.fsliplabelsel
        gmt pstext -F+f6,Helvetica-Bold,white+jCM $RJOK ${TDMODEL}.fsliplabelsel "${VERBOSE}" >> map.ps
      fi
      if [[ ${TDSTRING} =~ .*e.* ]]; then
        # elastic component of velocity CONVERT TO PSVELO
        info_msg "TDEFNODE elastic component of velocity"
        awk '{ if ($5==1 && $6==1) print $8, $9, $28, $29, 0, 0, 1, $1 }' ${TDPATH}${TDMODEL}.vsum > ${TDMODEL}.elastic
        awk -v gpsscalefac=$VELSCALE '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4)*gpsscalefac; else print $1, $2, az+360, sqrt($3*$3+$4*$4)*gpsscalefac; }' ${TDMODEL}.elastic > ${TDMODEL}.xyelastic
        gmt psxy -SV$ARROWFMT -W0.1p,black -Gred ${TDMODEL}.xyelastic  $RJOK "${VERBOSE}" >> map.ps
      fi
      if [[ ${TDSTRING} =~ .*t.* ]]; then
        # rotation component of velocity; CONVERT TO PSVELO
        info_msg "TDEFNODE block rotation component of velocity"
        awk '{ if ($5==1 && $6==1) print $8, $9, $38, $39, 0, 0, 1, $1 }' ${TDPATH}${TDMODEL}.vsum > ${TDMODEL}.block
        awk -v gpsscalefac=$VELSCALE '{ az=atan2($3, $4) * 180 / 3.14159265358979; if (az > 0) print $1, $2, az, sqrt($3*$3+$4*$4)*gpsscalefac; else print $1, $2, az+360, sqrt($3*$3+$4*$4)*gpsscalefac; }' ${TDMODEL}.block > ${TDMODEL}.xyblock
        gmt psxy -SV$ARROWFMT -W0.1p,black -Ggreen ${TDMODEL}.xyblock $RJOK "${VERBOSE}" >> map.ps
      fi
			;;

    topo)
      if [[ $dontplottopoflag -eq 0 ]]; then
        info_msg "Topography from $BATHY"
        gmt grdimage $BATHY -I+d -t$TOPOTRANS -C$BATHYCPT $RJOK "${VERBOSE}" >> map.ps
      else
        info_msg "Plotting of topo shaded relief suppressed by -ts"
      fi
      ;;

    volcanoes)
      info_msg "Volcanoes"
      awk < $SMITHVOLC '(NR>1) {print $2, $1}' | gmt psxy -W0.25p,"${V_LINEW}" -G"${V_FILL}" -St"${V_SIZE}"/0  $RJOK "${VERBOSE}" >> map.ps
      awk < $WHELLEYVOLC '(NR>1) {print $2, $1}' | gmt psxy -W0.25p,"${V_LINEW}" -G"${V_FILL}" -St"${V_SIZE}"/0  $RJOK "${VERBOSE}" >> map.ps
      ;;

	esac
done

gmt gmtset FONT_TITLE 12p,Helvetica,black

#####
# Plot the frame and close the map if KEEPOPEN is set to "" and we aren't overplotting a legend
# legendovermapflag=0
# makelegendflag=0

if [[ $legendovermapflag -eq 0 ]]; then
  info_msg "Plotting grid and keeping PS file open if --keepopenps is set ($KEEPOPEN)"
  if [[ $usecustombflag -eq 1 ]]; then
    echo gmt psbasemap -R -J -O $KEEPOPEN "${VERBOSE}" ${BSTRING[@]}
    gmt psbasemap -R -J -O $KEEPOPEN "${VERBOSE}" ${BSTRING[@]} >> map.ps
  else
    if [[ $PLOTTITLE == "BlankMapTitle" ]]; then
      gmt psbasemap -R -J -O $KEEPOPEN "${VERBOSE}" -Bxa"$GRIDSP""$GRIDSP_LINE" -Bya"$GRIDSP""$GRIDSP_LINE" -B"${GRIDCALL}" >> map.ps
    else
      gmt psbasemap -R -J -O $KEEPOPEN "${VERBOSE}" -Bxa"$GRIDSP""$GRIDSP_LINE" -Bya"$GRIDSP""$GRIDSP_LINE" -B"${GRIDCALL}"+t"${PLOTTITLE}" >> map.ps
    fi
  fi
else # We are overplotting a legend, so keep it open in any case
  info_msg "Plotting grid and keeping PS file open for legend"
  if [[ $usecustombflag -eq 1 ]]; then
    gmt psbasemap -R -J -O -K "${VERBOSE}" ${BSTRING[@]} >> map.ps
  else
    if [[ $PLOTTITLE == "BlankMapTitle" ]]; then
      gmt psbasemap -R -J -O -K "${VERBOSE}" -Bxa"$GRIDSP""$GRIDSP_LINE" -Bya"$GRIDSP""$GRIDSP_LINE" -B"${GRIDCALL}" >> map.ps
    else
      gmt psbasemap -R -J -O -K "${VERBOSE}" -Bxa"$GRIDSP""$GRIDSP_LINE" -Bya"$GRIDSP""$GRIDSP_LINE" -B"${GRIDCALL}"+t"${PLOTTITLE}" >> map.ps
    fi
  fi
fi

# Plot the short source data below the map frame

if [[ $makelegendflag -eq 1 ]]; then
  gmt gmtset MAP_TICK_LENGTH_PRIMARY 0.5p MAP_ANNOT_OFFSET_PRIMARY 1.5p MAP_ANNOT_OFFSET_SECONDARY 2.5p MAP_LABEL_OFFSET 2.5p FONT_LABEL 6p,Helvetica,black

  ###### Attribute the information on the map and plot colorbars, etc.
  # We need to move to a gmt pslegend format

  # Note: we could use gmt psconvert to find the clipped size of the map prior to
  # plotting the legend, and guarantee that we can plot above every map rather
  # than require four coordinates. We could just ask for a legend width?

  if [[ $legendovermapflag -eq 1 ]]; then
    LEGMAP="map.ps"
    #echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -JX20ix20i -R0/10/0/10 -Xf$PLOTSHIFTX -Yf$PLOTSHIFTY -K "${VERBOSE}" > maplegend.ps
  else
    info_msg "Plotting legend in its own file"
    LEGMAP="maplegend.ps"
    echo "0 0" | gmt psxy -Sc0.001i -Gwhite -W0p -JX20ix20i -R0/10/0/10 -X$PLOTSHIFTX -Y$PLOTSHIFTY -K "${VERBOSE}" > maplegend.ps
  fi

  # YADD=0.15i
  # echo "${plots[@]}" | gmt pstext "${VERBOSE}" -F+f8,Helvetica,black+jBL -Y$YADD $RJOK >> maplegend.ps
  # Could run out of room if we have too much data plotted!

  echo "# Legend " > legendbars.txt
  #echo "G 0.1i" >> legendbars.txt
  barplotcount=0
  plottedneiscptflag=0
  # Plot the color bars in a column first
  for plot in ${plots[@]} ; do
  	case $plot in
      cities)
          echo "G 0.2i" >> legendbars.txt
          echo "B ${CPTDIR}population.cpt 0.2i 0.1i+malu -W0.00001 -Bxa10f1+l\"City population (100k)\"" >> legendbars.txt
          barplotcount=$barplotcount+1

        ;;
      cmt)
        if [[ $plottedneiscptflag -eq 0 ]]; then
          plottedneiscptflag=1
          echo "G 0.2i" >> legendbars.txt
          echo "B ${CPTDIR}neis2_psscale.cpt 0.2i 0.1i+malu -Bxa100f50+l\"Earthquake / slab depth (km)\"" >> legendbars.txt
          barplotcount=$barplotcount+1
        fi
        ;;

  		grav)
        if [[ -e gravtmp.cpt ]]; then
          echo "G 0.2i" >> legendbars.txt
          echo "B gravtmp.cpt 0.2i 0.1i+malu -Bxa100f50+l\"$GRAVMODEL gravity (mgal)\"" >> legendbars.txt
          barplotcount=$barplotcount+1
        else
          echo "G 0.2i" >> legendbars.txt
          echo "B $GRAVCPT 0.2i 0.1i+malu -Bxa250f50+l\"$GRAVMODEL gravity (mgal)\"" >> legendbars.txt
          barplotcount=$barplotcount+1
        fi
  			;;

  		mag)
        echo "G 0.2i" >> legendbars.txt
        echo "B ${CPTDIR}mag.cpt 0.2i 0.1i+malu -Bxa100f50+l\"Magnetization (nT)\"" >> legendbars.txt
        barplotcount=$barplotcount+1
  			;;

      plateazdiff)
        echo "G 0.2i" >> legendbars.txt
        echo "B ${CPTDIR}cycleaz.cpt 0.2i 0.1i+malu -Bxa90f30+l\"Azimuth difference (°)\"" >> legendbars.txt
        barplotcount=$barplotcount+1
        ;;

      platevelgrid)
        echo "G 0.2i" >> legendbars.txt
        echo "B pv.cpt 0.2i 0.1i+malu -Bxa50f10+l\"Plate velocity (mm/yr)\"" >> legendbars.txt
        barplotcount=$barplotcount+1
        ;;

      seis)
        if [[ $plottedneiscptflag -eq 0 ]]; then
          plottedneiscptflag=1
          echo "G 0.2i" >> legendbars.txt
          echo "B ${CPTDIR}neis2_psscale.cpt 0.2i 0.1i+malu -Bxa100f50+l\"Earthquake / slab depth (km)\"" >> legendbars.txt
          barplotcount=$barplotcount+1
        fi
  			;;

  		slab2)
        if [[ $plottedneiscptflag -eq 0 ]]; then
          plottedneiscptflag=1
          echo "G 0.2i" >> legendbars.txt
          echo "B ${CPTDIR}neis2_psscale.cpt 0.2i 0.1i+malu -Bxa100f50+l\"Earthquake / slab depth (km)\"" >> legendbars.txt
          barplotcount=$barplotcount+1
        fi
  			;;

      topo)
        echo "G 0.2i" >> legendbars.txt
        echo "B ${CPTDIR}mby3_km.cpt 0.2i 0.1i+malu -Bxa2f1+l\"Elevation (km)\"" >> legendbars.txt
        barplotcount=$barplotcount+1
        ;;

  	esac
  done

  velboxflag=0
  [[ $barplotcount -eq 0 ]] && LEGEND_WIDTH=0
  LEG2_X=$(echo "$LEGENDX $LEGEND_WIDTH 0.1i" | awk '{print $1+$2+$3 }' )
  LEG2_Y=${MAP_PS_HEIGHT_IN}

  CENTERLON=$(echo "($MINLON + $MAXLON) / 2" | bc -l)
  CENTERLAT=$(echo "($MINLAT + $MAXLAT) / 2" | bc -l)

  # The non-colobar plots come next. pslegend can't handle a lot of things well,
  # and scaling is difficult. Instead we make small eps files and plot them,
  # keeping track of their size to allow relative positioning
  # Not sure how robust this is... but it works...

  # Velocities need to be scaled by gpsscalefactor to fit with the map

  # We will plot items vertically in increments of 3, and then add an X_INC and send Y to MAP_PS_HEIGHT_IN
  count=0
  # Keep track of the largest width we have used and make next column not overlap it.
  NEXTX=0
  GPS_ELLIPSE_TEXT=$(awk -v c=0.95 'BEGIN{print c*100 "%" }')

  for plot in ${plots[@]} ; do
  	case $plot in
      cmt)
        echo "$CENTERLON $CENTERLAT 15 322 39 -73 121 53 -104 1.12 25.000000 126.020000 13.120000 C021576A" | gmt psmeca -E"${CMT_NORMALCOLOR}" -L0.25p,black -Z$CPTDIR"neis2.cpt" -Sc"$CMTSCALE"i/0 $RJOK ${VERBOSE} >> mecaleg.ps
        echo "$CENTERLON $CENTERLAT N/6.0" | gmt pstext -F+f6p,Helvetica,black+jCB "${VERBOSE}" -J -R -Y0.1i -O -K >> mecaleg.ps
        echo "$CENTERLON $CENTERLAT 14 152 82 2 61 88 172 3.55 26.000000 125.780000 8.270000 B082783A" | gmt psmeca -E"${CMT_SSCOLOR}" -L0.25p,black -Z$CPTDIR"neis2.cpt" -Sc"$CMTSCALE"i/0 $RJOK -X0.35i -Y-0.1i ${VERBOSE} >> mecaleg.ps
        echo "$CENTERLON $CENTERLAT SS/7.0" | gmt pstext -F+f6p,Helvetica,black+jCB "${VERBOSE}" -J -R -Y0.1i -O -K >> mecaleg.ps
        echo "$CENTERLON $CENTERLAT 33 341 35 92 158 55 89 1.12 28.000000 123.750000 7.070000 M081676B" | gmt psmeca -E"${CMT_THRUSTCOLOR}" -L0.25p,black -Z$CPTDIR"neis2.cpt" -Sc"$CMTSCALE"i/0 -X0.35i -Y-0.1i -R -J -O -K ${VERBOSE} >> mecaleg.ps
        echo "$CENTERLON $CENTERLAT R/8.0" | gmt pstext -F+f6p,Helvetica,black+jCB "${VERBOSE}" -J -R -Y0.1i -O >> mecaleg.ps
        PS_DIM=$(gmt psconvert mecaleg.ps -Te -A0.05i 2> >(grep Width) | awk -F'[ []' '{print $10, $17}')
        PS_WIDTH_IN=$(echo $PS_DIM | awk '{print $1/2.54}')
        PS_HEIGHT_IN=$(echo $PS_DIM | awk '{print $2/2.54}')
        gmt psimage -Dx"${LEG2_X}i/${LEG2_Y}i"+w${PS_WIDTH_IN}i mecaleg.eps $RJOK ${VERBOSE} >> $LEGMAP
        LEG2_Y=$(echo "$LEG2_Y + $PS_HEIGHT_IN + 0.02" | bc -l)
        count=$count+1
        NEXTX=$(echo $PS_WIDTH_IN $NEXTX | awk '{if ($1>$2) { print $1 } else { print $2 } }')
        ;;

      grid)
        GRIDMAXVEL_INT=$(echo "scale=0;($GRIDMAXVEL+5)/1" | bc)
        V100=$(echo "$GRIDMAXVEL_INT" | bc -l)
        if [[ $PLATEVEC_COLOR =~ "white" ]]; then
          echo "$CENTERLON $CENTERLAT $GRIDMAXVEL_INT 0 0 0 0 0 ID" | gmt psvelo -W0p,gray@$PLATEVEC_TRANS -Ggray@$PLATEVEC_TRANS -A${ARROWFMT} -Se$VELSCALE/${GPS_ELLIPSE}/0 -L $RJOK "${VERBOSE}" >> velarrow.ps 2>/dev/null
        else
          echo "$CENTERLON $CENTERLAT $GRIDMAXVEL_INT 0 0 0 0 0 ID" | gmt psvelo -W0p,$PLATEVEC_COLOR@$PLATEVEC_TRANS -G$PLATEVEC_COLOR@$PLATEVEC_TRANS -A${ARROWFMT} -Se$VELSCALE/${GPS_ELLIPSE}/0 -L $RJOK "${VERBOSE}" >> velarrow.ps 2>/dev/null
        fi
        echo "$CENTERLON $CENTERLAT Plate velocity ($GRIDMAXVEL_INT mm/yr)" | gmt pstext -F+f6p,Helvetica,black+jLB "${VERBOSE}" -J -R -Y0.1i -O >> velarrow.ps
        PS_DIM=$(gmt psconvert velarrow.ps -Te -A0.05i 2> >(grep Width) | awk -F'[ []' '{print $10, $17}')
        PS_WIDTH_IN=$(echo $PS_DIM | awk '{print $1/2.54}')
        PS_HEIGHT_IN=$(echo $PS_DIM | awk '{print $2/2.54}')
        gmt psimage -Dx"${LEG2_X}i/${LEG2_Y}i"+w${PS_WIDTH_IN}i velarrow.eps $RJOK ${VERBOSE} >> $LEGMAP
        LEG2_Y=$(echo "$LEG2_Y + $PS_HEIGHT_IN + 0.02" | bc -l)
        count=$count+1
        NEXTX=$(echo $PS_WIDTH_IN $NEXTX | awk '{if ($1>$2) { print $1 } else { print $2 } }')
        ;;

      gps)

        GPSMAXVEL_INT=$(echo "scale=0;($GPSMAXVEL+5)/1" | bc)
        echo "$CENTERLON $CENTERLAT $GPSMAXVEL_INT 0 5 5 0 ID" | gmt psvelo -W${GPS_LINEWIDTH},${GPS_LINECOLOR} -G${GPS_FILLCOLOR} -A${ARROWFMT} -Se$VELSCALE/${GPS_ELLIPSE}/0 -L $RJOK "${VERBOSE}" >> velgps.ps 2>/dev/null
        GPSMESSAGE="GPS: $GPSMAXVEL_INT mm/yr (${GPS_ELLIPSE_TEXT})"
        echo "$CENTERLON $CENTERLAT $GPSMESSAGE" | gmt pstext -F+f6p,Helvetica,black+jLB -J -R -Y0.1i -O ${VERBOSE} >> velgps.ps
        PS_DIM=$(gmt psconvert velgps.ps -Te -A0.05i 2> >(grep Width) | awk -F'[ []' '{print $10, $17}')
        PS_WIDTH_IN=$(echo $PS_DIM | awk '{print $1/2.54}')
        PS_HEIGHT_IN=$(echo $PS_DIM | awk '{print $2/2.54}')
        gmt psimage -Dx"${LEG2_X}i/${LEG2_Y}i"+w${PS_WIDTH_IN}i velgps.eps $RJOK ${VERBOSE} >> $LEGMAP
        LEG2_Y=$(echo "$LEG2_Y + $PS_HEIGHT_IN + 0.02" | bc -l)
        count=$count+1
        NEXTX=$(echo $PS_WIDTH_IN $NEXTX | awk '{if ($1>$2) { print $1 } else { print $2 } }')
        ;;


    kinsv)
        echo "$CENTERLON $CENTERLAT" |  gmt psxy -Sc0.01i -W0p,white -Gwhite $RJOK "${VERBOSE}" >> kinsv.ps
        echo "$CENTERLON $CENTERLAT" |  gmt psxy -Ss0.4i -W0p,lightblue -Glightblue $RJOK -X0.6i "${VERBOSE}" >> kinsv.ps
        KINMESSAGE=" EQ kinematic vectors "
        echo "$CENTERLON $CENTERLAT $KINMESSAGE" | gmt pstext -F+f6p,Helvetica,black+jLB "${VERBOSE}" -J -R -Y0.2i -O -K >> kinsv.ps
        echo "$CENTERLON $CENTERLAT 31 .35" |  gmt psxy -SV0.05i+jb+e -W0.4p,${NP1_COLOR} -G${NP1_COLOR} $RJOK -Y-0.2i "${VERBOSE}" >> kinsv.ps

        if [[ $plottedkinsd -eq 1 ]]; then # Don't close
          echo "$CENTERLON $CENTERLAT 235 .35" | gmt psxy -SV0.05i+jb+e -W0.4p,${NP2_COLOR} -G${NP2_COLOR} $RJOK "${VERBOSE}" >> kinsv.ps
        else
          echo "$CENTERLON $CENTERLAT 235 .35" | gmt psxy -SV0.05i+jb+e -W0.4p,${NP2_COLOR} -G${NP2_COLOR} -R -J -O "${VERBOSE}" >> kinsv.ps
        fi
        if [[ $plottedkinsd -eq 1 ]]; then
          echo "$CENTERLON $CENTERLAT 55 .1" | gmt psxy -SV0.05i+jb -W0.5p,white -Gwhite $RJOK "${VERBOSE}" >> kinsv.ps
          echo "$CENTERLON $CENTERLAT 325 0.175" |  gmt psxy -SV0.05i+jb -W0.5p,white -Gwhite $RJOK "${VERBOSE}" >> kinsv.ps
          echo "$CENTERLON $CENTERLAT 211 .1" | gmt psxy -SV0.05i+jb -W0.5p,gray -Ggray $RJOK "${VERBOSE}" >> kinsv.ps
          echo "$CENTERLON $CENTERLAT 121 0.175" | gmt psxy -SV0.05i+jb -W0.5p,gray -Ggray -R -J -O "${VERBOSE}" >> kinsv.ps
        fi
        PS_DIM=$(gmt psconvert kinsv.ps -Te -A0.05i 2> >(grep Width) | awk -F'[ []' '{print $10, $17}')
        PS_WIDTH_IN=$(echo $PS_DIM | awk '{print $1/2.54}')
        PS_HEIGHT_IN=$(echo $PS_DIM | awk '{print $2/2.54}')
        gmt psimage -Dx"${LEG2_X}i/${LEG2_Y}i"+w${PS_WIDTH_IN}i kinsv.eps $RJOK ${VERBOSE} >> $LEGMAP
        LEG2_Y=$(echo "$LEG2_Y + $PS_HEIGHT_IN + 0.02" | bc -l)
        count=$count+1
        NEXTX=$(echo $PS_WIDTH_IN $NEXTX | awk '{if ($1>$2) { print $1 } else { print $2 } }')
       ;;

    kingeo)

        ;;

      plate)
        # echo "$CENTERLON $CENTERLAT 90 1" | gmt psxy -SV$ARROWFMT -W${GPS_LINEWIDTH},${GPS_LINECOLOR} -G${GPS_FILLCOLOR} $RJOK "${VERBOSE}" >> plate.ps
        # echo "$CENTERLON $CENTERLAT Kinematics stuff" | gmt pstext -F+f6p,Helvetica,black+jCB "${VERBOSE}" -J -R -X0.2i -Y0.1i -O >> plate.ps
        # PS_DIM=$(gmt psconvert plate.ps -Te -A0.05i 2> >(grep Width) | awk -F'[ []' '{print $10, $17}')
        # PS_WIDTH_IN=$(echo $PS_DIM | awk '{print $1/2.54}')
        # PS_HEIGHT_IN=$(echo $PS_DIM | awk '{print $2/2.54}')
        # gmt psimage -Dx"${LEG2_X}i/${LEG2_Y}i"+w${PS_WIDTH_IN}i plate.ps $RJOK >> $LEGMAP
        # LEG2_Y=$(echo "$LEG2_Y + $PS_HEIGHT_IN + 0.02" | bc -l)
        # count=$count+1
        # NEXTX=$(echo $PS_WIDTH_IN $NEXTX | awk '{if ($1>$2) { print $1 } else { print $2 } }')
        ;;

      srcmod)
  			# echo 0 0.1 "Slip magnitudes from: $SRCMODFSPLOCATIONS"  | gmt pstext "${VERBOSE}" -F+f8,Helvetica,black+jBL -Y$YADD $RJOK >> maplegend.ps
        # YADD=0.2
  			;;

      tdefnode)
        velboxflag=1
        # echo 0 0.1 "TDEFNODE: $TDPATH"  | gmt pstext "${VERBOSE}" -F+f8,Helvetica,black+jBL -Y$YADD  $RJOK >> maplegend.ps
        # YADD=0.15
        ;;
    esac
    if [[ $count -eq 3 ]]; then
      count=0
      LEG2_X=$(echo "$LEG2_X + $NEXTX" | bc -l)
      echo "Updated LEG2_X to $LEG2_X"
      LEG2_Y=${MAP_PS_HEIGHT_IN}
    fi
  done


  # gmt pstext tectoplot.shortplot -F+f6p,Helvetica,black $KEEPOPEN $VERBOSE >> map.ps
  # x y fontinfo angle justify linespace parwidth parjust
  echo "> 0 0 9p Helvetica,black 0 l 0.1i ${INCH}i l" > datasourceslegend.txt
  uniq $THISDIR/tectoplot.shortsources | awk 'BEGIN {printf "T Data sources: "} {print}'  | tr '\n' ' ' >> datasourceslegend.txt

  # gmt gmtset FONT_ANNOT_PRIMARY 8p,Helvetica-bold,black
  MAP_PS_HEIGHT_IN_minus=$(echo "$MAP_PS_HEIGHT_IN-11/72" | bc -l )
  gmt pslegend datasourceslegend.txt -Dx0.0i/${MAP_PS_HEIGHT_IN_minus}i+w${LEGEND_WIDTH}+w${INCH}i+jBL -C0.05i/0.05i -J -R -O -K ${VERBOSE} >> $LEGMAP
  gmt pslegend legendbars.txt -Dx0i/${MAP_PS_HEIGHT_IN}i+w${LEGEND_WIDTH}+jBL -C0.05i/0.05i -J -R -O $KEEPOPEN ${VERBOSE} >> $LEGMAP



  # If we are closing the separate legend file, PDF it
  if [[ $keepopenflag -eq 0 && $legendovermapflag -eq 0 ]]; then
    gmt psconvert -Tf -A0.5i  maplegend.ps
    mv maplegend.pdf $THISDIR"/"$MAPOUTLEGEND
    info_msg "Map legend is at $THISDIR/$MAPOUTLEGEND"
    [[ $openflag -eq 1 ]] && open -a $OPENPROGRAM $THISDIR"/"$MAPOUTLEGEND
  fi

fi  # [[ $makelegendflag -eq 1 ]]



# Export TECTOPLOT call and GMT command history from PS file to .history file

echo "${COMMAND}" > "$MAPOUT.history"
echo "${COMMAND}" >> $TECTOPLOTDIR"tectoplot.history"

grep "GMT:" map.ps | sed -e 's/%@GMT: //' >> "$MAPOUT.history"

# Requires gs 9.26 and not later as they nuked transparency in later versions
if [[ $keepopenflag -eq 0 ]]; then
   gmt psconvert -Tf -A0.5i "${VERBOSE}" map.ps
   mv map.pdf $THISDIR"/"$MAPOUT
   mv "$MAPOUT.history" $THISDIR"/"$MAPOUT".history"
   info_msg "Map is at $THISDIR/$MAPOUT"
   [[ $openflag -eq 1 ]] && open -a $OPENPROGRAM $THISDIR"/"$MAPOUT
fi

exit 0