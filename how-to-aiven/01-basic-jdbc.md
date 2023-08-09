Basic JDBC solution with Aiven for Apache Flink
===============================================

![Apache Flink tables using the JDBC connector](img/direct-jdbc.png)

We can deploy the Basic JDBC solution with Aiven for Apache Flink by:

0. Run the `.env` file to set the parameters

```bash
. .env
```


1. Retrieving the integration id between PostgreSQL, Apache Kafka and Apache Flink

```bash
PG_FLINK_SI=$(avn service integration-list --json demo-postgresql-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
KAFKA_FLINK_SI=$(avn service integration-list --json demo-kafka-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
```

2. Creating an application named `BasicJDBC`

```bash
avn service flink create-application demo-flink-ninja \
    --project $PROJECT \
    "{\"name\":\"BasicJDBC\"}"
```

3. Retrieve the application id into `BASIC_JDBC` variable with the help of the Aiven CLI and [jq](https://jqlang.github.io/jq/)

```bash
BASIC_JDBC=$(avn service flink list-applications demo-flink-ninja   \
    --project $PROJECT | jq -r '.applications[] | select(.name == "BasicJDBC").id')
```

4. Replacing the integration ids in the Application definition file named `01-basic-jdbc.json`

```bash
sed "s/PG_INTEGRATION_ID/$PG_FLINK_SI/" 'flink-applications/01-basic-jdbc.json' > tmp/01-basic-jdbc.json
sed "s/KAFKA_INTEGRATION_ID/$KAFKA_FLINK_SI/" 'tmp/01-basic-jdbc.json' > tmp/01-basic-jdbc-final.json
```


5. Creating the Apache Flink application mapping the PostgreSQL tables and the join statement

```bash
avn service flink create-application-version demo-flink-ninja   \
    --project $PROJECT                                          \
    --application-id $BASIC_JDBC                                \
    @tmp/01-basic-jdbc-final.json
```

The `01-basic-jdbc.json` contains the application definition, and, in particular:

* Five Flink source table definitions using the JDBC connector, mapping each PostgreSQL table to a Flink table with alias `src_<TABLE_NAME>`
* One sink table writing to a kafka topic named `order_output` with the following structure

```sql
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
insert into order_output
select 
	src_orders.id order_id,
	src_clients.name client_name,
	src_tables.name table_name,
	LISTAGG(
          JSON_OBJECT( 
            'pizza' VALUE src_pizzas.name,
            'price' VALUE src_pizzas.price 
            )
        )
from src_orders cross join unnest(src_orders.pizzas) as pizza_unnest(pizza_id) 
  join src_pizzas on src_pizzas.id =  pizza_unnest.pizza_id
	join src_table_assignment on src_orders.table_assignment_id = src_table_assignment.id
	join src_clients on src_table_assignment.client_id = src_clients.id
	join src_tables on src_table_assignment.table_id = src_tables.id
where order_time > CEIL(LOCALTIMESTAMP to hour) - interval '1' hour 

group by 
    src_orders.id,
    src_clients.name,
    src_tables.name
    ;
```

Compared to the PostgreSQL SQL, The Flink SQL:

* Replaces the `CURRENT_TIMESTAMP` with `LOCALTIMESTAMP` and the `TRUNC` with the `CEIL` function
* Replaces the join beween `orders` and `pizzas` with a new join based on the `unnest` operation
* Replaces the `JSON_BUILD_OBJECT` and `JSON_AGG` with `JSON_OBJECT` and `LISTAGG` (even if the second is not 100% compatible, it allows the creation of a valid JSON) 

**Running the Application**

The above application will run in batch, therefore we'll need an external scheduler invoking the application run every hour. With Aiven for Apache Flink you can:

1. Retrieve the Application version id you want to run, e.g. for the version `1` of the `BasicJDBC` application:

```bash
BASIC_JDBC_VERSION_1=$(avn service flink get-application demo-flink-ninja \
    --project $PROJECT --application-id $BASIC_JDBC | jq -r '.application_versions[] | select(.version == 1).id')
```

2. Create a deployment and store its id in the `DEPLOYMENT_ID` variable

```bash
avn service flink create-application-deployment  demo-flink-ninja   \
  --project $PROJECT                                                \
  --application-id $BASIC_JDBC                                      \
  "{\"parallelism\": 1,\"restart_enabled\": true,  \"version_id\": \"$BASIC_JDBC_VERSION_1\"}"
```

3. Retrieve the deployment id

```bash
BASIC_JDBC_DEPLOYMENT=$(avn service flink list-application-deployments demo-flink-ninja     \
  --project $PROJECT                                                                        \
  --application-id $BASIC_JDBC | jq  -r ".deployments[] | select(.version_id == \"$BASIC_JDBC_VERSION_1\").id")                                
```

4. Retrieve the deployment status

```bash
avn service flink get-application-deployment demo-flink-ninja     \
  --project $PROJECT                                              \
  --application-id $BASIC_JDBC                                    \
  --deployment-id $BASIC_JDBC_DEPLOYMENT | jq '.status'
```

The app should be in `RUNNING` state and then go in `FINISHED` state