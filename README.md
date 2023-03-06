# PR Review Apps on Fly.io

This GitHub action wraps the Fly.io CLI to automatically deploy pull requests to [fly.io](http://fly.io) for review. These are useful for testing changes on a branch without having to setup explicit review environments.

This action will create, deploy, and destroy Fly apps. Just set an Action Secret for `FLY_API_TOKEN`.

If you have an existing `fly.toml` in your repo, this action will copy it with a new name when deploying. By default, Fly apps will be named with the scheme `pr-{number}-{repo_org}-{repo_name}`.

This Action is a fork from https://github.com/superfly/fly-pr-review-apps to accomodate Fewlines' needs. Please use the official action if you can.

## Inputs

| name                       | description                                                                                                                                                                                                            |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`                     | The name of the Fly app. Alternatively, set the env `FLY_APP`. For safety, must include the PR number. Example: `myapp-pr-${{ github.event.number }}`. Defaults to `pr-{number}-{repo_org}-{repo_name}`.               |
| `region`                   | Which Fly region to run the app in. Alternatively, set the env `FLY_REGION`. Defaults to `iad`.                                                                                                                        |
| `org`                      | Which Fly organization to launch the app under. Alternatively, set the env `FLY_ORG`. Defaults to `personal`.                                                                                                          |
| `path`                     | Path to run the `flyctl` commands from. Useful if you have an existing `fly.toml` in a subdirectory.                                                                                                                   |
| `postgres`                 | Optional set to true to add a Postgres cluster to your review app.                                                                                                                                                     |
| `postgres_cluster_regions` | Optional create a PG cluster by giving more region to set Read Replicas, separated by a space. The leader will always be on the FLY_REGION and have a Read Replica. (eg: "ams ams" will add two replicas in Amsterdam) |
| `pr_number`                | Optional set the number of the PR (this is useful in the case of a GitHub Action using `workflow_dispatch` for instance).                                                                                              |
| `event_type`               | Optional set the event_type of the PR (this is useful in the case of a GitHub Action using `workflow_dispatch` to specify a closed event for instance).                                                                |
| `update`                   | Whether or not to update this Fly app when the PR is updated. Default `true`.                                                                                                                                          |

## Required Secrets

`FLY_API_TOKEN` - **Required**. The token to use for authentication. You can find a token by running `flyctl auth token` or going to your [user settings on fly.io](https://fly.io/user/personal_access_tokens).

## Basic Example

```yaml
name: Review App
on:
  pull_request:
    types: [opened, reopened, synchronize, closed]

env:
  FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
  FLY_REGION: iad
  FLY_ORG: personal

jobs:
  review_app:
    runs-on: ubuntu-latest

    # Only run one deployment at a time per PR.
    concurrency:
      group: pr-${{ github.event.number }}

    # Create a GitHub deployment environment per review app so it shows up
    # in the pull request UI.
    environment:
      name: pr-${{ github.event.number }}
      url: ${{ steps.deploy.outputs.url }}

    steps:
      - uses: actions/checkout@v2

      - name: Deploy
        id: deploy
        uses: fewlinesco/fly-io-review-apps@v3.0
```

## Cleaning up GitHub environments

This action will destroy the Fly app, but it will not destroy the GitHub environment, so those will hang around in the GitHub UI. If this is bothersome, use an action like `strumwolf/delete-deployment-environment` to delete the environment when the PR is closed.

```yaml
on:
  pull_request:
    types: [opened, reopened, synchronize, closed]

# ...

jobs:
  review_app:
    # ...

    # Create a GitHub deployment environment per review app.
    environment:
      name: pr-${{ github.event.number }}
      url: ${{ steps.deploy.outputs.url }}

    steps:
      - uses: actions/checkout@v3

      - name: Deploy app
        id: deploy
        uses: fewlinesco/fly-io-review-apps@v3.0

      - name: Clean up GitHub environment
        uses: strumwolf/delete-deployment-environment@v2
        if: ${{ github.event.action == 'closed' }}
        with:
          # ⚠️ The provided token needs permission for admin write:org
          token: ${{ secrets.GITHUB_TOKEN }}
          environment: pr-${{ github.event.number }}
```

## Example with Postgres cluster

If you want to add a Postgres instance to your review app, you can set `postgres` to `true` and it will create a PG app for you, attach it to your review app and add its `DATABASE_URL`.

Keep in mind that it will be a brand new database, migrations and seeds is not managed by this Github Action.
However, having a separate database for your review apps help with isolation and avoid problems like running migrations in production when making a PR.

```yaml
# ...
steps:
  - uses: actions/checkout@v3

  - name: Deploy app
    id: deploy
    uses: fewlinesco/fly-io-review-apps@v3.0
    with:
      postgres: true
```

If you need a Postgres cluster for your review app, you can add regions to `postgres_cluster_regions` like so:

```yaml
# ...
steps:
  - uses: actions/checkout@v3

  - name: Deploy app
    id: deploy
    uses: fewlinesco/fly-io-review-apps@v3.0
    with:
      postgres: true
      region: cdg
      postgres_cluster_regions: "ams ams fra"
```

In this example, you would have a cluster of 5 databases instances with a leader in Paris (`cdg`) and 4 replicas: 1 in Paris (`cdg`) 2 in Amsterdam (`ams`) and 1 in Frankfurt (`fra`).
Note that the leader will always be on the `region` (which defaults to `cdg` if you omit it).

## Example with multiple Fly apps

If you need to run multiple Fly apps per review app, for example Redis, memcached, etc, just give each app a unique name. Your application code will need to be able to discover the app hostnames.

Redis example:

```yaml
steps:
  - uses: actions/checkout@v3

  - name: Deploy redis
    uses: fewlinesco/fly-io-review-apps@v3.0
    with:
      update: false # Don't need to re-deploy redis when the PR is updated
      path: redis # Keep fly.toml in a subdirectory to avoid confusing flyctl
      image: flyio/redis:6.2.6
      name: pr-${{ github.event.number }}-myapp-redis

  - name: Deploy app
    id: deploy
    uses: fewlinesco/ffly-io-review-apps@v3.0
    with:
      name: pr-${{ github.event.number }}-myapp-app
```
