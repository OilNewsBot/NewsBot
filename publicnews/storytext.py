"""Source-only change detection shared by private and public news journals."""
import html
import re


_NUMBERS = re.compile(r"(?<!\w)[+−-]?\d+(?:[.,]\d+)*%?")


def words(text):
    return re.findall(r"[\w]+", html.unescape(text or "").casefold())


def compact(text, length=320):
    text = " ".join((text or "").split())
    return text if len(text) <= length else text[:length - 1].rsplit(" ", 1)[0] + "…"


def meaningful_change(old_title, old_body, new_title, new_body):
    # Preserve signs and numeric order, including revisions that swap two
    # amounts without introducing any new words ("from 5 to 8" → "from 8 to 5").
    if _NUMBERS.findall(old_title or "") != _NUMBERS.findall(new_title or ""):
        return True
    if words(old_title) != words(new_title):
        return True
    old, new = words(old_body), words(new_body)
    if not new:
        return False
    if _NUMBERS.findall(old_body or "") != _NUMBERS.findall(new_body or ""):
        return True
    if old == new:
        return False
    changed = set(old) ^ set(new)
    material = {"no", "not", "never", "approved", "rejected", "denied", "cancelled", "halted",
                "resumed", "increased", "decreased", "one", "two", "three", "four", "five", "six",
                "seven", "eight", "nine", "ten"}
    return (any(any(c.isdigit() for c in word) for word in changed) or bool(changed & material)
            or len(changed) >= 3 or (len(new) <= 12 and len(changed) >= 2))


def changed_excerpt(old_body, new_title, new_body):
    def key(sentence):
        return tuple(words(sentence)), tuple(_NUMBERS.findall(sentence))
    before = {key(s) for s in re.split(r"(?<=[.!?])\s+|\n+", old_body or "")}
    fresh = [s.strip() for s in re.split(r"(?<=[.!?])\s+|\n+", new_body or "")
             if s.strip() and key(s) not in before]
    return compact(" ".join(fresh)) or new_title
