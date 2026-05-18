/// Canonical event names and property keys. Use these constants — never
/// inline strings — so renames don't silently fragment the dashboard.
class AnalyticsEvents {
  AnalyticsEvents._();

  // ─── App lifecycle ─────────────────────────────────────────────────────
  static const String appOpened = 'app_opened';
  static const String appBackgrounded = 'app_backgrounded';
  static const String sessionStarted = 'session_started';
  static const String sessionEnded = 'session_ended';

  // ─── Onboarding slides ─────────────────────────────────────────────────
  static const String onboardingSlideViewed = 'onboarding_slide_viewed';
  static const String onboardingContinueTapped =
      'onboarding_continue_tapped';
  static const String onboardingSkipButtonTapped =
      'onboarding_skip_button_tapped';
  static const String onboardingSlideSkipped = 'onboarding_slide_skipped';
  static const String onboardingSlidesCompleted =
      'onboarding_slides_completed';
  static const String userClosedAppDuringOnboarding =
      'user_closed_app_during_onboarding';

  // ─── Permissions ───────────────────────────────────────────────────────
  static const String notificationPermissionShown =
      'notification_permission_shown';
  static const String notificationPermissionAccepted =
      'notification_permission_accepted';
  static const String notificationPermissionDenied =
      'notification_permission_denied';
  static const String photoPermissionShown = 'photo_permission_shown';
  static const String photoPermissionAccepted = 'photo_permission_accepted';
  static const String photoPermissionDenied = 'photo_permission_denied';
  static const String permissionsSectionCompleted =
      'permissions_section_completed';
  // Legacy aliases kept for back-compat with existing call sites; new
  // code should prefer the *_accepted / *_denied / *_shown variants above.
  static const String photoPermissionRequested =
      'photo_permission_requested';
  static const String photoPermissionGranted = photoPermissionAccepted;

  // ─── Paywall ───────────────────────────────────────────────────────────
  static const String paywallViewed = 'paywall_viewed';
  static const String weeklyPlanTapped = 'weekly_plan_tapped';
  static const String yearlyPlanTapped = 'yearly_plan_tapped';
  static const String weeklyPlanAppleDialogShown =
      'weekly_plan_apple_dialog_shown';
  static const String yearlyPlanAppleDialogShown =
      'yearly_plan_apple_dialog_shown';
  static const String weeklyPlanPurchased = 'weekly_plan_purchased';
  static const String yearlyPlanPurchased = 'yearly_plan_purchased';
  static const String purchaseCancelled = 'purchase_cancelled';
  static const String paywallClosedWithoutPurchase =
      'paywall_closed_without_purchase';
  static const String paywallScrolled = 'paywall_scrolled';
  static const String userClosedAppDuringPaywall =
      'user_closed_app_during_paywall';
  // Legacy / generic aliases kept so existing code compiles.
  static const String paywallShown = paywallViewed;
  static const String paywallDismissed = paywallClosedWithoutPurchase;
  static const String subscriptionStarted = 'subscription_started';
  static const String subscriptionRestored = 'subscription_restored';

  // ─── Main app access ───────────────────────────────────────────────────
  static const String mainAppLoaded = 'main_app_loaded';
  static const String mainAppAccessedAfterPurchase =
      'main_app_accessed_after_purchase';

  // ─── Funnel ────────────────────────────────────────────────────────────
  static const String funnelStepIntroSlides = 'funnel_step_intro_slides';
  static const String funnelStepPermissions = 'funnel_step_permissions';
  static const String funnelStepPaywall = 'funnel_step_paywall';
  static const String funnelStepPurchase = 'funnel_step_purchase';
  static const String funnelStepMainApp = 'funnel_step_main_app';
  static const String funnelDropOff = 'funnel_drop_off';

  // ─── Existing gallery / cleanup events (unchanged) ─────────────────────
  static const String galleryLoadStarted = 'gallery_load_started';
  static const String galleryLoadCompleted = 'gallery_load_completed';
  static const String galleryLoadFailed = 'gallery_load_failed';
  static const String cleanupStarted = 'cleanup_started';
  static const String swipePerformed = 'swipe_performed';
  static const String cleanupPaused = 'cleanup_paused';
  static const String cleanupReviewOpened = 'cleanup_review_opened';
  static const String cleanupConfirmed = 'cleanup_confirmed';
  static const String cleanupCanceled = 'cleanup_canceled';

  // ─── Misc ──────────────────────────────────────────────────────────────
  static const String screenViewed = 'screen_viewed';
  static const String errorOccurred = 'error_occurred';
}

/// Funnel-step canonical names. We surface these on every funnel event so
/// dashboard cohort queries can pivot by step + status uniformly.
class FunnelSteps {
  FunnelSteps._();
  static const int introSlides = 1;
  static const int permissions = 2;
  static const int paywall = 3;
  static const int purchase = 4;
  static const int mainApp = 5;
}

/// Reasons for a funnel drop-off. Kept as constants so analytics queries
/// don't have to fuzzy-match free-form strings.
class FunnelDropOffReason {
  FunnelDropOffReason._();
  static const String appClosed = 'app_closed';
  static const String paymentCancelled = 'payment_cancelled';
  static const String permissionDenied = 'permission_denied';
  static const String paywallClosed = 'paywall_closed';
  static const String purchaseFailed = 'purchase_failed';
}
