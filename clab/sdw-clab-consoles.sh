#!/bin/bash

# List of container names
container_names=('clab-sdedge-nfv-internet-s1' 'clab-sdedge-nfv-internet-isp1' 'clab-sdedge-nfv-internet-isp2')

DOCKERCMD="docker exec -it"

allcontainers=${container_names[*]}
USAGE="
Usage:
  ./sdw-clab-consoles.sh <cmd>
    to open|close all consoles
    Valid values:
      <cmd>: open|close

  ./sdw-clab-consoles.sh <cmd> <container-name>
    to open|close the console of a specific container
    Valid values:
        <cmd>: open|close
        <container-name>: $allcontainers
"

function container_console {

    cmd=$1
    container_name=$2
    
    if [ "$cmd" == 'open' ]; then
        echo "--"
        echo "-- Starting console of container $container_name"
        if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            container_hostname="$(docker exec $container_name hostname)"
            # Start console
            if [[ $container_name == *"isp"* ]]; then
                xfce4-terminal --title="$container_hostname" --hide-menubar -x $DOCKERCMD $container_name sr_cli >/dev/null 2>&1 &
            else
                xfce4-terminal --title="$container_hostname" --hide-menubar -x $DOCKERCMD $container_name /bin/bash >/dev/null 2>&1 &
            fi
        else
            echo "-- WARNING: container '${container_name}' not started"
        fi

    elif [ "$cmd" == 'close' ]; then
        echo "--"
        echo "-- Closing console of container $container_name"
        if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            container_hostname="$(docker exec $container_name hostname)"
            while wmctrl -c $container_hostname; do sleep 0.5; done
        else
            echo "-- WARNING: container '${container_name}' not started"
        fi
    fi
}

#
# Main
#
if [ "$1" == 'open' ] || [ "$1" == 'close' ] ; then
    cmd=$1
else
    echo ""
    echo "ERROR: unknown command '$1'"
    echo "$USAGE"
    exit 1
fi

if [ ! "$1" ] ; then
    echo ""
    echo "$USAGE"
    exit 1
fi

if [ "$2" ]; then
    if [[ ! " ${container_names[@]} " =~ " $2 " ]]; then
        echo ""
        echo "ERROR: unknown container '$2'"
        echo "$USAGE"
        exit 1
    fi
    containername=$2
    container_console $cmd $containername
else

    for j in ${!container_names[*]}; do 
        container_console $cmd ${container_names[$j]}
    done
fi