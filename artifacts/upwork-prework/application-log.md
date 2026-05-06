# Upwork Proof-First Application Log

## 2026-05-05

### Live Screening Pass - GitHub SwiftUI Search / No New Submission

- Time: 2026-05-05 20:58 EDT
- Search checked: `"github" SwiftUI bug fix`, filtered to less than 5 proposals, payment verified, most recent.
- Skipped leads:
  - `SwiftUI iOS Developer Needed for Animated Gamified Onboarding and Bee Logic`: `$30` fixed budget for broad production UI/animation/state work, not a fast paid diagnostic/fix.
  - `iOS Voice + Whiteboard App - Bug Fix on Existing Build`: already applied earlier.
  - `App Store Connect New Analytics Dashboard Help`: explicit 25-minute Zoom call.
  - `Upload and Publish iOS App`: asks freelancer to use a paid Apple Developer Program account.
  - `Urgent: Apple Developer Account Activation Needed`: account activation/billing-risk work.
  - `Build & Publish iOS App for SMS Verification (Open-Source Swift Base Available)`: inspected because it mentioned an open-source Swift base, then skipped because it involves SMS activation/temporary-number work, publishing on the freelancer's App Store developer account, and transferring the app afterward.
- Product fix completed: Fast Cash ranker now flags App Store developer-account publishing, app transfer, SMS activation, temporary-number, verification-code, and OTP phrasing as account-risk work; test coverage added.
- Current outcome: No new proposal submitted; no earnings yet.
- Proof artifact: `live-screening-2026-05-05-2058.md`

### Live Screening Pass - No Money Proof / No New Submission

- Time: 2026-05-05 20:54 EDT
- Reply check: Upwork Messages showed "Conversations will appear here." No client conversations, interviews, offers, contracts, or milestone discussions were visible.
- Money proof check: Upwork Transactions showed pending earnings `$0.00` and available balance `$0.00`. The only visible transaction was a `-$11.29` Freelancer Plus membership subscription from May 1, 2026, which is a charge and not earnings.
- Skipped leads:
  - SCA100 invitation: broad hourly AI-training/human-feedback invitation, no concrete artifact to complete before applying, not a zero-human-intervention fast-cash deliverable.
  - WordPress IDX / Estatik / Trestle: plausible technical issue, but no public site URL, logs, screenshots, repo, or code snippet visible before applying; 14 Connects; last viewed by client 3 weeks ago.
  - `"public URL" audit`: only visible result was payment-unverified, `$0 spent`, and no stable public target artifact in the card.
  - `public repo bug fix`: search page loaded a skeleton/stale result state and did not expose actionable candidates during this pass.
- Product fix completed: Fast Cash ranking/proposal/dashboard code now rejects call/live-walkthrough/post-hire-access-only jobs more sharply and makes money proof plus blockers visible in the dashboard.
- Current outcome: No new proposal submitted; no earnings yet.
- Proof artifact: `live-screening-2026-05-05-2054.md`

### Live Screening Pass - No New Submission

- Time: 2026-05-05 20:49 EDT
- Reply check: Upwork Messages showed no active client conversations. No visible offer, interview, funded milestone, approved milestone, clearing earnings, or available earnings was found in this pass.
- Searches checked: `"GitHub issue"`, `repository bug`, `"critical error" WordPress`, and `http WordPress bug`.
- Skipped leads:
  - Visible Expensify jobs not already applied were crowded, duplicate-withdrawn, in review, or too saturated for remaining Connects.
  - AWS website bug fixing exposed no public repo/log/site details before hire and had only a $20 fixed budget.
  - WordPress maintenance/audit roles were broad or had no public target artifact.
  - Estatik/Trestle IDX job had a plausible technical symptom and a stronger client history, but no actual site URL, repo, logs, or screenshots were exposed; submitting would have violated the proof-first rule.
- Monitor: Updated the active heartbeat automation `upwork-fast-cash-artifact-monitor` to check replies/offers first and to avoid spending the final Connects on weak no-artifact leads.
- Current outcome: No new proposal submitted; no earnings yet.
- Proof artifact: `live-screening-2026-05-05-2049.md`

### Expensify #89545 Magic Link Fresh Session Blank Page

- Job: https://www.upwork.com/jobs/~022051363824384416616
- Proposal: https://www.upwork.com/nx/proposals/2051823497921880065
- Submitted: 2026-05-05 20:37 America/Toronto
- Bid: Fixed-price, $250 gross / $225 estimated net
- Connects: 14 required, 0 boost, 19 remaining after submission
- Proof artifacts:
  - `expensify-89545-magic-link-fresh-session-diagnostic.md` attached to proposal
  - `expensify-89545-magic-link-fresh-session-patch.txt` attached to proposal
  - `expensify-89545-magic-link-fresh-session.patch` stored locally
- Prework summary: Cloned `Expensify/App`, traced the website `ValidateLoginPage` magic-link flow, found that a fresh/incognito "Just sign in here" session can land in `authToken + JUST_SIGNED_IN + no credentials.login + no exitTo`, and patched the render branch so `isUserClickedSignIn` keeps the existing full-screen loading indicator visible instead of rendering an empty fragment. Added a focused UI regression test for the fresh-session state.
- Validation: Ran `git diff --check` cleanly in the cloned Expensify repo. Did not claim a Jest run because the clean clone had no `node_modules` and the machine is nearly out of disk space.
- Payment note: Upwork showed the Enterprise/Business Plus fixed-price notice that this project is not escrow-funded at proposal time; client is vetted and payment method verified, but payment depends on client review/approval.
- Async stance: No Zoom/call requested; proposal offers to turn the prepared patch into the PR and iterate on reviewer feedback.
- Current outcome: Submitted with diagnostic and patch attached.

### Expensify #89588 Search Group Selection Crash

- Job: https://www.upwork.com/jobs/~022051601967902931653
- Proposal: https://www.upwork.com/nx/proposals/2051821055206694913
- Submitted: 2026-05-05 20:27 America/Toronto
- Bid: Fixed-price, $250 gross / $225 estimated net
- Connects: 14 required, 0 boost, 33 remaining after submission
- Proof artifacts:
  - `expensify-89588-search-group-selection-crash-diagnostic.md` attached to proposal
  - `expensify-89588-search-group-selection-crash-patch.txt` attached to proposal
  - `expensify-89588-search-group-selection-crash.patch` stored locally
- Prework summary: Cloned `Expensify/App`, traced the Search selection-refresh effect for grouped snapshot data, found that the flat branch dereferenced `selectedTransactions[transactionItem.transactionID].isSelected` while the grouped branch already used optional chaining, and patched `src/components/Search/index.tsx` so stale/missing transaction-selection entries cannot crash the refresh path.
- Validation: Ran `git diff --check` cleanly in the cloned Expensify repo. Did not claim a full Jest/app run because the clean clone had no `node_modules`.
- Payment note: Upwork showed the Enterprise/Business Plus fixed-price notice that this project is not escrow-funded at proposal time; client is vetted and payment method verified, but payment depends on client review/approval.
- Async stance: No Zoom/call requested; proposal offers to turn the prepared patch into the PR and iterate on reviewer feedback.
- Current outcome: Submitted with diagnostic and patch attached.

### Expensify #89636 Gusto Accounting Connections List

- Job: https://www.upwork.com/jobs/~022051738617216628844
- Proposal: https://www.upwork.com/nx/proposals/2051819435696693249
- Submitted: 2026-05-05 20:21 America/Toronto
- Bid: Fixed-price, $250 gross / $225 estimated net
- Connects: 14 required, 0 boost, 47 remaining after submission
- Proof artifacts:
  - `expensify-89636-gusto-accounting-diagnostic.md` attached to proposal
  - `expensify-89636-gusto-accounting-patch.txt` attached to proposal
  - `expensify-89636-gusto-accounting.patch` stored locally
- Prework summary: Cloned `Expensify/App`, traced the Accounting page integration branching, identified that a Gusto-only policy can make `isEmptyObject(policy?.connections)` false while `getConnectedIntegration(policy, ACCOUNTING_CONNECTION_NAMES)` remains undefined, and patched `PolicyAccountingPage.tsx` to gate the setup list and "Other" grouping on `hasAccountingConnections(policy)` instead of raw connection-object emptiness.
- Validation: Ran `git diff --check` cleanly in the cloned Expensify repo. Did not claim a full Jest/app run because the clean worktree had no `node_modules`.
- Payment note: Upwork showed the standard fixed-price notice; client is Upwork Enterprise with verified payment, but payment still depends on client review/approval.
- Async stance: No Zoom/call requested; proposal offers to turn the prepared patch into the PR and iterate on reviewer feedback.
- Current outcome: Submitted with diagnostic and patch attached.

### Expensify #89668 QAB Location Permission Modal

- Job: https://www.upwork.com/jobs/~022051787438365476220
- Proposal: https://www.upwork.com/nx/proposals/2051816765162528769
- Submitted: 2026-05-05 20:10 America/Toronto
- Bid: Fixed-price, $250 gross / $225 estimated net
- Connects: 14 required, 0 boost, 61 remaining after submission
- Proof artifacts:
  - `expensify-89668-location-qab-diagnostic.md` attached to proposal
  - `expensify-89668-location-qab-patch.txt` attached to proposal
  - `expensify-89668-location-qab.patch` stored locally; Upwork rejected `.patch` upload
- Prework summary: Cloned `Expensify/App`, traced the QAB receipt-scan skip-confirmation path, identified that a recent `NVP_LAST_LOCATION_PERMISSION_PROMPT` can suppress `LocationPermissionModal`, patched `useReceiptScan` to force the location permission flow for scan quick actions, and added a unit regression test for recent prompt + skip confirmation + `REQUEST_SCAN`.
- Validation: Ran `git diff --check` cleanly in the cloned Expensify repo. Did not claim a full Jest run because the shallow clone had no `node_modules`; focused command after install is `npm test -- tests/unit/hooks/useReceiptScan.test.ts`.
- Payment note: Upwork showed the Enterprise/Business Plus fixed-price notice that this project is not escrow-funded at proposal time; client is vetted and payment method verified, but payment depends on client approval.
- Async stance: No Zoom/call requested; proposal asks to turn the prepared patch into the PR and iterate on reviewer feedback.
- Current outcome: Submitted with diagnostic and patch attached.

### Filmmaker Journey Elementor / SEO / Email Capture

- Job: https://www.upwork.com/jobs/~022050689413518209233
- Proposal: https://www.upwork.com/nx/proposals/2051812704900583425
- Submitted: 2026-05-05 23:34 UTC / 19:34 America/Toronto
- Bid: Fixed-price milestones, $600 gross / $540 estimated net
- Milestones:
  - $150: Same-day task-sheet triage + SEO/email-capture foundation pass, due 2026-05-06
  - $250: Elementor page fixes, Favorites/Notes repair, affiliate/email implementation, due 2026-05-09
  - $200: Backlink/citation/community research + final handoff, due 2026-05-12
- Connects: 14 required, 0 boost
- Proof artifacts:
  - `filmmakerjourney-elementor-seo-email-capture-diagnostic.md`
  - `filmmakerjourney-client-facing-mini-audit.docx` attached to proposal
- Prework summary: Read attached `MASTER TASKS 2026MAY.xlsx`, verified task refs and Amazon StoreID, audited public WordPress/Elementor site, found H1/template mismatches, missing meta descriptions, sitemap cleanup candidates, and image alt/LCP issues.
- Async stance: Explicitly no Zoom needed; proposal asks for WordPress admin access plus backup permission after hire.
- Current outcome: Submitted; not opened at time of submission.

### TimberIreland WooCommerce Restoration

- Job: https://www.upwork.com/jobs/~022051554286980031443
- Proposal: https://www.upwork.com/nx/proposals/2051808641927979009
- Submitted: 2026-05-05 19:37 America/Toronto
- Bid: Fixed-price milestone, $150 gross / $135 estimated net
- Connects: 9 required, 0 boost
- Proof artifact: `timberireland-woocommerce-restoration-diagnostic.md`
- Prework summary: Found current `www` homepage serving cached maintenance page, root redirecting to `www.old.timberireland.ie` with 403, and cart/checkout/category/legal paths redirecting to old host with 404.
- Async stance: No Zoom requested; proposal asks for WordPress admin plus hosting/SFTP or file-manager access with backup permission.
- Current outcome: Submitted; not opened at time of submission.

### Cloudflare Worker for Shopify/Yotpo SEO Crawlability

- Job: https://www.upwork.com/jobs/~022051708057310152975
- Proposal: https://www.upwork.com/nx/proposals/2051804028417159169
- Submitted: 2026-05-05
- Bid: Hourly, $40/hr
- Connects: 14 required, 0 boost
- Proof artifacts:
  - `yotpo-shopify-cloudflare-worker-prototype.ts`
  - `yotpo-shopify-cloudflare-worker-prototype.md`
- Prework summary: Built prototype Cloudflare Worker design for pass-through product routes, `/reviews/[handle]` shadow pages, Shopify lookup, KV cache/background refresh, Yotpo adapter, HTMLRewriter injection, JSON-LD, and fail-open behavior.

### HRLodex Origin Timeout Diagnostic

- Job: https://www.upwork.com/jobs/~022051575524626999730
- Proposal: https://www.upwork.com/nx/proposals/2051803011277467649
- Submitted: 2026-05-05
- Bid: Hourly, $20/hr
- Connects: 13 required, 0 boost
- Proof artifact: `hrlodex-origin-timeout-diagnostic.md`
- Prework summary: Found `hrlodex.uz` Cloudflare 522/origin timeout pattern.

### FUNFACTORYPARTIES Bounce/Malware Diagnostic

- Job: https://www.upwork.com/jobs/~022039121853216479138
- Proposal: https://www.upwork.com/nx/proposals/2051800346215243777
- Submitted: 2026-05-05
- Bid: Hourly, $35/hr
- Connects: 14 required, 0 boost
- Proof artifact: proposal text contained passive public audit of `FUNFACTORYPARTIES.COM`.

### iOS Voice + Whiteboard App Bug Fix

- Job: https://www.upwork.com/jobs/~022048117375062995564
- Proposal: https://www.upwork.com/nx/proposals/2051783574629462017
- Submitted: 2026-05-05
- Bid: Fixed-price, $100 gross / $90 estimated net
- Connects: unknown from current log
- Note: Submitted before the later stricter "proof-first/no-call" filter was narrowed.
