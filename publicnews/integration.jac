"""Connect public channels to the existing Jac RSS, account and model services."""

import importlib;
import os;
import from auth { require_user }
import from personal.api { check_origin }
import from personal.providers { fetch_feed, parse_feed }

glob news_catalog: any = importlib.import_module("publicnews.catalog"),
     providers: any = importlib.import_module("publicnews.providers"),
     news_worker: any = importlib.import_module("publicnews.worker"),
     news_routes: any = importlib.import_module("publicnews.routes");

def make_catalog(settings: any, directory: any, llm: any) -> any {
    (model, client) = providers.select_provider(
        settings.triage_model, bool(settings.anthropic_api_key), llm
    );
    catalog = news_catalog.Catalog(
        settings.db_path,
        directory.catalog,
        model,
        os.environ.get("NEWSSTREAM_SUMMARY_SOURCES") or "rss"
    );
    catalog.ai_enabled = client is not None;
    try {
        limit = int(os.environ.get("NEWSSTREAM_SUMMARY_DAILY_LIMIT") or "40");
    } except ValueError {
        limit = 0;
    }
    catalog.worker = news_worker.PublicWorker(
        catalog, fetch_feed, parse_feed, directory.router.local, client, max(0, limit)
    );
    return catalog;
}

def install_catalog_routes(app: any, repo: any, catalog: any) {
    news_routes.install(app, repo, catalog, require_user, check_origin);
}

async def run_catalog(catalog: any) {
    await catalog.worker.run();
}
