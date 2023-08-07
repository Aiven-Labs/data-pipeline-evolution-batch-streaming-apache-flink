# The following is a script that creates all the needed services in Aiven, it requires:
# - An Aiven account https://console.aiven.io/signup
# - An Aiven token in the .env file (copy the .env.sample file for reference)
# - The Aiven Command Line Interface CLI installation https://docs.aiven.io/docs/tools/cli

# Loading the variables (TOKEN) from the .env file
. .env

# Create PostgreSQL
avn --auth-token $TOKEN service create demo-postgresql-ninja      \
    -t pg                               \
    --plan business-4                   \
    --cloud google-europe-west1

# Create Apache Kafka
avn --auth-token $TOKEN service create demo-kafka-ninja           \
    -t kafka                            \
    --plan business-4                   \
    --cloud google-europe-west1         \
    -c kafka_connect=true               \
    -c schema_registry=true             \
    -c kafka.auto_create_topics_enable=true

# Create Apache Flink
avn --auth-token $TOKEN service create demo-flink-ninja             \
    -t flink                                                        \
    --plan business-4                                               \
    --cloud google-europe-west1

# Create integration between Kafka and Flink
avn --auth-token $TOKEN service integration-create      \
    -t flink                                            \
    -s demo-kafka-ninja                                 \
    -d demo-flink-ninja

# Create integration between PostgreSQL and Flink
avn --auth-token $TOKEN service integration-create      \
    -t flink                                            \
    -s demo-postgresql-ninja                            \
    -d demo-flink-ninja

./scripts/populate_database.sh
