import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../router/app_router.dart';

final mobileBackNavigationProvider = Provider<MobileBackNavigation>((ref) {
  final navigation = MobileBackNavigation(ref.watch(appRouterProvider));
  ref.onDispose(navigation.dispose);
  return navigation;
});

/// Section changes use go/goBranch, so they need history separate from the
/// Navigator's editor/dialog stack. Observe settled routes, not redirect inputs.
class MobileBackNavigation {
  MobileBackNavigation(this.router) {
    dispatcher = _MobileBackDispatcher(this);
    router.routerDelegate.addListener(_recordLocation);
    _recordLocation();
  }

  final GoRouter router;
  late final RootBackButtonDispatcher dispatcher;
  final List<Uri> _history = [];
  Uri? _returningTo;
  bool _disposed = false;

  Uri get _location => router.routerDelegate.currentConfiguration.uri;

  bool _isWorkspace(Uri uri) =>
      uri.path.startsWith('/') &&
      uri.path != '/boot' &&
      !uri.path.startsWith('/onboarding');

  bool get canGoBack =>
      _isWorkspace(_location) &&
      (_history.length > 1 || _location.path != '/dashboard');

  void _recordLocation() {
    final location = _location;
    if (!_isWorkspace(location)) {
      _history.clear();
      _returningTo = null;
      return;
    }
    if (_returningTo == location) {
      _returningTo = null;
    } else if (!router.canPop() &&
        (_history.isEmpty || _history.last != location)) {
      _history.add(location);
      // Keep navigation memory bounded during long counter sessions.
      if (_history.length > 100) _history.removeAt(0);
    }
    updatePlatformBackState(router.canPop());
  }

  /// Android predictive back must be delivered to Flutter even when the current
  /// section is the first page in its Navigator.
  bool updatePlatformBackState(bool navigatorCanHandlePop) {
    if (!_disposed) {
      SystemNavigator.setFrameworkHandlesBack(
        navigatorCanHandlePop || canGoBack,
      );
    }
    return true;
  }

  bool back() {
    if (!canGoBack) return false;
    if (_history.length > 1) {
      _history.removeLast();
      _returningTo = _history.last;
    } else {
      _history.clear();
      _returningTo = Uri.parse('/dashboard');
      _history.add(_returningTo!);
    }
    router.go(_returningTo.toString());
    return true;
  }

  void dispose() {
    _disposed = true;
    router.routerDelegate.removeListener(_recordLocation);
  }
}

class _MobileBackDispatcher extends RootBackButtonDispatcher {
  _MobileBackDispatcher(this.navigation);
  final MobileBackNavigation navigation;
  bool _handlingBack = false;

  @override
  Future<bool> didPopRoute() async {
    if (_handlingBack) return true;
    _handlingBack = true;
    try {
      // Let dialogs, nested routes and PopScope/UnsavedGuard consume back first.
      if (await super.didPopRoute()) return true;
      return navigation.back();
    } finally {
      _handlingBack = false;
    }
  }
}
