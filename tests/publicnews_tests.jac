"""Run the shared catalog's offline persistence and worker scenarios."""

import asyncio;
import importlib;

test "public catalog refresh, summary budgets, threads and selective sharing" {
    cases: any = importlib.import_module("tests.publicnews_cases");
    asyncio.run(cases.catalog_regressions());
}

test "summary provider selection, bounded compatible requests and cache isolation" {
    cases: any = importlib.import_module("tests.publicnews_cases");
    asyncio.run(cases.provider_regressions());
}
