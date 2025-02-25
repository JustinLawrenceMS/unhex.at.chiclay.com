#!/bin/bash

set -e  # Exit script on error

LOG_FILE="/var/www/html/install.log"
echo "Starting Magento post-installation script..." | tee -a "$LOG_FILE"

# Ensure PHP errors configuration directory exists.
if [ ! -d /usr/local/etc/php/conf.d ]; then
    mkdir -p /usr/local/etc/php/conf.d
fi

# Create the errors.ini file if it doesn't exist.
if [ ! -f /usr/local/etc/php/conf.d/errors.ini ]; then
    touch /usr/local/etc/php/conf.d/errors.ini
fi

# Enable PHP error reporting for debugging
echo "Enabling PHP error reporting..." | tee -a "$LOG_FILE"
echo "display_errors = On" >> /usr/local/etc/php/conf.d/errors.ini
echo "display_startup_errors = On" >> /usr/local/etc/php/conf.d/errors.ini
echo "error_reporting = E_ALL" >> /usr/local/etc/php/conf.d/errors.ini

# In your entrypoint script
echo "memory_limit = ${PHP_MEMORY_LIMIT}" > /usr/local/etc/php/conf.d/docker-php-memlimit.ini

# Load environment variables from .env
if [ -f /var/www/html/.env ]; then
    set -o allexport
    source /var/www/html/.env
    set +o allexport
    echo ".env file loaded successfully." | tee -a "$LOG_FILE"
else
    echo "ERROR: .env file not found!" | tee -a "$LOG_FILE"
    exit 1
fi

# Wait for MySQL
echo "Waiting for MySQL..." | tee -a "$LOG_FILE"
until mysqladmin ping -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" --silent; do
    echo "MySQL not ready yet, waiting..." | tee -a "$LOG_FILE"
    sleep 2
done
echo "MySQL is up!" | tee -a "$LOG_FILE"
sleep 5  # Extra delay to ensure MySQL is fully ready

# Wait for Elasticsearch
echo "Waiting for Elasticsearch..." | tee -a "$LOG_FILE"
for i in {1..30}; do
    if curl -s "http://${ELASTICSEARCH_HOST}:9200" > /dev/null; then
        echo "Elasticsearch is up!" | tee -a "$LOG_FILE"
        break
    fi
    echo "Elasticsearch not ready yet, waiting..." | tee -a "$LOG_FILE"
    sleep 2
done
if ! curl -s "http://${ELASTICSEARCH_HOST}:9200" > /dev/null; then
    echo "WARNING: Elasticsearch failed to start after 60 seconds, proceeding with skip validation..." | tee -a "$LOG_FILE"
fi

# Set working directory
cd /var/www/html

# Ensure Magento CLI is executable
if [ ! -x "bin/magento" ]; then
    echo "Making bin/magento executable..." | tee -a "$LOG_FILE"
    chmod 755 bin/magento
fi

# Install Composer dependencies
echo "Installing Composer dependencies..." | tee -a "$LOG_FILE"
if [ ! -f "vendor/autoload.php" ]; then
    composer install --no-interaction --prefer-dist --verbose 2>&1 | tee -a "$LOG_FILE" || {
        echo "ERROR: Composer install failed!" | tee -a "$LOG_FILE"
        exit 1
    }
fi

# Reset and initialize database
echo "Resetting Magento database..." | tee -a "$LOG_FILE"
mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -e "DROP DATABASE IF EXISTS ${DB_NAME}; CREATE DATABASE ${DB_NAME};" || {
    echo "ERROR: Failed to reset database!" | tee -a "$LOG_FILE"
    exit 1
}

# Verify Elasticsearch before install (for debugging)
echo "Verifying Elasticsearch connection before setup:install..." | tee -a "$LOG_FILE"
curl -s "http://${ELASTICSEARCH_HOST}:9200" || {
    echo "WARNING: Cannot reach Elasticsearch at ${ELASTICSEARCH_HOST}:9200, proceeding with skip validation..." | tee -a "$LOG_FILE"
}
echo "Elasticsearch cluster info:" | tee -a "$LOG_FILE"
curl -s "http://${ELASTICSEARCH_HOST}:9200/_cluster/health" | tee -a "$LOG_FILE"

# Run Magento setup:install with skip validation
echo "Running Magento setup:install..." | tee -a "$LOG_FILE"
php bin/magento setup:install \
    --base-url="${MAGENTO_BASE_URL}" \
    --db-host="${DB_HOST}" \
    --db-name="${DB_NAME}" \
    --db-user="${DB_USER}" \
    --db-password="${DB_PASSWORD}" \
    --admin-firstname="${ADMIN_FIRSTNAME}" \
    --admin-lastname="${ADMIN_LASTNAME}" \
    --admin-email="${ADMIN_EMAIL}" \
    --admin-user="${ADMIN_USER}" \
    --admin-password="${ADMIN_PASSWORD}" \
    --language="en_US" \
    --currency="USD" \
    --timezone="America/Chicago" \
    --use-rewrites=1 \
    --search-engine=elasticsearch8 \
    --elasticsearch-host="${ELASTICSEARCH_HOST}" \
    --elasticsearch-port=9200 \
    --key="${CRYPT_KEY}" \
    --verbose 2>&1 | tee -a "$LOG_FILE" || {
    echo "ERROR: setup:install failed!" | tee -a "$LOG_FILE"
    exit 1
}

# Verify env.php and config.php
echo "Verifying env.php and config.php..." | tee -a "$LOG_FILE"
ls -l app/etc/env.php app/etc/config.php || {
    echo "ERROR: env.php or config.php not created properly!" | tee -a "$LOG_FILE"
    exit 1
}

# Test database connection and schema
echo "Testing database connection and schema..." | tee -a "$LOG_FILE"
mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SHOW TABLES FROM ${DB_NAME};" || {
    echo "ERROR: Cannot connect to database!" | tee -a "$LOG_FILE"
    exit 1
}
TABLE_COUNT=$(mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SHOW TABLES FROM ${DB_NAME};" | wc -l)
if [ "$TABLE_COUNT" -lt 10 ]; then
    echo "ERROR: Database schema incomplete (only $TABLE_COUNT tables found), exiting..." | tee -a "$LOG_FILE"
    exit 1
fi

# Verify required tables exist (theme, flag, main_table)
echo "Verifying critical Magento tables..." | tee -a "$LOG_FILE"
REQUIRED_TABLES=("theme" "flag" "main_table")
MISSING_TABLE=0
for table in "${REQUIRED_TABLES[@]}"; do
    EXISTS=$(mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -N -e "SHOW TABLES LIKE '$table'" ${DB_NAME})
    if [ -z "$EXISTS" ]; then
        echo "WARNING: Required table '$table' not found." | tee -a "$LOG_FILE"
        MISSING_TABLE=1
    fi
done

if [ "$MISSING_TABLE" -eq 1 ]; then
    echo "Critical tables missing; saving configuration files and forcing a full Magento reinstall..." | tee -a "$LOG_FILE"
    # Save current config files as backups
    if [ -f "app/etc/env.php" ]; then
        mv app/etc/env.php app/etc/env.php.sav
        echo "Backed up app/etc/env.php to app/etc/env.php.sav" | tee -a "$LOG_FILE"
    fi
    if [ -f "app/etc/config.php" ]; then
        cp app/etc/config.php app/etc/config.php.sav
        echo "Backed up app/etc/config.php to app/etc/config.php.sav" | tee -a "$LOG_FILE"
    fi

    # Drop the entire database schema and run install again.
    mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_PASSWORD}" -e "DROP DATABASE ${DB_NAME}; CREATE DATABASE ${DB_NAME};" || {
        echo "ERROR: Unable to recreate database ${DB_NAME}!" | tee -a "$LOG_FILE"
        exit 1
    }
    php bin/magento setup:install \
        --base-url="${MAGENTO_BASE_URL}" \
        --db-host="${DB_HOST}" \
        --db-name="${DB_NAME}" \
        --db-user="${DB_USER}" \
        --db-password="${DB_PASSWORD}" \
        --admin-firstname="${ADMIN_FIRSTNAME}" \
        --admin-lastname="${ADMIN_LASTNAME}" \
        --admin-email="${ADMIN_EMAIL}" \
        --admin-user="${ADMIN_USER}" \
        --admin-password="${ADMIN_PASSWORD}" \
        --language="en_US" \
        --currency="USD" \
        --timezone="America/Chicago" \
        --use-rewrites=1 \
        --search-engine=elasticsearch8 \
        --elasticsearch-host="${ELASTICSEARCH_HOST}" \
        --elasticsearch-port=9200 \
        --key="${CRYPT_KEY}" \
        --verbose 2>&1 | tee -a "$LOG_FILE" || {
            echo "ERROR: setup:install failed on re-run!" | tee -a "$LOG_FILE"
            exit 1
    }
fi

# Set runtime permissions for Magento directories
echo "Setting runtime file permissions..." | tee -a "$LOG_FILE"
chmod 775 var pub/static pub/media generated 2>/dev/null || {
    echo "WARNING: Could not set permissions on Magento directories, proceeding anyway..." | tee -a "$LOG_FILE"
}
find var pub/static pub/media generated -type d -exec chmod 775 {} \; 2>/dev/null || true
find var pub/static pub/media generated -type f -exec chmod 664 {} \; 2>/dev/null || true
chown -R www-data:www-data . 2>/dev/null || {
    echo "WARNING: Could not chown files, proceeding anyway..." | tee -a "$LOG_FILE"
}

# Setup store early
echo "Setting up store..." | tee -a "$LOG_FILE"
php bin/magento store:website:create base "Base Website" --default 2>&1 | tee -a "$LOG_FILE" || {
    echo "WARNING: Failed to create website, may already exist..." | tee -a "$LOG_FILE"
}
php bin/magento store:group:create default "Default Store" base --default 2>&1 | tee -a "$LOG_FILE" || {
    echo "WARNING: Failed to create store group, may already exist..." | tee -a "$LOG_FILE"
}
php bin/magento store:view:create default "Default Store View" default en_US --default 2>&1 | tee -a "$LOG_FILE" || {
    echo "WARNING: Failed to create store view, may already exist..." | tee -a "$LOG_FILE"
}

# Run Magento setup:upgrade once
echo "Running Magento setup:upgrade..." | tee -a "$LOG_FILE"
php bin/magento module:enable --all --verbose 2>&1 | tee -a "$LOG_FILE" || {
    echo "ERROR: module:enable --all failed!" | tee -a "$LOG_FILE"
    exit 1
}
php bin/magento setup:upgrade --verbose 2>&1 | tee -a "$LOG_FILE" || {
    echo "ERROR: setup:upgrade failed!" | tee -a "$LOG_FILE"
    exit 1
}

# Compile DI
echo "Running Magento setup:di:compile..." | tee -a "$LOG_FILE"
php bin/magento setup:di:compile --verbose 2>&1 | tee -a "$LOG_FILE" || {
    echo "ERROR: setup:di:compile failed!" | tee -a "$LOG_FILE"
    exit 1
}

# Configure Elasticsearch with fallback
echo "Configuring Elasticsearch..." | tee -a "$LOG_FILE"
php bin/magento config:set catalog/search/engine elasticsearch8 2>&1 | tee -a "$LOG_FILE" && {
    php bin/magento config:set catalog/search/elasticsearch8_server_hostname "${ELASTICSEARCH_HOST}" 2>&1 | tee -a "$LOG_FILE" && \
    php bin/magento config:set catalog/search/elasticsearch8_server_port 9200 2>&1 | tee -a "$LOG_FILE" && \
    php bin/magento config:set catalog/search/elasticsearch8_index_prefix magento2 2>&1 | tee -a "$LOG_FILE" || {
        echo "WARNING: Elasticsearch config partially failed, proceeding..." | tee -a "$LOG_FILE"
    }
} || {
    echo "WARNING: Elasticsearch config failed, falling back to MySQL search..." | tee -a "$LOG_FILE"
    php bin/magento config:set catalog/search/engine mysql 2>&1 | tee -a "$LOG_FILE" || {
        echo "WARNING: Failed to set MySQL search engine, proceeding without search config..." | tee -a "$LOG_FILE"
    }
}

php bin/magento indexer:reindex 2>&1 | tee -a "$LOG_FILE" || {
    echo "WARNING: indexer:reindex failed, possibly due to Elasticsearch issues!" | tee -a "$LOG_FILE"
}
php bin/magento cache:clean 2>&1 | tee -a "$LOG_FILE" || {
    echo "WARNING: cache:clean failed!" | tee -a "$LOG_FILE"
}

echo "Post-install tasks completed!" | tee -a "$LOG_FILE"

# Set Apache log directory via environment variable
export APACHE_LOG_DIR="/var/www/html/var/log/apache"
echo "APACHE_LOG_DIR set to $APACHE_LOG_DIR" | tee -a "$LOG_FILE"

# Ensure log directory exists
mkdir -p "$APACHE_LOG_DIR" 2>/dev/null || {
    echo "WARNING: Could not create $APACHE_LOG_DIR, falling back to stdout..." | tee -a "$LOG_FILE"
    ln -sf /dev/stdout "$APACHE_LOG_DIR/access.log" 2>/dev/null || true
    ln -sf /dev/stderr "$APACHE_LOG_DIR/error.log" 2>/dev/null || true
}
chmod 775 "$APACHE_LOG_DIR" 2>/dev/null || {
    echo "WARNING: Could not set permissions on $APACHE_LOG_DIR, proceeding anyway..." | tee -a "$LOG_FILE"
}

# Start Apache
echo "Starting Apache..." | tee -a "$LOG_FILE"
exec apache2ctl -D FOREGROUND
