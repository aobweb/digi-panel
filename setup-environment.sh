#!/usr/bin/env bash

function checkAndSetPorts() {
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

function setupDockerConfigs() {
    if ! [[ -f "./docker-service-configs/mariadb/my.cnf" ]]; then
        echo "Setting up MariaDB config..."
        if rsync ./docker-service-configs/mariadb/my.cnf-EXAMPLE ./docker-service-configs/mariadb/my.cnf; then
            echo "MariaDB config successfully created..."
        else
            echo "Could not create MariaDB config..."
            exit
        fi
    else
        echo "MariaDB config already exists..."
    fi

    if ! [[ -f "./docker-service-configs/nginx/conf.d/app.conf" ]]; then
        echo "Setting up Nginx config..."
        if rsync ./docker-service-configs/nginx/conf.d/app.conf-EXAMPLE ./docker-service-configs/nginx/conf.d/app.conf; then
            primaryPortResult=$(sed -i "s/{{WEB_PRIMARY_PORT}}/$httpPort/g" ./docker-service-configs/nginx/conf.d/app.conf)
            secondaryPortResult=$(sed -i "s/{{WEB_SECONDARY_PORT}}/$httpsPort/g" ./docker-service-configs/nginx/conf.d/app.conf)
            if [[ $primaryPortResult -gt 0 || $secondaryPortResult -gt 0 ]]; then
                echo "Could not setup placeholder values for Nginx config..."
                exit
            fi

            echo "Nginx config successfully created..."
        else
            echo "Could not create Nginx config..."
            exit
        fi
    else
        echo "Nginx config already exists..."
    fi

    echo "Docker configs setup complete"
}

function checkDbConnection() {
    local counter=1
    local username=$1
    local password=$2

    echo "Trying connection to a max of 20 tries"
    while [ "$counter" -lt "21" ]; do
        echo "Attempt $counter"

        if docker exec digi-panel-db mysql -u "$username" -p"$password" -e "SHOW DATABASES;" | grep -q 'digi-panel'; then
            echo "digi-panel database exists"
            echo "Validating connection to digi-panel"

            if docker exec digi-panel-db mysql -u "$username" -p"$password" -e "SHOW TABLES FROM \`digi-panel\`;"; then
                break
            else
                echo "Could not connect to the digi-panel database..."
                exit
            fi
        fi

        echo "Could not connect. Retrying..."
        counter=$((counter + 1))
        sleep 1
    done

    if [ "$counter" -ge "20" ]; then
        echo "Could not connect to MariaDB..."
        exit
    fi

    echo "Connection successful"
}

function setupEnvFile() {
    local -A params=(
        ["{{APP_NAME}}"]="\"Digi Panel\""
        ["{{WEB_PRIMARY_PORT}}"]=$httpPort
        ["{{DB_HOST}}"]="digi-panel-db"
        ["{{DB_PORT}}"]=$dbPort
        ["{{DB_USERNAME}}"]=$1
        ["{{DB_PASSWORD}}"]=$dbPassword
    )

    echo "Copying .env file..."
    rsync ./.env.example ./.env

    echo "Setting up placeholder parameters..."
    for index in "${!params[@]}"; do
        echo "Setting $index to ${params[$index]}"
        sed -i "s/$index/${params[$index]}/g" .env
    done

    echo "File setup complete"
}

echo "Beginning local environment setup..."
if docker ps -a | grep "digi-panel-.*"; then
    echo "Service containers are already running. You need to stop the service if you want to restart it. You can do so with the remove-environment.sh script"
    exit
else
    echo "Searching for free ports for the docker services"

    httpPort=80
    httpsPort=443
    dbPort=3306
    requiredPorts=("httpPort" "httpsPort" "dbPort")

    for port in "${requiredPorts[@]}"; do
        checkAndSetPorts "$port" "${!port}"
    done
fi

# Setup docker service configs
setupDockerConfigs

# Setup docker compose file
if [[ -f "./docker-compose.yml" ]]; then
    echo "Docker compose file found. Skipping generation..."
    echo "Getting MariaDB root password from compose file..."
    rootPassword=$(awk '/MYSQL_ROOT_PASSWORD:/ {print $2}' docker-compose.yml)
    # TODO check if root password is missing from docker-compose.yml and ask user to input new password to set in compose file
else
    echo "Setting up docker-compose file..."
    rsync ./docker-compose.yml-EXAMPLE ./docker-compose.yml

    echo "Setting up ports"
    placeholderValues=([$httpPort]="{{WEB_PRIMARY_PORT}}" [$httpsPort]="{{WEB_SECONDARY_PORT}}" [$dbPort]="{{DB_PORT}}")

    for index in "${!placeholderValues[@]}"; do
        echo "Setting ${placeholderValues[index]} to $index"
        sed -i "s/${placeholderValues[index]}/$index/g" docker-compose.yml
    done

    echo "Please set the root password for MariaDB..."
    echo "[Press enter to leave blank]"
    echo
    read -rsp "Password: " rootPassword
    sed -i "s/{{DB_ROOT_PASSWORD}}/$rootPassword/g" docker-compose.yml
    echo
    echo "Password set successfully"
fi

echo "Running docker-compose up..."
docker-compose up -d

if docker ps | grep -E "digi-panel-app|digi-panel-web|digi-panel-db"; then
    echo "Docker services setup successfully"
else
    echo "Failed to install docker services!"
    exit
fi

echo "Installing dependencies with composer install..."
if [[ -d "./vendor/" ]]; then
    echo "Vendor folder already exists. Skipping..."
else
    echo "Vendor folder not found. Executing composer install..."
    docker-compose exec --user www digi-panel-app /usr/local/bin/composer install
    if [[ -d "./vendor/" ]]; then
        echo "Dependencies successfully installed"
    else
        echo "Failed to install dependencies!"
        exit
    fi
fi

echo "Checking database is successfully created..."
checkDbConnection "root" "$rootPassword"

# Application db user is always dropped and recreated to simplify setup
dbUser="digiuser"
echo "Dropping application DB user..."
if ! docker exec digi-panel-db mysql -u root -p"$rootPassword" -e "DROP USER IF EXISTS '$dbUser'@'%';"; then
    echo "Could not drop application DB user..."
    exit
fi
echo "Creating new database user for the application..."
echo "Please set a password for the user"
echo "[Press enter to leave blank]"
echo
read -rsp "Password: " dbPassword
docker exec digi-panel-db mysql -u root -p"$rootPassword" -e "GRANT ALL ON \`digi-panel\`.* TO '$dbUser'@'%' IDENTIFIED BY '$dbPassword';"
docker exec digi-panel-db mysql -u root -p"$rootPassword" -e "FLUSH PRIVILEGES;"
echo

# Setup laravel env config
if [[ -f "./.env" ]]; then
    echo "Laravel env config file found. Skipping generation and updating user password and db ports..."
    oldHttpPort=$(awk -F ':' '/APP_URL/ {print $3}' .env)
    oldDbPort=$(awk -F '=' '/DB_PORT=/ {print $2}' .env)
    oldDbPassword=$(awk -F '=' '/DB_PASSWORD=/ {print $2}' .env)

    sed -i "s/$oldHttpPort/$httpPort/g" .env
    sed -i "s/$oldDbPort/$dbPort/g" .env
    sed -i "s/$oldDbPassword/$dbPassword/g" .env
else
    echo "Setting up .env file"
    setupEnvFile $dbUser

    echo "Executing finishing touches..."
    echo "Generating laravel key..."
    docker exec digi-panel-app php artisan key:generate
    echo "Running laravel migrate..."
    docker exec digi-panel-app php artisan migrate
fi

echo "Verifying database connection with new user..."
checkDbConnection $dbUser "$dbPassword"

echo "Validating application db connection"
if echo "DB::connection()->getPdo();" | docker-compose exec -T digi-panel-app php artisan tinker; then # Disable TTY allocation otherwise error is thrown
    echo "Laravel DB connection successful"
else
    echo "Could not establish connection"
    exit
fi

echo "Local environment setup complete"
