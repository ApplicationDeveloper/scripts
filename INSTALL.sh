#!/usr/bin/env bash
#TODO:
#   * Quiet execution,
#   * Invalid input prevention / fallback loop

PHP_VERSION="php7.3"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

processes=(
    "update_aptitude"
    "download_prerequisites"
#    "add_php_gpg_key_file"
#    "add_php_package_source"
    "download_php"
    "download_php_modules"
    "download_composer"
    "download_nginx"
    "download_mariadb_server"
    "setup_mariadb_server"
    "download_env_file"
    "setup_system_config"
    "setup_nginx"
    "modify_folder_ownerships"
    "modify_folder_permissions"
#    "download_vendor_packages"
    "end_script"
)

lookup_in_processes () {
    arg=$1

    if [[ ! $arg =~ ^--.* ]]; then
        return 1
    fi

    arg=`echo $arg | sed 's/--\(.*\)/\1/'`
    arg=`echo $arg | sed 's/-/_/g'`
    
    for process in ${processes[*]}
    do
        if [[ $arg == $process ]]; then
            return
        fi
    done

    return 1
}

execute_processes () {
    if [[ $# -gt 0 ]]; then
        if [[ $1 == "--help" ]]; then
            print_usage
            exit
        fi

        for argument in $@
        do
            lookup_in_processes $argument
            RESULT=$?

            if [[ $RESULT -ne 0 ]]; then
                echo "$argument is an invalid option"
                print_usage

                exit 1
            fi

            $process
        done
    else
        for process in ${processes[*]}
        do
            $process
            RESULT=$?

            if [[ $RESULT -ne 0 ]]; then
                exit 1
            fi
        done
    fi
}

print_usage () {
    echo "Usage:
        sudo ./INSTALL.sh [options | command]
        (e.g) sudo ./INSTALL --update-aptitude
        Options: \
         --help Show help
        Description: <> "
}

# if [[ $1 = "--help" ]]
# then
    # printf $usage
# elif [[ $# -gt 0 ]]
# then
    # echo "invalid options: $@"
    # printf $usage
# fi

install_package () {
    apt -y -qq  install $@
}

download_prerequisites () {
    echo "Downloading prerequisites..."
    install_package ca-certificates apt-transport-https zip unzip
}

# In Debian 10 (Buster), PHP is already updated
# add_php_gpg_key_file () {
#     echo  "Adding php gpg key file..."
#     wget -q https://packages.sury.org/php/apt.gpg -O- | apt-key add -
# }
#
# add_php_package_source () {
#     echo "Adding php package source..."
#     echo "deb https://packages.sury.org/php/ stretch main" | tee /etc/apt/sources.list.d/php.list
# }

update_aptitude () {
    apt update
}

download_php () {
    echo "Downloading PHP..."
    install_package $PHP_VERSION
}

download_php_modules () {
    echo "Downloading PHP Modules..."
    # Based on https://laravel.com/docs/6.0/installation
    install_package \
        $PHP_VERSION-mbstring \
        $PHP_VERSION-curl \
        $PHP_VERSION-dom \
        $PHP_VERSION-mysql \
        $PHP_VERSION-fpm \
        $PHP_VERSION-json \
        $PHP_VERSION-xml \
        $PHP_VERSION-bcmath \
        $PHP_VERSION-sqlite3
}

download_composer () {
    echo "Downloading composer..."
    EXPECTED_SIGNATURE="$(wget -q -O - https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
        >&2 echo 'ERROR: Invalid installer signature'
        rm composer-setup.php
        return 1
    fi

    php composer-setup.php --quiet
    #RESULT=$?
    rm composer-setup.php
    #exit $RESULT
}

download_nginx () {
    echo "Downloading nginx..."
    install_package nginx
}

download_mariadb_server () {
    echo "Downloading MariaDB server..."
    install_package mariadb-server
}

setup_mariadb_server () {
    echo "Setting up SQL server..."
    read -r -p "Would you like to change root password of MariaDB? (y/N): " response

    if [[ "$response" =~ ^([yY]) ]]
    then
        mysql_secure_installation
    fi
}

download_env_file () {
    if [[ ! -f ".env" ]]; then
        echo "Downloading env file ..."
        wget https://raw.githubusercontent.com/laravel/laravel/master/.env.example -O .env
    fi
}

setup_system_config () {
    read -r -p "Would you like to skip system environment configuration: (y/N): " response

    if [[ "$response" =~ ^([yY]) ]]
    then
        return 0
    fi

    read -r -p "School name: " school_name
    read -r -p "Database: " db
    read -r -p "DB user: " db_user
    read -r -p "DB password: " db_pass

    sed -i "s/\(APP_NAME=\).*/\1\"$school_name\"/" .env
    sed -i "s/\(DB_DATABASE=\).*/\1$db/" .env
    sed -i "s/\(DB_USERNAME=\).*/\1$db_user/" .env
    sed -i "s/\(DB_PASSWORD=\).*/\1$db_pass/" .env
}

setup_nginx () {
    read -r -p "Domain name: (e.g school.edu): " domain_name

    while : ; do
        read -r -p "Port: (default: 80): " port

        port=${port:=80}

        occurrence=`grep -o "listen $port" /etc/nginx/sites-enabled/* --exclude=$domain_name | wc -l`

        if [[ "$occurrence" -eq 0 ]]; then
            break
        fi

        echo "Port '$port' is already used"
    done

    working_directory=`pwd`
    site_directory=/etc/nginx/sites-available/$domain_name

echo "server {
    listen $port default_server;
    listen [::]:$port default_server;

    server_name _;

    root $working_directory/public;

    add_header X-Frame-Options \"SAMEORIGIN\";
    add_header X-XSS-Protection \"1; mode-block\";
    add_header X-Content-Type-Options \"nosniff\";

    index index.php index.html;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \\.php$ {
        fastcgi_pass unix:/var/run/php/$PHP_VERSION-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\\.(?!well-known).* {
        deny all;
    }
} " > $site_directory

    rm /etc/nginx/sites-enabled/default
    ln -s $site_directory /etc/nginx/sites-enabled/

    service nginx restart
}

modify_folder_ownerships () {
    echo "Modifying folder ownerships..."
    chown -R $SUDO_USER:www-data storage/
    chown -R $SUDO_USER:www-data bootstrap/cache
}

modify_folder_permissions () {
    echo "Modifying folder permissions..."
    chmod -R 775 storage
    chmod -R 775 bootstrap/cache
}

# download_vendor_packages () {
#     echo "Downloading vendor packages..."
#     php composer.phar update
# }

end_script () {
    echo "Generating new application key..."
    php artisan key:generate

    read -r -p "Do you want to launch the app now? (y/N) " response

    if [[ $response =~ ^([yY]) ]]
    then
        firefox "http://localhost"
    fi
    echo "Script finished."
}

execute_processes "$@"
