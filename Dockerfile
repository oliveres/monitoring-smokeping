# Odvozený image nad upstreamem - NENÍ to fork.
# Bereme hotovou binárku od SuperQ a jen do ní zapečeme config.yml.
#
# Proč COPY a ne bind mount:
#   Bind mount řeší daemon proti HOST filesystému. Portainer má git stack
#   naklonovaný ve svém vlastním kontejneru, takže daemon soubor nenajde
#   a vyrobí místo něj prázdný adresář.
#   Build context se naopak posílá daemonovi jako tar stream po socketu,
#   takže na host filesystém nikdo nesahá. Proto tohle projde.
#
# Jediná údržba: tag na řádku FROM. Bumpuje ho Renovate (viz renovate.json).

FROM quay.io/superq/smokeping-prober:v0.12.0

COPY config.yml /etc/smokeping_prober/config.yml
