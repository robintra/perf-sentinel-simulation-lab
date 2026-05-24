import os
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "djangosvc.settings")

from djangosvc.tracing import init_tracing  # noqa: E402
init_tracing()

from django.core.wsgi import get_wsgi_application  # noqa: E402
application = get_wsgi_application()

from djangosvc.schema import ensure_schema  # noqa: E402
try:
    ensure_schema()
except Exception as e:
    import logging
    logging.getLogger("djangosvc").warning("schema bootstrap deferred: %s", e)
