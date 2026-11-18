"""Deterministic article labels shared by public and private feeds.

IDs are persisted in watchlists. Keep an ID when changing a display name or
adding an alias. Facets describe mentions in the source text, including a
proposal or a denial. They do not verify a reported event.
"""
import re

from fastapi import HTTPException


SECTORS = ("energy", "tech", "healthcare", "industrials", "consumer-discretionary",
           "materials", "utilities", "real-estate", "general")

# The first group supplies the established single-topic feed label. The second
# group supplies more precise watch targets; one article can match several.
_BROAD = {
    "energy": [
        ("oil-gas", "Oil & gas", r"(?<!olive )(?<!cooking )(?<!palm )(?<!canola )(?<!vegetable )(?<!soybean )(?<!essential )oil(?! paint)|crude (?:oil|prices?|exports?|production|futures|imports?|output)|Brent crude|WTI|petroleum|OPEC|natural gas|LNG|refiner(?:y|ies)|shale"),
        ("renewables", "Renewables", r"solar (?:power|panels?|energy|projects?|farms?|installations?|generation)|photovoltaics?|wind farms?|wind turbines?|biofuels?"),
    ],
    "tech": [
        ("semiconductors", "Semiconductors", r"semiconductors?|chipmakers?|microchips?|microprocessors?|(?:computer|graphics|server) processors?|Nvidia|(?:AI|computer|memory|logic) chips?|chip (?:design|manufacturing|equipment|packaging)|TSMC"),
        ("ai", "Artificial intelligence", r"artificial intelligence|machine learning|language models?|generative AI|ChatGPT|AI (?:models?|agents?|tools?|inference)"),
        ("cybersecurity", "Cybersecurity", r"cybersecurity|ransomware|cyberattacks?|data breaches|security breaches|security breach"),
        ("software-cloud", "Software & cloud", r"software|cloud computing|cloud services|iCloud|data cent(?:er|re)s?"),
    ],
    "healthcare": [
        ("medicines-trials", "Medicines & trials", r"clinical trials?|drugmakers?|vaccines?|FDA|pharmaceuticals?"),
        ("health-services", "Health services", r"hospitals?|Medicare|Medicaid|health insurers?|patient care"),
    ],
    "industrials": [
        ("transport-logistics", "Transportation & logistics", r"freight|railroads?|railways?|logistics|cargo|shipping containers?"),
        ("manufacturing", "Manufacturing", r"factories|industrial production|heavy equipment|machine tools?|assembly lines?"),
        ("aerospace", "Aerospace", r"aircraft|airplanes?|aerospace|jet engines?"),
    ],
    "consumer-discretionary": [
        ("retail", "Retail", r"retailers?|retail sales|department stores?|apparel|e-commerce"),
        ("travel-leisure", "Travel & leisure", r"hotels?|cruise lines?|theme parks?|tourism"),
        ("automobiles", "Automobiles", r"automakers?|car sales|electric vehicles?|auto sales"),
    ],
    "materials": [
        ("metals-mining", "Metals & mining", r"(?<!data )(?<!crypto )(?<!bitcoin )mining|(?<!crypto )(?<!bitcoin )miners?|copper|iron ore|steelmakers?|alumin(?:um|ium)|gold mines?"),
        ("chemicals-packaging", "Chemicals & packaging", r"specialty chemicals?|fertili[sz]ers?|chemical producers?|paper mills?|paperboard"),
    ],
    "utilities": [
        ("electric-utilities", "Electric utilities", r"electric(?:ity)? utilit(?:y|ies)|transmission lines?|power grids?|grid operators?|ratepayers?|electricity rates?|power distribution"),
        ("water-utilities", "Water utilities", r"water utilit(?:y|ies)|water treatment|wastewater|water rates?"),
    ],
    "real-estate": [
        ("housing", "Housing", r"homebuilders?|home sales|housing markets?|housing starts|mortgages?|home prices"),
        ("commercial-property", "Commercial property", r"REITs?|office leasing|commercial (?:property|properties|real estate)|industrial real estate|office rents?"),
    ],
}

_DETAIL = {
    "energy": [
        ("lng", "Liquefied natural gas", r"LNG|liquefied natural gas"),
        ("lng-exports", "LNG exports", r"(?:LNG|liquefied natural gas) (?:export(?:s|ers?|ing)?|liquefaction (?:plants?|terminals?|capacity))|export(?:s|ing)? (?:of )?(?:LNG|liquefied natural gas)"),
        ("exploration-production", "Exploration & production", r"exploration and production|upstream (?:oil|gas|energy)|(?:oil|gas|shale) (?:drilling|exploration|production|wells?)|crude (?:output|production)|drilling rigs?"),
        ("refining", "Refining", r"refiner(?:y|ies)|refining (?:capacity|margins?|operations)|crude distillation|oil refiners?"),
        ("pipelines", "Oil & gas pipelines", r"(?:oil|gas|crude|petroleum|fuel) pipelines?|pipelines? (?:carrying|transporting) (?:crude|oil|gas)"),
        ("tanker-shipping", "Tanker shipping", r"oil tankers?|LNG carriers?|tanker (?:freight|traffic|rates|shipments)|crude (?:cargoes|shipments)|seaborne (?:oil|crude)"),
    ],
    "tech": [
        ("semiconductor-equipment", "Semiconductor equipment", r"(?:semiconductor|chipmaking|chip manufacturing|wafer fabrication|chip) equipment|(?:EUV|chip|semiconductor) lithography|lithography (?:systems?|machines?|tools?)"),
        ("semiconductor-packaging", "Semiconductor packaging", r"(?:semiconductor|chip|chiplet|wafer(?:-level)?) packaging|advanced packaging (?:of|for) (?:chips|semiconductors)|CoWoS"),
        ("foundries", "Chip foundries", r"(?:chip|semiconductor|silicon|contract chip) foundr(?:y|ies)|(?:chip|semiconductor|wafer) fabs?|wafer fabrication"),
        ("networking", "Networks & connectivity", r"fiber broadband|broadband networks?|network infrastructure|telecom equipment|internet routing"),
    ],
    "healthcare": [
        ("biotech", "Biotechnology", r"biotech(?:nology)?|gene therap(?:y|ies)|cell therap(?:y|ies)|biologics"),
        ("medical-devices", "Medical devices", r"medical devices?|surgical robots?|diagnostic devices?|medical implants?"),
        ("health-insurance", "Health insurance", r"health insur(?:ers?|ance)|Medicare Advantage|Medicaid plans?|health plans?"),
    ],
    "industrials": [
        ("maritime", "Ports & maritime freight", r"container (?:shipping|ports?|ships?)|port (?:operators?|congestion|throughput)|maritime (?:trade|shipping|security)|commercial shipping"),
        ("aviation", "Aviation", r"airlines?|airliners?|air travel|civil aviation|air traffic"),
        ("rail", "Rail transport", r"rail (?:freight|operators?|network)|freight rail|railroads?|railways?"),
    ],
    "consumer-discretionary": [
        ("restaurants", "Restaurants", r"restaurants?|fast-food chains?|quick-service chains?|same-store restaurant sales"),
        ("apparel", "Apparel & footwear", r"apparel|footwear|sportswear|fashion retailers?"),
        ("electric-vehicles", "Electric vehicles", r"electric vehicles?|electric cars?|battery electric|EV (?:sales|deliveries|makers)"),
    ],
    "materials": [
        ("critical-minerals", "Critical minerals", r"critical (?:minerals?|metals)|lithium|rare earths?|nickel sul(?:f|ph)ate|cobalt mines?"),
        ("steel", "Steel", r"steel (?:mills?|prices?|production|imports?)|steelmakers?|steelmaking|iron ore"),
        ("polymers", "Plastics & polymers", r"polymers?|polyethylene|polypropylene|plastic resins?"),
    ],
    "utilities": [
        ("grid-transmission", "Grid & transmission", r"power grids?|grid (?:operators?|connections?|investment|reliability)|transmission (?:lines?|networks?|capacity)|electricity transmission"),
        ("rates", "Utility rates", r"rate cases?|ratepayers?|(?:electricity|utility|water|electric) rates?|public utility rate|utility tariffs?"),
        ("power-generation", "Power generation", r"power plants?|electricity generation|nuclear reactors?|generating stations?|hydropower generation"),
        ("storage", "Grid storage", r"grid[- ]scale (?:battery|storage)|battery storage|energy storage (?:capacity|systems?|projects?)"),
    ],
    "real-estate": [
        ("multifamily", "Apartments & multifamily", r"multifamily|multi-family housing|apartment (?:buildings?|leases?|rents?|loans?|mortgages?|refinanc\w*|complex(?:es)?|operators?|markets?|development)|affordable housing"),
        ("property-finance", "Property finance", r"mortgage (?:rates?|lenders?|refinanc\w*|servicing)|(?:property|apartment|multifamily|real estate) refinanc\w*|commercial mortgages?|CMBS"),
        ("office", "Office property", r"office (?:leases?|leasing|rents?|vacanc(?:y|ies)|property|properties|buildings?)"),
    ],
}

# Use unambiguous names or domain-specific phrases for proper names and events.
_FACET_RULES = {
    "events": ("event", [
        ("export-restrictions", "Export restrictions", r"export (?:controls?|curbs?|bans?|restrictions?|licen[sc]ing requirements?)|restrict(?:ed|s|ing)? exports?|ban(?:s|ned)? (?:on )?exports?"),
        ("sanctions", "Sanctions", r"sanctions|sanctioned (?:entities|companies|vessels|banks)"),
        ("rate-decisions", "Rate decisions", r"rate (?:decisions?|cases?|orders?|rulings?)|(?:approves?|approved|denies|denied|rejects?|rejected) (?:an? |the )?(?:electricity |water |utility )?rate (?:hike|increase|cut)|(?:interest|policy) rate (?:cut|hike|decision)"),
        ("refinancing", "Refinancing", r"refinanc(?:e|ed|es|ing)|debt refinancing"),
        ("earnings", "Earnings", r"quarterly (?:earnings|results|profit)|earnings (?:report|call|forecast)|full-year results"),
        ("acquisition", "Mergers & acquisitions", r"mergers?|acquisition agreements?|takeover (?:bids?|offers?)|acqui(?:res|red) (?:a |an |the )?(?:company|competitor|stake)"),
        ("capacity-expansion", "Capacity expansion", r"(?:capacity|terminal|pipeline|plant|facility) expansions?|expand(?:s|ed|ing)? (?:[a-z-]+ ){0,3}capacity|additional (?:export|production|generation) capacity"),
        ("outage", "Outages & disruptions", r"outages?|service disruptions?|supply disruptions?|production halts?|suspend(?:ed|s)? operations"),
        ("regulatory-review", "Regulatory review", r"regulatory (?:approvals?|reviews?|clearance)|FDA approv(?:es|als?|ed)|antitrust reviews?|permitting hearings?"),
        ("clinical-trial", "Clinical trials", r"clinical trials?|phase (?:1|2|3|I|II|III) (?:stud(?:y|ies)|trials?)"),
        ("strike", "Labor action", r"workers? (?:strike|walkout)|labor strikes?|union (?:strike|walkout)|strike (?:action|vote)|strike by (?:workers|employees)"),
        ("tariffs", "Trade tariffs", r"import (?:tariffs?|duties)|tariffs? on (?:imports?|steel|goods|vehicles)|trade tariffs?"),
    ]),
    "entities": ("entity", [
        ("opec", "OPEC", r"OPEC\+?|Organi[sz]ation of the Petroleum Exporting Countries"),
        ("eia", "U.S. Energy Information Administration", r"Energy Information Administration|(?-i:EIA)"),
        ("ukmto", "UK Maritime Trade Operations", r"UKMTO|UK Maritime Trade Operations|United Kingdom Maritime Trade Operations"),
        ("ferc", "Federal Energy Regulatory Commission", r"Federal Energy Regulatory Commission|FERC"),
        ("ercot", "ERCOT", r"ERCOT|Electric Reliability Council of Texas"),
        ("puct", "Public Utility Commission of Texas", r"Public Utility Commission of Texas|Texas Public Utility Commission|(?-i:PUCT)"),
        ("tsmc", "TSMC", r"TSMC|Taiwan Semiconductor Manufacturing(?: Company)?"),
        ("nvidia", "Nvidia", r"Nvidia"),
        ("asml", "ASML", r"ASML"),
        ("fda", "U.S. Food and Drug Administration", r"Food and Drug Administration|(?-i:FDA)"),
        ("cms", "Centers for Medicare & Medicaid Services", r"Centers for Medicare (?:and|&) Medicaid Services"),
        ("boeing", "Boeing", r"Boeing"),
        ("faa", "Federal Aviation Administration", r"Federal Aviation Administration|(?-i:FAA)"),
        ("tesla", "Tesla", r"(?<!Nikola )(?-i:Tesla)(?! coils?| units?)(?: Motors| Inc\.?)?"),
        ("bhp", "BHP", r"(?-i:BHP)(?: Group)?"),
        ("rio-tinto", "Rio Tinto", r"Rio Tinto"),
        ("fannie-mae", "Fannie Mae", r"Fannie Mae|Federal National Mortgage Association"),
        ("freddie-mac", "Freddie Mac", r"Freddie Mac|Federal Home Loan Mortgage Corporation"),
        ("federal-reserve", "Federal Reserve", r"Federal Reserve|Federal Open Market Committee|FOMC"),
    ]),
    "places": ("place", [
        ("united-states", "United States", r"United States|(?-i:U\.?S\.(?:A\.)?|USA|US)"),
        ("texas", "Texas", r"Texas"),
        ("gulf-coast", "U.S. Gulf Coast", r"(?:U\.?S\.?|Texas|Louisiana) Gulf Coast"),
        ("strait-of-hormuz", "Strait of Hormuz", r"(?:Strait of )?Hormuz"),
        ("suez-canal", "Suez Canal", r"Suez Canal"),
        ("red-sea", "Red Sea", r"Red Sea"),
        ("taiwan", "Taiwan", r"Taiwan(?:ese)?"),
        ("china", "China", r"China|Chinese"),
        ("japan", "Japan", r"Japan(?:ese)?"),
        ("south-korea", "South Korea", r"South Korea(?:n)?"),
        ("iran", "Iran", r"Iran(?:ian)?"),
        ("saudi-arabia", "Saudi Arabia", r"Saudi Arabia(?:n)?"),
        ("canada", "Canada", r"Canada|Canadian"),
        ("european-union", "European Union", r"European Union|(?-i:EU)"),
    ]),
}


def _compile(rules, prefix):
    return [(f"{prefix}.{slug}", label, re.compile(r"(?<!\w)(?:" + terms + r")(?!\w)", re.I))
            for slug, label, terms in rules]


_BROAD_RULES = {s: _compile(_BROAD[s], s) for s in _BROAD}
_DETAIL_RULES = {s: _compile(_DETAIL[s], s) for s in _DETAIL}
_SECTOR_RULES = {s: _BROAD_RULES[s] + _DETAIL_RULES[s] for s in _BROAD}
_FACETS = {axis: _compile(rules, prefix) for axis, (prefix, rules) in _FACET_RULES.items()}
_TOPIC_IDS = frozenset(key for rules in _SECTOR_RULES.values() for key, _, _ in rules)
_WATCH_IDS = _TOPIC_IDS.union(key for rules in _FACETS.values() for key, _, _ in rules)


def _validate(value, known, detail):
    if (not isinstance(value, list) or len(value) > len(known)
            or any(not isinstance(v, str) or v not in known for v in value)):
        raise HTTPException(422, detail)
    return list(dict.fromkeys(value))


def categories(value):
    return _validate(value, SECTORS, "Choose categories from the NewsDrop sectors")


def topic_ids(value):
    return _validate(value, _TOPIC_IDS, "Choose a subsector from the NewsDrop taxonomy")


def watch_ids(value):
    return _validate(value, _WATCH_IDS, "Choose a topic, event, entity or place from the NewsDrop taxonomy")


def _options(rules):
    return [{"id": key, "label": label} for key, label, _ in rules]


def taxonomy():
    return [{"sector": sector, "topics": _options(rules)} for sector, rules in _SECTOR_RULES.items()]


def facets():
    return {axis: _options(rules) for axis, rules in _FACETS.items()}


def _matches(rules, content):
    return [{"id": key, "label": label} for key, label, pattern in rules if pattern.search(content)]


def article_labels(title, text, section="general"):
    content = f"{title or ''}\n{text or ''}"
    # A directed section narrows subsectors only. A geographic or regulatory
    # mention can occur in any section. General News can match multiple sectors.
    eligible = [_SECTOR_RULES[section]] if section in _SECTOR_RULES else _SECTOR_RULES.values()
    return {"subsectors": [label for rules in eligible for label in _matches(rules, content)],
            **{axis: _matches(rules, content) for axis, rules in _FACETS.items()}}


def section_topic(title, text, section="general"):
    section = section if section in SECTORS else "general"
    for group in (_BROAD_RULES, _DETAIL_RULES):
        matches = []
        for sector, rules in group.items():
            if section not in ("general", sector):
                continue
            for _, label, pattern in rules:
                score = 2 * len(pattern.findall(title or "")) + len(pattern.findall(text or ""))
                if score:
                    matches.append((score, sector, label))
        if matches:
            best = max(score for score, _, _ in matches)
            winners = [(sector, topic) for score, sector, topic in matches if score == best]
            if len(winners) == 1:
                return winners[0]
            if len({sector for sector, _ in winners}) == 1:
                return winners[0][0], ""
            return section, ""
    return section, ""


def channel_topic(title, text, assigned, primary, tags, mixed):
    if mixed or primary == "general":
        return section_topic(title, text, assigned or "general")
    if len(tags) > 1:
        section, topic = section_topic(title, text)
        if section in tags:
            return section, topic
    return section_topic(title, text, primary)
