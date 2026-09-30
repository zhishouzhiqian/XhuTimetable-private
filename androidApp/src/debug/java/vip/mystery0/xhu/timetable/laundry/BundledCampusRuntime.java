package vip.mystery0.xhu.timetable.laundry;

import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.res.AssetManager;
import android.content.res.Resources;
import dalvik.system.DexClassLoader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.Locale;

/** 只加载随测试包携带的组件，不查询或加载其他已安装应用。 */
final class BundledCampusRuntime extends ContextWrapper {
    private static BundledCampusRuntime cached;
    private final ApplicationInfo info;
    private final Resources resources;
    private final ClassLoader loader;

    static synchronized BundledCampusRuntime open(Context owner) throws Exception {
        // 同一进程复用 ClassLoader，避免再次进入设备页时重复装载同一原生库。
        if (cached != null) return cached;
        String expected;
        try (InputStream in = owner.getAssets().open("campus-runtime.sha256")) {
            byte[] bytes = new byte[64]; int offset = 0, count;
            while (offset < bytes.length && (count = in.read(bytes, offset, bytes.length - offset)) > 0) offset += count;
            expected = new String(bytes, "US-ASCII");
        }
        if (!expected.matches("[a-f0-9]{64}")) throw new IllegalStateException();
        File directory = new File(owner.getNoBackupFilesDir(), "campus-runtime");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException();
        File archive = new File(directory, expected + ".apk");
        if (!archive.exists()) {
            File temporary = File.createTempFile("runtime-", ".tmp", directory);
            // Android 14+ 要求动态代码文件在写入前标记只读。
            try (InputStream in = owner.getAssets().open("campus-runtime.apk");
                 FileOutputStream out = new FileOutputStream(temporary)) {
                if (!temporary.setReadOnly()) throw new IllegalStateException();
                byte[] buffer = new byte[65536]; int count;
                while ((count = in.read(buffer)) != -1) out.write(buffer, 0, count);
                out.getFD().sync();
            }
            if (!expected.equals(digest(temporary)) || !temporary.renameTo(archive)) throw new IllegalStateException();
        }
        if (!expected.equals(digest(archive)) || !archive.setReadOnly()) throw new IllegalStateException();
        cached = new BundledCampusRuntime(owner, archive);
        return cached;
    }

    // 新组件实际初始化成功后再清理历史归档，避免旧的完整 APK 长期占据安装后空间。
    static synchronized void pruneOldArchives(Context owner) {
        if (cached == null) return;
        File directory = new File(owner.getNoBackupFilesDir(), "campus-runtime");
        File[] files = directory.listFiles();
        if (files == null) return;
        for (File file : files) {
            if (file.isFile() && file.getName().matches("[a-f0-9]{64}\\.apk")
                && !file.getAbsolutePath().equals(cached.info.sourceDir)) file.delete();
        }
    }

    private BundledCampusRuntime(Context owner, File archive) throws Exception {
        super(owner);
        info = new ApplicationInfo(owner.getApplicationInfo());
        info.sourceDir = archive.getAbsolutePath();
        info.publicSourceDir = archive.getAbsolutePath();
        info.splitSourceDirs = null; info.splitPublicSourceDirs = null;
        resources = owner.getPackageManager().getResourcesForApplication(info);
        loader = new DexClassLoader(archive.getAbsolutePath(), owner.getCodeCacheDir().getAbsolutePath(),
            info.nativeLibraryDir, ClassLoader.getSystemClassLoader());
    }
    @Override public Context getApplicationContext() { return this; }
    @Override public ApplicationInfo getApplicationInfo() { return new ApplicationInfo(info); }
    @Override public ClassLoader getClassLoader() { return loader; }
    @Override public Resources getResources() { return resources; }
    @Override public AssetManager getAssets() { return resources.getAssets(); }
    @Override public String getPackageCodePath() { return info.sourceDir; }
    @Override public String getPackageResourcePath() { return info.publicSourceDir; }
    @Override public SharedPreferences getSharedPreferences(String name, int mode) {
        return getBaseContext().getSharedPreferences("campus_" + name, mode);
    }
    private static String digest(File file) throws Exception {
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(file)) {
            byte[] buffer = new byte[65536]; int count;
            while ((count = in.read(buffer)) != -1) hash.update(buffer, 0, count);
        }
        StringBuilder value = new StringBuilder();
        for (byte b : hash.digest()) value.append(String.format(Locale.ROOT, "%02x", b & 255));
        return value.toString();
    }
}
