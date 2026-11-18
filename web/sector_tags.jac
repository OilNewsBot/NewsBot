"""Category labels and choices used by channels, subscriptions and personal sources."""

import from .public_data { SECTORS, sector_name }
import "./sector_tags.css";

def:pub SectorTags(tags: list[any], topic: str = "") -> JsxElement {
    <span className="sector-labels" aria-label="Coverage">
        {for tag in tags {
            <span key={str(tag)} className="sector-label" data-sector={str(tag)}>
                {sector_name(str(tag))}
            </span>
        }}
        {if topic {
            <span className="topic-label">{topic}</span>
        }}
    </span>
}

def:pub SectorPicker(
    selected: list[any],
    onChange: any,
    label: str,
    primary: str = "",
    disabled: bool = False,
    allowAll: bool = False
) -> JsxElement {
    def toggle(slug: str) {
        if slug in selected {
            onChange(
                [
                    s
                    for s in selected
                    if s != slug
                ]
            );
        } else {
            onChange(selected + [slug]);
        }
    }
    <fieldset className="sector-picker" disabled={disabled}>
        <legend>{label}</legend>
        <div className="sector-options">
            {if allowAll {
                <button
                    type="button"
                    className="sector-option"
                    aria-pressed={not len(selected)}
                    onClick={lambda { onChange([]); }}
                >
                    All categories
                </button>
            }}
            {for slug in SECTORS + ["general"] {
                <button
                    type="button"
                    key={slug}
                    data-sector={slug}
                    className="sector-option"
                    aria-pressed={slug == primary or slug in selected}
                    disabled={slug == primary}
                    onClick={lambda { toggle(slug); }}
                >
                    {sector_name(slug)}
                </button>
            }}
        </div>
    </fieldset>
}
