Apache Flink CDC connector against the `orders` table + JDBC lookup to the PostgreSQL view
==========================================================================================

![Flink with a CDC connector to the orders table and JDBC connector to the view](/img/flink-cdc-order-jdbc.png)

We can deploy the Flink CDC connector against the `orders` table + JDBC lookup to the PostgreSQL view with Aiven for Apache Flink by:

0. Run the `.env` file to set the parameters

```bash
. .env
```


1. Retrieving the integration id between PostgreSQL, Apache Kafka and Apache Flink

```bash
PG_FLINK_SI=$(avn service integration-list --json demo-postgresql-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
KAFKA_FLINK_SI=$(avn service integration-list --json demo-kafka-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
```

2. Creating an application named `CDC-JDBC-Flink`

```bash
avn service flink create-application demo-flink-ninja \
    --project $PROJECT \
    "{\"name\":\"CDCJDBCFlink\"}"
```

3. Retrieve the application id into `FLINK_CDC_JDBC` variable with the help of the Aiven CLI and [jq](https://jqlang.github.io/jq/)

```bash
FLINK_CDC_JDBC=$(avn service flink list-applications demo-flink-ninja   \
    --project $PROJECT | jq -r '.applications[] | select(.name == "CDCJDBCFlink").id')
```

4. Replacing the integration ids in the Application definition file named `03-flink-cdc-jdbc.json`

```bash
sed "s/PG_INTEGRATION_ID/$PG_FLINK_SI/" 'flink-applications/03-flink-cdc-jdbc.json' > tmp/03-flink-cdc-jdbc.json
sed "s/KAFKA_INTEGRATION_ID/$KAFKA_FLINK_SI/" 'tmp/03-flink-cdc-jdbc.json' > tmp/03-flink-cdc-jdbc-final.json
```

5. After connecting to the PostgreSQL database (with `avn service cli demo-postgresql-ninja`), creating the `dbz_publication` for the `orders` table with:

```
CREATE PUBLICATION dbz_publication FOR TABLE orders;
```

6. Creating the Apache Flink application mapping the PostgreSQL tables and the join statement

```bash
avn service flink create-application-version demo-flink-ninja   \
    --project $PROJECT                                          \
    --application-id $FLINK_CDC_JDBC                            \
    @tmp/03-flink-cdc-jdbc-final.json
```

The `03-flink-cdc-jdbc.json` contains the application definition, and, in particular:

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

* One Flink source table definition using the PostgreSQL CDC connector, mapping the `orders` PG table in the `orders_cdc` flink table

```
CREATE TABLE orders_cdc (
    id int,
    table_assignment_id int,
    order_time TIMESTAMP(3),
    PRIMARY KEY (id) not enforced
) WITH (
  'connector' = 'postgres-cdc',
  'database-name' = 'defaultdb',
  'hostname' = '',
  'password' = '',
  'schema-name' = 'public',
  'table-name' = 'orders',
  'username' = ''
)
```

* One sink table writing to a kafka topic named `order_output` with the following structure


* The SQL transformation logic as

```sql
INSERT INTO order_output
select order_id, client_name, table_name, json_agg 
from orders_cdc
join order_enriched_in FOR SYSTEM_TIME AS of order_enriched_in.proctime
on order_enriched_in.order_id=orders_cdc.id
```

The transformation SQL only performs the JDBC lookup every time an order is entered and tracked by the CDC pipeline.

**Running the Application**

The above application will run in batch, therefore we'll need an external scheduler invoking the application run every hour. With Aiven for Apache Flink you can:

1. Retrieve the Application version id you want to run, e.g. for the version `1` of the `BasicJDBC` application:

```bash
FLINK_CDC_JDBC_VERSION_1=$(avn service flink get-application demo-flink-ninja \
    --project $PROJECT --application-id $FLINK_CDC_JDBC | jq -r '.application_versions[] | select(.version == 1).id')
```

2. Create a deployment and store its id in the `DEPLOYMENT_ID` variable

```bash
avn service flink create-application-deployment  demo-flink-ninja   \
  --project $PROJECT                                                \
  --application-id $FLINK_CDC_JDBC                                      \
  "{\"parallelism\": 1,\"restart_enabled\": true,  \"version_id\": \"$FLINK_CDC_JDBC_VERSION_1\"}"
```

3. Retrieve the deployment id

```bash
FLINK_CDC_JDBC_DEPLOYMENT=$(avn service flink list-application-deployments demo-flink-ninja     \
  --project $PROJECT                                                                        \
  --application-id $FLINK_CDC_JDBC | jq  -r ".deployments[] | select(.version_id == \"$FLINK_CDC_JDBC_VERSION_1\").id")                                
```

4. Retrieve the deployment status

```bash
avn service flink get-application-deployment demo-flink-ninja     \
  --project $PROJECT                                              \
  --application-id $FLINK_CDC_JDBC                                \
  --deployment-id $FLINK_CDC_JDBC_DEPLOYMENT | jq '.status'
```

The app should be in `RUNNING` state and then go in `FINISHED` state