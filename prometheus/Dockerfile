# Stejný vzor jako monitoring-edge: config se generuje při buildu z šablony,
# takže do kontejneru nic nemountujeme a Portainer git stack funguje bez
# jediného souboru na hostu.

FROM alpine:3.20 AS builder

RUN apk add --no-cache gettext
RUN mkdir /out

ARG HOSTNAME
ARG CENTRAL_PROMETHEUS_URL
ARG BASIC_AUTH_USER
ARG BASIC_AUTH_PASSWORD

COPY prometheus.yml.template /tmp/prometheus.yml.template
RUN envsubst < /tmp/prometheus.yml.template > /out/prometheus.yml

FROM prom/prometheus:latest
COPY --from=builder /out/prometheus.yml /etc/prometheus/prometheus.yml
