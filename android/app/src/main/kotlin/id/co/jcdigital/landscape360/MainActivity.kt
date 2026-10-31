package id.co.jcdigital.landscape360

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A FragmentActivity: the fingerprint / face unlock prompt (local_auth) needs one
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android 13+: the "Landscape 360 is using GPS" notification of a recording, GPS
        // Tracking or S.O.S only shows once the user allows notifications
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "l360/notifications").setMethodCallHandler { call, result ->
            if (call.method != "request") return@setMethodCallHandler result.notImplemented()
            val needed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            if (needed) {
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1360)
            }
            result.success(null)
        }
    }
}
