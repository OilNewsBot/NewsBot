"""Offline integration test using the production application and two HTTP sessions."""

import asyncio;
import importlib;
import from app { create_app }
import from tests.helpers { make_settings }

test "publishing, Following and discussion persist across a service restart" {
    cases: any = importlib.import_module("tests.workspace_flow");
    asyncio.run(cases.exercise_workspace(create_app, make_settings()));
}
