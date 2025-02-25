# Use Ubuntu 24.04 as the base image
FROM ubuntu:24.04

# Update and install Apache2, PHP, Composer, and necessary extensions
RUN apt-get update && apt-get install -y \
        apache2 \
        php \
        libapache2-mod-php \
        php-mysql \
        php-cli \
        php-common \
        php-json \
        php-opcache \
        php-mbstring \
        php-xml \
        php-dom \
        php-gd \
        php-soap \
        php-bcmath \
        git \
        curl \
        unzip \
        composer \
        mysql-client-core-8.0 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Enable Apache mod_rewrite for Magento
RUN a2enmod rewrite

# Create a non-root user to run Magento and Composer
RUN useradd -m -s /bin/bash magentouser

# Set working directory for Magento installation
WORKDIR /var/www/html

# Copy Magento files, post-install script, and .env
COPY --chown=magentouser:magentouser . /var/www/html/
COPY --chown=magentouser:magentouser ./post-install.sh /usr/local/bin/post-install.sh
COPY --chown=magentouser:magentouser ./.env /var/www/html/.env

# Add build arguments for Magento keys (optional, can rely on .env)
ARG MAGENTO_PUBLIC_KEY
ARG MAGENTO_PRIVATE_KEY

# Set ownership and prepare Composer directory as root
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html \
    && chmod +x /usr/local/bin/post-install.sh \
    && chmod 644 /var/www/html/app/etc/*.php 2>/dev/null || true \
    && mkdir -p /var/www/.composer \
    && chown www-data:www-data /var/www/.composer \
    && chmod 755 /var/www/.composer

# Switch to www-data user
USER www-data

# Configure Composer authentication and install dependencies
RUN composer config http-basic.repo.magento.com "${MAGENTO_PUBLIC_KEY}" "${MAGENTO_PRIVATE_KEY}" \
    && composer install --no-interaction --prefer-dist --verbose

# Expose the port Apache runs on
EXPOSE 80

USER root

COPY magento.conf /etc/apache2/sites-available/magento.conf
RUN a2enmod rewrite && \
    a2dissite 000-default && \
    a2ensite magento && \
    mkdir -p /var/www/html/var/log/apache && \
    chmod 755 /var/www/html/var/log/apache

# Use an entrypoint to run the post-install script and then start Apache
ENTRYPOINT ["/usr/local/bin/post-install.sh"]
CMD ["apache2ctl", "-D", "FOREGROUND"]
