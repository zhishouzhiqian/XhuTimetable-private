package vip.mystery0.xhu.timetable.laundry;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.WindowManager;
import androidx.activity.ComponentActivity;
import androidx.activity.result.ActivityResultLauncher;
import com.google.zxing.client.android.Intents;
import com.journeyapps.barcodescanner.ScanContract;
import com.journeyapps.barcodescanner.ScanOptions;

/** 仅在本机识别洗衣二维码，不打开链接或发送网络请求。 */
public final class LaundryScanActivity extends ComponentActivity {
    private final ActivityResultLauncher<ScanOptions> scanner = registerForActivityResult(
        new ScanContract(), result -> {
            String contents = result.getContents();
            if (contents == null) {
                Intent original = result.getOriginalIntent();
                if (original != null && original.hasExtra(Intents.Scan.MISSING_CAMERA_PERMISSION))
                    finishWith("camera_denied");
                else finishWith("cancelled");
                return;
            }
            String resNo = resNoFromCode(contents);
            if (resNo == null) finishWith("unknown");
            else {
                setResult(Activity.RESULT_OK, new Intent().putExtra("laundry_scan_status", "recognized")
                    .putExtra("laundry_res_no", resNo));
                finish();
            }
        });

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        if (savedInstanceState == null) {
            scanner.launch(new ScanOptions()
                .setCaptureActivity(LaundryQrCaptureActivity.class)
                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setPrompt("请对准洗衣机二维码")
                .setBeepEnabled(false)
                .setBarcodeImageEnabled(false));
        }
    }

    private void finishWith(String status) {
        setResult("unknown".equals(status) ? Activity.RESULT_OK : Activity.RESULT_CANCELED,
            new Intent().putExtra("laundry_scan_status", status));
        finish();
    }

    private static String resNoFromCode(String contents) {
        return vip.mystery0.xhu.timetable.model.laundry.LaundryQrPolicy.INSTANCE.deviceNumber(contents);
    }
}
