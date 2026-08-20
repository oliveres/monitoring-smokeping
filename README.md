# monitoring-smokeping

Náhrada Smokepingu postavená na [SuperQ/smokeping_prober](https://github.com/SuperQ/smokeping_prober),
nasazovaná jako Portainer git stack. Prober posílá plynulou sérii ICMP pingů
a zaznamenává odpovědi do Prometheus histogramů; distribuci latence (ten
původní „kouř") si pak vytáhneš z bucketů přes `histogram_quantile()`.

Data tečou stejnou cestou jako zbytek monitoringu: lokální Prometheus agent →
remote write přes Caddy → centrální Prometheus + Grafana.

## Proč Dockerfile a ne bind mount

Tohle je jádro celého repa, ať se k tomu nemusíš vracet.

| | Kdo řeší cestu | Funguje v Portainer git stacku |
|---|---|---|
| **Bind mount** (`./config.yml:/etc/...`) | daemon, proti **host** filesystému | ne — Portainer má repo naklonované ve svém kontejneru, daemon soubor nenajde a vyrobí prázdný adresář |
| **Build context** (`COPY`) | compose zabalí adresář do **tar streamu** a pošle daemonovi po socketu | ano — na host filesystém nikdo nesahá |

Proto je tu dvouřádkový `Dockerfile`, který jen zapeče `config.yml` do
upstream image. Není to fork — upstream binárku nesestavujeme ani nesledujeme,
jediná údržba je tag na řádku `FROM`, a ten bumpuje Renovate.

## Struktura

```
Dockerfile              # FROM upstream + COPY config.yml
config.yml              # seznam ping targetů
docker-compose.yml      # stack pro Portainer
renovate.json           # automatický bump FROM tagu
prometheus/
  scrape-snippet.yml    # referenční scrape config pro agenta
  alerts.yml            # referenční recording + alert pravidla
```

Soubory v `prometheus/` stack nekonzumuje, jsou to podklady pro centrální
Prometheus a pro agenta na hostu.

## Nasazení v Portaineru

1. **Stacks → Add stack → Repository**
2. Repository URL: tento repo, reference `refs/heads/main`
3. Compose path: `docker-compose.yml`
4. **Enable relative path volumes nechat vypnuté** — nic bindovat nepotřebujeme
5. Deploy

Pro automatické nasazení po pushi zapni GitOps updates (polling interval nebo
webhook).

### Co musí být na hostu

Docker engine a nic víc. Žádný fping, žádný Perl, žádné kernel moduly, žádný
soubor na disku. Privilegia řeší `user: root` + `cap_add: NET_RAW` v compose.

Kde kontejner běží, to je tvůj vantage point: na Proxmox hostu s host netns
měříš z hosta, ve VM měříš z té VM přes virtio bridge. Není to detail.

## Ověření po nasazení

```bash
# Kolik sérií bucketů běží (musí sedět: (počet bucketů + 1) × počet cílů)
curl -s localhost:9374/metrics | grep -c '^smokeping_response_duration_seconds_bucket'

# Musí zůstat na nule. Nenulové = nemáš raw socket, spadlo to na capabilities.
curl -s localhost:9374/metrics | grep '^smokeping_send_errors_total'

# Po každém redeploy: sedí targety uvnitř kontejneru?
# Když vidíš staré, neproběhl build - ne špatný COPY.
docker exec smokeping-prober cat /etc/smokeping_prober/config.yml
```

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
  sum by (vantage, host, le) (
    rate(smokeping_response_duration_seconds_bucket[$__rate_interval])
  )
)

# Průměr
  rate(smokeping_response_duration_seconds_sum[$__rate_interval])
/ rate(smokeping_response_duration_seconds_count[$__rate_interval])

# Heatmap panel (vlastní "smoke")
# Format = Heatmap, Data format = Time series buckets, Y-axis unit = seconds
sum by (le) (
  rate(smokeping_response_duration_seconds_bucket{host="$host"}[$__rate_interval])
)
```

## Dashboard

- Grafana.com ID **22471** (heatmap + stat + status-history)
- Nebo `dashboard.json` přímo v upstream repu

## Buckety

`--buckets` je **globální CLI flag**, per-target ho nastavit nejde, a jeho
pozdější změna udělá zlom v historických sériích — staré řady si drží staré
hodnoty `le`. Rozmysli si to při zakládání, ne za půl roku.

Aktuální sada má 13 bucketů v rozsahu 0,2 ms – 1 s s hustotou kolem 5–50 ms.
Upstream default je 20 bucketů geometrickou řadou od 50 µs do 26 s, kde půlka
je vždycky prázdná.

Když budeš míchat extrémy (0,2 ms LAN vs. 150 ms US), zvaž **dvě instance
proberu na různých portech** s vlastními sadami. Jinak ti v obou pásmech chybí
rozlišení.

Kardinalita: ~21 sérií na cíl (13 bucketů + `+Inf` + `sum`/`count` + 5 counterů
a gauge). Při 20 cílech × 3 vantage pointy jsi na ~1 260 sérií.

## Na co narazíš

**ICMP rate limiting.** Hodně routerů a cloud edge zařízení limituje echo reply
na 1–2/s. Při `interval: 1s` z toho vypadne falešný packet loss. Otestuj cíl
zvlášť, než z něj uděláš alert; podezřelým dej `interval: 2s`.

**Redeploy nepřestavěl image.** Proto je v compose `pull_policy: build`. Cache
u `COPY` je content-addressed, takže změněný config si vrstvu invaliduje sám —
ale jen když build vůbec proběhne.

**Bridge místo host netns.** Bez `network_mode: host` měříš `docker0` a NAT.
U WAN cílů je to šum, u LAN gateway na 0,2 ms už ne.

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
