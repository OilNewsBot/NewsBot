"""Shared data access and display helpers for the public channel catalog."""

glob:pub SECTORS: list[str] = [
         "energy",
         "tech",
         "healthcare",
         "industrials",
         "consumer-discretionary",
         "materials",
         "utilities",
         "real-estate"
     ];
glob:pub SECTION_NAMES: dict[str, str] = {
         "energy": "Energy",
         "tech": "Tech",
         "healthcare": "Healthcare",
         "industrials": "Industrials",
         "consumer-discretionary": "Consumer Discretionary",
         "materials": "Materials",
         "utilities": "Utilities",
         "real-estate": "Real Estate",
         "general": "General News"
     };

def:pub sector_name(slug: str) -> str {
    return SECTION_NAMES.get(slug, slug);
}

def:pub source_name(value: str) -> str {
    if value == "rss" {
        return "RSS";
    }
    if value == "x" {
        return "X";
    }
    if value == "telegram" {
        return "Telegram";
    }
    return "Community";
}

def:pub count_label(value: any, singular: str, plural: str) -> str {
    return str(value or 0) + " " + (singular if value == 1 else plural);
}

def:pub display_date(value: any) -> str {
    return new(Date, str(value)).toLocaleDateString(
        "en-US", {"month": "short", "day": "numeric", "year": "numeric"}
    )
        if value
        else "";
}

def:pub public_url(value: any) -> str {
    url = str(value or "").strip();
    return url if url.startswith("https://") or url.startswith("http://") else "";
}

async def:pub request_json(path: str, method: str = "GET", body: any = None) -> any {
    options: any = {
        "method": method,
        "credentials": "same-origin",
        "cache": "no-store"
    };
    if body is not None {
        options.headers = {"Content-Type": "application/json"};
        options.body = JSON.stringify(body);
    }
    try {
        response = await fetch(path, options);
        data: any = await response.json();
        return {
            "ok": response.ok,
            "status": response.status,
            "data": data,
            "error": str(data.detail)
                if isinstance(data.detail, str)
                else "Request failed. Please try again."
        };
    } except Exception {
        return {
            "ok": False,
            "status": 0,
            "error": "Could not reach Newsstream. Please try again.",
            "data": {}
        };
    }
}

def:pub channel_preview(channel: any, sector: str = "") -> list[any] {
    return [
        item
        for item in channel.headlines
        if not sector
            or item.section == sector
            or (not item.section and sector in (channel.tags or [channel.category]))
    ][:3];
}

def:pub by_sector(channels: list[any], slug: str) -> list[any] {
    selected: list[any] = [];
    for ch in channels {
        if slug in (ch.tags or [ch.category])
            or len(
                [
                    h
                    for h in ch.headlines
                    if h.section == slug
                ]
            ) {
            selected.append(ch);
        }
    }
    return selected;
}

def:pub order_channels(channels: list[any], order: str) -> list[any] {
    values: any = [c for c in channels];
    values.sort(lambda (c: any) { return str(c.name).lower(); });
    if order == "clicks" {
        values.sort(lambda (c: any) { return -int(c.clicks); });
    } elif order == "rating" {
        values.sort(lambda (c: any) { return -int(c.recommendations); });
    } elif order == "category" {
        values.sort(lambda (c: any) { return sector_name(c.category); });
    } elif order == "new" {
        values.sort(
            lambda (c: any) { return -new(Date, str(c.created_at)).getTime(); }
        );
    }
    return values;
}
