package vip.mystery0.xhu.timetable.laundry;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileOutputStream;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

/** 会话和设备标识只保存在本应用不可备份目录，使用 Android Keystore 加密。 */
final class CampusSessionStore {
    private static final String ALIAS = "campus-debug-session-v1";
    private final AtomicFile file;
    CampusSessionStore(Context context) {
        this(context, "campus-session.enc");
    }
    CampusSessionStore(Context context, String filename) {
        file = new AtomicFile(new File(context.getNoBackupFilesDir(), filename));
    }
    private SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (!store.containsAlias(ALIAS)) {
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            generator.generateKey();
        }
        return (SecretKey) store.getKey(ALIAS, null);
    }
    JSONObject load() throws Exception {
        if (!file.getBaseFile().exists()) return new JSONObject();
        byte[] bytes = file.readFully();
        if (bytes.length < 29) throw new IllegalStateException();
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, bytes, 0, 12));
        return new JSONObject(new String(cipher.doFinal(bytes, 12, bytes.length - 12), "UTF-8"));
    }
    void save(JSONObject data) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key());
        FileOutputStream out = file.startWrite();
        try {
            out.write(cipher.getIV());
            out.write(cipher.doFinal(data.toString().getBytes("UTF-8")));
            file.finishWrite(out);
        } catch (Exception error) {
            file.failWrite(out);
            throw error;
        }
    }
}
