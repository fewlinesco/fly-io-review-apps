#!/bin/bash -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=${INPUT_PR_NUMBER:-$(jq -r .number /github/workflow/event.json)}
if [ "$PR_NUMBER" = "null" ]; then
  echo "This action requires a PR number to be passed in as an input or be run from a pull request."
  exit 1
fi

REPO_OWNER=$(jq -r .organization.login /github/workflow/event.json)
REPO_NAME=$(jq -r .repository.name /github/workflow/event.json)
EVENT_TYPE=${INPUT_EVENT_TYPE:-$(jq -r .action /github/workflow/event.json)}

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$REPO_OWNER-$REPO_NAME}"
postgres_app="${INPUT_POSTGRES_NAME:-pr-$PR_NUMBER-$REPO_OWNER-$REPO_NAME-postgres}"
region="${INPUT_REGION:-${FLY_REGION:-cdg}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
postgres_vm_size="${INPUT_POSTGRES_VM_SIZE:-shared-cpu-1x}"

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  if [ -n "$INPUT_POSTGRES" ]; then
    flyctl apps destroy "$postgres_app" -y || true
  fi
  exit 0
fi

# Create (using launch as create doesn't accept --region) the Fly app OR update the existing one.
if ! flyctl status --app "$app"; then
  flyctl launch --force-machines --copy-config --name "$app" --org "$org" --image "$image" --region "$region" --no-deploy
  flyctl ips allocate-v4 --app "$app" --region "$region" --shared
  flyctl ips allocate-v6 --app "$app"

  # if PostgreSQL is requested, create a PostgreSQL App then Deploy Application
  if [ -n "$INPUT_POSTGRES" ]; then
    if ! flyctl status --app "$postgres_app"; then
      db_output=$(flyctl postgres create --name "$postgres_app" --region "$region" --org "$org" --vm-size "$postgres_vm_size" --volume-size 1 --initial-cluster-size 2 | grep "Connection string")
      # Create additional PostgreSQL read replicas
      if [ -n "$INPUT_POSTGRES_CLUSTER_REGIONS" ]; then
        pg_machine_id=$(flyctl machine list -a $postgres_app --json | jq --raw-output  '.[0].id')

        # Creating the first replica on the same region to have at least one replica
        flyctl machine clone ${pg_machine_id} --region $region --app $postgres_app

        for cluster_region in $(echo $INPUT_POSTGRES_CLUSTER_REGIONS); do
          flyctl machine clone ${pg_machine_id} --region $cluster_region --app $postgres_app
        done
      fi

      flyctl postgres attach --app "$app" "$postgres_app" || true

      # Fix until Prisma can deal with IPv6 or Fly gives us something else
      # see https://github.com/prisma/prisma/issues/18079
      connection_string=$(echo $db_output | sed -e 's/[[:space:]]*Connection string:[[:space:]]*//g')
      new_connection_string=$(echo $connection_string | sed -e "s/\.flycast/.internal/g")
      bash -c "flyctl deploy --app "\""$app"\"" --image "\""$image"\"" --region "\""$region"\"" --env DATABASE_URL="\""$new_connection_string"\"" $(for secret in $(echo $INPUT_SECRETS | tr ";" "\n") ; do
        value="${secret}"
        echo -n "--env $secret='${!value}' "
      done)"
    fi
  else # If PostgreSQL is not requested, just deploy the application
    flyctl deploy --app "$app" --image "$image" --region "$region"
  fi

  # Set current secrets for future deployments as they are not persisted when used with --env above
  bash -c "flyctl secrets set --app "\""$app"\"" DATABASE_URL="\""$new_connection_string"\"" $(for secret in $(echo $INPUT_SECRETS | tr ";" "\n") ; do
    value="${secret}"
    echo -n " $secret='${!value}' "
  done) || true"

  # Scale the app to 2 instances
  app_machine_id=$(flyctl machine list -a $app --json | jq --raw-output  '.[0].id')
  flyctl machine clone ${app_machine_id} --region $region --app $app
else 
  # If the App already exists, deploy it again with secrets as they may have changed
  if [ "$INPUT_UPDATE" != "false" ]; then
    bash -c "flyctl deploy --app "\""$app"\"" --image "\""$image"\"" --region "\""$region"\"" --strategy rolling $(for secret in $(echo $INPUT_SECRETS | tr ";" "\n") ; do
      value="${secret}"
      echo -n "--env $secret='${!value}' "
    done)"

    # Still need to re-set secrets for future deployments as they are not persisted when used with --env above
    bash -c "flyctl secrets set --app "\""$app"\"" $(for secret in $(echo $INPUT_SECRETS | tr ";" "\n") ; do
      value="${secret}"
      echo -n " $secret='${!value}' "
    done) || true"
  fi
fi

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)

echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
