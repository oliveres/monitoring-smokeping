# monitoring-smokeping

Náhrada Smokepingu postavená na [SuperQ/smokeping_prober](https://github.com/SuperQ/smokeping_prober).
Soběstačný Portainer git stack: měří latenci a packet loss, scrapuje sám sebe
a posílá data remote writem do centrálního Prometheusu.

Prober posílá plynulou sérii ICMP pingů a zaznamenává odpovědi do Prometheus
histogramů; distribuci latence (ten původní „kouř") si pak vytáhneš z bucketů
přes `histogram_quantile()`.

## Architektura

```
   smokeping-prober          smokeping-agent            centrální Prometheus
   (host netns)              (host netns, --agent)      (přes Caddy)
   ICMP -> histogramy   ->   scrape 127.0.0.1:9374  ->  remote write  ->  Grafana
   :9374 loopback            WAL na named volume
```

Stack nemá s ostatními monitorovacími stacky nic společného a nic po nich
nechce. Oba kontejnery jedou v host network namespace, takže `127.0.0.1` je
mezi nimi doslova ten samý socket — žádný bridge, žádný `host.docker.internal`,
a port 9374 se ven nevystavuje vůbec.

Agent běží s `--agent`, tedy skutečný agent mode: žádná TSDB, žádné query API,
žádná pravidla. Jen scrape a remote write.

## Proč Dockerfile a ne bind mount

Tohle je jádro celého repa, ať se k tomu nemusíš vracet.

| | Kdo řeší cestu | Funguje v Portainer git stacku |
|---|---|---|
| **Bind mount** (`./config.yml:/etc/...`) | daemon, proti **host** filesystému | ne — Portainer má repo naklonované ve svém kontejneru, daemon soubor nenajde a vyrobí prázdný adresář |
| **Build context** (`COPY`) | compose zabalí adresář do **tar streamu** a pošle daemonovi po socketu | ano — na host filesystém nikdo nesahá |

Proto je tu dvouřádkový `Dockerfile`, který zapeče `config.yml` do upstream
image, a `prometheus/Dockerfile`, který přes `envsubst` vygeneruje
`prometheus.yml` ze šablony. Na hostu neleží jediný soubor.

Není to fork — upstream binárku nesestavujeme ani nesledujeme, jediná údržba
je tag na řádku `FROM`, a ten bumpuje Renovate.

## Struktura

```
Dockerfile                    # FROM upstream + COPY config.yml
config.yml                    # seznam ping targetů
docker-compose.yml            # prober + agent
.env.example                  # proměnné pro Portainer
renovate.json                 # automatický bump FROM tagu
prometheus/
  Dockerfile                  # envsubst šablony při buildu
  prometheus.yml.template     # scrape + remote write
  alerts.yml                  # pravidla pro CENTRÁLNÍ Prometheus
```

`prometheus/alerts.yml` stack nekonzumuje — agent v agent módu pravidla
spouštět neumí. Patří na centrál.

## Konfigurace

Proměnné z `.env.example` zadej v Portaineru v sekci Environment variables:

| Proměnná | Význam |
|---|---|
| `HOSTNAME` | identita měřicího bodu, skončí jako label `host` |
| `CENTRAL_PROMETHEUS_URL` | remote write endpoint včetně `/api/v1/write` |
| `BASIC_AUTH_USER` / `BASIC_AUTH_PASSWORD` | auth pro remote write, prázdné uvnitř VPC |

Dosazují se při **buildu** jako build args, ne za běhu. Změna kterékoli z nich
proto vyžaduje redeploy stacku, ne jen restart kontejneru.

## Konvence labelů

Prober používá `host` pro **cíl** pingu (`host="8.8.8.8"`), zatímco napříč
monitoringem `host` znamená stroj, **ze** kterého měříme. To by se srazilo,
takže `metric_relabel_configs` cíl přejmenuje ještě před remote writem:

| Label | Význam |
|---|---|
| `host` | vantage point (z `HOSTNAME`, doplní `external_labels`) |
| `target` | cíl pingu (`8.8.8.8`, `www.nix.cz`) |
| `ip` | vyresolvovaná adresa cíle |
| `role` | vždy `smokeping` |

## Nasazení v Portaineru

1. **Stacks → Add stack → Repository**
2. Repository URL: tento repo, reference `refs/heads/main`
3. Compose path: `docker-compose.yml`
4. **Enable relative path volumes nechat vypnuté** — nic nebindujeme
5. Vyplnit Environment variables podle `.env.example`
6. Deploy

Pro automatické nasazení po pushi zapni GitOps updates (polling nebo webhook).

### Co musí být na hostu

Docker engine a nic víc. Žádný fping, žádný Perl, žádné kernel moduly, žádný
soubor na disku, žádný sysctl. Privilegia řeší `user: root` + `cap_add: NET_RAW`.

Kde stack běží, to je tvůj vantage point: na Proxmox hostu s host netns měříš
z hosta, ve VM měříš z té VM přes virtio bridge. Není to detail.

## Ověření po nasazení

Spouštět na Docker **hostu** — díky host netns je to ten samý socket
jako v kontejnerech.

```bash
# 1) Sonda odesílá? Musí být samé nuly.
curl -s localhost:9374/metrics | grep '^smokeping_send_errors_total'

# 2) Odpovědi se vrací? Obě čísla musí u každého cíle růst zhruba stejně.
curl -s localhost:9374/metrics | grep -E '^smokeping_(requests_total|response_duration_seconds_count)'

# 3) Sedí počet bucketů? (počet bucketů + 1) x počet cílů
curl -s localhost:9374/metrics | grep -c '^smokeping_response_duration_seconds_bucket'

# 4) Vidí agent prober?
curl -s localhost:9091/api/v1/targets 2>/dev/null | jq '.data.activeTargets[] | {job: .labels.job, health, lastError}'
# Agent mode nemá query API - když tohle nevrátí nic, koukni do logu:
docker logs smokeping-agent 2>&1 | grep -iE 'scrape|remote'

# 5) Doručuje agent do centrálu?
curl -s localhost:9091/metrics | grep -E 'prometheus_remote_storage_(samples_total|samples_failed_total|highest_timestamp)'

# 6) Po každém redeploy: sedí targety uvnitř kontejneru?
#    Když vidíš staré, neproběhl build - ne špatný COPY.
docker exec smokeping-prober cat /etc/smokeping_prober/config.yml
```

End-to-end kontrola na **centrálním** Prometheusu:

```promql
count by (host, target) (smokeping_requests_total)
```

Až se vrátí řádek pro každý cíl s tvým `host` labelem, je řetěz kompletní.

## Změna targetů

Uprav `config.yml`, commitni, pushni, redeploy stacku. Config je zapečený
v image, takže `POST /-/reload` je tu k ničemu. Výhodou je, že targety jsou
verzované spolu s image — rollback stacku vrátí i seznam cílů.

## Metriky

| Metrika | Typ | Popis |
|---|---|---|
| `smokeping_requests_total` | Counter | odeslané pingy |
| `smokeping_response_duration_seconds` | Histogram | doba odezvy |
| `smokeping_response_ttl` | Gauge | TTL poslední odpovědi |
| `smokeping_response_duplicates_total` | Counter | duplicitní odpovědi |
| `smokeping_receive_errors_total` | Counter | chyby při příjmu |
| `smokeping_send_errors_total` | Counter | chyby při odesílání |

Samostatná metrika pro packet loss **neexistuje**, počítá se z rozdílu
`requests_total` a `response_duration_seconds_count`.

## Užitečné dotazy

```promql
# Packet loss
1 - (
    rate(smokeping_response_duration_seconds_count[$__rate_interval])
  / rate(smokeping_requests_total[$__rate_interval])
)

# p90 latence
histogram_quantile(0.90,
  sum by (host, target, le) (
    rate(smokeping_response_duration_seconds_bucket[$__rate_interval])
  )
)

# Průměr
  rate(smokeping_response_duration_seconds_sum[$__rate_interval])
/ rate(smokeping_response_duration_seconds_count[$__rate_interval])

# Heatmap panel (vlastní "smoke")
# Format = Heatmap, Data format = Time series buckets, Y-axis unit = seconds
sum by (le) (
  rate(smokeping_response_duration_seconds_bucket{target="$target"}[$__rate_interval])
)
```

## Dashboard

- Grafana.com ID **22471** (heatmap + stat + status-history)
- Nebo `dashboard.json` přímo v upstream repu

Obojí předpokládá původní label `host` pro cíl, takže po importu přepiš
dotazy na `target`.

## Buckety

`--buckets` je **globální CLI flag**, per-target ho nastavit nejde, a jeho
pozdější změna udělá zlom v historických sériích — staré řady si drží staré
hodnoty `le`. Rozmysli si to při zakládání, ne za půl roku.

Aktuální sada má 13 bucketů v rozsahu 0,2 ms - 1 s s hustotou kolem 5-50 ms.
Upstream default je 20 bucketů geometrickou řadou od 50 us do 26 s, kde půlka
je vždycky prázdná.

Když budeš míchat extrémy (0,2 ms LAN vs. 150 ms US), zvaž **dvě instance
proberu na různých portech** s vlastními sadami. Jinak ti v obou pásmech chybí
rozlišení.

Kardinalita: ~21 sérií na cíl (13 bucketů + `+Inf` + `sum`/`count` + 5 counterů
a gauge). Při 20 cílech x 3 vantage pointy jsi na ~1 260 sérií.

## Na co narazíš

**ICMP rate limiting.** Hodně routerů a cloud edge zařízení limituje echo reply
na 1-2/s. Při `interval: 1s` z toho vypadne falešný packet loss. Otestuj cíl
zvlášť, než z něj uděláš alert; podezřelým dej `interval: 2s`.

**Redeploy nepřestavěl image.** Proto je v compose `pull_policy: build`. Cache
u `COPY` je content-addressed, takže změněný config si vrstvu invaliduje sám —
ale jen když build vůbec proběhne.

**Hostname se zapeče do metrik.** Prober resolvuje při načtení configu a sám
od sebe znovu neresolvuje. U cílů za anycastem nebo CDN bys napořád měřil jeden
konkrétní endpoint. Tam je poctivější dát rovnou literál IP.

**Port 9091 je i default pushgateway.** Kdyby ti na hostu kolidoval, změň ho
v `command` v compose i v self-scrape jobu v šabloně.

## Bez roota v kontejneru

Pokud nechceš `user: root`, vypusť z `command` flag `--privileged` (prober pak
jede přes ICMP datagram socket místo raw socketu) a nastav na **hostu**:

```
# /etc/sysctl.d/99-ping.conf
net.ipv4.ping_group_range = 0 2147483647
```

Per-container `sysctls:` tu nepomůže — sysctl je namespaced na síťovou
namespace a ta je při `network_mode: host` hostovská. Je to tedy výměna
roota v kontejneru za zásah do bare metalu.
