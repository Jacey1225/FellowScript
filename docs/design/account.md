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
