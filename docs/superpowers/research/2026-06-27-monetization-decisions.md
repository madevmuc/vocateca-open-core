# Decision-Support Memo — Paragraphos Monetization (Open Decisions)

**Date:** 2026-06-27
**For:** Solo developer (Germany), turning Paragraphos into Open-Core (free manual + paid Pro automation).
**Scope:** The three open decision items from the monetization design
(`docs/superpowers/specs/2026-06-27-paragraphos-monetization-design.md`, §"Offene Entscheidungs-Items"):
(1) Nhost as EU auth/entitlement backend, (2) EU Merchant-of-Record choice, (3) Pro subscription pricing.

> **Not legal/tax advice.** This is technically-grounded vendor research to support a decision.
> Confirm exact domiciles, sub-processor lists, and DSGVO/AVV (DPA) terms in writing with each
> vendor before signing, and have the EULA / VAT setup reviewed by a German IT/tax professional
> before commercial launch. Web sources were read on 2026-06-27 and are listed per section.

---

## Decision 1 — Nhost as EU auth + entitlement backend

### Findings

- **Corporate domicile.** Nhost presents itself as a European/EU-native managed BaaS, consistently
  described as **Sweden-based** (matching the spec's assumption). I could **not** independently
  verify the exact registered legal entity name and Swedish company-register number from public
  pages in this pass — Nhost's marketing pages assert European/EU-native positioning but do not
  print the entity/Handelsregister details on the homepage or pricing page. **This must be
  confirmed in writing** (entity name + registration number + registered seat) before relying on
  "EU member state domicile" as a compliance fact. Confidence on "Sweden / EU" is **moderate**;
  confidence on the *specific legal entity* is **low** until confirmed.
- **EU data region.** Nhost runs multiple regions (marketing cites "6 Regions / 4 Continents"),
  and third-party write-ups describe a **primary EU region in Frankfurt (eu-central-1)**. So an
  EU-resident deployment is available — but the *default* region for a new project may not be EU.
  **Action:** explicitly select the EU/Frankfurt region at project creation and confirm no
  personal data lands in a non-EU region.
- **DSGVO / AVV (DPA).** Nhost is repeatedly listed among GDPR-compliant EU BaaS options and is
  described as advertising GDPR/DPA. I could not retrieve a public DPA document URL in this pass
  (the obvious `/legal/dpa` path 404'd). **Action:** request the signed AVV/DPA (Art. 28 DSGVO)
  directly and obtain the **sub-processor list** in writing.
- **Sub-processor caveat (important).** Under the hood Nhost is built on **Hasura** (GraphQL over
  Postgres), Hasura Auth (JWT, magic links, OAuth, MFA), Hasura Storage (S3-backed), and
  serverless functions. The compute almost certainly runs on a **US hyperscaler (AWS)** even when
  the *region* is Frankfurt. EU region ≠ EU-only sub-processors: an EU-region AWS deployment still
  has a US parent in the processing chain (CLOUD Act exposure). For Paragraphos this is **low
  practical risk** because the data stored is minimal (email + subscription status + JWT), but it
  is a caveat to document in the privacy policy and to confirm against the sub-processor list.
- **Pricing (relevant tiers for a small app):**
  - **Starter — $0/mo:** 1 GB DB, 1 GB storage, 5 GB egress, 1 project, **pauses after 1 week
    of inactivity** → unsuitable for a production entitlement backend that must answer auth/
    entitlement checks at any time.
  - **Pro — from $25/mo** ($15 compute credits included): 10 GB DB, 50 GB storage, 50 GB egress,
    automated backups + point-in-time recovery. **This is the realistic floor for production.**
  - Team ($599/mo) and Enterprise (custom) add SOC 2 Type II and SLAs — overkill at this stage.

### Recommendation

**Proceed with Nhost on the Pro plan (~$25/mo) for production, in the EU/Frankfurt region**, for an
auth + entitlement workload this small. It fits the design (magic-link JWT + a `subscriptions`
table + entitlement check) and is the most EU-native managed option. **Gate the go-live on three
written confirmations:** (a) registered legal entity + EU seat, (b) a signed Art. 28 AVV/DPA, and
(c) the sub-processor list with the EU region pinned. Note the $25/mo recurring cost as a fixed
COGS line against Pro revenue (≈ break-even at a handful of subscribers).

**Confidence:** Moderate. The fit and EU-region availability are solid; the unverified specifics
(exact entity, DPA document, sub-processor chain) are the gating risk.

### Open questions
- Exact Nhost legal entity, Swedish registration number, and registered seat?
- Is a signed AVV/DPA provided self-serve, and what is the full sub-processor list (AWS region,
  email/OTP delivery provider for magic links — a likely additional sub-processor)?
- Can the EU region be enforced/locked, and is failover ever to a non-EU region?
- Magic-link email delivery: which provider sends it, and is *that* EU-domiciled? (Auth emails
  carry personal data and add a sub-processor regardless of where Nhost sits.)

---

## Decision 2 — EU-domiciled Merchant of Record (vs. PSP + own OSS)

For an indie/solo dev selling a **low-priced** Mac-app subscription, the decisive axes are
**self-serve onboarding**, **no contract minimums / enterprise gates**, **EU domicile**, and
**who carries the EU-VAT**. Findings per option:

| Option | Domicile | VAT carried by | Fees (indicative) | Indie / self-serve? | Subscriptions | Notes |
|---|---|---|---|---|---|---|
| **Cleverbridge** | Cologne, **DE** | MoR (Cleverbridge) | ~2.5–8% rev + **platform fee ~$50k–200k/yr** reported; negotiated, no public rate card | **No** — sales-assisted, enterprise-gated | Yes | Best-in-class EU MoR but structurally for enterprise; no self-serve signup. |
| **Nexway** | Nîmes, **FR** | MoR (Nexway) | "Success-based," negotiated; **no public rate card** | **No** — no self-serve signup flow | Yes | Enterprise/premium MoR; exceeds an early indie's needs. |
| **Vatly** | **NL** (Sandorian Consultancy B.V., KvK 84842822) | MoR (Vatly) | "Start free, pay only when you earn"; **exact % not public**; early-access | **Partly** — built for EU SaaS founders, but **early-access / limited spots / dedicated onboarding** as of 2025 → not yet frictionless self-serve | Yes (subscription management) | Genuinely EU-domiciled (NL), the best *fit philosophy*, but maturity/availability and undisclosed % are the risk. |
| **Mollie (NL) PSP + own OSS/OSS-VAT** | **NL** (PSP only) | **You** (via DE OSS / One-Stop-Shop) | Transparent: cards ~€0.25 + 1.8%; SEPA DD ~€0.25 + 0.9%; iDEAL ~€0.29 flat; **no monthly minimum** | **Yes** — fully self-serve | Recurring via SEPA mandates / Mollie subscriptions API | Cheapest per-transaction, but **you** own VAT filing, invoicing, and consumer-law obligations. |

Key facts behind the table:
- **Cleverbridge (DE):** Pricing is negotiated through sales — reported ~2.5–8% of revenue plus a
  substantial annual platform fee, no public rate card, no self-serve signup. Excellent EU MoR,
  wrong size class for a solo dev at launch.
- **Nexway (FR):** Success-based, negotiated pricing, **no self-serve signup**; positioned for
  SaaS/enterprise. Same size-class mismatch.
- **Vatly (NL):** Explicitly the "MoR built for European SaaS," EU-incorporated (NL), markets
  "no monthly fee, pay only when you earn," and supports EU payment methods (iDEAL/SEPA/Bancontact)
  and subscription management. As MoR, **Vatly carries the VAT**. Caveats: it launched into
  **early access in 2025 with limited spots + dedicated onboarding**, and it does **not publish its
  transaction %**. So the *fit* is ideal but the *maturity/terms* are unconfirmed.
- **Mollie + own OSS (NL PSP):** Transparent low per-transaction fees, no minimums, fully
  self-serve, recurring billing supported. The trade-off is real: with a PSP you are **not** an
  MoR, so **you** register for the EU One-Stop-Shop (OSS) in Germany and remit VAT yourself
  (optionally automating invoicing/VAT via a tool such as Quaderno). More admin, lower fees, full
  EU footprint.

### Recommendation

**Primary: choose an EU-domiciled MoR so you do not personally carry EU-VAT or consumer-invoicing —
and for a solo indie, Vatly (NL) is the best-fit candidate** *provided* it clears two checks: a
published/quoted transaction % you find acceptable, and general (non-waitlisted) availability with
no contract minimum. If Vatly is acceptable on those two points, it dominates for this use case:
EU domicile (NL → full DSGVO), MoR carries VAT, subscription support, indie philosophy, webhook to
fill the Nhost `subscriptions` table.

**Fallback A (if Vatly's terms/availability don't pan out): Mollie (NL) + DE OSS self-registration.**
This keeps everything EU-domiciled and self-serve at the lowest fees, at the cost of you running
OSS-VAT and invoicing (mitigate with Quaderno-style automation). This is the pragmatic EU-pure
path if no EU MoR will take a tiny account on clean terms.

**Not recommended at launch: Cleverbridge / Nexway** — both are enterprise-gated, negotiated-pricing,
no self-serve; they fit a later, larger stage. Revisit only if you outgrow the indie tier.

**Confidence:** Moderate-high on *eliminating* Cleverbridge/Nexway for now (clear enterprise gating).
Moderate on *Vatly-first* — the recommendation hinges on its undisclosed % and current availability,
which must be confirmed before committing. Mollie+OSS is the well-understood safety net.

### Open questions
- Vatly: exact transaction %, payout schedule/terms, any minimum, and is it open beyond early access?
- Vatly/any MoR: does it expose a **webhook** suitable for driving the Nhost `subscriptions` table
  (subscription created/renewed/cancelled events)? Confirm before architecture-locking.
- Mollie path: cost/effort of DE OSS registration and whether Quaderno (or equivalent) is itself
  EU-domiciled (another sub-processor to vet).
- For all: confirm support for both **monthly and yearly** subscription terms and for SEPA + cards.

---

## Decision 3 — Pro subscription pricing benchmark

### Comparable prosumer macOS tools (current prices, read 2026-06-27)

| Tool | Category | Pricing |
|---|---|---|
| **MacWhisper** (Gumroad) | Local transcription | **€59 one-time** lifetime Pro (free tier exists) |
| **Whisper Transcription** (Mac App Store) | Local transcription | **$29.99/yr** Pro, or **$99.99 lifetime**; optional cloud "Assistant" add-on $9.99/mo or **$89.99/yr** |
| **Downie** (Charlie Monroe) | Video/podcast downloader w/ automated mode | **~$20 one-time**; via Setapp from ~$4.99/mo |
| **Downie + Permute bundle** | Downloader + converter | **~$26.99 one-time** |
| **Setapp** (whole-suite subscription) | 250+ Mac apps bundle | **$9.99/mo** or **$107.88/yr** (Mac); $12.49/mo Mac+iOS |

Reading the market:
- Single-purpose prosumer Mac utilities cluster around **$20–$60 one-time** or **~$30/yr** when
  subscription (Whisper Transcription's $29.99/yr is the closest direct analog — local
  transcription, indie).
- Cloud/"ongoing service" add-ons justify subscription pricing and sit around **$90/yr** (Whisper
  Assistant $89.99/yr), which is the relevant comp for Paragraphos's value prop: an **ongoing,
  always-running automation/daemon service**, not a one-time tool. Set-and-forget automation that
  runs unattended on your behalf is exactly the kind of continuous value that supports a
  subscription rather than a one-time fee.
- Whole-suite subscriptions (Setapp ~$10/mo / ~$108/yr) set the ceiling for "what a Mac power user
  will pay monthly for software" — a single-feature Pro tier should sit **well below** that.

### Recommendation (suggested price band)

Paragraphos Pro sells **one thing**: unattended automation (scheduled auto-pull + folder-watch
daemon). That is narrower than a full app suite but is a genuine **recurring service**. Suggested
band, in EUR (German market, MoR will add VAT on top to the buyer):

- **Monthly: €4.99 / month** (range €3.99–€6.99). Keeps the impulse-purchase psychology; well under
  Setapp's whole-suite €9-ish.
- **Yearly: €39 / year** (range €29–€49) — i.e. ~2 months free vs. monthly, landing right next to
  the Whisper Transcription ($29.99/yr) / Assistant ($89.99/yr) comps and signalling "cheaper to
  commit annually."
- **Anchor on the yearly plan** (most automation users keep it running long-term, so annual matches
  the value and cuts MoR per-transaction overhead and churn). A €39/yr headline with a €4.99/mo
  option is a clean, defensible pair.
- Optionally consider a **lifetime** option later (the Mac-indie market — MacWhisper, Charlie Monroe
  — rewards it), but for an *unattended-automation* value prop that incurs ongoing backend cost
  (Nhost $25/mo) **subscription is the right primary model**; defer lifetime.

**Sanity vs. COGS:** Nhost Pro is ~$25/mo fixed. At €39/yr, roughly **8–10 paying yearly subscribers**
cover the backend; everything above is margin (minus MoR %, Apple's $99/yr, and any email/VAT tooling).

**Confidence:** Moderate. The band is well-anchored to live comps, but actual willingness-to-pay for
"automation only" (vs. the whole app) is untested — validate with a small launch and be ready to
adjust. Starting slightly low and raising later is easier than the reverse.

### Open questions
- Is there appetite for a **lifetime** tier alongside the subscription (common in this niche)?
- Should the upsell emphasize €/month framing on the monthly or €/month-equivalent on the yearly?
- Regional pricing (PPP) — out of scope for a German-first launch but worth noting for later.

---

## Summary of recommendations

1. **Nhost:** Go ahead on the **Pro plan (~$25/mo), EU/Frankfurt region** — best EU-native fit for
   a tiny auth+entitlement workload. **Gate launch** on written confirmation of (a) the exact EU
   legal entity, (b) a signed Art. 28 AVV/DPA, (c) the sub-processor list (note: AWS US parent +
   the magic-link email sender are likely sub-processors even with an EU region).
2. **Merchant of Record:** Prefer an **EU MoR so you don't carry VAT**. For a solo indie, **Vatly
   (NL)** is the best-fit candidate *if* its transaction % and availability check out; otherwise
   fall back to **Mollie (NL) PSP + DE OSS self-registration** (cheapest, fully EU, but you run VAT).
   **Drop Cleverbridge (DE) and Nexway (FR) for now** — enterprise-gated, no self-serve, negotiated
   fees with platform minimums.
3. **Pricing:** Suggested Pro band **€4.99/month** and **€39/year** (≈2 months free annually),
   anchored to live macOS comps (Whisper Transcription $29.99/yr; cloud add-ons ~$90/yr; Setapp
   ~$108/yr suite ceiling). Lead with the yearly plan; defer a lifetime option.

---

## Sources

Nhost:
- https://nhost.io/pricing
- https://nhost.io/
- https://danubedata.ro/blog/firebase-alternatives-europe-gdpr-2026
- https://www.webbfabriken.com/en/blog/gdpr-compliant-web-hosting-sweden-2026
- https://www.spotsaas.com/product/nhost/pricing

Merchant of Record:
- Vatly: https://vatly.com/ ; https://sandorian.com/blog/announcing-vatly-merchant-of-record-for-european-saas ; https://vatly.com/vs/lemonsqueezy
- Cleverbridge: https://grow.cleverbridge.com/pricing ; https://grow.cleverbridge.com/blog/top-merchant-of-record-providers-2026 ; https://fungies.io/cleverbridge-review-2026/
- Nexway: https://nexway.com/merchant-of-record/ ; https://nexway.com/pricing/ ; https://nexway.com/about-us/
- Mollie: https://www.mollie.com/pricing ; https://blog.finexer.com/mollie-pricing/ ; https://payrequest.io/payment-providers/mollie
- MoR background: https://fungies.io/merchant-of-record-for-saas-guide-2026/

Pricing benchmarks:
- MacWhisper / Whisper Transcription: https://www.getvoibe.com/resources/macwhisper-pricing/ ; https://macwhisper.org/
- Downie / Permute: https://software.charliemonroe.net/downie/ ; https://thesweetbits.com/tools/downie-video-downloader/
- Setapp: https://setapp.com/pricing ; https://9to5mac.com/2026/03/03/setapp-now-lets-users-buy-or-subscribe-to-select-apps-individually/
