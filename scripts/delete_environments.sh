# The following is a script that deletes all the needed services in Aiven, it requires:
# - An Aiven account https://console.aiven.io/signup
# - An Aiven token in the .env file (copy the .env.sample file for reference)
# - The Aiven Command Line Interface CLI installation https://docs.aiven.io/docs/tools/cli


# Loading the variables (TOKEN) from the .env file
. .env

# Delete PostgreSQL
avn --auth-token $TOKEN service terminate demo-postgresql-ninja --force

# Delete Apache Kafka
avn --auth-token $TOKEN service terminate demo-kafka-ninja --force

# Delete Apache Flink
avn --auth-token $TOKEN service terminate demo-flink-ninja --force

rm -rf tmp