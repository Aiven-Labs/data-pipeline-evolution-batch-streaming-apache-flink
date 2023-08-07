# This procedure loads the data in Aiven for PostgreSQL

# Loading the variables (TOKEN) from the .env file
. .env

# Getting connection URL
mkdir -p tmp
avn --auth-token $TOKEN service get demo-postgresql-ninja --format '{service_uri}' > tmp/postgresql_connection_uri.txt

# Waiting for the service to be up
avn --auth-token $TOKEN service wait demo-postgresql-ninja

# Populating the database
avn --auth-token $TOKEN service cli demo-postgresql-ninja << EOF
\i scripts/load_dims.sql
EOF