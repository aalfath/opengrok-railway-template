# OpenGrok for Railway: the official image, pinned by version and digest,
# with Caddy (basic auth) in front and a small start script.
# Upstream: https://github.com/oracle/opengrok (CDDL-1.0)
FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0 AS caddy

FROM opengrok/docker:1.14.21@sha256:f60db43496bff95767c2149b544e5f2f9d4815281e7d5ed189a5390b0790b3a8

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy

# - Tomcat listens on loopback only: the public port is Caddy's, with basic auth.
# - Source, index and configuration live on one Railway volume at /var/lib/opengrok.
# - The indexer's 256 MB RAM buffer becomes a value sized from the service's memory.
RUN sed -i 's|<Connector port="8080" protocol="HTTP/1.1"|<Connector address="127.0.0.1" port="8080" protocol="HTTP/1.1"|' /usr/local/tomcat/conf/server.xml \
 && grep -q 'address="127.0.0.1" port="8080"' /usr/local/tomcat/conf/server.xml \
 && sed -i "s|-m, '256'|-m, '%RAMBUF%'|; s|args_subst: {\"%API_TIMEOUT%\": \"\$API_TIMEOUT\"}|args_subst: {\"%API_TIMEOUT%\": \"\$API_TIMEOUT\", \"%RAMBUF%\": \"\$OPENGROK_INDEXER_RAMBUF_MB\"}|" /scripts/sync.yml \
 && grep -q "'%RAMBUF%'" /scripts/sync.yml && grep -q '"%RAMBUF%": "$OPENGROK_INDEXER_RAMBUF_MB"' /scripts/sync.yml \
 && rmdir /opengrok/src /opengrok/data /opengrok/etc \
 && ln -s /var/lib/opengrok/src /opengrok/src \
 && ln -s /var/lib/opengrok/data /opengrok/data \
 && ln -s /var/lib/opengrok/etc /opengrok/etc \
 && mkdir -p /usr/local/tomcat/conf/Catalina/localhost && chown -R appuser:appgroup /usr/local/tomcat/conf/Catalina \
 && caddy version

COPY gitconfig /etc/gitconfig
COPY railway-start.sh railway-repos.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/railway-start.sh /usr/local/bin/railway-repos.sh && chmod 644 /etc/gitconfig

ENV PORT=8000
EXPOSE 8000
CMD ["/usr/local/bin/railway-start.sh"]
