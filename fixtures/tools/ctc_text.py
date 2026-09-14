import re

def normalize_ctc_text(text, labels):
    dictionary = {c: i for i, c in enumerate(labels)}
    parts, chars, events = [], [], []
    for match in re.finditer(r'\S+', text):
        first = len(chars)
        for offset, character in enumerate(match.group()):
            if character.isascii() and character.isalpha() or character == "'":
                symbol = character.upper()
                if symbol not in dictionary:
                    raise ValueError(f'Unsupported acoustic symbol {symbol!r}')
                chars.append(symbol)
            elif character == '-':
                chars.append('|')
                events.append({'position': match.start() + offset, 'character': character, 'action': 'hyphen to CTC separator; original lexeme retained'})
            elif character in '.,!?;:"()[]':
                events.append({'position': match.start() + offset, 'character': character, 'action': 'punctuation omitted from acoustic target; original lexeme retained'})
            else:
                raise ValueError(f'Unsupported transcript character {character!r} at {match.start() + offset}; no token dropped')
        if len(chars) == first or not any(c != '|' for c in chars[first:]):
            raise ValueError('Word has no supported acoustic symbols')
        parts.append({'text': match.group(), 'location': match.start(), 'length': len(match.group()), 'charStart': first, 'charEnd': len(chars)})
        chars.append('|')
    if not parts:
        raise ValueError('Empty transcript')
    chars.pop()
    return parts, chars, events
