Apache Flink CDC connector against the outbox table
==========================================================================================

![Outbox Pattern with Apache Flink CDC](/img/outbox-flink.png)

We can deploy the Flink CDC connector against the `orders_outbox` outbox table with Aiven for Apache Flink by:

0. Run the `.env` file to set the parameters

```bash
. .env
```


1. Retrieving the integration id between PostgreSQL, Apache Kafka and Apache Flink

```bash
PG_FLINK_SI=$(avn service integration-list --json demo-postgresql-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
KAFKA_FLINK_SI=$(avn service integration-list --json demo-kafka-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
```

2. Creating an application named `CDC-Flink-Outbox`

```bash
avn service flink create-application demo-flink-ninja \
    --project $PROJECT \
    "{\"name\":\"CDC-Flink-Outbox\"}"
```

3. Retrieve the application id into `FLINK_CDC_OUTBOX` variable with the help of the Aiven CLI and [jq](https://jqlang.github.io/jq/)

```bash
FLINK_CDC_OUTBOX=$(avn service flink list-applications demo-flink-ninja   \
    --project $PROJECT | jq -r '.applications[] | select(.name == "CDC-Flink-Outbox").id')
```

4. Replacing the integration ids in the Application definition file named `04-flink-cdc-outbox.json`

```bash
sed "s/PG_INTEGRATION_ID/$PG_FLINK_SI/" 'flink-applications/04-flink-cdc-outbox.json' > tmp/04-flink-cdc-outbox.json
sed "s/KAFKA_INTEGRATION_ID/$KAFKA_FLINK_SI/" 'tmp/04-flink-cdc-outbox.json' > tmp/04-flink-cdc-outbox-final.json
```

5. After connecting to the PostgreSQL database (with `avn service cli demo-postgresql-ninja`), creating the `dbz_publication` for the `orders_outbox` table with:

```
CREATE PUBLICATION dbz_publication FOR TABLE orders_outbox;
```

If the publication is already existing, you can drop and recreate it with:

```
DROP PUBLICATION dbz_publication;
CREATE PUBLICATION dbz_publication FOR TABLE orders_outbox;
```

6. Creating the Apache Flink application mapping the PostgreSQL tables and the join statement

```bash
avn service flink create-application-version demo-flink-ninja   \
    --project $PROJECT                                          \
    --application-id $FLINK_CDC_OUTBOX                          \
    @tmp/04-flink-cdc-outbox-final.json
```

The `04-flink-cdc-outbox.json` contains the application definition, and, in particular:

* One Flink source table definitions using the PostgreSQL CDC connector, mapping the `ORDERS_OUTBOX` PostgreSQL table in a Flink table named `order_outbox`

```
CREATE TABLE order_outbox (
  order_id int,
  client_name string,
  table_name string,
  pizzas string
) WITH (
  'connector' = 'postgres-cdc',
  'database-name' = 'defaultdb',
  'hostname' = '',
  'password' = '',
  'schema-name' = 'public',
  'table-name' = 'orders_outbox',
  'username' = ''
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
INSERT INTO order_output
select * from order_outbox;
```

The transformation SQL only performs the JDBC lookup every time an order is entered and tracked by the CDC pipeline.

**Running the Application**

The above application will run in batch, therefore we'll need an external scheduler invoking the application run every hour. With Aiven for Apache Flink you can:

1. Retrieve the Application version id you want to run, e.g. for the version `1` of the `BasicJDBC` application:

```bash
FLINK_CDC_OUTBOX_VERSION_1=$(avn service flink get-application demo-flink-ninja \
    --project $PROJECT --application-id $FLINK_CDC_OUTBOX | jq -r '.application_versions[] | select(.version == 1).id')
```

2. Create a deployment and store its id in the `DEPLOYMENT_ID` variable

```bash
avn service flink create-application-deployment  demo-flink-ninja   \
  --project $PROJECT                                                \
  --application-id $FLINK_CDC_OUTBOX                                      \
  "{\"parallelism\": 1,\"restart_enabled\": true,  \"version_id\": \"$FLINK_CDC_OUTBOX_VERSION_1\"}"
```

3. Retrieve the deployment id

```bash
FLINK_CDC_OUTBOX_DEPLOYMENT=$(avn service flink list-application-deployments demo-flink-ninja     \
  --project $PROJECT                                                                        \
  --application-id $FLINK_CDC_OUTBOX | jq  -r ".deployments[] | select(.version_id == \"$FLINK_CDC_OUTBOX_VERSION_1\").id")                                
```

4. Retrieve the deployment status

```bash
avn service flink get-application-deployment demo-flink-ninja     \
  --project $PROJECT                                              \
  --application-id $FLINK_CDC_OUTBOX                                \
  --deployment-id $FLINK_CDC_OUTBOX_DEPLOYMENT | jq '.status'
```

The app should be in `RUNNING` state 