package vip.mystery0.xhu.timetable.laundry;

import org.json.JSONArray;

/** 订单列表携带实际采样时刻，复用核验结果时不重新起算倒计时。 */
final class CampusOrderSnapshot {
    final JSONArray orders;
    final long observedAt;
    CampusOrderSnapshot(JSONArray orders, long observedAt) {
        this.orders = orders;
        this.observedAt = observedAt;
    }
}
