#!/bin/sh
set -eu

# Use the mounted admin secret only inside the container. Never pass it through
# a host process argument or persist it in the local .env file.
DB_HOST=postgres
DB_PORT=5432
DB_PASSWORD_ADMIN=$(cat /run/secrets/postgres_password)
export DB_HOST DB_PORT DB_PASSWORD_ADMIN

exec npm --prefix /app/server run create-tenant -- --tenant "$1" --email "$2"
