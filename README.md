# CFS TikTok Downloader

Repo gabungan:
- Website (Next.js): `app/`, `public/`, `next.config.js`, `package.json`
- Aplikasi Android (Flutter + WebView): `lib/`, `pubspec.yaml`, `overlay/`, `assets/`
- Build APK otomatis: `.github/workflows/build-apk.yml` (push ke main -> APK di Releases)

Website di-deploy ke Vercel TERPISAH (tanpa file Flutter): https://cfstiktokdownloader.vercel.app
URL itu diatur di `kSiteUrl` pada `lib/main.dart`.
`android/` dibuat otomatis oleh workflow, jangan di-commit.
