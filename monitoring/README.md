# Lork Monitoring (Prometheus + Grafana)

Lork doesn't have a `/metrics` endpoint, but it does report its state as JSON on
`/api/v1/health` and `/api/v1/proxy-stats`. This folder runs a few small exporters that
turn that JSON into Prometheus metrics, plus a ready-made Grafana dashboard and alert
rules. **Lork itself needs no changes.**

What you can see:

- **Health**: whether Lork is up, how fast its health endpoint responds, uptime and restarts
- **Browser pool**: how many browser instances are running
- **Auths**: how many requests returned `SUCCESS`, `INVALID`, `BANNED`, `TIMEOUT` or `ERROR`, as totals, per minute and as a success rate
- **Proxies**: active, rate-limited and dead counts, plus successes, failures and success rate for each proxy
- **Relay traffic**: bytes sent and received, and connections opened, open and failed
- **Log errors**: warnings and errors Lork logs, and the stuck-browser failures the watchdog restarts Lork for
- **Container**: Lork's memory and CPU use (from cAdvisor)

It also has [`lork-watchdog.sh`](#watchdog-temporary-workaround), a script that restarts
Lork when it gets stuck. It's separate from the exporters, so you can run it on its own.

---

## Pick a route

| | **Route A: Full stack** | **Route B: Exporters only** |
|---|---|---|
| **Use it if** | You have no Prometheus or Grafana yet | You already run Prometheus, or VictoriaMetrics with vmagent (e.g. Zapdos), plus Grafana |
| **What it runs** | Exporters, Prometheus and Grafana | Exporters only |
| **Scrape config** | Already set up | You add 4 jobs to your existing config |
| **Dashboard** | Loaded automatically | You import it once |
| **Alerts** | Loaded automatically | Optional; you add them to your own alerting |

Both routes use the same exporters and the same dashboard. First do
[Before you start](#before-you-start), then follow either [Route A](#route-a-full-stack)
or [Route B](#route-b-existing-prometheus-or-victoriametrics).

---

## Before you start

**1. Lork must listen on port 5090 inside its container.**
The Lork image's Docker health check always calls `localhost:5090`. If you change
`LORK_SERVER_PORT` or `server.port`, Docker will mark Lork **unhealthy** even though it's
working, and the exporters won't find it either. To use a different port, change only the
**host** side of the port mapping:

```yaml
# Lork's docker-compose.yml
    ports:
      - "127.0.0.1:5070:5090"   # host 5070 -> container 5090. Only change the left-hand number.
```

Check the health status with `docker ps`: Lork should show `(healthy)`.

**2. Find Lork's Docker network.** The exporters join it so they can reach Lork as `http://lork:5090`:

```bash
docker inspect $(docker ps -qf name=lork-1) -f '{{json .NetworkSettings.Networks}}' | jq 'keys'
# e.g. ["lork_default"]
```

If it isn't `lork_default`, set `LORK_NETWORK` when you start the exporters (shown below).

**3. Put this folder next to Lork's compose file**, for example `~/Lork/monitoring`.

> [!IMPORTANT]
> Always run `docker compose` **from inside `monitoring/`**. This folder's compose file is
> called `compose.yaml` so that `docker compose down` here stops only the monitoring
> containers and never Lork.

---

## Route A: Full stack

This runs everything: exporters, Prometheus (30 days of history) and Grafana with the
dashboard already set up.

```bash
cd monitoring
docker compose --profile stack up -d
# If the network isn't lork_default:
# LORK_NETWORK=<network> docker compose --profile stack up -d
```

Then:

1. Open Grafana at **http://127.0.0.1:3000** and log in as `admin` / `admin`. Grafana asks you to set a new password.
2. Open **Dashboards → Lork → Lork**.
3. Optionally, check that Prometheus is collecting data at **http://127.0.0.1:9090/targets**. All five targets should be **UP**.

Grafana and Prometheus only listen on `127.0.0.1`. On a remote server, use an SSH tunnel:

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 user@your-server
```

To expose them on your network instead, remove the `127.0.0.1:` prefix from their `ports:`
lines in `compose.yaml`. Only do this behind a firewall or reverse proxy.

The alert rules in `alerts.yml` are loaded automatically. You can see them under
**Alerts** in Prometheus. To get notifications, connect an Alertmanager or use Grafana
alerting.

---

## Route B: Existing Prometheus or VictoriaMetrics

This runs only the exporters. Your existing scraper collects from them, and your existing
Grafana shows the data.

### 1. Start the exporters

```bash
cd monitoring
docker compose up -d
# If the network isn't lork_default:
# LORK_NETWORK=<network> docker compose up -d
```

If you already run cAdvisor, delete the `cadvisor` service from `compose.yaml` first.

Check they can reach Lork:

```bash
curl -s 'http://127.0.0.1:7979/probe?module=health&target=http://lork:5090/api/v1/health'
# expect: lork_browser_instances 2, lork_proxies_total ..., lork_uptime_seconds ...

curl -s 'http://127.0.0.1:9115/probe?module=lork_health&target=http://lork:5090/api/v1/health' | grep probe_success
# expect: probe_success 1
```

mtail reads Lork's logs rather than its API, so it needs a separate check — see
[Auth counters](#auth-counters-mtail).

### 2. Choose the scrape address

The exporters are published on the host at `127.0.0.1:7979` (json), `127.0.0.1:9115`
(blackbox), `127.0.0.1:3903` (mtail) and `127.0.0.1:8081` (cAdvisor). Whether your scraper can use those addresses
depends on where it runs:

| Your Prometheus or vmagent runs... | Address to use in `scrape-jobs.yml` |
|---|---|
| On the host, or in Docker with `network_mode: host` | `127.0.0.1`, unchanged |
| In a normal Docker container on the same host | `host.docker.internal`, and add `extra_hosts: ["host.docker.internal:host-gateway"]` to its service |
| On another machine | The Lork server's IP, and remove `127.0.0.1:` from the exporter `ports:` in `compose.yaml` |

To check how a containerised scraper is networked:

```bash
docker inspect <prometheus-or-vmagent-container> -f '{{.HostConfig.NetworkMode}}'
```

Only edit the `127.0.0.1:…` addresses. Leave the `http://lork:5090/...` targets as they
are, because the exporters fetch those, not your scraper.

### 3. Add the scrape jobs

`scrape-jobs.yml` has three jobs (`lork_api`, `lork_health`, `cadvisor`) that go under
`scrape_configs:` in your existing config.

Find your config file. For vmagent (e.g. Zapdos) or Prometheus in Docker, it's the file
passed as `-promscrape.config=` (vmagent) or `--config.file=` (Prometheus):

```bash
docker inspect <container> -f 'args={{json .Args}}  mounts={{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}'
```

The `mounts` output shows where that file is on the host. Back it up and append the jobs.
This assumes `scrape_configs:` is the **last** section in the file and its jobs are
indented with two spaces (`  - job_name:`):

```bash
cp prometheus.yml prometheus.yml.bak
grep -v '^#' /path/to/monitoring/scrape-jobs.yml >> prometheus.yml
```

If your file is laid out differently, paste the three jobs under `scrape_configs:` by hand.

### 4. Validate and reload

**VictoriaMetrics / vmagent** (e.g. Zapdos):

```bash
docker exec vmagent /vmagent-prod -dryRun -promscrape.config=/etc/prometheus/prometheus.yml
# expect: "all the configs are ok"
curl -X POST http://127.0.0.1:8429/-/reload     # use vmagent's -httpListenAddr

curl -s http://127.0.0.1:8429/targets | grep -E 'lork|cadvisor'
# expect four targets with state=up: lork_api x2, lork_health, cadvisor
```

**Prometheus:**

```bash
docker exec <prometheus> promtool check config /etc/prometheus/prometheus.yml
curl -X POST http://127.0.0.1:9090/-/reload     # needs --web.enable-lifecycle, otherwise restart the container
```

Then open `http://<prometheus>:9090/targets` and check that the four Lork targets are **UP**.

If validation fails, restore the backup (`cp prometheus.yml.bak prometheus.yml`) and look
at the error.

### 5. Import the dashboard

In Grafana, go to **Dashboards → New → Import**, upload `grafana/dashboards/lork.json`,
and pick your datasource in the **Prometheus** dropdown at the top of the dashboard.
A VictoriaMetrics datasource works too, because VictoriaMetrics accepts the same queries
(PromQL).

### 6. Alerts (optional)

`alerts.yml` is a standard Prometheus rules file:

- **Prometheus:** add it under `rule_files:` and reload.
- **VictoriaMetrics:** vmagent only collects metrics and doesn't evaluate rules. Run
  **vmalert** with `-rule=alerts.yml`, or recreate the rules as Grafana alerts.

| Alert | Fires when |
|---|---|
| `LorkDown` | The health check has failed for 2 minutes |
| `LorkNoActiveProxies` | No usable proxies for 5 minutes |
| `LorkProxyFailing` | A proxy fails more than half of its auths over 30 minutes, with at least 5 failures |
| `LorkAuthSuccessRateLow` | Fewer than half of all auth requests returned 200 over 30 minutes, with at least 10 failures (needs mtail) |
| `LorkAuthsBanned` | 5 or more auths came back `418 BANNED` within 15 minutes (needs mtail) |
| `LorkBrowserStuck` | 3 or more dead DevTools connections in 5 minutes, or 5 or more login page timeouts in 10 minutes (needs mtail) |
| `LorkMemoryHigh` | The Lork container has used more than 3.5 GB for 10 minutes (the example compose limit is 4 GB) |

---

## Auth counters (mtail)

Lork has no counter for auth results, but it logs one line per finished request:

```
21:25:01 | SUCCESS  |              API | -    | 200 OK: successful auth
```

`mtail/lork.mtail` turns those lines into `lork_auth_results_total{status="..."}`. It
keys off the HTTP status code, which maps one-to-one to Lork's auth status:

| Code | `status` |
|---|---|
| `200` | `SUCCESS` |
| `400` | `INVALID` |
| `418` | `BANNED` |
| `408` | `TIMEOUT` |
| `500` | `ERROR` |

It also counts two other things from the same logs:

- `lork_log_lines_total{level,module}`: every Lork log line, by level (`INFO`, `WARNING`, `ERROR`, ...) and module (`API`, `BrowserAuth`, ...). The **Warnings and errors per minute** panel shows the `WARNING` and above.
- `lork_devtools_connect_failed_total` and `lork_page_load_timeouts_total`: the two failures [`lork-watchdog.sh`](#watchdog-temporary-workaround) restarts Lork for, using the watchdog's own patterns. The **Watchdog triggers per minute** panel shows them.

The `mtail` service reads Docker's JSON log files directly, so **Lork needs no config
change** — no log file to mount, no restart. It does mean:

- **Linux hosts only**, and only with the default `json-file` logging driver. On Docker
  Desktop, remove the service; the auth panels will be empty. (`docker inspect -f
  '{{.HostConfig.LogConfig.Type}}' <lork container>` should print `json-file`.)
- mtail starts reading at the end of the log, so counts begin at zero when it starts.
- The counters reset when mtail restarts. The dashboard uses `rate()` / `increase()`,
  which handle that.

### Check it works

```bash
cd monitoring
docker compose up -d mtail
curl -s 127.0.0.1:3903/metrics | grep lork_auth
```

Straight after starting, that grep returns **nothing** — mtail begins at the end of each
log and only creates a counter once a line matches, so `lork_auth_results_total` does not
exist until the first auth. That is normal, not a failure. After a few auths:

```
lork_auth_results_total{prog="lork.mtail",status="SUCCESS"} 3
```

If nothing appears, run the patterns over the existing logs instead of waiting for new
ones — `-one_shot` reads every log from the start, prints the totals and exits:

```bash
docker compose run --rm mtail \
  -one_shot -one_shot_format=prometheus -progs=/etc/mtail \
  -logs='/var/lib/docker/containers/*/*-json.log' | grep lork_auth
```

A count of zero there means the patterns don't match your log lines. Print the result
lines to compare against — the `sed` strips the colour codes Lork writes, which would
otherwise make the output hard to read:

```bash
docker compose -f ../docker-compose.yml logs --no-log-prefix --tail 2000 lork \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -E '\| *[0-9]{3} [A-Z]'
```

Every pattern in `lork.mtail` needs an `API` field in the line and the status code
straight after the last `|`. The patterns allow for colour codes and for Docker's JSON
wrapper, so write them against the *uncoloured* layout above. Edit them to match, then
check they still compile before restarting:

```bash
docker compose run --rm mtail -compile_only -progs=/etc/mtail && docker compose restart mtail
```

### Then check your scraper sees it

`lork_auth_results_total` only exists once an auth has been counted, so query the scrape
health instead — this works even with no auth traffic:

```promql
up{job="lork_logs"}
```

A `1` means the job is scraping mtail. Prometheus shows the target under
**Status → Targets**; vmagent lists it at `http://127.0.0.1:8429/targets`. Note that a
fresh target takes one `scrape_interval` to produce its first sample, so an empty result
right after a reload usually just means you queried too early.

> **Status of the patterns.** The `SUCCESS` pattern is verified against real Lork output.
> The `INVALID`, `BANNED`, `TIMEOUT` and `ERROR` patterns assume failures follow the same
> layout with a different code, which has not yet been confirmed against a real failing
> line. If your failure counts stay at zero while auths are visibly failing, that is the
> first thing to check.
>
> `lork_log_lines_total` assumes every Lork line starts `HH:MM:SS | LEVEL | Module |`,
> as the `SUCCESS` line above does. If `INFO` lines are being counted, the layout is right.

---

## Disk usage

Nothing in this folder deletes anything, and **Docker's default `json-file` driver keeps
container logs forever**. Lork writes a line per auth, so on a busy instance that file is
the thing most likely to fill your disk. mtail only reads it; it neither rotates nor
truncates.

Lork's own `logging.rotation` and `logging.retention` settings do *not* help here — they
apply to `logging.file`, which is `null` by default. With Lork logging to stdout, Docker
owns the file.

Check what you're using now:

```bash
sudo du -ch /var/lib/docker/containers/*/*-json.log | sort -h | tail -5
```

### Cap it

`compose.yaml` here already caps every monitoring service at 3 x 10 MB. Lork itself is the
one that matters, so add the same to **Lork's** `docker-compose.yml`:

```yaml
services:
  lork:
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
```

That keeps roughly the last 250 MB and lets Docker discard the rest. Apply it:

```bash
cd ~/Lork
docker compose up -d --force-recreate lork
```

A plain `restart` will **not** pick this up — logging options are fixed when the container
is created. Recreating also discards the old container's log file, which reclaims the
space immediately.

To cap every container on the host instead, including ones you add later, put the same
options in `/etc/docker/daemon.json` under `log-driver` / `log-opts` and restart the Docker
daemon. That restarts everything on the box, so it's the more disruptive option.

### Reclaim space without restarting Lork

If a log is already large and you don't want downtime:

```bash
sudo truncate -s 0 /var/lib/docker/containers/<container-id>/<container-id>-json.log
```

mtail detects the truncation and carries on from the new start of file. Its counters are
held in memory, so they are unaffected.

### What mtail does with rotation

When Docker rotates, the current file is renamed and a new one takes its place. mtail
follows the new file — the glob in `compose.yaml` matches only `*-json.log`, not the
rotated `*-json.log.1`, so rotated content is not re-counted. Lines written in the instant
between rotation and mtail reopening the file can be missed, which is a handful of auths
at worst.

mtail itself stores nothing on disk. Its counters live in memory and reset when the
container restarts.

---

## Watchdog (temporary workaround)

`lork-watchdog.sh` is a temporary workaround for
[issue #1](https://github.com/The-Treeline-Project/Lork-Releases/issues/1). It follows
Lork's logs and restarts the container if Lork gets stuck in either of these ways:

- **Dead browser connection:** a browser slot keeps trying to reconnect to a DevTools port that has closed (`Connect call failed ('127.0.0.1', <port>)`).
- **Login page stall:** every PTC login page load times out (`Page load timed out`) and no browser gets past the login page.

It runs on the host, not in Docker, and is separate from the exporters: you can use it
with or without the rest of this folder. By default it restarts Lork using the compose file
in the **parent** folder, so with this folder at `~/Lork/monitoring` it restarts the Lork
in `~/Lork`. Make it executable and check that it runs:

```bash
cd ~/Lork/monitoring
chmod +x lork-watchdog.sh
./lork-watchdog.sh        # should print "Watching 'lork' in /home/<user>/Lork ..."; Ctrl+C to stop
```

If it prints `.../Lork/monitoring` instead, set `COMPOSE_DIR` to Lork's folder.

The user running it must be able to use Docker without `sudo`, i.e. be in the `docker` group.

These environment variables are optional:

| Variable | Default | Meaning |
|---|---|---|
| `COMPOSE_DIR` | The folder above the script | Folder containing Lork's `docker-compose.yml` |
| `SERVICE` | `lork` | Compose service name |
| `THRESHOLD` / `WINDOW` | `5` / `120` | Restart after this many refused DevTools connections within this many seconds |
| `STALL_THRESHOLD` | `8` | Restart after this many page load timeouts in a row with no progress |
| `COOLDOWN` | `180` | Seconds to ignore errors after a restart |

Every restart shows up on the dashboard: the **Watchdog triggers per minute** panel
climbs in the minutes before it, and **Uptime** drops to zero. The `LorkBrowserStuck`
alert fires on the same failures, so you can use it with or without the watchdog.

Run the script under **one** of the options below so it keeps running after you log out
and starts again after a reboot. Don't run both, or they'll both restart Lork.

### Option 1: systemd

Create `/etc/systemd/system/lork-watchdog.service`. Replace `<user>` and the paths with
your own:

```ini
[Unit]
Description=Lork watchdog
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=<user>
WorkingDirectory=/home/<user>/Lork
Environment=COMPOSE_DIR=/home/<user>/Lork
ExecStart=/home/<user>/Lork/monitoring/lork-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now lork-watchdog
systemctl status lork-watchdog
journalctl -u lork-watchdog -f        # follow its log
```

To stop it: `sudo systemctl disable --now lork-watchdog`.

### Option 2: PM2

For machines that already use [PM2](https://pm2.keymetrics.io/) to run other tools:

```bash
cd ~/Lork
COMPOSE_DIR=$PWD pm2 start ./monitoring/lork-watchdog.sh --name lork-watchdog --interpreter bash
pm2 save                               # remember it across restarts
pm2 startup                            # first time only: run the command it prints to start PM2 on boot
pm2 logs lork-watchdog                 # follow its log
```

To stop it: `pm2 delete lork-watchdog && pm2 save`. After changing an environment
variable, run `pm2 restart lork-watchdog --update-env`.

---

## Metrics reference

| Metric | Type | Source |
|---|---|---|
| `probe_success{job="lork_health"}` | gauge | 1 when `/health` returns 200 with `"status":"healthy"` |
| `probe_duration_seconds{job="lork_health"}` | gauge | Health endpoint response time |
| `lork_uptime_seconds` | gauge | `/health` → `uptime_seconds` |
| `lork_browser_instances` | gauge | `/health` → `instances` |
| `lork_proxies_total` / `_active` / `_rate_limited` / `_dead` | gauge | `/health` → `proxies.*` |
| `lork_auth_results_total{status}` | counter | Lork's log lines, via mtail — `status` is `SUCCESS`, `INVALID`, `BANNED`, `TIMEOUT` or `ERROR` |
| `lork_log_lines_total{level,module}` | counter | Lork's log lines, via mtail |
| `lork_devtools_connect_failed_total` | counter | `Connect call failed ('127.0.0.1', <port>)` log lines, via mtail |
| `lork_page_load_timeouts_total` | counter | `BrowserAuth ... Page load timed out` log lines, via mtail |
| `lork_proxy_successes{host,port}` | counter | `/proxy-stats` → `proxies[].successes` |
| `lork_proxy_failures{host,port}` | counter | `/proxy-stats` → `proxies[].failures` |
| `lork_proxy_status_info{host,port,status}` | info (always 1) | `/proxy-stats` → `proxies[].status` |
| `lork_relay_connections` / `_failures` / `_bytes_up` / `_bytes_down` | counter | `/proxy-stats` → `relay.*` |
| `lork_relay_active` | gauge | `/proxy-stats` → `relay.active` |
| `container_memory_working_set_bytes{name=~".*lork.*"}` and similar | gauge/counter | cAdvisor |

Example queries:

```promql
sum by (status) (rate(lork_auth_results_total[5m])) * 60          # auth results per minute, by status
sum(increase(lork_auth_results_total{status="SUCCESS"}[1h]))     # auths that passed in the last hour
sum(increase(lork_auth_results_total{status!="SUCCESS"}[1h]))    # auths that failed in the last hour
sum(increase(lork_auth_results_total{status="SUCCESS"}[1h]))
  / sum(increase(lork_auth_results_total[1h]))                   # auth success rate
sum(rate(lork_proxy_successes[5m])) * 60                         # successful proxy attempts per minute
sum(increase(lork_proxy_successes[1h]))
  / sum(increase(lork_proxy_successes[1h]) + increase(lork_proxy_failures[1h]))   # success rate
resets(lork_uptime_seconds[24h])                                 # Lork restarts today
```

### Two sources of auth numbers

The dashboard counts auths twice, from two different places. They will not agree, and
that is expected:

| | Source | Counts |
|---|---|---|
| **Auth results** (`lork_auth_results_total`) | Lork's log lines, via mtail | One per API request, split by returned status |
| **Proxy attempts** (`lork_proxy_successes` / `_failures`) | `/api/v1/proxy-stats` | One per proxy attempt — a request retried on a second proxy counts twice |

Use the **auth result** panels to answer "how many requests passed and how many
failed". Use the **proxy** panels to find out which proxy is dragging the rate down.
The proxy counters also cannot tell a bad password from a dead proxy; the log-derived
ones can, because they carry the status.

---

## Things to know

- **Per-proxy stats are empty straight after Lork starts.** Proxies appear in
  `/proxy-stats`, and in `lork_proxies_total`, only once Lork has used them. After a
  restart these read 0 until the first auth, even though the logs say `Loaded N proxies`.
- **Proxies are grouped by `host:port`.** If all your proxy lines use the same gateway,
  such as a rotating residential endpoint, the dashboard shows that as a single proxy.
- **Counters reset when Lork restarts**, because the stats file lives inside the
  container. The dashboard uses `rate()` / `increase()`, which handle resets. To keep
  totals across restarts, mount the file:
  ```bash
  touch proxy_stats.json    # in Lork's folder
  ```
  ```yaml
  # Lork's docker-compose.yml → volumes:
      - ./proxy_stats.json:/lork/proxy_stats.json
  ```
- **cAdvisor needs a Linux host.** On Docker Desktop (macOS/Windows), remove it; the
  container panels will then be empty.
- **Container panels match any container whose name contains `lork`.** If you renamed
  the service, edit the `name=~".*lork.*"` filter in the dashboard and in `alerts.yml`.
- **If your Lork service isn't called `lork`**, replace `http://lork:5090` with your
  service name in `prometheus/prometheus.yml` (Route A) or `scrape-jobs.yml` (Route B).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `network lork_default not found` on startup | Lork's network has another name; set `LORK_NETWORK` (see [Before you start](#before-you-start)) |
| Exporter `curl` returns `connection refused` or `no such host` | Lork isn't on port 5090 inside its container, or the exporters are on the wrong network |
| Lork shows `(unhealthy)` in `docker ps` but works | Its container port isn't 5090; see [Before you start](#before-you-start) |
| Targets are `DOWN` with `connection refused` on 7979/9115/8081 | Your scraper can't reach `127.0.0.1` from where it runs; see [Route B step 2](#2-choose-the-scrape-address) |
| `docker compose down` stopped Lork | It was run outside `monitoring/`, or `compose.yaml` was renamed |
| Proxy panels are empty | No auths since Lork started; see [Things to know](#things-to-know) |
| Disk filling up | Docker keeps container logs forever by default — see [Disk usage](#disk-usage) |
| Auth result panels are empty | mtail isn't running, isn't scraped, or its patterns don't match your log lines — see [Auth counters](#auth-counters-mtail) |
| Watchdog logs `no such service: lork` or `no configuration file provided` | `COMPOSE_DIR` isn't Lork's folder; see [Watchdog](#watchdog-temporary-workaround) |
| Watchdog restarts Lork but **Watchdog triggers** is empty | mtail isn't running or scraped, or it was started before the new counters were added; restart it — see [Auth counters](#auth-counters-mtail) |
| Auth success rate is blank | No auths in the selected time range — the rate is a ratio, so it has nothing to divide |

## Removing it

```bash
cd monitoring
docker compose --profile stack down        # Route A (add -v to also delete Prometheus/Grafana data)
docker compose down                        # Route B
```

For Route B, also remove the three Lork jobs from your scrape config and reload it.
