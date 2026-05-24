import os

SECRET_KEY = "lab-only-not-production"
DEBUG = False
ALLOWED_HOSTS = ["*"]

INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "djangosvc.apps.DjangoSvcConfig",
]

MIDDLEWARE = []
ROOT_URLCONF = "djangosvc.urls"
WSGI_APPLICATION = "djangosvc.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.environ.get("DB_NAME", "lab"),
        "USER": os.environ.get("DB_USER", "django_user"),
        "PASSWORD": os.environ.get("DB_PASSWORD", "lab_django"),
        "HOST": os.environ.get("DB_HOST", "postgres.db.svc.cluster.local"),
        "PORT": os.environ.get("DB_PORT", "5432"),
        "OPTIONS": {
            "options": "-csearch_path=django,public",
        },
        "CONN_MAX_AGE": None,
        "CONN_HEALTH_CHECKS": True,
    }
}

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
USE_TZ = True
