#!/bin/bash

# exit when any command fails
set -e

WIDTH=1920
HEIGHT=1080

LOG_FILE=./perf/draw3d/perf_${DEVICE_FAMILY}_${WIDTH}_${HEIGHT}.log

declare -a traces=(vase filmtv skybox coverflow evilskull polybump tekkaman carnival)

# draw3d benchmarks
draw3d(){
    echo > $LOG_FILE # clear log
    for trace in "${traces[@]}"
    do
        echo -e "\n**************************************\n" >> $LOG_FILE
        echo -e "draw3d $trace benchmark\n" >> $LOG_FILE
        CONFIGS="-DEXT_GFX_ENABLE" ./ci/blackbox.sh --driver=fpga --app=draw3d --args="-t$trace.cgltrace -w${WIDTH} -h${HEIGHT}" | grep 'Total elapsed time:' >> $LOG_FILE
    done
    echo "draw3d tests done!"
}

usage()
{
    echo "usage: [-a|--all] [-h|--help]"
}

case $1 in
    -a | --all )
        ALL=true
        draw3d
        ;;
    -h | --help )
        usage
        ;;
    -* | --* )
        echo "invalid option"
        usage
        ;;
    * )
        ALL=false
        draw3d
        ;;             
esac