package in.medibo.app;

// CMD #2076 — the instrumentation runner Firebase Test Lab drives. It does
// nothing but hand MainActivity to integration_test's FlutterTestRunner, which
// runs integration_test/android_gate_test.dart on the device and reports each
// Dart test as a JUnit result. See scripts/android_testlab.sh.

import androidx.test.rule.ActivityTestRule;
import dev.flutter.plugins.integration_test.FlutterTestRunner;
import org.junit.Rule;
import org.junit.runner.RunWith;

@RunWith(FlutterTestRunner.class)
public class MainActivityTest {
  @Rule
  public ActivityTestRule<MainActivity> rule = new ActivityTestRule<>(MainActivity.class, true, false);
}
