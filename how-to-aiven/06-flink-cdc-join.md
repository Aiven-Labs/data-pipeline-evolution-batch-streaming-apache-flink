Apache Flink CDC connector against the original tables + temporal joins
==========================================================================================

![Direct table CDC and consistency in Apache Flink](/img/all-cdc-to-flink.png)

To complete this scenario we need:

1. To start an Apache Kafka Debezium CDC connector tracking the five original tables
2. To create the Flink pipeline

1. Start the Kafka CDC connector tracking the five original tables
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

2. Replace the placeholders in the `kafka-connectors/all-tables-cdc.json`

```bash
sed "s/PG_HOST/$PG_HOST/" 'kafka-connectors/all-tables-cdc.json' > tmp/all-tables-cdc.json
sed "s/PG_PORT/$PG_PORT/" 'tmp/all-tables-cdc.json' > tmp/all-tables-cdc-port.json
sed "s/PG_PASSWORD/$PG_PASSWORD/" 'tmp/all-tables-cdc-port.json' > tmp/all-tables-cdc-final.json
```

3. Create the connector with

```bash
avn service connector create demo-kafka-ninja @tmp/all-tables-cdc-final.json
```

4. Check the connector status

```bash
avn service connector status demo-kafka-ninja my_order_source_deb_1
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
      -C -t my_pg1.public.orders
    ```


3. Create the Flink pipeline
----------------------------

We can deploy the Flink CDC connector against all the five original tables and recreate consistency with temporal joins with Aiven for Apache Flink by:

0. Run the `.env` file to set the parameters

```bash
. .env
```


1. Retrieving the integration id between PostgreSQL, Apache Kafka and Apache Flink

```bash
PG_FLINK_SI=$(avn service integration-list --json demo-postgresql-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
KAFKA_FLINK_SI=$(avn service integration-list --json demo-kafka-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
```

2. Creating an application named `CDC-Flink-Temporal-Join`

```bash
avn service flink create-application demo-flink-ninja \
    --project $PROJECT \
    "{\"name\":\"CDC-Flink-Temporal-Join\"}"
```

3. Retrieve the application id into `FLINK_CDC_TEMPORAL_JOIN` variable with the help of the Aiven CLI and [jq](https://jqlang.github.io/jq/)

```bash
FLINK_CDC_TEMPORAL_JOIN=$(avn service flink list-applications demo-flink-ninja   \
    --project $PROJECT | jq -r '.applications[] | select(.name == "CDC-Flink-Temporal-Join").id')
```

4. Replacing the integration ids in the Application definition file named `06-flink-cdc-temporal-join.json`

```bash
sed "s/PG_INTEGRATION_ID/$PG_FLINK_SI/" 'flink-applications/06-flink-cdc-temporal-join.json' > tmp/06-flink-cdc-temporal-join.json
sed "s/KAFKA_INTEGRATION_ID/$KAFKA_FLINK_SI/" 'tmp/06-flink-cdc-temporal-join.json' > tmp/06-flink-cdc-temporal-join-final.json
```

5. Creating the Apache Flink application mapping the PostgreSQL tables and the join statement

```bash
avn service flink create-application-version demo-flink-ninja   \
    --project $PROJECT                                          \
    --application-id $FLINK_CDC_TEMPORAL_JOIN                   \
    @tmp/06-flink-cdc-temporal-join-final.json
```

The `06-flink-cdc-temporal-join.json` contains the application definition, and, in particular:

* One Flink source table definition per topic mapping the CDC flow from the PostgreSQL tables, an example is for `src_orders` mapping the `my_pg.public.orders` topic

```
CREATE TABLE src_orders (
    id int,
    table_assignment_id int,
    order_time bigint,
    pizzas ARRAY<INT>,
    PRIMARY KEY (id) not enforced,
    event_time TIMESTAMP_LTZ(3) METADATA FROM 'value.source.timestamp' VIRTUAL,
    WATERMARK for event_time as event_time
) WITH (
    'connector' = 'kafka',
    'properties.bootstrap.servers' = '',
    'scan.startup.mode' = 'earliest-offset',
    'topic' = 'my_pg.public.orders',
    'value.format' = 'debezium-json'
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


* The SQL transformation logic including the various temporal joins

```sql
INSERT INTO order_output
select 
  src_orders.id order_id,
	src_clients.name client_name,
	src_tables.name table_name,
	JSON_ARRAYAGG( 
          JSON_OBJECT( 
            'pizza' VALUE src_pizzas.name,
            'price' VALUE src_pizzas.price 
            )
        )
from src_orders cross join unnest(src_orders.pizzas) as pizza_unnest(pizza_id) 
  join src_pizzas FOR SYSTEM_TIME AS of src_orders.event_time  
  on src_pizzas.id =  pizza_unnest.pizza_id
  join src_table_assignment  FOR SYSTEM_TIME AS of src_orders.event_time 
  on src_orders.table_assignment_id = src_table_assignment.id
  join src_clients  FOR SYSTEM_TIME AS of src_orders.event_time 
  on src_table_assignment.client_id = src_clients.id
  join src_tables  FOR SYSTEM_TIME AS of src_orders.event_time 
  on src_table_assignment.table_id = src_tables.id
group by src_orders.id,
  src_clients.name,
	src_tables.name;
```

The transformation SQL performs the temporal joins across all the tables involved.


**Running the Application**

The above application will run in batch, therefore we'll need an external scheduler invoking the application run every hour. With Aiven for Apache Flink you can:

1. Retrieve the Application version id you want to run, e.g. for the version `1` of the `CDC-Flink-Temporal-Join` application:

```bash
FLINK_CDC_TEMPORAL_JOIN_VERSION_1=$(avn service flink get-application demo-flink-ninja \
    --project $PROJECT --application-id $FLINK_CDC_TEMPORAL_JOIN | jq -r '.application_versions[] | select(.version == 1).id')
```

2. Create a deployment and store its id in the `DEPLOYMENT_ID` variable

```bash
avn service flink create-application-deployment  demo-flink-ninja   \
  --project $PROJECT                                                \
  --application-id $FLINK_CDC_TEMPORAL_JOIN                                      \
  "{\"parallelism\": 1,\"restart_enabled\": true,  \"version_id\": \"$FLINK_CDC_TEMPORAL_JOIN_VERSION_1\"}"
```

3. Retrieve the deployment id

```bash
FLINK_CDC_TEMPORAL_JOIN_DEPLOYMENT=$(avn service flink list-application-deployments demo-flink-ninja     \
  --project $PROJECT                                                                        \
  --application-id $FLINK_CDC_TEMPORAL_JOIN | jq  -r ".deployments[] | select(.version_id == \"$FLINK_CDC_TEMPORAL_JOIN_VERSION_1\").id")                                
```

4. Retrieve the deployment status

```bash
avn service flink get-application-deployment demo-flink-ninja     \
  --project $PROJECT                                              \
  --application-id $FLINK_CDC_TEMPORAL_JOIN                                \
  --deployment-id $FLINK_CDC_TEMPORAL_JOIN_DEPLOYMENT | jq '.status'
```

The app should be in `RUNNING` state 