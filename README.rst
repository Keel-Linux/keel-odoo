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

Odoo runs on the node whose PostgreSQL accepts writes. The timer
``keel-odoo-follow.timer`` runs ``/usr/lib/keel-odoo/follow.py`` every 3
seconds. It starts Odoo on a primary and stops it on a standby. After a
failover, Odoo starts on the new primary some seconds after the VIP moves.

Known limits
------------

- There is no ``wkhtmltopdf``, so PDF reports do not render yet
  (decision 0022 plans a pinned package in the Keel archive).
- Odoo has no Adminer and no OCA addons. Put addons in
  ``/opt/odoo/extra-addons``.
- The websocket (``/websocket``) works in the simple mode. In the cloud
  modes Anubis sits in front, and the snippet of ``keel-overlay-anubis``
  does not pass the ``Upgrade`` header yet.

Credentials *(set at the first boot)*
-------------------------------------

- Webmin, SSH: user **root**.
- PostgreSQL: user **postgres**, password ``secrets.db_password``.
- Odoo: user **admin**. The password is ``secrets.app_password``, and it is
  also the master password.

.. _Odoo: https://www.odoo.com/
