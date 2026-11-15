"""Scene slots for the two cuts, shared by retime.py, prep-plates.py and make-captions.py.

Each narration line starts VO seconds into its scene. A slot is VO + the line's length
+ a short tail; the last scene adds a hold on the end card.
"""
VO = 0.4

# 16:9 master (README, docs site), about 112 s.
MASTER = [("s01", 5.5), ("s02", 9.2), ("s03", 13.6), ("s04", 12.5), ("s05", 8.4), ("s06", 11.0),
          ("s07", 13.2), ("s08", 10.0), ("s09", 7.6), ("s10", 7.9), ("s11", 12.7)]

# 1:1 LinkedIn cut: drops the four questions (s05) and the stack (s10), shorter tails.
SQUARE = [("s01", 5.4), ("s02", 9.0), ("s03", 13.5), ("s04", 12.3), ("s06", 10.6), ("s07", 13.1),
          ("s08", 9.9), ("s09", 7.6), ("s11", 11.0)]


def starts(slots):
    """Scene start times and the total length."""
    out, t = {}, 0.0
    for sid, d in slots:
        out[sid] = round(t, 2)
        t += d
    return out, round(t, 2)
