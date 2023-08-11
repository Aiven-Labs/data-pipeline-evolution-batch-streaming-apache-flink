Apache Kafka CDC reading PostgreSQL logical decoding messages + Apache Flink
==========================================================================================

![Outbox pattern with PostgreSQL logical decoding messages and Kafka CDC connector](/img/logical-decoding-messages-kafka-flink.png)

To complete this scenario we need:

1. To start an Apache Kafka Debezium CDC connector tracking the `orders` table, this will allow to read the additional logical decoding messages being pushed to the WAL log
2. Push a logical decoding message via PostgreSQL
3. To create the Flink pipeline

1. Start the Kafka CDC connector tracking the `orders` table to read additional logical decoding messages
---------------------------------------------------------------------------------------------------------


We can deploy a Debezium source connector to PostgreSQL with Aiven for Apache Kafka by:

0. Run the `.env` file to set the parameters

```bash
. .env
```

1. Retrieve the PostgreSQL connection info:

```bash
PG_HOST=$(avn service get demo-postgresql-ninja --json | jq -r '.service_uri_params.host')
PG_PORT=$(avn service get demo-postgresql-ninja --json | jq -r '.service_uri_params.port')
PG_PASSWORD=$(avn service get demo-postgresql-ninja --json | jq -r '.service_uri_params.password')
```

2. Replace the placeholders in the `kafka-connectors/orders-cdc.json`

```bash
sed "s/PG_HOST/$PG_HOST/" 'kafka-connectors/orders-cdc.json' > tmp/orders-cdc.json
sed "s/PG_PORT/$PG_PORT/" 'tmp/orders-cdc.json' > tmp/orders-cdc-port.json
sed "s/PG_PASSWORD/$PG_PASSWORD/" 'tmp/orders-cdc-port.json' > tmp/orders-cdc-final.json
```

3. Create the connector with

```bash
avn service connector create demo-kafka-ninja @tmp/orders-cdc-final.json
```

4. Check the connector status

```bash
avn service connector status demo-kafka-ninja my_order_source_deb
```

5. Check the data in Apache Kafka with [kcat](https://docs.aiven.io/docs/products/kafka/howto/kcat) by:

  * Retrieving the command and the Apache Kafka certificates with:

    ```bash
    avn service connection-info kcat demo-kafka-ninja -W 
    ```

  * Running the `kcat` command with:

    ```
    kcat -b KAFKA_HOST:KAFKA_PORT               \
      -X security.protocol=SSL                  \
      -X ssl.ca.location=ca.pem                 \
      -X ssl.key.location=service.key           \
      -X ssl.certificate.location=service.crt   \
      -C -t my_pg.public.orders
    ```

2. Push a new logical decoding message via PostgreSQL
-----------------------------------------------------

To verify the flow, we need to push one logical decoding message in PostgreSQL. To do so we can:

1. Connect to the PostgreSQL database with

```bash
avn service cli demo-postgresql-ninja
```

2. Execute the following

```sql
BEGIN;
DO
  $$
  DECLARE
    INSERTED_ORDER_ID INT;
    JSON_ORDER text;
  BEGIN

  INSERT INTO ORDERS 
    (TABLE_ASSIGNMENT_ID, ORDER_TIME, PIZZAS) 
    VALUES (2, CURRENT_TIMESTAMP, '{1,2,3,4}') RETURNING id into INSERTED_ORDER_ID;
  
  select JSONB_BUILD_OBJECT(
      'order_id', orders.id,
      'client_name', clients.name,
      'table_name', tables.name,
      'pizzas',
      JSONB_AGG(
              JSONB_BUILD_OBJECT( 
                'pizza', pizzas.name,
                'price', pizzas.price
                )
            )
    ) into JSON_ORDER
    from orders 
      join table_assignment on orders.table_assignment_id = table_assignment.id
      join pizzas on pizzas.id = ANY (orders.pizzas)
      join clients on table_assignment.client_id = clients.id
      join tables on table_assignment.table_id = tables.id
    where orders.id=INSERTED_ORDER_ID 
    group by 
        orders.id,
        clients.name,
        tables.name;

    SELECT * FROM pg_logical_emit_message(true,'myprefix',JSON_ORDER) into JSON_ORDER;
  END;
  $$;
END;
```


3. Create the Flink pipeline
----------------------------

We can deploy the Flink Kafka connector against the `my_pg.messages` topic (representing the concatenation of `database.server.name` and the table name including the schema) with Aiven for Apache Flink by:

0. Run the `.env` file to set the parameters

```bash
. .env
```


1. Retrieving the integration id between PostgreSQL, Apache Kafka and Apache Flink

```bash
PG_FLINK_SI=$(avn service integration-list --json demo-postgresql-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
KAFKA_FLINK_SI=$(avn service integration-list --json demo-kafka-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
```

2. Creating an application named `CDC-Kafka-Logical-msg-Flink`

```bash
avn service flink create-application demo-flink-ninja \
    --project $PROJECT \
    "{\"name\":\"CDC-Kafka-Logical-msg-Flink\"}"
```

3. Retrieve the application id into `KAFKA_CDC_LOG_MSG_FLINK` variable with the help of the Aiven CLI and [jq](https://jqlang.github.io/jq/)

```bash
KAFKA_CDC_LOG_MSG_FLINK=$(avn service flink list-applications demo-flink-ninja   \
    --project $PROJECT | jq -r '.applications[] | select(.name == "CDC-Kafka-Logical-msg-Flink").id')
```

4. Replacing the integration ids in the Application definition file named `05-kafka-logical-msg-flink.json`

```bash
sed "s/PG_INTEGRATION_ID/$PG_FLINK_SI/" 'flink-applications/05-kafka-logical-msg-flink.json' > tmp/05-kafka-logical-msg-flink.json
sed "s/KAFKA_INTEGRATION_ID/$KAFKA_FLINK_SI/" 'tmp/05-kafka-logical-msg-flink.json' > tmp/05-kafka-logical-msg-flink-final.json
```

5. Creating the Apache Flink application mapping the PostgreSQL tables and the join statement

```bash
avn service flink create-application-version demo-flink-ninja   \
    --project $PROJECT                                          \
    --application-id $KAFKA_CDC_LOG_MSG_FLINK                      \
    @tmp/05-kafka-logical-msg-flink-final.json
```

The `05-kafka-logical-msg-flink.json` contains the application definition, and, in particular:

* One Flink source table definitions using the Kafka connector, mapping the `my_pg.messages` Kafka topic in a table named `pg_messages`

```
CREATE TABLE pg_messages (
    op string,
    ts_ms bigint,
    source ROW( version string, connector string, name string, ts_ms bigint, snapshot string, db string, sequence string, schema string, `table` string, txId bigint, lsn bigint, xmin bigint),
    message ROW( prefix string, content string)
) WITH (
    'connector' = 'kafka',
    'properties.bootstrap.servers' = '',
    'scan.startup.mode' = 'earliest-offset',
    'topic' = 'my_pg.message',
    'value.format' = 'json'
)
```


* One sink table writing to a kafka topic named `order_output` with the following structure

```
CREATE TABLE order_output (
    order_id INT,
    client_name string,
    table_name string,
    pizzas string,
    PRIMARY KEY (order_id) not enforced
) WITH (
   'connector' = 'upsert-kafka',
   'properties.bootstrap.servers' = '',
   'topic' = 'order_output',
   'value.format' = 'json',
   'key.format' = 'json'
)
```


* The SQL transformation logic as

```sql
INSERT into order_output
select 
    JSON_VALUE(FROM_BASE64(message.content), '$.order_id'  RETURNING INT),
    JSON_VALUE(FROM_BASE64(message.content), '$.client_name'),
    JSON_VALUE(FROM_BASE64(message.content), '$.table_name'), 
    JSON_QUERY(FROM_BASE64(message.content), '$.pizzas[*]')
from pg_messages
```

The transformation SQL decodes the `message.content` section from base64 and then extracts, using the `JSON_VALUE` and `JSON_QUERY` functions, the relevant pieces of information.


**Running the Application**

The above application will run in batch, therefore we'll need an external scheduler invoking the application run every hour. With Aiven for Apache Flink you can:

1. Retrieve the Application version id you want to run, e.g. for the version `1` of the `BasicJDBC` application:

```bash
KAFKA_CDC_LOG_MSG_FLINK_VERSION_1=$(avn service flink get-application demo-flink-ninja \
    --project $PROJECT --application-id $KAFKA_CDC_LOG_MSG_FLINK | jq -r '.application_versions[] | select(.version == 1).id')
```

2. Create a deployment and store its id in the `DEPLOYMENT_ID` variable

```bash
avn service flink create-application-deployment  demo-flink-ninja   \
  --project $PROJECT                                                \
  --application-id $KAFKA_CDC_LOG_MSG_FLINK                                      \
  "{\"parallelism\": 1,\"restart_enabled\": true,  \"version_id\": \"$KAFKA_CDC_LOG_MSG_FLINK_VERSION_1\"}"
```

3. Retrieve the deployment id

```bash
KAFKA_CDC_LOG_MSG_FLINK_DEPLOYMENT=$(avn service flink list-application-deployments demo-flink-ninja     \
  --project $PROJECT                                                                        \
  --application-id $KAFKA_CDC_LOG_MSG_FLINK | jq  -r ".deployments[] | select(.version_id == \"$KAFKA_CDC_LOG_MSG_FLINK_VERSION_1\").id")                                
```

4. Retrieve the deployment status

```bash
avn service flink get-application-deployment demo-flink-ninja     \
  --project $PROJECT                                              \
  --application-id $KAFKA_CDC_LOG_MSG_FLINK                                \
  --deployment-id $KAFKA_CDC_LOG_MSG_FLINK_DEPLOYMENT | jq '.status'
```

The app should be in `RUNNING` state