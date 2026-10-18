Keel Odoo
=========

`Odoo`_ 18.0 Community behind Nginx on the LNPP stack of Keel Linux
(handbook decision 0059, step 6). The layer is built on ``lnpp``:

    bt-layer odoo --parent lnpp

The chain is Core, Web, LNPP and Odoo. Apache is gone. TurnKey's Odoo
appliance ran Odoo 16 behind Apache on LAPP. This layer replaces it.

What the layer adds to LNPP
---------------------------

- Odoo 18.0, a checkout of the ``Keel-Linux/odoo`` snapshot in
  ``/opt/odoo/18.0``, at a pinned commit. The Python libraries come from
  Debian 13 only. Nothing is installed with pip.
- A route in the include directory of Keel Web
  (``/etc/nginx/keel-default.d/60-keel-odoo.conf``). Nginx sends HTTP to
  ``127.0.0.1:8069`` and ``/websocket`` to ``127.0.0.1:8072``. Odoo runs
  with ``proxy_mode`` on. The check page ``/keel-check/`` of LNPP stays.
- A database role ``odoo`` with no password. Odoo connects on the unix
  socket and PostgreSQL authenticates the operating system user.
- The first boot hook ``45odoo``. It sets the password of the ``admin``
  user and the master password from ``secrets.app_password``, freezes
  ``web.base.url`` from ``app.domain``, and renews ``database.secret`` and
  ``database.uuid``. A first boot with no console and no password stops
  with a message.

Files and the pair
------------------

Attachments are stored in the database (``ir_attachment.location`` is
``db``), so the PostgreSQL pair of decision 0054 carries them. A failover
loses no file. This is the choice of least power: it adds no mechanism
beside the pair. The cost is a larger database and slower access to large
files. A database that an operator creates later needs the same system
parameter. Sessions are files in ``/var/lib/odoo/sessions``: users log in
again after a failover.

Odoo is loaded on every node and serves on the node whose PostgreSQL
accepts writes. ``odoo.service`` runs ``/usr/lib/keel-odoo/serve.py``. It
imports Odoo, then asks PostgreSQL every 0.2 seconds one read only question:
is the server out of recovery and open for writes? A standby answers it, and
a standby is never writable. On the writable node, and after the first boot
hook has finished, it starts Odoo at once, with the imports done. On a node
that is not writable it stops Odoo, and a fenced or old primary is in
recovery, so it does not serve. Odoo cannot start in a database that is in
recovery, so a warm Odoo on a standby is not possible. While it waits, the
process holds no listener and writes nothing. After a failover, Odoo
answers a few seconds after PostgreSQL accepts writes.

Reports
-------

``wkhtmltopdf`` 0.12.6.1-3, the upstream build with patched qt, is in
``/usr/local/bin``. The build installs it at a pinned digest, because
Debian 13 has no package for it. Only that build prints the header and the
footer of a report. ``report.url`` is ``http://127.0.0.1:8069``, so the
printer reads the style sheets from Odoo on the loopback.

Known limits
------------

- ``wkhtmltopdf`` is a pinned file from the upstream packaging project, not
  a package of the Keel archive (decision 0022 plans one). An update is a
  new layer.
- In the cloud modes the Core Rule Set of Coraza reads every request. The
  layer ends rule 930130 for the Odoo routes, because the model
  ``res.config.settings`` looks like a restricted file to it. A JSON-RPC
  call may be 16 MiB, and the base64 fields of a file (``datas``, ``raw``,
  ``image_1920`` and the like) are not read by the rules. Any other JSON
  body of more than 256 KiB is refused. The web client uploads files as
  ``multipart/form-data``, and that is not under this limit.
- Odoo has no Adminer and no OCA addons. Put addons in
  ``/opt/odoo/extra-addons``.
- The websocket (``/websocket``) needs keel-overlay-anubis 0.1.1 in the
  cloud modes: its snippet passes the ``Upgrade`` header.

Credentials *(set at the first boot)*
-------------------------------------

- Webmin, SSH: user **root**.
- PostgreSQL: user **postgres**, password ``secrets.db_password``.
- Odoo: user **admin**. The password is ``secrets.app_password``, and it is
  also the master password.

.. _Odoo: https://www.odoo.com/
