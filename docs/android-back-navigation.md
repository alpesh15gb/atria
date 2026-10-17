# Android system back navigation

Section changes made with go/goBranch now retain a bounded mobile navigation history. System back first delegates to Flutter navigation so dialogs, editors and unsaved-change confirmations retain their existing behavior. At section roots it returns to the previously visited section; Android predictive back is marked as handled while this history exists. At the dashboard with no remaining history Android may exit normally. Desktop navigation is unchanged.

Regression coverage includes section and document-type history, modal dismissal, editor pops, counter navigation, unsaved invoice confirmation, and the Android framework-handles-back platform signal. Physical Android edge gestures still require a device pass.
