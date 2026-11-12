# Exness Trade Dashboard (Flutter)

Android-first read-only app for the existing MT5 FastAPI bridge.

## Generate the native Flutter project locally
Install Flutter and Android SDK, then from repository root:

```powershell
cd android
flutter create --platforms=android --project-name exness_trade_dashboard .
flutter pub get
flutter run
```

Build an APK locally with `flutter build apk --release`. No GitHub Actions required.

## Setup
- Keep Windows MT5 terminal and the read-only FastAPI backend running.
- Enable Tailscale on both devices and use the **private HTTPS Serve URL**.
- In the app enter the base URL (without /health) and the API token from Windows `.env`.
- The API token is stored with flutter_secure_storage, never committed.
- Set a 6-digit PIN on first launch; enable fingerprint in Settings if supported.
- Dashboard refreshes every second while in foreground.

## Security
- Real-account access is READ ONLY; no trade endpoints are used.
- The backend currently exposes /account, /positions, /health. No dedicated quote endpoint exists; current position prices are displayed instead.
- Never publish your API token, MT5 credentials, or private account data.
- Treat this as a development build; review device security before production use.
