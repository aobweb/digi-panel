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

function checkDbConnection() {
    local counter=1
    local username=$1
    local password=$2

    echo "Trying connection to a max of 20 tries"
    while [ "$counter" -lt "21" ]; do
        echo "Attempt $counter"

        if docker-compose exec digi-panel-db mysql -u "$username" -p"$password" -e "SHOW DATABASES;" | grep -q 'digi-panel'; then
            echo "digi-panel database exists"
            echo "Validating connection to digi-panel"

            if docker-compose exec digi-panel-db mysql -u "$username" -p"$password" -e "SHOW TABLES FROM \`digi-panel\`;"; then
                break
            else
                echo "Could not connect to the digi-panel database..."
                exit
            fi
        fi

        echo "Could not connect. Retrying..."
        counter=$((counter + 1))
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

echo "Running docker-compose up..."
echo
echo
docker-compose up -d

if docker ps | grep -E "digi-panel-app|digi-panel-web|digi-panel-db"; then
    echo "Docker services setup successfully"
else
    echo "Failed to install docker services!"
    exit
fi

echo "Installing dependencies with composer install..."
if [ -d "./vendor/" ]; then
    echo "Vendor folder already exists. Skipping..."
else
    echo "Vendor folder not found. Executing composer install..."
    docker-compose exec --user www digi-panel-app /usr/local/bin/composer install
    if [ -d "./vendor/" ]; then
        echo "Dependencies successfully installed"
    else
        echo "Failed to install dependencies!"
        exit
    fi
fi

echo "Checking database is successfully created..."
checkDbConnection "root" "$rootPassword"

echo "Creating separate database user for the application..."
echo "Please set a password for the user"
echo "[Press enter to leave blank]"
echo
read -rsp "Password: " dbPassword
docker-compose exec digi-panel-db mysql -u root -p"$rootPassword" -e "GRANT ALL ON \`digi-panel\`.* TO 'digiuser'@'%' IDENTIFIED BY '$dbPassword';"
docker-compose exec digi-panel-db mysql -u root -p"$rootPassword" -e "FLUSH PRIVILEGES;"
echo
echo "Verifying database connection with new user..."
checkDbConnection "digiuser" "$dbPassword"

echo "Setting up .env file"
setupEnvFile "digiuser"

echo "Executing finishing touches..."
echo "Generating laravel key..."
docker-compose exec digi-panel-app php artisan key:generate
echo "Running laravel migrate..."
docker-compose exec digi-panel-app php artisan migrate
echo "Validating application db connection"
if echo "DB::connection()->getPdo();" | docker-compose exec -T digi-panel-app php artisan tinker; then # Disable TTY allocation otherwise error is thrown
    echo "Laravel DB connection successful"
else
    echo "Could not establish connection"
    exit
fi

echo "Local environment setup complete"
