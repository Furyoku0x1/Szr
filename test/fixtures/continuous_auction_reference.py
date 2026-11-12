"""Unbounded-integer reference for ContinuousAuction, above the original library's range.

A direct transliteration of the audited single-word algorithm (frozen in
test/utils/ContinuousAuctionV1.sol) with Python integers, so nothing can overflow. It writes
two files of operation sequences with the exact state expected after every step:

- continuous-auction-inrange.json: inside the original's range, checked against the frozen
  original to show this transliteration is faithful.
- continuous-auction-extended.json: products larger than the original could hold, checked
  against the live library.

    python3 test/fixtures/continuous_auction_reference.py
"""

import json
import random
from pathlib import Path

DURATION = 2 * 24 * 60 * 60
WAD = 10**18
WORD = 2**256 - 1
OLD_CAP = WORD // DURATION
MAX_DEPTH = 818592150592861781622465154682686325
FULL_DEPTH = 1_000_020_000 * WAD  # total supply plus the sale buffer
STEPS = 6


def up(a, b):
    return -(-a // b)


class Curve:
    def __init__(self, depth, price, floor):
        self.depth, self.floor = depth, floor
        self.mass = (price - floor) * depth * depth
        self.time = self.mass * DURATION  # the original's `excessTime`, never truncated
        self.scaled = 0  # the last purchase's intermediate, which must also fit one word

    def product(self):
        return self.floor * self.depth**2 + up(self.time, DURATION)

    def price(self):
        return up(self.product(), self.depth**2)

    def project(self, elapsed, depth):
        if self.mass != 0:
            if elapsed >= up(self.time, self.mass):
                self.time = self.mass = 0
            else:
                self.time -= self.mass * elapsed
        if depth != self.depth:
            old, new = self.depth**2, depth**2
            self.time = up(self.time * new, old)
            self.mass = up(self.mass * new, old)
            self.depth = depth

    def buy(self, quantity):
        invariant = self.product()
        self.scaled = up(invariant * quantity, self.depth * (self.depth - quantity))
        payment = up(self.scaled, WAD)
        old = self.depth**2
        self.depth -= quantity
        new = self.depth**2
        baseline = up(self.time * new, old)
        mass = up(self.mass * new, old)
        self.time = (invariant - self.floor * new) * DURATION
        self.mass = mass + up(self.time - baseline, DURATION)
        return payment

    def fits(self):
        words = (self.product(), self.mass, self.scaled)
        return max(words) <= WORD and self.depth <= MAX_DEPTH

    def encoded(self):
        excess = up(self.time, DURATION)
        return excess, excess * DURATION - self.time


def depth(rng):
    scale = 10 ** rng.randint(18, 27)
    return rng.randint(scale, min(scale * 10, FULL_DEPTH))


def elapsed(rng):
    return rng.choice([
        0,
        rng.randint(1, 600),
        rng.randint(1, DURATION - 1),
        rng.randint(DURATION - 2, DURATION + 2),
        rng.randint(DURATION, 10**10),
    ])


def vector(rng, extended):
    start = depth(rng)
    if extended:
        # Log-uniform between the original's ceiling and the new one, so depth has room to grow.
        low = max(2, OLD_CAP // start**2 + 1)
        price = low + ((WORD // start**2 - low) >> rng.randint(0, 17))
    else:
        if OLD_CAP // start**2 < 2:
            return None
        price = rng.randint(2, (OLD_CAP // start**2) >> rng.randint(0, 40) or 2)
    floor = rng.randint(1, price - 1)
    curve = Curve(start, price, floor)
    rows = []
    for _ in range(STEPS):
        kind = rng.randint(0, 2)
        if kind == 2 and curve.depth >= 2:
            amount = rng.choice([rng.randint(1, 1000), rng.randint(1, curve.depth - 1)])
            wait, target = amount, 0
            payment = curve.buy(amount)
        else:
            kind = kind % 2
            wait = elapsed(rng)
            target = curve.depth if kind == 0 else depth(rng)
            payment = 0
            curve.project(wait, target)
        if not curve.fits():
            return None
        if not extended and curve.product() > OLD_CAP:
            return None
        excess, deficit = curve.encoded()
        time = 0 if extended else curve.time
        rows.append(
            (kind, wait, target, payment, curve.price(), excess, deficit, curve.mass, time)
        )
    if extended and curve.product() <= OLD_CAP:
        return None  # decayed back inside the original's range; not what this file is for
    names = ["kind", "first", "second", "payment", "price", "excess", "deficit", "mass", "time"]
    out = {"depth": hex(start), "opening": hex(price), "floor": hex(floor)}
    for position, name in enumerate(names):
        out[name] = [hex(row[position]) for row in rows]
    return out


def main():
    rng = random.Random(20261112)
    for extended, name in ((True, "extended"), (False, "inrange")):
        vectors = []
        while len(vectors) < 60:
            candidate = vector(rng, extended)
            if candidate is not None:
                vectors.append(candidate)
        target = Path(__file__).with_name(f"continuous-auction-{name}.json")
        target.write_text(json.dumps(vectors, indent=1) + "\n")
        print(f"wrote {len(vectors)} vectors to {target.name}")


if __name__ == "__main__":
    main()
