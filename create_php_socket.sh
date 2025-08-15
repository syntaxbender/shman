#!/bin/bash

read -p "Hangi kullanıcı için pool oluşturulsun? (örn: myuser): " USERNAME

PHP_VERSIONS=$(ls /etc/php/ | grep -E '^[0-9]+\.[0-9]+$')

if [ ${#PHP_VERSIONS[@]} -eq 0 ]; then
    echo "Hiçbir PHP sürümü bulunamadı."
    exit 1
fi

echo "Mevcut PHP sürümleri:"
select PHP_VERSION in "${PHP_VERSIONS[@]}"; do
    if [[ -n "$PHP_VERSION" ]]; then
        break
    else
        echo "Lütfen geçerli bir seçim yapın."
    fi
done

POOL_CONF_DIR="/etc/php/${PHP_VERSION}/fpm/pool.d"
POOL_CONF_FILE="${POOL_CONF_DIR}/${USERNAME}.conf"

cat <<EOF > "$POOL_CONF_FILE"
[${USERNAME}]
listen = /run/php/${USERNAME}.sock
listen.owner = ${USERNAME}
listen.group = ${USERNAME}
listen.mode = 0660

user = ${USERNAME}
group = ${USERNAME}

pm = dynamic
pm.max_children = 20
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 4
EOF
