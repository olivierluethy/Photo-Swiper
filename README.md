# Photo Swiper

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
