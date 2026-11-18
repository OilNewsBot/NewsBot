"""Shared sector labels for articles, subscriptions and personal sources."""
import re

from fastapi import HTTPException


SECTORS = ("energy", "tech", "healthcare", "industrials", "consumer-discretionary",
           "materials", "utilities", "real-estate", "general")

# Use specific terms for subtopics. A story without a clear match keeps its
# section label and has no subtopic. Headlines carry more weight than excerpts.
_TERMS = {
    "energy": {
        "Oil & gas": "oil|crude|petroleum|opec|natural gas|lng|refineries|refinery|shale",
        "Renewables": "solar|photovoltaic|wind farm[s]?|wind turbine[s]?|biofuels?",
    },
    "tech": {
        "Semiconductors": "semiconductors?|chipmakers?|microchips?|processors?|nvidia|chips",
        "Artificial intelligence": "artificial intelligence|machine learning|language models?|generative ai|chatgpt",
        "Cybersecurity": "cybersecurity|ransomware|cyberattacks?|security breach",
        "Software & cloud": "software|cloud computing|cloud services|icloud",
    },
    "healthcare": {
        "Medicines & trials": "clinical trials?|drugmakers?|vaccines?|fda|pharmaceuticals?",
        "Health services": "hospitals?|medicare|medicaid|health insurers?|patient care",
    },
    "industrials": {
        "Transportation & logistics": "freight|railroads?|railways?|logistics|cargo|shipping containers?",
        "Manufacturing": "factories|industrial production|heavy equipment|machine tools?|assembly lines?",
        "Aerospace": "aircraft|airplanes?|aerospace|jet engines?",
    },
    "consumer-discretionary": {
        "Retail": "retailers?|retail sales|department stores?|apparel|e-commerce",
        "Travel & leisure": "hotels?|cruise lines?|theme parks?|tourism",
        "Automobiles": "automakers?|car sales|electric vehicles?|auto sales",
    },
    "materials": {
        "Metals & mining": "mining|miners?|copper|iron ore|steelmakers?|aluminum|aluminium|gold mines?",
        "Chemicals & packaging": "specialty chemicals?|fertili[sz]ers?|chemical producers?|paper mills?|paperboard",
    },
    "utilities": {
        "Electric utilities": "electric utilit(?:y|ies)|transmission lines?|power grids?|grid operators?|ratepayers?|electricity rates?",
        "Water utilities": "water utilit(?:y|ies)|water treatment|wastewater|water rates?",
    },
    "real-estate": {
        "Housing": "homebuilders?|homebuilders? confidence|home sales|housing markets?|housing starts|mortgages?|home prices",
        "Commercial property": "reits?|office leasing|commercial (?:property|properties|real estate)|industrial real estate|office rents?",
    },
}
_PATTERNS = [(sector, topic, re.compile(r"\b(?:" + terms + r")\b", re.I))
             for sector, topics in _TERMS.items() for topic, terms in topics.items()]


def categories(value):
    if (not isinstance(value, list) or len(value) > len(SECTORS)
            or any(not isinstance(v, str) or v not in SECTORS for v in value)):
        raise HTTPException(422, "Choose categories from the Newsstream sectors")
    return list(dict.fromkeys(value))


def section_topic(title, text, section="general"):
    section = section if section in SECTORS else "general"
    scores = [(2 * len(pattern.findall(title)) + len(pattern.findall(text)), sector, topic)
              for sector, topic, pattern in _PATTERNS if section in ("general", sector)]
    best = max((score for score, _, _ in scores), default=0)
    winners = [(sector, topic) for score, sector, topic in scores if score == best and score > 0]
    if len(winners) == 1:
        return winners[0]
    if winners and len({sector for sector, _ in winners}) == 1:
        return winners[0][0], ""
    return section, ""


def channel_topic(title, text, assigned, primary, tags, mixed):
    if mixed or primary == "general":
        return section_topic(title, text, assigned or "general")
    if len(tags) > 1:
        section, topic = section_topic(title, text)
        if section in tags:
            return section, topic
    return section_topic(title, text, primary)
