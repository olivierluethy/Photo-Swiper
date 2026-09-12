<div align="center">
  <img src="assets/icon512x512.jpg" alt="Photo Swiper logo" width="140" />
  <h1>Photo Swiper</h1>
  <p><b>Clean up your camera roll one swipe at a time.</b><br/>A Flutter app for iOS and Android that lets you swipe photos and videos to keep or delete, then review before anything is removed.</p>
  <p>
    <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg"></a>
    <img alt="Flutter" src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white">
    <img alt="Dart" src="https://img.shields.io/badge/Dart-0175C2?logo=dart&logoColor=white">
    <img alt="iOS" src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white">
    <img alt="Android" src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white">
  </p>
</div>

---

A Flutter mobile app for cleaning up your camera roll — swipe through photos and
videos to quickly keep or delete them, then review and confirm before anything is
removed.

## Features

- Swipe-to-decide interface for photos and videos (keep or delete).
- Grid selection and a review screen before deletion is confirmed.
- Onboarding flow with intro, benefits and permission screens.
- Video previews via an inline player.
- In-app purchases / premium paywall (RevenueCat) and trial reminder notifications.
- Product analytics (PostHog) and an in-app review prompt.

## Tech

- Flutter / Dart.
- `photo_manager` (media access), `permission_handler`, `video_player`,
  `share_plus`, `shared_preferences`.
- `purchases_flutter` (RevenueCat), `posthog_flutter`,
  `flutter_local_notifications`, `flutter_animate`.

## Run

```bash
flutter pub get
flutter run
```

Requires the Flutter SDK. Targets iOS and Android (photo-library and notification
permissions are requested at runtime).

## License

Released under the [MIT License](LICENSE) © 2026 Olivier Lüthy. You're free to use, modify and distribute this
software, including commercially, as long as the copyright notice and license are included.

## Author

Built by **Olivier Lüthy** — [GitHub](https://github.com/olivierluethy).
