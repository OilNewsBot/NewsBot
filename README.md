# NewsDrop

NewsDrop is a community news desk for people following markets. Discover a publisher, follow a topic or track one developing story. When you return, Home shows what changed since your last visit, why each story appeared and where the reporting came from.

The directory starts with **42 channels** across eight sectors and General News. Anyone can browse. A NewsDrop account lets you publish channels, discuss reports, manage private sources and carry your follows between devices connected to the same server.

## Try NewsDrop

1. Open **Discover**. Filter by sector, then expand a channel to see its recent reports, source and click count. Open its page to follow it.
2. In **Following**, open **Browse and combine topics**. Choose **Semiconductor equipment** and **Export restrictions** to follow reports that mention both. On an individual report, **Follow story** tracks future developments on its timeline.
3. Return to **Home**. Your first briefing offers recent coverage. Mark an edition as read when you finish. The next briefing highlights newer reports and material revisions, with links to the original sources.
4. Open **My Sources** to publish a community, RSS, X or Telegram channel. Private connections have their own feed and controls. You choose which eligible private items to publish.

## Run locally

Run these commands from your NewsDrop checkout on Linux or an Apple Silicon Mac. For a fresh checkout, use `git clone https://github.com/OilNewsBot/NewsBot.git NewsDrop` and open the resulting `NewsDrop` directory.

```sh
python3 scripts/bootstrap.py
export PATH="$HOME/.local/bin:$PATH"
jac run
```

Open [NewsDrop on localhost](http://127.0.0.1:8000). The initial edition and public RSS work without provider keys. For Windows, use the WSL instructions in the [setup and hosting guide](docs/getting-started.md).

## Documentation

| If you want to… | Start here |
| --- | --- |
| Use the briefing, publish a channel or manage alerts | [Reader guide](docs/feature-overhaul.md) |
| Understand the goals and available features | [Product overview](docs/spec.md) |
| Run a shared server or configure AI and integrations | [Setup and hosting](docs/getting-started.md) |
| Understand how reports become stories and briefings | [Architecture](docs/project.md) |
| Look up endpoints or platform-specific instructions | [Documentation index](docs/README.md) |
