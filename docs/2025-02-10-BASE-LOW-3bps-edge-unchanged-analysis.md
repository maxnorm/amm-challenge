# Why BASE_LOW = 3 bps Left Edge at 379.74

**Date:** 2025-02-10  
**Context:** Hypothesis: “Higher base (8 bps) plus activity on top can overcharge vs YQ’s 3 bps + build-up.” We changed `BASE_LOW` from 8e14 to 3e14. Edge stayed at **379.74**.

---

## 1. Why the edge barely moved

### 1.1 Imbalance floor dominates the “base” in practice

In Sapient V23 the **floor** is not just `BASE_LOW`; it’s:

```text
imbFloor = BASE_LOW + imbalance × FLOOR_IMB_SCALE
         = 3e14   + imbalance × 500e14   (FLOOR_IMB_SCALE = 0.5 in WAD)
```

So:

- **0% imbalance** → floor = 3 bps (base only).
- **10% imbalance** → floor = 3 + 5 = **8 bps** (already at old base).
- **20% imbalance** → floor = 3 + 10 = **13 bps**.

`rawFee` is forced **≥ imbFloor**. So whenever there is meaningful imbalance, the effective “base” is already well above 3 bps. Cutting `BASE_LOW` by 5 bps only shifts the floor by 5 bps in the **low-imbalance** regime. If the sim has few trades with near-zero imbalance, most of the time the floor is set by `imbalance × FLOOR_IMB_SCALE`, and changing `BASE_LOW` has limited impact.

### 1.2 Most of the fee is “activity,” not base

Even with base 3 bps, the additive terms dominate in active regimes:

- `SIGMA_COEF × sigmaHat` (15e18)
- `IMB_COEF × imbalance` (100e14)
- `VOL_COEF × vol` (15e18)
- Symmetric tox (linear + quad + SYM_HIGH above threshold)
- Then vulnerable-side tox premium, dir/surge/size, trade boost, tail compression

So typical fees are in the 20–75 bps range. A 5 bps reduction in the constant term is a small fraction of the total fee, and thus of revenue and edge.

### 1.3 Tail compression

Both strategies use `TAIL_KNEE = 5 bps`. For fees above the knee, the same slope compression applies. So the **structure** of the fee (base + lots of add-ons, then tail) is unchanged; we only shifted the constant term by 5 bps. That shift is small relative to the compressed range.

### 1.4 Net effect

- In **calm / low-imbalance** cases we now charge 3 bps instead of 8 → slightly less revenue per trade, possibly more volume.
- In **normal / high-imbalance** cases the floor and the rest of the formula already push fees well above 3 bps, so the base change has little effect.
- **Edge** (simulation score) can stay ~constant (e.g. 379.74) if: (a) most weight is in regimes where the floor and add-ons dominate, and (b) any volume gain from a lower calm fee roughly offsets the lower revenue in those few calm trades.

So: **matching YQ’s base level (3 bps) alone does not replicate YQ’s structure.** We still have “constant + our add-ons (imb, vol, symTox, floor, decay, dir, surge, size, tail)” rather than “low base + **activity-driven** build-up (λ, flowSize, actEma) + tox/stale/dir/tail” like YQ.

---

## 2. Structural takeaway

From the V23 vs YQ comparison doc:

- **YQ:** 3 bps base + **λ, flowSize** in base + **actEma** and tox build-up in mid.
- **Us (V23):** 3 bps base + **imbalance, vol, symTox** + floor + no λ/flowSize/actEma.

So:

1. **Base level** (3 vs 8 bps) is not the main differentiator in our sim; **floor and activity terms** are.
2. To get closer to YQ’s behavior we’d need to **replace or complement** our base formula with **activity-based** build-up (lambda, flowSize, actEma) and possibly **reduce** the role of the imbalance floor so that “low base” actually shows through when activity is low.
3. If we only lower base and keep **FLOOR_IMB_SCALE = 500e14**, we should not expect a big edge move; the floor still lifts the fee as soon as imbalance is non-trivial.

---

## 3. What to try next (optional)

- **Lower the imbalance floor** when using 3 bps base, so that “low base” matters in more states: e.g. reduce `FLOOR_IMB_SCALE` or make the floor depend on base in a gentler way (e.g. `imbFloor = BASE_LOW + smaller_coef × imbalance`), then re-run and compare edge.
- **Add activity in the base** (λ, flowSize, actEma) with the **low base (3 bps)** and **no** (or reduced) imbalance/vol in base, to mirror YQ’s “3 bps + build-up” and see if edge moves.
- **Instrument the sim** (if possible): fraction of trades where fee is at or near the floor, and average fee in “calm” vs “active” regimes, to see how often the 5 bps base cut actually affects the quoted fee.

---

## 4. Summary

| Change              | Effect on edge |
|---------------------|----------------|
| BASE_LOW 8 → 3 bps | Edge ~379.74 (unchanged) |

**Reason:** The **imbalance floor** (`BASE_LOW + 0.5×imbalance`) and the **additive terms** (sigma, imb, vol, tox, …) dominate in most regimes, so the 5 bps base cut only matters in low-imbalance/calm cases. Matching YQ’s **base level** alone is not enough; the **structure** (low base + activity-based build-up, different floor role) is what distinguishes YQ. Next step: adjust floor and/or add activity terms with the low base and re-test.
