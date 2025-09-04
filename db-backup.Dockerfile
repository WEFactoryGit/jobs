FROM alpine
WORKDIR /scripts

RUN apk add --no-cache bash gzip mysql-client postgresql-client aws-cli
COPY scripts/backup-db.sh /scripts/backup-db.sh
RUN chmod +x /scripts/backup-db.sh /scripts/backup-db.sh

# 非敏感环境变量
ENV DB_TYPE=
ENV DB_HOST=
ENV DB_PORT=
ENV DB_USER=
ENV DB_NAME=
ENV R2_ENDPOINT=
ENV R2_BUCKET=

# 敏感信息环境变量(不在镜像中设置默认值)
# ENV DB_PASSWORD=
# ENV AWS_ACCESS_KEY_ID=
# ENV AWS_SECRET_ACCESS_KEY=

ENTRYPOINT ["/scripts/backup-db.sh"]