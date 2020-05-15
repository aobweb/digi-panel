#!/usr/bin/env bash

echo "Checking if environment exists..."
if ! docker ps -a | grep -i "digi-panel-.*"; then
    echo "No digi panel containers found. Exiting..."
    exit
fi

echo "Stopping and removing containers..."
if docker container stop digi-panel-app digi-panel-web digi-panel-db >/dev/null &&
   docker container rm digi-panel-app digi-panel-web digi-panel-db >/dev/null; then
    echo "Validating operation success..."
    if ! docker ps -a | grep "digi-panel-.*" >/dev/null; then
        echo "Containers successfully removed"
    fi
else
    echo "Could not remove digi panel containers..."
    exit;
fi

if docker volume ls | grep -i "digi-panel.*" >/dev/null; then
    echo "Would you also like to remove the database volume?"
    read -rp "[y/n] " input

    if echo "$input" | grep -i ".*y.*" >/dev/null; then
        echo "Removing database volume..."
        if docker volume rm digi-panel_dbdata; then
            echo "Volume successfully removed"
        else
            echo "Could not remove volume..."
            exit
        fi
    fi
fi

echo "Operations complete"
