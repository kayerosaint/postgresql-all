#!/bin/bash
set -e

# Загрузка переменных окружения
if [ -f ".env" ]; then
    export $(grep -v '^#' .env | xargs)
fi

# FTP-параметры
FTP_URL_BASE="ftp://10.10.130.17/upload/"
DATA_DIR="/home/sqldata/data"

# Список доступных версий PostgreSQL
declare -a POSTGRESQL_VERSIONS=("postgresql-15.10-2.1C_x86_64_rpm.tar.bz2" "postgresql-16.6-3.1C_x86_64_rpm.tar.bz2" "postgresql-17.2-4.1C_x86_64_rpm.tar.bz2")

# Проверка на существование каталога и его содержимое
if [ -d "$DATA_DIR" ]; then
    if [ "$(ls -A $DATA_DIR)" ]; then
        echo "Каталог $DATA_DIR не пустой. Хотите очистить его для повторной установки? (y/n)"
        read -r clean_dir
        # Остановка и отключение всех версий PostgreSQL
	if [[ "$clean_dir" == "y" ]]; then
    		echo "Остановка всех версий PostgreSQL..."
    		systemctl stop postgresql-*  # Останавливаем все версии PostgreSQL

    	# Находим все службы PostgreSQL и отключаем их
    	echo "Отключение всех версий PostgreSQL..."
    		for service in $(systemctl list-units --type=service --all | grep 'postgresql' | awk '{print $1}'); do
        		if systemctl is-active --quiet "$service"; then
            		systemctl stop "$service"  # Остановка службы, если она активна
        		fi
        	systemctl disable "$service"  # Отключение автозапуска службы
        	echo "Служба $service успешно отключена."
    	done

    	echo "Очистка каталога $DATA_DIR..."
    	rm -rf "$DATA_DIR"/*  # Очищаем каталог
    fi
    else
        echo "Каталог $DATA_DIR существует, но он пустой. Продолжаем установку..."
    fi
else
    echo "Каталог $DATA_DIR не существует, создаём новый..."
    mkdir -p "$DATA_DIR"
fi

# Выбор версии PostgreSQL
echo "Выберите версию PostgreSQL для установки:"
select version in "${POSTGRESQL_VERSIONS[@]}"; do
    if [[ -n "$version" ]]; then
        FTP_URL="$FTP_URL_BASE$version"
        break
    else
        echo "Неверный выбор. Пожалуйста, попробуйте снова."
    fi
done

# Извлечение мажорной версии PostgreSQL
if [[ "$version" =~ postgresql-([0-9]+)\.[0-9]+- ]]; then
    major_version="${BASH_REMATCH[1]}"
else
    echo "Не удалось определить мажорную версию PostgreSQL из имени файла: $version"
    exit 1
fi

# Проверка, что версия извлечена корректно
if [[ -z "$major_version" ]]; then
    echo "Ошибка: Не удалось определить мажорную версию PostgreSQL."
    exit 1
fi

echo "Выбранная мажорная версия PostgreSQL: $major_version"

# Установка необходимых репозиториев
dnf install -y epel-release

# Проверка наличия утилит для распаковки tar.bz2
if ! command -v tar &>/dev/null || ! command -v bzip2 &>/dev/null; then
    echo "Устанавливаем tar и bzip2..."
    dnf install -y tar bzip2
fi

# Создание временной папки и загрузка PostgreSQL
mkdir -p /tmp/pgsql_install
cd /tmp/pgsql_install
curl -u "$FTP_USER":"$FTP_PASS" -O "$FTP_URL"
tar -xvjf "${version}"
cd /tmp/pgsql_install/"${version%.*.*}"  # Переходим в распакованную директорию

# Установка RPM-пакетов
dnf install -y *.rpm

# Открытие порта 5432 в firewalld
if ! firewall-cmd --list-ports | grep -q "5432/tcp"; then
    echo "Открываем порт 5432..."
    firewall-cmd --add-port=5432/tcp --permanent
    firewall-cmd --reload
fi

# Инициализация базы данных
chown postgres:postgres "$DATA_DIR"
su - postgres -c "/usr/pgsql-${major_version}/bin/initdb -D '$DATA_DIR'"

# Функция для добавления или замены строки в конфигурационном файле
add_or_replace_conf() {
    local file=$1
    local key=$2
    local value=$3
    sed -i "/^[#]*[[:space:]]*$key[[:space:]]*=/d" "$file"
    echo "$key = $value" >> "$file"
}

# Настройка конфигурации PostgreSQL
PG_CONF="$DATA_DIR/postgresql.conf"
HBA_CONF="$DATA_DIR/pg_hba.conf"

# Убедимся, что все необходимые параметры настроены правильно
add_or_replace_conf "$PG_CONF" "synchronous_commit" "off"
add_or_replace_conf "$PG_CONF" "full_page_writes" "off"
add_or_replace_conf "$PG_CONF" "maintenance_work_mem" "512MB"
add_or_replace_conf "$PG_CONF" "max_connections" "2000"
add_or_replace_conf "$PG_CONF" "row_security" "off"
add_or_replace_conf "$PG_CONF" "ssl" "off"
add_or_replace_conf "$PG_CONF" "temp_buffers" "256MB"
add_or_replace_conf "$PG_CONF" "fsync" "on"
add_or_replace_conf "$PG_CONF" "checkpoint_completion_target" "0.9"
add_or_replace_conf "$PG_CONF" "min_wal_size" "512MB"
add_or_replace_conf "$PG_CONF" "max_wal_size" "1GB"
add_or_replace_conf "$PG_CONF" "commit_delay" "1000"
add_or_replace_conf "$PG_CONF" "commit_siblings" "5"
add_or_replace_conf "$PG_CONF" "bgwriter_delay" "20ms"
add_or_replace_conf "$PG_CONF" "bgwriter_lru_multiplier" "4.0"
add_or_replace_conf "$PG_CONF" "bgwriter_lru_maxpages" "400"
add_or_replace_conf "$PG_CONF" "autovacuum" "on"
add_or_replace_conf "$PG_CONF" "autovacuum_max_workers" "4"
add_or_replace_conf "$PG_CONF" "autovacuum_naptime" "20s"
add_or_replace_conf "$PG_CONF" "max_files_per_process" "8000"
add_or_replace_conf "$PG_CONF" "random_page_cost" "1.7"
add_or_replace_conf "$PG_CONF" "from_collapse_limit" "20"
add_or_replace_conf "$PG_CONF" "join_collapse_limit" "20"
add_or_replace_conf "$PG_CONF" "geqo" "on"
add_or_replace_conf "$PG_CONF" "geqo_threshold" "12"
add_or_replace_conf "$PG_CONF" "effective_io_concurrency" "2"
add_or_replace_conf "$PG_CONF" "standard_conforming_strings" "off"
add_or_replace_conf "$PG_CONF" "escape_string_warning" "off"
add_or_replace_conf "$PG_CONF" "max_locks_per_transaction" "1000"

# Определение параметров производительности
CPU_CORES=$(nproc)
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_MB=$((MEM_TOTAL / 1024))  # Переводим в МБ
SHARED_BUFFERS=$((MEM_TOTAL_MB / 4))MB
WORK_MEM=$((MEM_TOTAL_MB / CPU_CORES / 2))MB
EFFECTIVE_CACHE_SIZE=$((MEM_TOTAL_MB * 3 / 4))MB

# Проверка и добавление/замена параметров производительности
add_or_replace_conf "$PG_CONF" "shared_buffers" "$SHARED_BUFFERS"
add_or_replace_conf "$PG_CONF" "work_mem" "$WORK_MEM"
add_or_replace_conf "$PG_CONF" "effective_cache_size" "$EFFECTIVE_CACHE_SIZE"

# Обработка специальных параметров
add_or_replace_conf "$PG_CONF" "data_directory" "'$DATA_DIR'"
add_or_replace_conf "$PG_CONF" "hba_file" "'$DATA_DIR/pg_hba.conf'"
add_or_replace_conf "$PG_CONF" "ident_file" "'$DATA_DIR/pg_ident.conf'"

# Обработка listen_addresses
if grep -q "listen_addresses" "$PG_CONF"; then
    sed -i '/listen_addresses/d' "$PG_CONF"
fi
echo "listen_addresses = '*'" >> "$PG_CONF"

# Если файла pg_hba.conf нет, создадим его
if [ ! -f "$HBA_CONF" ]; then
    touch "$HBA_CONF"
fi

# Добавление разрешений доступа в pg_hba.conf
if ! grep -q "0.0.0.0/0" "$HBA_CONF"; then
    echo "host all all 0.0.0.0/0 trust" >> "$HBA_CONF"
fi

# Изменение пути в юнит-файле
SERVICE_FILE="/usr/lib/systemd/system/postgresql-${major_version}.service"
if [ -f "$SERVICE_FILE" ]; then
    sed -i 's|Environment=PGDATA=/var/lib/pgsql/[0-9]*/data/|Environment=PGDATA=/home/sqldata/data|' "$SERVICE_FILE"
    systemctl daemon-reload
else
    echo "Юнит-файл не найден: $SERVICE_FILE"
fi

# Запуск PostgreSQL
systemctl enable "postgresql-${major_version}"
systemctl start "postgresql-${major_version}"

# Установка пароля для пользователя postgres
echo "Хотите установить пароль для пользователя postgres? (y/n)"
read -r set_pass
if [[ "$set_pass" == "y" ]]; then
    echo "Введите новый пароль для postgres:"
    read -s new_pass
    su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '$new_pass';\""
fi

# Настройка параметров ядра и лимитов
echo "Хотите настроить параметры ядра и системные лимиты? (y/n)"
read -r set_limits
if [[ "$set_limits" == "y" ]]; then
    sed -i '/kernel.shmmax/d' /etc/sysctl.conf
    sed -i '/kernel.shmall/d' /etc/sysctl.conf
    sed -i '/kernel.sem/d' /etc/sysctl.conf
    sed -i '/fs.file-max/d' /etc/sysctl.conf
    sed -i '/vm.swappiness/d' /etc/sysctl.conf
    sed -i '/vm.dirty_bytes/d' /etc/sysctl.conf
    sed -i '/vm.dirty_background_bytes/d' /etc/sysctl.conf
#   sed -i '/kernel.sched_migration_cost_ns/d' /etc/sysctl.conf
    
    cat >> /etc/sysctl.conf <<EOL
kernel.shmmax = $((MEM_TOTAL * 1024))
kernel.shmall = $((MEM_TOTAL * 1024 / 4096))
kernel.sem = 250 32000 100 128
fs.file-max = 100000
vm.swappiness=1
vm.dirty_bytes = 134217728
vm.dirty_background_bytes = 1073741824
EOL
    sysctl -p
    
    sed -i '/postgres   soft   nofile/d' /etc/security/limits.conf
    sed -i '/postgres   hard   nofile/d' /etc/security/limits.conf
    
    cat >> /etc/security/limits.conf <<EOL
postgres   soft   nofile   100000
postgres   hard   nofile   100000
EOL
fi

echo "Установка и настройка PostgreSQL завершена!"
