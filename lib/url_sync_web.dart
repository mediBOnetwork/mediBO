// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

String currentPath() => html.window.location.pathname ?? '/';
String currentSearch() => html.window.location.search ?? '';

void pushUrl(String path) => html.window.history.pushState(null, '', path);
void replaceUrl(String path) => html.window.history.replaceState(null, '', path);

void listenPopState(void Function(String path) handler) {
  html.window.onPopState.listen((_) {
    handler(html.window.location.pathname ?? '/');
  });
}
