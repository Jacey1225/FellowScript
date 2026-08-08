# Account

The Account page (`/account`) lets users manage their profile, view their subscription, and delete their account. It is available on both the web and iOS clients.

---

## Sections

### Profile
- Displays `username` and `email`
- Edit form for updating either field, resetting password, or setting **Timezone** — a searchable list of IANA names (e.g. `America/Los_Angeles`) on both platforms: an antd `Select` on web, a `.searchable` `List` sheet (`TimeZonePickerSheet`) on iOS, sourced from `Intl.supportedValuesOf('timeZone')` / `TimeZone.knownTimeZoneIdentifiers` respectively
- Changes go to `PUT /user/{user_id}`
- Timezone determines when the nightly data backup runs for that user — always their own local 3am, not a fixed server time (see [Data → Nightly Backup Database](../architecture/data.md))

### Subscription Card (`SubscriptionCard`)

| State | Display |
|---|---|
| Free plan | "Free Plan" header, active badge, usage limits, upgrade prompt |
| Paid (individual/group) | Plan name, billing period, card brand + last 4, cancel option |

Upgrade prompt: "Upgrade to unlock unlimited notes, AI check-ins, and notifications."

Clicking **Upgrade** on web opens a Stripe Checkout session (`POST /subscriptions/stripe/checkout`). On iOS, tapping the plan tile triggers StoreKit 2 (`StoreKitManager`).

### Danger Zone

Account deletion requires the user to type their username as confirmation, then press **Delete Account**.

- **Web**: `DELETE /user/{user_id}` is called; on success the user is signed out and redirected to `/signin`.
- **iOS**: `NetworkService.deleteUser(userId:)` is awaited first; `signOut()` is called after on `MainActor` (no race condition).

The delete endpoint manually removes owned notes, nulls message and devotion author fields, then deletes the user row. All remaining related rows (subscriptions, highlights, bookmarks, notifications, agents) cascade automatically via FK constraints.

---

## Visual Design (iOS)

The iOS Account page (`FellowScript/FellowScript/Account/AccountView.swift`) uses the same
interactions as above, restyled to match the app's warm-bloom / glass-card visual language
shared with the Dashboard, Chat, Notes, and Note Editor screens. Appearance-only — every
binding, async flow (Subscription's purchase/restore/cancel/leave/seat-edit/join-request
flows, Edit Profile save + timezone picker, Agent/Event/Notification create-toggle-delete,
Two-Factor Authentication, Danger Zone's username-match delete gate), sheet, and alert is
unchanged.

- **Container** — the root `List(.insetGrouped)` is replaced with a `ScrollView` +
  `VStack(spacing: 20)`, over `Theme.bgPage` plus two `RadialGradient` blooms (same values as
  `ChatRootView`). Each of the 14 sections is its own `glassCard(cornerRadius: 20)` tile instead
  of a flat `Theme.cardBg` list section; in-card `Divider().background(Theme.borderGoldFaint)`
  replaces native list row separators.
- **Section headers** — the shared `sectionLabel(_:)` component (also used by
  Dashboard/Chat/Bible Reader) replaces the page's own near-duplicate `sectionHeader(_:)` helper.
- **Profile avatar** — upgraded to the gradient-fill recipe used by `ChatRootView.ContactRow`'s
  avatar (translucent gold gradient fill, gold stroke), same size and position.
- **CTAs** — plain-text-link buttons (Subscription's Start/seat-edit Save-Cancel/Change plan
  size/Restore Purchases/manage-plan actions, Edit Profile's Save Changes, Friend Requests'
  Accept, Agents'/Events'/Notifications' "+ New …" rows, Danger Zone's Delete My Account) are
  restyled into a small shared family: a solid gradient CTA pill for primary actions, a ghost
  outline pill for secondary/destructive actions, matching the pill language already shipped in
  Chat's segment toggle and the Note Editor's header chips.
- **Notifications "View All"** — a small ghost pill next to the section label (the one new visual
  composition this pass introduces; no new token).
- **Danger Zone** — keeps its distinct red tint, now expressed as a tinted variant of the same
  glass card (`glassCard(tint: Theme.dangerBg, border: [...Theme.borderDanger])`) rather than a
  flat red fill. Sign Out stays in its own separate, neutral (non-danger-tinted) glass card.
