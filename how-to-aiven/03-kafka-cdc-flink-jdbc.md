Apache Kafka CDC connector against the `orders` table + Flink JDBC lookup to the PostgreSQL view
================================================================================================

![Kafka CDC PostgreSQL - Flink with a Kafka connector to the orders topic and JDBC connector to the view](/img/kafka-cdc-flink-kafka-jdbc.png)

To complete this scenario we need:

1. To start a Kafka CDC connector tracking the `orders` table
2. To create the Flink pipeline

1. Start the Kafka CDC connector tracking the `orders` table
------------------------------------------------------------


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

2. Create the Flink pipeline
----------------------------

We can deploy the Flink Kafka connector against the `my_pg.public.orders` topic (representing the concatenation of `database.server.name` and the table name including the schema) + JDBC lookup to the PostgreSQL view with Aiven for Apache Flink by:

0. Run the `.env` file to set the parameters

```bash
. .env
```


1. Retrieving the integration id between PostgreSQL, Apache Kafka and Apache Flink

```bash
PG_FLINK_SI=$(avn service integration-list --json demo-postgresql-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
KAFKA_FLINK_SI=$(avn service integration-list --json demo-kafka-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
```

2. Creating an application named `CDC-Kafka-JDBC-Flink`

```bash
avn service flink create-application demo-flink-ninja \
    --project $PROJECT \
    "{\"name\":\"CDC-Kafka-JDBC-Flink\"}"
```

3. Retrieve the application id into `KAFKA_CDC_FLINK_JDBC` variable with the help of the Aiven CLI and [jq](https://jqlang.github.io/jq/)

```bash
KAFKA_CDC_FLINK_JDBC=$(avn service flink list-applications demo-flink-ninja   \
    --project $PROJECT | jq -r '.applications[] | select(.name == "CDC-Kafka-JDBC-Flink").id')
```

4. Replacing the integration ids in the Application definition file named `03-kafka-cdc-flink-jdbc.json`

```bash
sed "s/PG_INTEGRATION_ID/$PG_FLINK_SI/" 'flink-applications/03-kafka-cdc-flink-jdbc.json' > tmp/03-kafka-cdc-flink-jdbc.json
sed "s/KAFKA_INTEGRATION_ID/$KAFKA_FLINK_SI/" 'tmp/03-kafka-cdc-flink-jdbc.json' > tmp/03-kafka-cdc-flink-jdbc-final.json
```

5. Creating the Apache Flink application mapping the PostgreSQL tables and the join statement

```bash
avn service flink create-application-version demo-flink-ninja   \
    --project $PROJECT                                          \
    --application-id $KAFKA_CDC_FLINK_JDBC                      \
    @tmp/03-kafka-cdc-flink-jdbc-final.json
```

The `03-kafka-cdc-flink-jdbc.json` contains the application definition, and, in particular:

* One Flink source table definitions using the JDBC connector, mapping the `ORDER_JOINING_VIEW` view in a table named `order_enriched_in`

```
CREATE TABLE order_enriched_in (
    order_id int,
    client_name string,
    table_name string,
    order_time timestamp(3),
    proctime as proctime(),
    json_agg string,
    PRIMARY KEY (order_id) not enforced
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:postgresql://',
    'table-name' = 'order_joining_view'
)
```

We added the `proctime` column to be able to perform a lookup whenever a new order arrives from the CDC stream.

* One Flink source table definition using the Kafka connector, mapping the `my_pg.public.orders` Kafka topic in the `kafka_orders_cdc` flink table, note we're using the `'value.format' = 'debezium-json'` to automatically extract the `after` part of the Debezium payload

```
CREATE TABLE kafka_orders_cdc (
    id int,
    table_assignment_id int,
    order_time BIGINT,
    order_timestamp as TO_TIMESTAMP_LTZ(order_time/1000, 3),
    pizzas ARRAY<INT>,
    PRIMARY KEY (id) not enforced
) WITH (
    'connector' = 'kafka',
    'properties.bootstrap.servers' = '',
    'scan.startup.mode' = 'earliest-offset',
    'topic' = 'my_pg.public.orders',
    'value.format' = 'debezium-json'
)
```

* One sink table writing to a kafka topic named `order_output` with the following structure


* The SQL transformation logic as

```sql
INSERT INTO order_output
select 
  order_id, 
  client_name, 
  table_name, 
  json_agg 
from kafka_orders_cdc
join order_enriched_in FOR SYSTEM_TIME AS of order_enriched_in.proctime
on order_enriched_in.order_id=kafka_orders_cdc.id
```

The transformation SQL only performs the JDBC lookup every time an order is entered and tracked by the CDC pipeline.


**Running the Application**

The above application will run in batch, therefore we'll need an external scheduler invoking the application run every hour. With Aiven for Apache Flink you can:

1. Retrieve the Application version id you want to run, e.g. for the version `1` of the `BasicJDBC` application:

```bash
KAFKA_CDC_FLINK_JDBC_VERSION_1=$(avn service flink get-application demo-flink-ninja \
    --project $PROJECT --application-id $KAFKA_CDC_FLINK_JDBC | jq -r '.application_versions[] | select(.version == 1).id')
```

2. Create a deployment and store its id in the `DEPLOYMENT_ID` variable

```bash
avn service flink create-application-deployment  demo-flink-ninja   \
  --project $PROJECT                                                \
  --application-id $KAFKA_CDC_FLINK_JDBC                                      \
  "{\"parallelism\": 1,\"restart_enabled\": true,  \"version_id\": \"$KAFKA_CDC_FLINK_JDBC_VERSION_1\"}"
```

3. Retrieve the deployment id

```bash
KAFKA_CDC_FLINK_JDBC_DEPLOYMENT=$(avn service flink list-application-deployments demo-flink-ninja     \
  --project $PROJECT                                                                        \
  --application-id $KAFKA_CDC_FLINK_JDBC | jq  -r ".deployments[] | select(.version_id == \"$KAFKA_CDC_FLINK_JDBC_VERSION_1\").id")                                
```

4. Retrieve the deployment status

```bash
avn service flink get-application-deployment demo-flink-ninja     \
  --project $PROJECT                                              \
  --application-id $KAFKA_CDC_FLINK_JDBC                                \
  --deployment-id $KAFKA_CDC_FLINK_JDBC_DEPLOYMENT | jq '.status'
```

The app should be in `RUNNING` state and then go in `FINISHED` state