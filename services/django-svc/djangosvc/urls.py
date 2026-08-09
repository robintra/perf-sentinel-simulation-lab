from django.urls import path
from djangosvc import views

urlpatterns = [
    path("health/live", views.health),
    path("health/ready", views.health),

    path("api/external/mock", views.mock),
    path("api/dispatch/<str:channel>", views.dispatch),
    path("api/payments/history", views.payments_history),

    path("api/fault/n-plus-one-sql", views.n_plus_one_sql),
    path("api/fault/n-plus-one-http", views.n_plus_one_http),
    path("api/fault/n-plus-one-messaging", views.n_plus_one_messaging),
    path("api/fault/redundant-sql", views.redundant_sql),
    path("api/fault/redundant-http", views.redundant_http),
    path("api/fault/slow-sql", views.slow_sql),
    path("api/fault/slow-http", views.slow_http),
    path("api/fault/slow-messaging", views.slow_messaging),
    path("api/fault/fanout", views.fanout),
    path("api/fault/chatty", views.chatty),
    path("api/fault/serialized", views.serialized),
    path("api/fault/pool-saturation", views.pool_saturation),
]
