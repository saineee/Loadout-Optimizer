# Loadout-Optimizer

A full-stack web app that pulls a player's showcased characters from the enka.network
API and shows their stats, weapons, and artifacts. It also has a built-in artifact
optimizer that scores and ranks artifacts in each slot based on a chosen build type,
and returns the best combination for that character.

## Why I built it

I've played Genshin Impact for six years, and I've used sites like enka.network and
akasha.cv the whole time. I wanted to build something of my own around a game I
actually care about.

The app itself is finished, but I'm still working on the infrastructure.

## Live demo

[Live app](http://13.218.149.143:5000)

The app runs as a single Fargate task with a public IP and no load balancer, so the
address changes every time the service redeploys. If the link is dead, the
[screenshots](#screenshots) below show the same thing. A load balancer would give it a
stable address, but it would cost more than the rest of the project combined.

## Features

- Look up any player by UID
- View the characters in a player's showcase, along with their equipped weapon and
  artifacts
- Find the best artifact in each slot for a chosen build with the optimizer
- Data is synced from the enka.network API and saved in PostgreSQL, so it persists
  between sessions
- Card-based UI

## Tech stack

| Area           | What I used                                    |
|----------------|------------------------------------------------|
| Web app        | Flask, Jinja2 templates, Gunicorn              |
| Data           | PostgreSQL, SQLAlchemy ORM, Pydantic           |
| Optimizer      | Pandas                                         |
| Testing        | pytest                                         |
| Infrastructure | Docker, Terraform, AWS (ECR, ECS Fargate, RDS, SSM Parameter Store, CloudWatch) |
| CI/CD          | GitHub Actions with OIDC                       |

A few of these choices are worth explaining:

- **Pandas** lets the optimizer score every artifact at once by applying the build
  formulas to a whole DataFrame, instead of looping through artifacts one by one.
- **Pydantic** checks the raw API data and enforces types before anything is saved,
  so bad data from the API gets caught early.
- **SQLAlchemy** handles all the inserts and upserts, so there's no raw SQL in the app.
- **Flask** is small and simple, which is all a project this size needs.

## Infrastructure

All AWS resources for this project are defined in Terraform, 14 in total. State is
stored in S3 with native S3 locking. I created the state bucket by hand, because
Terraform can't manage the bucket that holds its own state.

### Task definition ownership

Terraform doesn't manage the task definition. The pipeline registers a new revision
on every deploy, so if Terraform managed it too, every deploy would show up as drift.
The ECS service uses `ignore_changes` on the task definition field, so Terraform owns
everything about the service except which revision is currently running.

### Secrets

`DATABASE_URL` isn't in the repo, the task definition, or Terraform state. It's stored
in SSM Parameter Store as a SecureString and injected into the container when it
starts. The database password is set with a write-only argument, so Terraform sends
it to AWS without ever saving it.

### IAM roles

There are three IAM roles, and each one only does one job:

| Role                     | Used by                          | Can do                                                    |
|--------------------------|----------------------------------|-----------------------------------------------------------|
| `GHAuth`                 | The deploy job on `master`       | Push to this ECR repo and update this ECS service          |
| `genshin-task-exec-role` | The running container            | Read `/genshin/*` from Parameter Store and write logs     |
| `ciPlanRole`             | The plan job on pull requests    | Read only                                                  |

The container uses its own execution role instead of the account-wide
`ecsTaskExecutionRole`. Another one of my projects uses that shared role, and giving
it permission to read this app's secret would have let that unrelated app read this
database's password too.

### Database and container security

The database has no public IP and isn't reachable from the internet. Its security
group only accepts traffic on port 5432 from the app's security group. Because the
rule references the security group instead of an IP address, it still works when
Fargate gives the task a new IP. Storage is encrypted at rest.

The container runs as an unprivileged user and can't write to its own application
directory.

## CI/CD

Merging to `master` deploys the app automatically. The pipeline runs these steps:

1. **Compile and test.** `compileall` checks that every Python file parses, and then
   pytest runs. The compile step is there because no test imports `app.py`, so
   without it, a syntax error in that file could make it all the way to production.
2. **Authenticate.** The runner gets a signed token from GitHub and exchanges it with
   AWS for credentials that expire after an hour.
3. **Build and push.** The image is pushed to ECR and tagged with the commit SHA, so I
   can always tell exactly which code a container is running. A lifecycle policy
   deletes everything except the 10 most recent images.
4. **Deploy.** The pipeline pulls the current task definition, swaps in the new image,
   registers it as a new revision, and points the service at it.

Merges that only change docs, Terraform, or the compose file skip the build, since
there's nothing new to put in an image.

### Automatic rollback

The container has a health check, and the ECS service has the deployment circuit
breaker enabled with rollback. If a new container starts but can't serve requests,
it fails the health check, the deployment fails, and ECS switches the service back to
the last working revision.

### Pull requests

Pull requests run the tests and a `terraform plan`, so any infrastructure change
shows its full diff before it's merged. I left `terraform apply` out of CI on
purpose. Running apply would need permission to create IAM roles, and a role that
can create IAM roles can give itself any permission it wants.

### OIDC trust policies

Both roles' trust policies are restricted by the OIDC subject claim. The deploy role
only accepts tokens from `master`, and the plan role only accepts tokens from pull
requests. Neither one can be assumed from any other repo or branch.

## Running locally

1. Clone the repo:

```bash
   git clone https://github.com/saineee/genshin_app.git
   cd genshin_app
```

2. Copy the example environment file and fill it in:

```bash
   cp .env.example .env
```

   `POSTGRES_PASSWORD` can be anything, since Docker uses it to create the local
   database on the first run. You only need `DATABASE_URL` if you want to run pytest
   or `sync.py` directly on your machine instead of through Docker Compose.

3. Start everything with Docker Compose:

```bash
   docker compose up --build
```

4. Open `http://localhost:5000`.

To load data, enter the UID of a Genshin player who has a public character showcase.

## Screenshots

### Homepage

![Homepage](screenshots/homepage.png)

### Character view

![Character view](screenshots/character_view.png)

### Optimizer

![Optimizer](screenshots/optimizer.png)

## Cost

Everything runs in us-east-1 and costs about $13 a month.

| Item                    | Monthly cost | Notes                                              |
|-------------------------|--------------|----------------------------------------------------|
| Fargate                 | ~$9          | 0.25 vCPU and 0.5 GB of memory, running 24/7        |
| Public IPv4 address     | $3.65        |                                                    |
| ECR                     | Almost $0    | Kept small by the lifecycle policy                 |
| CloudWatch Logs         | Almost $0    | Under 1 MB, with 14-day retention                  |
| Parameter Store and KMS | $0           | Standard tier and AWS-managed keys are free        |
| RDS                     | $0 for now   | db.t3.micro with 20 GB, about $15 after the free tier |

Once the RDS free tier ends, the total will be closer to $28 a month.

If this ever had real users, the first two things I'd change are putting a load
balancer in front of the task instead of giving it a public IP, and shutting the
service down overnight on a schedule.

## Known limitations

### Pydantic only validates one write path

`sync.py`, the CLI, validates data through `schemas.py`, but the `/characters` web
route doesn't. The two paths are different on purpose: the CLI inserts and skips
duplicates, while the web route upserts. Still, only one of them is validated.

### The web entrypoint isn't tested

`app.py` calls `create_all` when it's imported, so it can't be imported without a
live database. Because of that, no test imports it, and the web entrypoint has no
test coverage. The `compileall` step in CI catches syntax errors in it, but nothing
else.

### No database migrations

The schema is created with `create_all` at startup, so changing a model on an
existing database means writing the DDL by hand.

### The optimizer ignores set bonuses

The optimizer picks the highest-scoring artifact for each slot separately. That isn't
always the same as the best five-piece combination, because it doesn't account for
set bonuses.

### Single task with no load balancer

To keep costs down, the app runs as a single task without a load balancer. That
means the public IP changes on every deploy, and there's a short outage during each
deployment.

### The health check doesn't check the database

The health check hits a route that renders a static template. A passing check means
the app is serving requests, but not that it can reach the database.

## License

[MIT](LICENSE)
