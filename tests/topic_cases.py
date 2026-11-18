"""Offline checks for source-text taxonomy and stable watch identifiers."""
from fastapi import HTTPException

from publicnews.topics import SECTORS, article_labels, facets, section_topic, taxonomy, topic_ids, watch_ids


def taxonomy_regressions():
    groups = taxonomy()
    assert [g["sector"] for g in groups] == list(SECTORS[:-1])
    options = {o["id"]: o["label"] for group in groups for o in group["topics"]}
    assert len(options) == sum(len(g["topics"]) for g in groups)
    assert all(len(g["topics"]) >= 4 for g in groups)
    assert topic_ids(list(options)) == list(options)
    axes = facets()
    assert set(axes) == {"events", "entities", "places"}
    all_ids = set(options)
    for choices in axes.values():
        assert choices and not all_ids.intersection(c["id"] for c in choices)
        all_ids.update(c["id"] for c in choices)
    assert set(watch_ids(sorted(all_ids))) == all_ids
    assert watch_ids(["event.refinancing", "event.refinancing"]) == ["event.refinancing"]
    assert watch_ids([]) == []
    for validate, value in [(topic_ids, ["event.refinancing"]), (watch_ids, ["real-estate.made-up"]),
                            (watch_ids, [False]), (topic_ids, "tech.foundries"), (topic_ids, [[]])]:
        try:
            validate(value)
        except HTTPException as e:
            assert e.status_code == 422
        else:
            raise AssertionError(f"Accepted invalid taxonomy selection {value!r}")

    def ids(title, body="", section="general"):
        result = article_labels(title, body, section)
        assert set(result) == {"subsectors", "events", "entities", "places"}
        for group in result.values():
            assert len(group) == len({tag["id"] for tag in group})
            assert all(tag["id"] in all_ids and tag["label"] for tag in group)
        return {axis: {tag["id"] for tag in group} for axis, group in result.items()}

    gas = ids("EIA forecasts U.S. LNG export capacity expansion", section="energy")
    assert {"energy.lng", "energy.lng-exports"} <= gas["subsectors"]
    assert gas["places"] == {"place.united-states"}
    assert gas["entities"] == {"entity.eia"}
    assert "event.capacity-expansion" in gas["events"]
    oil = ids("Oil production, refinery capacity and crude pipelines", section="energy")
    assert {"energy.exploration-production", "energy.refining", "energy.pipelines"} <= oil["subsectors"]
    assert section_topic("Oil refinery reports quarterly sales", "") == ("energy", "Oil & gas")

    chips = ids("ASML faces export restrictions on semiconductor equipment",
                "TSMC's chip foundries in Taiwan are investing in chip packaging.", "tech")
    assert {"tech.semiconductor-equipment", "tech.semiconductor-packaging", "tech.foundries"} <= chips["subsectors"]
    assert chips["events"] == {"event.export-restrictions"}
    assert chips["places"] == {"place.taiwan"} and chips["entities"] == {"entity.asml", "entity.tsmc"}
    assert section_topic("Chipmakers expand into new markets", "") == ("tech", "Semiconductors")

    apartments = ids("Apartment refinancing in Canada", section="real-estate")
    assert apartments["subsectors"] == {"real-estate.multifamily", "real-estate.property-finance"}
    assert apartments["events"] == {"event.refinancing"} and apartments["places"] == {"place.canada"}

    grid = ids("Electric utility awaits rate decision in Texas", "PUCT will review the rate case.", "utilities")
    assert {"utilities.electric-utilities", "utilities.rates"} <= grid["subsectors"]
    assert grid["events"] == {"event.rate-decisions"} and grid["places"] == {"place.texas"}
    assert grid["entities"] == {"entity.puct"}
    assert ids("Utility considers options", section="utilities")["subsectors"] == set()
    assert ids("FDA and Fannie Mae comment", section="tech")["entities"] == {"entity.fda", "entity.fannie-mae"}
    assert ids("Tesla and Rio Tinto discuss purchasing", section="materials")["entities"] == {"entity.tesla", "entity.rio-tinto"}
    assert "tech.foundries" not in ids("TSMC elects a director", section="tech")["subsectors"]

    for headline, expected in [
        ("FDA opens review of a medical device", "healthcare.medical-devices"),
        ("Port congestion hits container shipping", "industrials.maritime"),
        ("Restaurant chains expand summer menus", "consumer-discretionary.restaurants"),
        ("Lithium production rises", "materials.critical-minerals"),
    ]:
        assert expected in ids(headline)["subsectors"]

    for headline in ("Fish and chips with olive oil", "Please tell us about the fundraiser",
                     "Packaging design at the school fair", "Candidate strikes a deal",
                     "A biography of Nikola Tesla", "A Tesla coil demonstration",
                     "The team uses data mining", "An apple pie on the Amazon River"):
        assert not any(ids(headline).values()), headline
    assert not any(ids(None, None).values())
    isolation = ids("TSMC to buy semiconductor equipment in Texas", section="real-estate")
    assert isolation["subsectors"] == set() and isolation["places"] == {"place.texas"}
    assert section_topic("Election results arrive", "") == ("general", "")
    assert section_topic("Copper mining", "Copper market update.") == ("materials", "Metals & mining")


if __name__ == "__main__":
    taxonomy_regressions()
