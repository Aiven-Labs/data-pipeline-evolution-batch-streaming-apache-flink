Unique Apache Flink JDBC connector against a PostgreSQL view
============================================================

![JDBC with View](/img/jdbc-with-view.png)

We can deploy the unique JDBC connector against a PostgreSQL view with Aiven for Apache Flink by:

1. In PostgreSQL create a view named `ORDER_JOINING_VIEW` with:

```
CREATE VIEW ORDER_JOINING_VIEW AS
select 
	orders.id order_id,
	clients.name client_name,
	tables.name table_name,
    order_time,
	cast(JSON_AGG(
          JSON_BUILD_OBJECT( 
            'pizza', pizzas.name,
            'price', pizzas.price
            )
        ) as text)
from orders 
	join table_assignment on orders.table_assignment_id = table_assignment.id
	join pizzas on pizzas.id = ANY (orders.pizzas)
	join clients on table_assignment.client_id = clients.id
	join tables on table_assignment.table_id = tables.id
group by 
    orders.id,
    clients.name,
    tables.name,
    order_time;
```

Compared to the original query, we're:
* exposing the `order_time` that we'll use from Apache Flink to retrieve only the latest rows. 
* removing the `order_time` where clause from the query
* cast the JSON as text to be able to read it from Flink

We expose the `order_time` since we want to be able to retrieve from Flink a specific point in time if a previous job fails.

**View based JDBC solution with Aiven for Apache Flink**

Using Aiven we can achieve it by:

0. Run the `.env` file to set the parameters

```bash
. .env
```


1. Retrieving the integration id between PostgreSQL, Apache Kafka and Apache Flink

```bash
PG_FLINK_SI=$(avn service integration-list --json demo-postgresql-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
KAFKA_FLINK_SI=$(avn service integration-list --json demo-kafka-ninja | jq -r '.[] | select(.dest == "demo-flink-ninja").service_integration_id')
```

2. Creating an application named `ViewBasedJDBC`

```bash
avn service flink create-application demo-flink-ninja \
    --project $PROJECT \
    "{\"name\":\"ViewBasedJDBC\"}"
```

3. Retrieve the application id into `VIEW_BASED_JDBC` variable with the help of the Aiven CLI and [jq](https://jqlang.github.io/jq/)

```bash
VIEW_BASED_JDBC=$(avn service flink list-applications demo-flink-ninja   \
    --project $PROJECT | jq -r '.applications[] | select(.name == "ViewBasedJDBC").id')
```

Replacing the integration ids in the Application definition file named `02-view-based-jdbc.json`

```bash
sed "s/PG_INTEGRATION_ID/$PG_FLINK_SI/" 'flink-applications/02-view-based-jdbc.json' > tmp/02-view-based-jdbc.json
sed "s/KAFKA_INTEGRATION_ID/$KAFKA_FLINK_SI/" 'tmp/02-view-based-jdbc.json' > tmp/02-view-based-jdbc-final.json
```


Creating the Apache Flink application mapping the PostgreSQL tables and the join statement

```bash
avn service flink create-application-version demo-flink-ninja   \
    --project $PROJECT                                          \
    --application-id $VIEW_BASED_JDBC                           \
    @tmp/02-view-based-jdbc-final.json
```

The `02-view-based-jdbc.json` contains the application definition, and, in particular:

* One Flink source table definitions using the JDBC connector, mapping the `ORDER_JOINING_VIEW` view in a table named `order_enriched_in`
* The same sink table as the previous solution writing to a kafka topic named `order_output`


* The SQL transformation logic is simpler, since we only need to filter the data

```sql
insert into order_output
select 
    order_id, 
    client_name, 
    table_name, 
    json_agg 
from order_enriched_in 
where 
    order_time > CEIL(LOCALTIMESTAMP to hour) - interval '1' hour 
    and order_time <= CEIL(LOCALTIMESTAMP to hour)
``` 

**Running the Application**

The above application will run in batch, therefore we'll need an external scheduler invoking the application run every hour. With Aiven for Apache Flink you can:

1. Retrieve the Application version id you want to run, e.g. for the version `1` of the `ViewBasedJDBC` application:

```bash
VIEW_BASED_JDBC_VERSION_1=$(avn service flink get-application demo-flink-ninja \
    --project $PROJECT --application-id $VIEW_BASED_JDBC | jq -r '.application_versions[] | select(.version == 1).id')
```

2. Create a deployment and store its id in the `DEPLOYMENT_ID` variable

```bash
avn service flink create-application-deployment  demo-flink-ninja   \
  --project $PROJECT                                                \
  --application-id $VIEW_BASED_JDBC                                      \
  "{\"parallelism\": 1,\"restart_enabled\": true,  \"version_id\": \"$VIEW_BASED_JDBC_VERSION_1\"}"
```

3. Retrieve the deployment id

```bash
VIEW_BASED_JDBC_DEPLOYMENT=$(avn service flink list-application-deployments demo-flink-ninja     \
  --project $PROJECT                                                                        \
  --application-id $VIEW_BASED_JDBC | jq  -r ".deployments[] | select(.version_id == \"$VIEW_BASED_JDBC_VERSION_1\").id")                                
```

4. Retrieve the deployment status

```bash
avn service flink get-application-deployment demo-flink-ninja     \
  --project $PROJECT                                              \
  --application-id $VIEW_BASED_JDBC                                    \
  --deployment-id $VIEW_BASED_JDBC_DEPLOYMENT | jq '.status'
```

The app should be in `RUNNING` state and then go in `FINISHED` state