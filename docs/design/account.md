# Account

The Account page (`/account`) lets users manage their profile, view their subscription, and delete their account. It is available on both the web and iOS clients.

---

## Sections

### Profile
- Displays `username` and `email`
- Edit form for updating either field or resetting password
- Changes go to `PUT /user/{user_id}`

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
