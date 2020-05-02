#!/usr/bin/env bash

function checkAndSetPorts () {
    local name=$1
    local port=$2

    echo "Checking for free $name port..."
    while :; do
        if ! ss -tlwn | grep ":$port" >/dev/null; then
            echo "$name $port is free"
            printf -v "${name}" "%s" "$port" # Sets the value of variable with the same name as the value of $name to the free port
            echo "Using $port as $name port"
            break
        else
            port=$((port + 1))
        fi
    done
}

echo "Beginning local environment setup..."
echo "Searching for free ports for the docker services"

httpPort=80
httpsPort=443
dbPort=3306
requiredPorts=("httpPort" "httpsPort" "dbPort")

for port in "${requiredPorts[@]}"; do
    checkAndSetPorts "$port" "${!port}"
done

echo "Setting up docker-compose file..."
rsync ./docker-compose.yml-EXAMPLE ./docker-compose.yml

echo "Setting actual ports"
placeholderValues=([$httpPort]="{{WEB_PRIMARY_PORT}}" [$httpsPort]="{{WEB_SECONDARY_PORT}}" [$dbPort]="{{DB_PORT}}")

for index in "${!placeholderValues[@]}"; do
    echo "Setting ${placeholderValues[index]} to $index"
    sed -i "s/${placeholderValues[index]}/$index/g" docker-compose.yml
done
