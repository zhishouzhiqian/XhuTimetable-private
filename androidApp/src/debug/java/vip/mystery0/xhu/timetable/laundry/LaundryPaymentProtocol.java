package vip.mystery0.xhu.timetable.laundry;

import java.net.URLEncoder;
import org.json.JSONArray;
import org.json.JSONObject;

/** 从已核验的实时报价构造订单；支付渠道仅接受已分析的微信重定向方式。 */
final class LaundryPaymentProtocol {
    static JSONObject createInput(JSONObject input, JSONObject quote, Object sequence) throws Exception {
        LaundryOrderProtocol.quote(input, quote);
        if (quote.optBoolean("onlyWalletPay",false)) throw new IllegalStateException("WECHAT_CHANNEL_UNAVAILABLE");
        long serial = new java.math.BigDecimal(sequence.toString()).longValueExact();
        if (serial <= 0) throw new IllegalStateException("RESPONSE_INVALID");
        JSONObject result = new JSONObject();
        for (String key : new String[]{"isv","businessType","orderTypeCode","paymentChannel","resNo","deviceId","modelType","campusAreaCode"})
            result.put(key,input.get(key));
        result.put("isvOrderId",serial).put("totalAmount",LaundryAmounts.cents(quote.get("totalAmount")))
            .put("discountAmount",LaundryAmounts.cents(quote.get("discountAmount")))
            .put("paymentAmount",LaundryAmounts.cents(quote.get("actualPayAmount")))
            .put("serviceItemDTOList",new JSONArray(quote.getJSONArray("serviceItemDTOList").toString()))
            .put("promotionDetailDTOList",new JSONArray(quote.getJSONArray("promotionDetailDTOList").toString()));
        return result;
    }
    static void checkCreated(JSONObject input, JSONObject order) throws Exception {
        if (order.optBoolean("createFailed",true) || !"WASH_AND_CARE".equals(order.optString("businessType"))
            || !input.get("isvOrderId").toString().equals(order.optString("isvOrderId"))
            || !input.getString("resNo").equals(order.optString("isvResNo"))
            || LaundryAmounts.cents(order.get("paymentAmount")) != input.getLong("paymentAmount")
            || order.optString("checkoutId").isEmpty()) throw new IllegalStateException("PAYMENT_MISMATCH");
    }
    static void checkCheckout(JSONObject pending, JSONObject checkout) throws Exception {
        if (!checkout.optBoolean("success",false) || checkout.optBoolean("failed",true)
            || !pending.getString("checkoutId").equals(checkout.optString("checkoutId"))
            || pending.getLong("amount") != LaundryAmounts.cents(checkout.get("orderAmount")))
            throw new IllegalStateException("PAYMENT_MISMATCH");
    }
    private static String enc(String value) throws Exception {
        return URLEncoder.encode(value,"UTF-8").replace("+","%20");
    }
    static String wechatUri(String checkoutId, JSONObject checkout, JSONArray methods) throws Exception {
        JSONObject selected=null;
        for(int i=0;i<methods.length();i++) {
            JSONObject m=methods.getJSONObject(i);
            if ("WECHAT".equals(m.optString("payOption")) && "USING".equals(m.optString("useStatus"))
                && "REDIRECT_PAY".equals(m.optString("prePayModel")) && "SCHEME".equals(m.optString("jumpType"))) {
                selected=m; break;
            }
        }
        if(selected==null) throw new IllegalStateException("WECHAT_CHANNEL_UNAVAILABLE");
        JSONObject extra=selected.optJSONObject("extraAttr");
        if(extra!=null && extra.length()>0) throw new IllegalStateException("WECHAT_CHANNEL_UNAVAILABLE");
        // 公开收银台脚本中 bizOrderId 参数实际传入 checkoutId；不传账号令牌。
        String[] keys={"payMethodConfigId","optionalChannelId","bizOrderId","amount","prePayModel","payType","payTool"};
        String[] values={selected.get("payMethodConfigId").toString(),selected.get("optionalChannelId").toString(),
            checkoutId,checkout.get("orderAmount").toString(),"REDIRECT_PAY",selected.getString("payTool"),selected.getString("payOptionDesc")};
        StringBuilder query=new StringBuilder();
        for(int i=0;i<keys.length;i++) { if(i>0)query.append('&');query.append(keys[i]).append('=').append(enc(values[i])); }
        return "weixin://dl/business/?appid=wx48eea1ea40d67ab0&path=pages/commonAggregateCashier/miniAppPay/index&query="
            +enc(query.toString())+"&env_version=release";
    }
}
