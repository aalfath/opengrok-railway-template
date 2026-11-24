# OpenGrok for Railway: the official image, pinned by version and digest,
# with Caddy (basic auth) in front and a small start script.
# Upstream: https://github.com/oracle/opengrok (CDDL-1.0)
FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0 AS caddy

FROM opengrok/docker:1.14.21@sha256:f60db43496bff95767c2149b544e5f2f9d4815281e7d5ed189a5390b0790b3a8

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy

# - Tomcat listens on loopback only; the public port is Caddy's, with basic auth.
# - The web app is unpacked at build time and reads its configuration from its
#   default path, /var/opengrok/etc/configuration.xml, on the Railway volume.
# - Upstream's Python start program is replaced by railway-start.sh and
#   railway-sync.sh, which do the same job in far less memory.
RUN sed -i 's|<Connector port="8080" protocol="HTTP/1.1"|<Connector address="127.0.0.1" port="8080" protocol="HTTP/1.1"|' /usr/local/tomcat/conf/server.xml \
 && grep -q 'address="127.0.0.1" port="8080"' /usr/local/tomcat/conf/server.xml \
 && rm -r /usr/local/tomcat/webapps && mkdir -p /usr/local/tomcat/webapps/ROOT \
 && cd /usr/local/tomcat/webapps/ROOT && unzip -q /opengrok/lib/source.war \
 && grep -q '/var/opengrok/etc/configuration.xml' WEB-INF/web.xml \
 && mkdir -p /usr/local/tomcat/conf/Catalina/localhost /usr/local/tomcat/logs /usr/local/tomcat/work /usr/local/tomcat/temp /var/opengrok \
 && chown -R appuser:appgroup /usr/local/tomcat/conf/Catalina /usr/local/tomcat/logs /usr/local/tomcat/work /usr/local/tomcat/temp /usr/local/tomcat/webapps \
 && caddy version

COPY gitconfig /etc/gitconfig
COPY railway-start.sh railway-sync.sh /usr/local/bin/
RUN chmod 644 /etc/gitconfig && chmod 755 /usr/local/bin/railway-start.sh /usr/local/bin/railway-sync.sh

ENV PORT=8000
EXPOSE 8000
WORKDIR /var/opengrok
CMD ["/usr/local/bin/railway-start.sh"]
