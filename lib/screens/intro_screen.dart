import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/analytics_events.dart';
import '../services/analytics_service.dart';
import '../widgets/onboarding_visuals.dart';
import 'notification_permission_screen.dart';

/// 3-slide intro. Each slide pairs a custom animated visual (sweep,
/// swipe-demo, phone+shield) with a staggered title/subtitle reveal.
/// Only the currently visible slide animates; the other two pause to
/// save battery. When the user has Reduce Motion enabled at the OS
/// level we render quiet, non-moving versions of each visual.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  final PageController _pageCtrl = PageController();
  int _currentPage = 0;
  final DateTime _enteredAt = DateTime.now();
  final Set<int> _slidesViewed = <int>{};

  static final List<_SlideData> _pages = [
    _SlideData(
      accent: const Color(0xFF6B4EFF),
      title: 'Clean Your\nGallery',
      subtitle:
          'Stop scrolling through thousands of photos.\nSwipe to keep or delete — effortlessly.',
      visualBuilder: (active, reduce) =>
          Slide1Visual(isActive: active, reduceMotion: reduce),
    ),
    _SlideData(
      accent: const Color(0xFF30D158),
      title: 'Swipe to\nDecide',
      subtitle:
          'Swipe right to keep.\nSwipe left to delete.\nNot sure? Tap the center button to review later.',
      visualBuilder: (active, reduce) =>
          Slide2Visual(isActive: active, reduceMotion: reduce),
    ),
    _SlideData(
      accent: const Color(0xFF0A84FF),
      title: 'Private by\nDesign',
      subtitle:
          'Everything runs on your device.\nNo cloud uploads. No external storage.\nYour photos never leave your phone.',
      visualBuilder: (active, reduce) =>
          Slide3Visual(isActive: active, reduceMotion: reduce),
    ),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.screen('intro_screen'));
    _emitSlideViewed(0);
  }

  void _emitSlideViewed(int index) {
    if (!_slidesViewed.add(index)) return;
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.onboardingSlideViewed,
      properties: {'slide_number': index + 1},
    ));
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _next() {
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.onboardingContinueTapped,
      properties: {'slide_number': _currentPage + 1},
    ));
    if (_currentPage < _pages.length - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeInOut,
      );
    } else {
      _finishOnboarding(skipped: false);
    }
  }

  void _finishOnboarding({required bool skipped}) {
    HapticFeedback.lightImpact();
    final duration = DateTime.now().difference(_enteredAt).inSeconds;
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.onboardingSlidesCompleted,
      properties: {
        'total_time_spent': duration,
        'skipped': skipped,
        'slides_viewed': _slidesViewed.length,
      },
    ));
    unawaited(AnalyticsService.instance.funnelStep(
      FunnelSteps.introSlides,
      event: AnalyticsEvents.funnelStepIntroSlides,
      status: skipped ? 'skipped' : 'viewed',
      extras: {'slides_viewed': _slidesViewed.length},
    ));
    _goToPermissionFlow();
  }

  void _skipIntro() {
    HapticFeedback.selectionClick();
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.onboardingSkipButtonTapped,
      properties: {'slide_number': _currentPage + 1},
    ));
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.onboardingSlideSkipped,
      properties: {'from_slide_number': _currentPage + 1},
    ));
    _finishOnboarding(skipped: true);
  }

  void _goToPermissionFlow() {
    // The onboarding-complete flag is intentionally NOT set here — only a
    // successful paywall purchase qualifies (see PaywallScreen). If the
    // user bails before that, they re-enter at /intro next launch.
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const NotificationPermissionScreen(),
        transitionDuration: const Duration(milliseconds: 340),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        transitionsBuilder: (_, animation, __, child) {
          final fade =
              CurvedAnimation(parent: animation, curve: Curves.easeOut);
          return FadeTransition(opacity: fade, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // OS-level "Reduce Motion" / "Remove Animations" toggle. Every visual
    // honours this by rendering a static composition.
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final isLastSlide = _currentPage == _pages.length - 1;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Column(
          children: [
            // Skip lives at the top-right and stays visible across all three
            // slides. We fade it out on the final slide so it doesn't compete
            // with the "Get Started" CTA.
            SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: isLastSlide ? 0.0 : 1.0,
                  child: IgnorePointer(
                    ignoring: isLastSlide,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TextButton(
                        onPressed: _skipIntro,
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF8E8E93),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text(
                          'Skip',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                onPageChanged: (i) {
                  setState(() => _currentPage = i);
                  _emitSlideViewed(i);
                },
                itemCount: _pages.length,
                itemBuilder: (_, i) => _SlidePage(
                  data: _pages[i],
                  isActive: i == _currentPage,
                  reduceMotion: reduceMotion,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _pages.length,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: i == _currentPage ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: i == _currentPage
                              ? const Color(0xFF6B4EFF)
                              : const Color(0xFF3A3A3C),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _next,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6B4EFF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        _currentPage < _pages.length - 1
                            ? 'Continue'
                            : 'Get Started',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

typedef SlideVisualBuilder = Widget Function(bool isActive, bool reduceMotion);

class _SlideData {
  final Color accent;
  final String title;
  final String subtitle;
  final SlideVisualBuilder visualBuilder;

  const _SlideData({
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.visualBuilder,
  });
}

class _SlidePage extends StatelessWidget {
  final _SlideData data;
  final bool isActive;
  final bool reduceMotion;

  const _SlidePage({
    required this.data,
    required this.isActive,
    required this.reduceMotion,
  });

  @override
  Widget build(BuildContext context) {
    // flutter_animate plays forward when `target` flips 0→1, in reverse
    // on 1→0. Tying it to `isActive` means a slide re-animates its
    // title/subtitle every time the user pages back to it.
    final target = isActive ? 1.0 : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          data.visualBuilder(isActive, reduceMotion),
          const SizedBox(height: 48),
          Text(
            data.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 38,
              fontWeight: FontWeight.w700,
              height: 1.15,
              letterSpacing: -0.5,
            ),
          )
              .animate(target: target)
              .fade(
                duration: const Duration(milliseconds: 380),
                curve: Curves.easeOut,
              )
              .slideY(
                begin: 0.15,
                end: 0,
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
              ),
          const SizedBox(height: 20),
          Text(
            data.subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF8E8E93),
              fontSize: 17,
              height: 1.55,
            ),
          )
              .animate(target: target)
              .fade(
                duration: const Duration(milliseconds: 380),
                delay: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
              )
              .slideY(
                begin: 0.12,
                end: 0,
                duration: const Duration(milliseconds: 420),
                delay: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
              ),
        ],
      ),
    );
  }
}
