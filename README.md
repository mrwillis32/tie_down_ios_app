# TieDown for iOS

> Standalone copy of `apps/ios` from the Tiedown-for-Neil-develop monorepo, made 2026-10-16.
> The backend (API + web app) lives in that monorepo; this folder only holds the iOS app.
> Changes here are not synced back automatically.

A native iPhone/iPad app for TieDown. It keeps the existing backend (API + web app) as is. Native
features wrap the web app's screens:

| Native | What it does |
|--------|--------------|
| **Login** | SwiftUI sign-in that calls `POST /api/v1/auth/login`. It tries the tenant, customer and owner portals, the same way the web login does. |
| **Session** | Tokens are kept in the Keychain and refreshed automatically via `/api/v1/auth/refresh` before they expire. The session is handed to the web screens as the HttpOnly `tiedown_session` cookie. Sign out revokes the token (`/api/v1/auth/logout`) and wipes all web data. |
| **Tab bar** | Native tabs for each user type: **staff** (Home, POS, Reservations, Customers, More), **customer** (portal) and **owner** (owner portal). Each tab keeps its own page and history. Tapping the active tab returns it to its start page. |
| **Face ID / Touch ID** | Optional app lock. You're asked once after the first sign-in, and can change it in More › App Settings. |
| **Offline** | A banner appears when the connection drops, failed pages show a native retry screen, and they reload automatically when you're back online. |
| **Push notifications** | Asks permission and registers the device token with the API (see *Backend contract* below). Tapping a notification with a `path` opens that screen. |
| **Tap to Pay on iPhone** | Stripe Terminal **5.8.1**, written to its current API. Connects once and shares the connection, refuses double charges, supports cancel, and asks for location permission. |
| **Links & files** | Phone, email, SMS and map links open the system apps. External sites open in Safari View Controller. Downloads (receipts, PDFs, CSVs) open the share sheet. JS alerts and confirms are native dialogs. The camera and mic work for the barcode scanner and voice input. |
| **Deep links** | `tiedown://open?path=/pos/orders/123` |

The web app can detect the native shell from `TieDowniOS/<version>` in the user agent (works during
SSR) or from `window.__TIEDOWN_NATIVE__` on the client.

## Requirements

- Xcode 16+ (tested with Xcode 27.1), iOS 17+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Apple Developer Program membership, plus these for the features that use them:
  - **Tap to Pay on iPhone** entitlement (request it in the Apple Developer portal). Tap to Pay needs a physical iPhone XS or later; the simulator uses Stripe's simulated reader.
  - **Push Notifications** capability, plus an APNs auth key (.p8) for the backend to send pushes.

## Build & run

```bash
cd ~/Desktop/tie_down_ios_app
xcodegen generate          # creates TieDown.xcodeproj from project.yml (re-run after adding files)
open TieDown.xcodeproj
```

1. Select the **TieDown** target › Signing & Capabilities › choose your **Team**. If `us.tiedown.app` is taken, change the bundle ID in `project.yml`.
2. Pick a simulator or your iPhone and press **Run**.

| Scheme / config | Talks to |
|-----------------|----------|
| `TieDown` › Debug | `app-dev.tiedown.us` / `api-dev.tiedown.us` |
| `TieDown Staging` | `app-staging.tiedown.us` / `api-staging.tiedown.us` |
| Release (Archive) | `app.tiedown.us` / `api.tiedown.us` |
| Debug with env var `TD_ENVIRONMENT=local` | `http://localhost:3001` / `http://localhost:8788` (`mise run dev`) |

Command-line build without signing:

```bash
xcodebuild -project TieDown.xcodeproj -scheme TieDown -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Backend contract

The app uses existing API endpoints only, plus these additions made as part of the iOS work:

| Endpoint | Used for |
|----------|----------|
| `POST /api/v1/auth/login`, `/auth/refresh`, `/auth/logout` | Native session |
| `POST /api/v1/payments/terminal/connection-token` | Stripe Terminal |
| `POST /api/v1/payments/terminal/payment-intent` `{ amount, currency, order_id? }` | Tap to Pay charge |
| `GET  /api/v1/payments/terminal/location` → `{ locationId }` | **New.** Tap to Pay needs a Terminal Location |
| `POST /api/v1/notifications/devices`, `DELETE /api/v1/notifications/devices/:token` | **New.** Push device registration |

### Tap to Pay JS bridge

```js
// Web → native
window.webkit.messageHandlers.tapToPay.postMessage({
  action: "collectPayment", amount: 1500, currency: "usd", orderId: "ord_123", requestId: "r1",
});
window.webkit.messageHandlers.tapToPay.postMessage({ action: "cancelCollect" });
window.webkit.messageHandlers.tapToPay.postMessage({ action: "prepare" }); // warm up the reader

// Native → web
window.onTapToPayResult = (r) => {
  // { success, paymentIntentId?, last4?, brand?, error?, canceled?, busy?, requestId? }
};
```

Only the app's own top-level page can call the bridge; iframes and other sites are ignored. The
server must still verify the PaymentIntent before marking an order paid.

### General bridge

```js
window.webkit.messageHandlers.native.postMessage({ action: "haptic", style: "success" });
window.webkit.messageHandlers.native.postMessage({ action: "share", url: "https://…", text: "Receipt" });
```

## Layout

```
tie_down_ios_app/
├── project.yml                 # XcodeGen spec (source of truth for the Xcode project)
└── TieDown/
    ├── Sources/
    │   ├── App/                # @main app, AppModel (composition root), tab definitions
    │   ├── Auth/               # AuthService (login/refresh/logout), Keychain, Face ID lock
    │   ├── Config/             # AppEnvironment (hosts per environment)
    │   ├── Networking/         # APIClient ({success,data,error} envelope), NetworkMonitor
    │   ├── Payments/           # TerminalManager (Stripe Terminal), TapToPayBridge
    │   ├── Push/               # PushManager
    │   ├── UI/                 # SwiftUI screens (login, tabs, More, settings, lock)
    │   └── Web/                # WebScreenModel (WKWebView + navigation rules), bridges
    ├── Resources/Assets.xcassets
    ├── Info.plist              # generated by XcodeGen
    └── TieDown.entitlements    # generated by XcodeGen
```

## App Store checklist

- [ ] Set the Team, and confirm the bundle ID
- [ ] Get Apple's approval for the Tap to Pay entitlement (development first, then distribution)
- [ ] Enable Push Notifications, and upload the APNs key to the backend secrets (`APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`)
- [ ] Replace the generated app icon (`Resources/Assets.xcassets/AppIcon.appiconset`) with final artwork if you have it
- [ ] Prepare a privacy policy URL, screenshots, and a review account for App Review
- [ ] Archive with the **Release** config, then upload via Xcode Organizer
