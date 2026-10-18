#!/usr/bin/env bats
# The Nginx half of the layer on a machine (decision 0059): keel-web's real
# sites, the include directory, the route of this layer and a stand-in of the
# route of the check page, with two stub servers on the ports of Odoo. It
# runs as root on a disposable trixie machine with nginx, openssl, curl and
# python3, only where KEEL_ODOO_STACK_TEST=1, with KEEL_WEB_SRC naming a
# checkout of keel-web. It proves what `nginx -t` and a request prove: no
# duplicate location with keel-web's sites, the routes reach the right port,
# the websocket headers pass, and Odoo sees https behind the socket of
# Anubis. It does not run Odoo: the boot test and the real platform do.

bats_require_minimum_version 1.5.0

setup_file() {
    if [ "${KEEL_ODOO_STACK_TEST:-}" != 1 ]; then
        skip "this suite rewrites /etc/nginx: set KEEL_ODOO_STACK_TEST=1 on a disposable machine"
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "refusing to run: needs root" >&2
        return 1
    fi
    if [ ! -f "${KEEL_WEB_SRC:-}/packages/keel-web/keel-default" ]; then
        echo "KEEL_WEB_SRC must name a checkout of keel-web" >&2
        return 1
    fi
    local repo web
    repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    web="$KEEL_WEB_SRC/packages/keel-web"
    install -D -m 0644 "$repo/overlay/etc/nginx/conf.d/keel-odoo.conf" /etc/nginx/conf.d/keel-odoo.conf
    install -D -m 0644 "$repo/overlay/etc/nginx/keel-default.d/60-keel-odoo.conf" \
        /etc/nginx/keel-default.d/60-keel-odoo.conf
    # the routes of the check page, as keel-lnpp declares them
    cat > /etc/nginx/keel-default.d/50-keel-lnpp.conf <<'ROUTE'
location = /keel-check {
	return 301 /keel-check/;
}
location ^~ /keel-check/ {
	default_type text/plain;
	return 200 "check page\n";
}
ROUTE
    install -D -m 0644 "$web/keel-default" /etc/nginx/sites-available/keel-default
    install -D -m 0644 "$web/default-anubis" /etc/nginx/sites-available/default-anubis
    install -D -m 0644 /dev/stdin /etc/nginx/snippets/keel-anubis.conf <<'SNIPPET'
proxy_set_header Host $host;
proxy_pass http://[::1]:8923;
SNIPPET
    mkdir -p /var/www/keel-default /etc/ssl/private /usr/local/share/ca-certificates
    printf 'not found\n' > /var/www/keel-default/404.html
    printf 'error\n' > /var/www/keel-default/50x.html
    printf 'default\n' > /var/www/keel-default/index.html
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=odoo.test \
        -keyout /etc/ssl/private/cert.key -out /usr/local/share/ca-certificates/cert.crt 2>/dev/null
    cat /usr/local/share/ca-certificates/cert.crt /etc/ssl/private/cert.key > /etc/ssl/private/cert.pem
    openssl dhparam -dsaparam -out /etc/ssl/private/dhparams.pem 2048 2>/dev/null
    rm -f /etc/nginx/sites-enabled/*
    ln -s /etc/nginx/sites-available/keel-default /etc/nginx/sites-enabled/keel-default
    # the stub servers answer with what they received
    cat > /tmp/keel-odoo-stub.py <<'STUB'
import http.server, sys
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = "port=%d path=%s host=%s proto=%s upgrade=%s connection=%s\n" % (
            port, self.path, self.headers.get("Host"), self.headers.get("X-Forwarded-Proto"),
            self.headers.get("Upgrade"), self.headers.get("Connection"))
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
STUB
    python3 /tmp/keel-odoo-stub.py 8069 &
    python3 /tmp/keel-odoo-stub.py 8072 &
    echo "$(jobs -p | tr '\n' ' ')" > /tmp/keel-odoo-stub.pids
    nginx -t
    systemctl restart nginx
    for _ in $(seq 20); do curl -sk -o /dev/null https://127.0.0.1/ && break; sleep 0.5; done
}

teardown_file() {
    [ -f /tmp/keel-odoo-stub.pids ] && kill $(cat /tmp/keel-odoo-stub.pids) 2>/dev/null || true
}

@test "the simple site and this route pass nginx -t together" {
    run nginx -t
    if [ "$status" -ne 0 ]; then
        echo "$output" >&3
        return 1
    fi
}

@test "a request for a page of Odoo reaches port 8069 with its path and host" {
    run curl -sk --resolve odoo.test:443:127.0.0.1 https://odoo.test/web/login
    [ "$status" -eq 0 ]
    [[ $output == "port=8069 path=/web/login host=odoo.test proto=https "* ]]
}

@test "a deep path and a query string reach 8069 unchanged" {
    run curl -sk "https://127.0.0.1/odoo/action-123?debug=1"
    [[ $output == "port=8069 path=/odoo/action-123?debug=1 "* ]]
}

@test "the websocket reaches port 8072 with the Upgrade and Connection headers" {
    run curl -sk --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' https://127.0.0.1/websocket
    [[ $output == "port=8072 path=/websocket "* ]]
    [[ $output == *"upgrade=websocket connection=upgrade"* ]]
}

@test "a request that is not a websocket upgrade closes the connection to Odoo" {
    run curl -sk https://127.0.0.1/websocket
    [[ $output == *"connection=close"* ]]
}

@test "the check page and its redirect still win over the catch-all" {
    run curl -sk https://127.0.0.1/keel-check/
    [ "$output" = "check page" ]
    run curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/keel-check
    [ "$output" = 301 ]
}

@test "the health check of keel-web still answers 204" {
    run curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/keel-health
    [ "$output" = 204 ]
}

# The loopback addresses of port 80 belong to keel-overlay-nginx's health
# server, so these two requests go to the address of the machine.
host_ip() {
    ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1
}

@test "in the simple mode Odoo sees the scheme of the request" {
    run curl -s "http://$(host_ip)/web/login"
    [[ $output == *"proto=http "* ]]
}

@test "a client cannot set the protocol that Odoo sees" {
    run curl -s -H 'X-Forwarded-Proto: https' "http://$(host_ip)/web/login"
    [[ $output == *"proto=http "* ]]
}

@test "behind Anubis, on the socket of Nginx, Odoo sees https" {
    rm /etc/nginx/sites-enabled/keel-default
    ln -s /etc/nginx/sites-available/default-anubis /etc/nginx/sites-enabled/default-anubis
    run nginx -t
    if [ "$status" -ne 0 ]; then
        echo "$output" >&3
        return 1
    fi
    systemctl reload nginx
    run curl -s --unix-socket /run/nginx/keel-app.sock http://odoo.test/web/login
    [[ $output == "port=8069 path=/web/login host=odoo.test proto=https "* ]]
    run curl -s --unix-socket /run/nginx/keel-app.sock -H 'Connection: Upgrade' -H 'Upgrade: websocket' http://odoo.test/websocket
    [[ $output == "port=8072 path=/websocket "* ]]
    run curl -s --unix-socket /run/nginx/keel-app.sock http://odoo.test/keel-check/
    [ "$output" = "check page" ]
}
