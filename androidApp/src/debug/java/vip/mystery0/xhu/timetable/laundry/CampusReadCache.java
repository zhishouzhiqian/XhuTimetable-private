package vip.mystery0.xhu.timetable.laundry;

import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONArray;

/** 仅由校园串行线程访问；不缓存报价、付款结果或设备可用状态。 */
final class CampusReadCache {
    private String uid = "", sid = "";
    private JSONArray urgent;
    private long observedAt, verifiedAt;
    private boolean handoff;
    private final LinkedHashMap<String, String> devices = new LinkedHashMap<String, String>(16, 0.75f, true) {
        @Override protected boolean removeEldestEntry(Map.Entry<String, String> entry) { return size() > 16; }
    };

    boolean session(String nextUid, String nextSid) {
        if (uid.equals(nextUid) && sid.equals(nextSid)) return false;
        uid = nextUid; sid = nextSid;
        urgent = null; handoff = false; devices.clear();
        return true;
    }
    void verified(JSONArray rows, long sampledAt, long completedAt) throws Exception {
        urgent = new JSONArray(rows.toString());
        observedAt = sampledAt; verifiedAt = completedAt; handoff = false;
    }
    void allowLoginHandoff() { handoff = urgent != null && !sid.isEmpty(); }
    boolean takeLoginHandoff(long now) {
        boolean valid = handoff && !sid.isEmpty() && now >= verifiedAt && now - verifiedAt <= 30000;
        handoff = false;
        return valid;
    }
    CampusOrderSnapshot takeUrgent(long now) {
        JSONArray rows = urgent;
        urgent = null;
        if (rows == null || now < observedAt || now - observedAt > 30000) return null;
        return new CampusOrderSnapshot(rows, observedAt);
    }
    void discardUrgent() { urgent = null; handoff = false; }
    String device(String resNo) { return devices.get(resNo); }
    void rememberDevice(String resNo, String deviceId) { devices.put(resNo, deviceId); }
    void forgetDevice(String resNo) { devices.remove(resNo); }
}
