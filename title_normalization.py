"""The Native normalizedTitle contract: C0 -> space, <=300 UTF-16 units at grapheme boundaries."""
import regex

_GRAPHEME = regex.compile(r'\X')

def normalized_title(title):
    # Python can hold surrogate code points; Swift String can only hold Unicode scalars.
    # Repair a valid UTF-16 pair, but reject unpaired surrogates instead of emitting invalid UTF-8.
    scalars = title.encode('utf-16-le', errors='surrogatepass').decode('utf-16-le')
    cleaned = ''.join(' ' if ord(c) <= 0x1f else c for c in scalars)
    parts = []; length = 0
    for match in _GRAPHEME.finditer(cleaned):
        cluster = match.group()
        units = len(cluster.encode('utf-16-le')) // 2
        if length + units > 300: break
        parts.append(cluster); length += units
    return ''.join(parts) or '無題'
