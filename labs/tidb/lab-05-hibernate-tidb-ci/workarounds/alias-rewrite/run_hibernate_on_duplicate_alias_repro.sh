export TIDB_CONTAINER_NAME=tidb

docker run -d --rm --name "${TIDB_CONTAINER_NAME}" \
-p 4000:4000 pingcap/tidb:v8.5.3

sleep 15

docker run --rm -i --network container:${TIDB_CONTAINER_NAME} \
  mysql:8.0 mysql -h 127.0.0.1 -P 4000 -u root -vvv < hibernate_on_duplicate_alias_repro.sql

#docker stop ${TIDB_CONTAINER_NAME}