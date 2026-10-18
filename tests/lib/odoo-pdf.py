"""Print one report as PDF through Odoo and write its text to stdout.

Run inside the container by tests/boot-test.sh with `python3 -`. It logs in
as admin on the loopback with the password of the spec (read from the file,
never from the arguments), makes a report on the layout of Odoo
(web.external_layout, which has a header and a footer), prints it through
wkhtmltopdf and extracts the text with pypdf."""
import http.cookiejar
import io
import json
import re
import sys
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:8069"
TAG = "keel_pdf_boot_test"
ARCH = (
    '<t t-name="base.%s"><t t-call="web.html_container"><t t-foreach="docs" t-as="o">'
    '<t t-call="web.external_layout"><div class="page"><h2>Keel PDF test</h2>'
    "<p>Marker KEEL-BODY-TEXT</p></div></t></t></t></t>"
) % TAG

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def get(path, data=None, headers=None):
    request = urllib.request.Request(BASE + path, data=data, headers=headers or {})
    return opener.open(request, timeout=120).read()


def call(model, method, args):
    payload = {"jsonrpc": "2.0", "method": "call", "id": 1,
               "params": {"model": model, "method": method, "args": args, "kwargs": {}}}
    out = json.loads(get("/web/dataset/call_kw/%s/%s" % (model, method), json.dumps(payload).encode(),
                         {"Content-Type": "application/json"}))
    if "error" in out:
        raise RuntimeError(out["error"]["data"]["message"])
    return out["result"]


def main():
    from pypdf import PdfReader
    password = open("/etc/keel/secrets/app_password").read().strip()
    page = get("/web/login").decode()
    token = re.search(r'name="csrf_token" value="([^"]+)"', page).group(1)
    get("/web/login", urllib.parse.urlencode(
        {"csrf_token": token, "login": "admin", "password": password}).encode())
    call("ir.ui.view", "create", [{"name": TAG, "type": "qweb", "key": "base." + TAG, "arch": ARCH}])
    call("ir.actions.report", "create", [{"name": TAG, "model": "res.partner", "report_type": "qweb-pdf",
                                          "report_name": "base." + TAG, "report_file": "base." + TAG}])
    pdf = get("/report/pdf/base.%s/1" % TAG)
    if not pdf.startswith(b"%PDF-"):
        print("not a PDF: %r" % pdf[:60], file=sys.stderr)
        return 1
    print("\n".join(p.extract_text() for p in PdfReader(io.BytesIO(pdf)).pages))
    return 0


if __name__ == "__main__":
    sys.exit(main())
