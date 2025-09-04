#!/bin/sh
set -e

# =======================
# 配置参数（通过环境变量传入）
# =======================
# PostgreSQL 连接信息
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_USER=${DB_USER:-postgres}
DB_PASSWORD=${DB_PASSWORD:-}
DB_NAMES=${DB_NAMES:-}      # 多数据库用空格分隔 "db1 db2 db3"

# MySQL 连接信息
DB_TYPE=${DB_TYPE:-postgres} # 数据库类型: mysql 或 postgres

# R2 配置
R2_BUCKET=${R2_BUCKET:-db-backup}
R2_ENDPOINT=${R2_ENDPOINT:-https://<account_id>.r2.cloudflarestorage.com>}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}

# 服务名称
SERVICE_NAME=${SERVICE_NAME:-backup}

# 临时目录
TMP_DIR=/tmp/backup
mkdir -p $TMP_DIR

# 当前时间戳
BACKUP_DATE=$(date +"%Y-%m-%d_%H-%M-%S")

# =======================
# 备份模式
# =======================
backup() {
    for DB_NAME in $DB_NAMES; do
        BACKUP_FILE="$TMP_DIR/${DB_NAME}_${BACKUP_DATE}.sql"
        echo "Backing up ${DB_TYPE} database: $DB_NAME"
        
        if [ "$DB_TYPE" = "mysql" ]; then
            # 先将mysqldump输出到临时文件，成功后再压缩
            TMP_FILE="$TMP_DIR/${DB_NAME}_${BACKUP_DATE}.sql.tmp"
            mariadb-dump --ssl=0 -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASSWORD $DB_NAME > $TMP_FILE
            gzip < $TMP_FILE > $BACKUP_FILE.gz
            rm -f $TMP_FILE
            BACKUP_FILE="${BACKUP_FILE}.gz"
        elif [ "$DB_TYPE" = "postgres" ]; then
            # 先将pg_dump输出到临时文件，成功后再压缩
            TMP_FILE="$TMP_DIR/${DB_NAME}_${BACKUP_DATE}.sql.tmp"
            PGPASSWORD=$DB_PASSWORD pg_dump -h $DB_HOST -p $DB_PORT -U $DB_USER $DB_NAME > $TMP_FILE
            gzip < $TMP_FILE > $BACKUP_FILE.gz
            rm -f $TMP_FILE
            BACKUP_FILE="${BACKUP_FILE}.gz"
        else
            echo "Unsupported DB_TYPE: $DB_TYPE"
            exit 1
        fi

        echo "Backup completed: $BACKUP_FILE"

        # 上传到 R2，使用期望的路径格式: $SERVICE_NAME/$DB_NAME/$BACKUP_DATE.sql.gz
        echo "Uploading $DB_NAME backup to R2..."
        aws --endpoint-url $R2_ENDPOINT s3 cp $BACKUP_FILE s3://$R2_BUCKET/$SERVICE_NAME/$DB_NAME/$BACKUP_DATE.sql.gz
    done
    echo "All backups uploaded successfully."
}

# =======================
# 恢复模式
# 参数：原数据库名 目标数据库名
# =======================
restore() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage for restore: $0 restore <source_db_name> <target_db_name>"
        exit 1
    fi

    SRC_DB=$1
    TARGET_DB=$2
    BACKUP_FILE="$TMP_DIR/${SRC_DB}_restore.sql.gz"

    echo "Downloading backup for $SRC_DB from R2..."
    aws --endpoint-url $R2_ENDPOINT s3 cp s3://$R2_BUCKET/$SERVICE_NAME/$SRC_DB/$BACKUP_DATE.sql.gz $BACKUP_FILE

    echo "Creating target database $TARGET_DB if it does not exist..."
    if [ "$DB_TYPE" = "mysql" ]; then
        # MySQL创建数据库命令
        mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASSWORD -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DB\`;"
        echo "Restoring $SRC_DB backup into $TARGET_DB..."
        gunzip -c $BACKUP_FILE | mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASSWORD $TARGET_DB
    elif [ "$DB_TYPE" = "postgres" ]; then
        # PostgreSQL创建数据库命令
        PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -tc "SELECT 1 FROM pg_database WHERE datname='$TARGET_DB'" | grep -q 1 || \
            PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -c "CREATE DATABASE \"$TARGET_DB\";"
        
        echo "Restoring $SRC_DB backup into $TARGET_DB..."
        PGPASSWORD=$DB_PASSWORD gunzip -c $BACKUP_FILE | psql -h $DB_HOST -p $DB_PORT -U $DB_USER $TARGET_DB
    else
        echo "Unsupported DB_TYPE: $DB_TYPE"
        exit 1
    fi

    echo "Restore completed: $TARGET_DB"
}

# =======================
# 主逻辑
# =======================
if [ "$1" = "backup" ]; then
    backup
elif [ "$1" = "restore" ]; then
    restore $2 $3
else
    echo "Usage: $0 {backup|restore} [source_db target_db]"
    exit 1
fi