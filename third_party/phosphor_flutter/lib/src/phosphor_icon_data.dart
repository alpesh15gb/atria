/// Patched for Flutter 3.47+.
///
/// The original 2.1.0 release declared `class PhosphorIconData extends IconData`
/// and `class PhosphorFlatIconData extends PhosphorIconData`. `IconData` is now a
/// `final` class and cannot be subclassed outside the Flutter framework library,
/// which was a hard compile error on every platform target and blocked all builds.
///
/// This vendored copy therefore no longer declares those classes: the generated
/// style files (`phosphor_icons_*.dart`) construct plain [IconData] values
/// directly, and `phosphor_icons_base.dart` annotates with [IconData].
///
/// Dart cannot typedef a non-function type, so `PhosphorIconData` is not aliased;
/// it no longer exists as a type name. The app uses `PhosphorIconsRegular` and
/// `PhosphorIconsFill`, whose static members are `IconData` and remain unchanged.
library phosphor_flutter;
