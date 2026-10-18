# keel-odoo: Odoo 18.0 behind Nginx on the LNPP stack of Keel (handbook
# decision 0059, step 6), built as a layer on the lnpp layer:
#
#     bt-layer odoo --parent lnpp
#
# Nginx, Coraza, Anubis and the default site come from the web layer;
# PostgreSQL 17, Python 3 and the pair of decision 0054 from the lnpp layer.
# This layer adds Odoo (a checkout of the Keel-Linux/odoo snapshot, with
# Debian's python3-* packages, never pip), its route in keel-web's include
# directory, and the script that starts Odoo on the node whose PostgreSQL
# accepts writes. Apache is gone: the TurnKey recipe used lapp.mk.

COMMON_OVERLAYS += $(CURDIR)/overlay

# Webmin comes from core and answers on 12321; Nginx serves 80 and 443.
# Odoo listens on the loopback, and PostgreSQL on a pair on the mesh only.
WEBMIN_FW_TCP_INCOMING = 22 80 443 12321

include $(FAB_PATH)/common/mk/turnkey.mk
