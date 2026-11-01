# Loadout-Optimizer

A full-stack web app that pulls a player's showcased characters from the enka.network
API and shows their stats, weapons, and artifacts. It also has a built-in artifact
optimizer that scores and ranks artifacts in each slot based on a chosen build type,
and returns the best combination for that character.

## Why I built it

I've played Genshin Impact for six years, and I've used sites like enka.network and
akasha.cv the whole time. I wanted to build something of my own around a game I
actually care about.

The app itself is finished. Everything I've worked on since then has been the
infrastructure around it.

## Where it runs

There's no permanent deployment right now. The app used to run on ECS Fargate with an
RDS database, and I took that down in September 2026. Now it runs in two places:

- Locally with Docker Compose
- On a two-node k3s cluster on EC2, which I create at the start of a work session and
  destroy at the end

Since the cluster only exists while I'm working on it, there's no live link. The
[screenshots](#screenshots) below show what the app looks like.

## Features

- Look up any player by UID
- View the characters in a player's showcase, along with their equipped weapon and
  artifacts
- Find the best artifact in each slot for a chosen build with the optimizer
- Data is synced from the enka.network API and saved in PostgreSQL, so it persists
  between sessions
- Card-based UI

## Tech stack

| Area           | What I used                                                        |
|----------------|--------------------------------------------------------------------|
| Web app        | Flask, Jinja2 templates, Gunicorn                                  |
| Data           | PostgreSQL, SQLAlchemy ORM, Pydantic                               |
| Optimizer      | Pandas                                                             |
| Testing        | pytest                                                             |
| Infrastructure | Docker, Terraform, Ansible, Kubernetes (k3s), ingress-nginx, AWS (EC2, VPC, ECR, IAM) |
| CI/CD          | GitHub Actions with OIDC                                           |

A few of these choices are worth explaining:

- **Pandas** lets the optimizer score every artifact at once by applying the build
  formulas to a whole DataFrame, instead of looping through artifacts one by one.
- **Pydantic** checks the raw API data and enforces types before anything is saved,
  so bad data from the API gets caught early.
- **SQLAlchemy** handles all the inserts and upserts, so there's no raw SQL in the app.
- **Flask** is small and simple, which is all a project this size needs.

## Infrastructure

Everything is defined in Terraform, split across three roots. Each root has its own
state file in the same S3 bucket, with native S3 locking. I created the state bucket by
hand, because Terraform can't manage the bucket that holds its own state.

| Root             | What it holds                                         | How long it lives                  |
|------------------|-------------------------------------------------------|------------------------------------|
| `terraform-k3s/` | The cluster: VPC, subnets, security group, two EC2 instances | Applied and destroyed every session |
| `terraform-ci/`  | The IAM role the pipeline uses for `terraform plan`  | Applied once, never destroyed      |
| `terraform/`     | The old ECS and RDS setup                             | Not applied anymore                |

The roots are split by how long their resources live. The CI role has to exist all the
time, and the cluster gets destroyed every session, so if the role were in the same root
as the cluster, every `terraform destroy` would delete it.

`terraform/` is kept for reference. Its state still holds one real resource, the ECR
repository the cluster pulls the app image from. Applying that root would rebuild the
whole ECS setup, so I don't.

### The cluster

`terraform-k3s/` doesn't use modules. It creates:

- A VPC at `10.0.0.0/16` with two public subnets, in us-east-1a and us-east-1b
- An internet gateway and a route table
- One security group
- An SSH key pair
- Two `t3.small` Ubuntu 24.04 instances, named `server` and `agent`

The two instances are separate resources instead of one resource with `count`, so
Ansible can tell which one is which.

The security group allows SSH, HTTP, and the Kubernetes API (6443) from my IP only.
Between the two nodes it allows 6443, the kubelet port (10250), and 8472/udp, which
flannel uses to carry Pod traffic from one node to the other. Those rules reference the
security group itself instead of an IP, so they keep working when the nodes get new
addresses.

### Ansible

`ansible/` turns the two bare instances into a k3s cluster. The inventory comes from
EC2 tags, so no IP address is written down anywhere. The playbook runs two roles in
order:

1. **Server.** Installs k3s with Traefik turned off, so ingress-nginx can use port 80.
   It adds the server's public IP to the API certificate, then copies the kubeconfig
   to my machine with the public IP filled in, so I can run `kubectl` from my laptop.
2. **Agent.** Reads the join token that the server role saved and uses it to join the
   cluster. This is why the server role has to run first.

Both installs use the k3s install script, which Ansible doesn't have a module for, so
they're `shell` tasks. Each one has a `creates:` check that points at a file the
installer writes, so a second run skips the install. I tested this by running the
playbook twice in a row and checking that the second run reported `changed=0`.

## Kubernetes

The manifests are in `k8s/`:

| Path                     | What it is                                                         |
|--------------------------|--------------------------------------------------------------------|
| `k8s/ingress-nginx.yaml` | The ingress-nginx controller, copied unchanged from its v1.15.1 release |
| `k8s/postgres/`          | Postgres Deployment, Service, and Secret                           |
| `k8s/app/`               | App Deployment, Service, Ingress, and the Secret with `DATABASE_URL` |

A request goes from the browser to ingress-nginx on port 80, then through the Ingress
to the app's Service, then to the app Pod on port 5000. The app reaches the database
through the `postgres` Service name.

There's no AWS load balancer. The controller's Service is type `LoadBalancer`, and k3s
handles that with its own built-in load balancer, which listens on port 80 on every
node. That means either node's public IP works.

### Secrets

The real Secret files are in `.gitignore`, and each one has a `.yaml.example` file next
to it with fake values. The examples don't end in `.yaml` on purpose. `kubectl apply -R`
applies every `.yaml` file it finds, and the examples use the same Secret names as the
real ones, so applying them would overwrite the real password with the fake one.

The ECR pull secret isn't a file at all. ECR login tokens expire after 12 hours, so I
create it from the CLI each session instead.

### Storage

Postgres stores its data in an `emptyDir` volume. That's a folder on the node that gets
deleted when the Pod goes away, so the database starts empty every time the Pod is
replaced or the cluster is rebuilt. I did this on purpose. The cluster gets destroyed at
the end of every session anyway, and all the data can be pulled from the enka.network
API again by entering a UID.

### Readiness and rollouts

The app has a readiness probe that sends a request to `/` every 10 seconds. The Pod
doesn't get any traffic until the probe passes.

I tested two failure cases:

- **Bad deploy.** I changed the image to a tag that doesn't exist. The new Pod couldn't
  pull the image and never became ready, so the old Pod kept serving the whole time.
  `kubectl rollout undo` put the old version back.
- **Pod deleted.** I deleted the app Pod. The Deployment started a replacement right
  away, and the site was down for about 10 seconds while it started and passed the
  readiness probe. With one replica, nothing else can serve traffic during that time.

### Running it on the cluster

After `terraform apply` in `terraform-k3s/` and the playbook in `ansible/`, from the
repo root:

```bash
kubectl apply -f k8s/ingress-nginx.yaml
kubectl wait -n ingress-nginx --for=condition=available deploy/ingress-nginx-controller --timeout=180s
kubectl create secret docker-registry ecr-repo --docker-server <account-id>.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username AWS --docker-password "$(aws ecr get-login-password)"
kubectl apply -R -f k8s/
```

The controller goes first because it checks every Ingress before it's saved, so an
Ingress applied before the controller is running gets rejected. The app Pod usually
restarts once at startup, because it tries to create its tables before Postgres is
accepting connections. The restart fixes it.

## CI/CD

`.github/workflows/pipeline.yml` has three jobs:

1. **Test.** Runs on every push to `master` and every pull request. `compileall` checks
   that every Python file parses, and then pytest runs. The compile step is there
   because no test imports `app.py`, so without it, a syntax error in that file would
   get past the tests. This is the only check required to merge.
2. **Plan.** Runs on pull requests. It runs `terraform plan` against `terraform-k3s/`,
   so any change to the cluster shows its diff before it's merged. It runs with
   `-lock=false`, so the role doesn't need write access to the state bucket. My IP is in
   a gitignored file, so the job uses a documentation address (`192.0.2.1/32`) instead.
   Because of that, the plan always shows the security group rules changing while the
   cluster is up. That's expected and isn't drift.
3. **Deploy.** Turned off with `if: false`. It used to build the image, push it to ECR,
   and deploy it to ECS. I kept it in the file in case ECS comes back.

I left `terraform apply` out of CI on purpose. Running apply would need permission to
create IAM roles, and a role that can create IAM roles can give itself any permission
it wants.

### OIDC

The plan job gets its AWS credentials through OIDC, so there are no AWS keys stored in
GitHub. The runner gets a signed token from GitHub and exchanges it with AWS for
credentials that expire after an hour. The role it assumes is read only.

The role's trust policy only accepts tokens from pull requests in this repo. It matches
on the numeric IDs of my account and the repo, not just their names, because the IDs
are what GitHub actually puts in the token. A trust policy with only the names was
denied even though it looked right, and I found the real value in CloudTrail. Matching
on the IDs also means renaming the repo won't break it. I renamed this repo from
`genshin_app` in October 2026.

## Running locally

1. Clone the repo:

```bash
   git clone https://github.com/saineee/Loadout-Optimizer.git
   cd Loadout-Optimizer
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

Everything runs in us-east-1. The cluster only costs money while it's up.

| Item                      | Cost              | Notes                                      |
|---------------------------|-------------------|--------------------------------------------|
| Two t3.small instances    | About 4 cents/hr  | Only while the cluster is up               |
| Two public IPv4 addresses | 1 cent/hr         | Only while the cluster is up               |
| ECR                       | Almost $0         | A lifecycle policy keeps the last 10 images |
| S3 state bucket           | Almost $0         |                                            |

With the cluster down, the project costs close to nothing. When it ran on ECS and RDS,
it cost about $13 a month, and it would have been closer to $28 once the RDS free tier
ended.

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

### The database doesn't keep its data

Postgres uses `emptyDir`, so the data is gone whenever the Pod is replaced. See
[Storage](#storage) for why.

### One replica

The app runs as a single Pod, so it's down for about 10 seconds whenever that Pod is
replaced. The app doesn't keep any state of its own, so a second replica would fix
this. I haven't added one.

### No HTTPS

The app is served over plain HTTP on port 80, and port 443 isn't open. Some browsers
switch to HTTPS on their own, so the address has to be typed with `http://`.

### The readiness probe doesn't check the database

The probe hits a route that renders a static template. A passing probe means the app
is serving requests, but not that it can still reach the database. The app can't
start without the database, though, since it creates its tables at startup.

## License

[MIT](LICENSE)
