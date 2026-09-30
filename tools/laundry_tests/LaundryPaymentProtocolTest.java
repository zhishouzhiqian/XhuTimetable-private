package vip.mystery0.xhu.timetable.laundry;
import org.json.*;
import java.net.URLDecoder;
public final class LaundryPaymentProtocolTest {
    interface Action {void run() throws Exception;}
    static int count;
    static void check(boolean ok){if(!ok)throw new AssertionError("check "+count);count++;}
    static void rejects(Action action) throws Exception {try{action.run();}catch(Exception e){count++;return;}throw new AssertionError("accepted invalid input");}
    static JSONObject input() throws Exception{return new JSONObject("{isv:'CAMPUS',businessType:'WASH_AND_CARE',orderTypeCode:'SERVICE_ORDER',paymentChannel:'TMXY_APP',resNo:'test-device',deviceId:'test-device-id',modelType:'FIXED_TIME_CHARGE',campusAreaCode:1,serviceItemDTOList:[{serviceItemId:'test-mode',serviceItemName:'测试档位'}]}");}
    static JSONObject quote() throws Exception{return new JSONObject("{resNo:'test-device',businessType:'WASH_AND_CARE',totalAmount:100,discountAmount:20,actualPayAmount:80,promotionDetailDTOList:[],serviceItemDTOList:[{serviceItemId:'test-mode'}]}");}
    public static void main(String[] args)throws Exception{
        JSONObject body=LaundryPaymentProtocol.createInput(input(),quote(),123);
        check(body.getLong("paymentAmount")==80);check(body.getLong("isvOrderId")==123);
        rejects(()->LaundryPaymentProtocol.createInput(input(),quote().put("actualPayAmount",90),123));
        rejects(()->LaundryPaymentProtocol.createInput(input(),quote().put("resNo","other"),123));
        rejects(()->LaundryPaymentProtocol.createInput(input(),quote().put("onlyWalletPay",true),123));
        rejects(()->LaundryPaymentProtocol.createInput(input(),quote(),-1));
        JSONObject created=new JSONObject("{createFailed:false,businessType:'WASH_AND_CARE',isvOrderId:'123',isvResNo:'test-device',paymentAmount:80,checkoutId:'test-checkout'}");
        LaundryPaymentProtocol.checkCreated(body,created);count++;
        rejects(()->LaundryPaymentProtocol.checkCreated(body,new JSONObject(created.toString()).put("paymentAmount",100)));
        rejects(()->LaundryPaymentProtocol.checkCreated(body,new JSONObject(created.toString()).put("isvOrderId","other")));
        JSONObject pending=new JSONObject("{checkoutId:'test-checkout',amount:80}");
        JSONObject checkout=new JSONObject("{checkoutId:'test-checkout',orderAmount:80,success:true,failed:false,status:'INIT'}");
        LaundryPaymentProtocol.checkCheckout(pending,checkout);count++;
        rejects(()->LaundryPaymentProtocol.checkCheckout(pending,new JSONObject(checkout.toString()).put("checkoutId","other")));
        rejects(()->LaundryPaymentProtocol.checkCheckout(pending,new JSONObject(checkout.toString()).put("orderAmount",81)));
        JSONObject method=new JSONObject("{payOption:'WECHAT',useStatus:'USING',prePayModel:'REDIRECT_PAY',jumpType:'SCHEME',extraAttr:{},payMethodConfigId:1,optionalChannelId:2,payTool:'YIBAO_WECHAT_APPLET',payOptionDesc:'微信支付'}");
        String uri=LaundryPaymentProtocol.wechatUri("test-checkout",checkout,new JSONArray().put(method));
        check(uri.startsWith("weixin://dl/business/?appid=wx48eea1ea40d67ab0"));
        check(URLDecoder.decode(uri,"UTF-8").contains("bizOrderId=test-checkout&amount=80"));
        rejects(()->LaundryPaymentProtocol.wechatUri("test-checkout",checkout,new JSONArray()));
        rejects(()->LaundryPaymentProtocol.wechatUri("test-checkout",checkout,new JSONArray().put(new JSONObject(method.toString()).put("prePayModel","DIRECT_PAY"))));
        rejects(()->LaundryPaymentProtocol.wechatUri("test-checkout",checkout,new JSONArray().put(new JSONObject(method.toString()).put("extraAttr",new JSONObject().put("unexpected","value")))));
        System.out.println(count+" payment contract checks passed");
    }
}
