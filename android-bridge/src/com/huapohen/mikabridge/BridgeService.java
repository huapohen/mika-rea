package com.huapohen.mikabridge;
import android.app.*;import android.content.*;import android.os.*;import org.json.*;import java.net.*;import java.io.*;import java.util.concurrent.*;
public class BridgeService extends Service {
 volatile boolean running=false; ExecutorService worker; volatile HttpURLConnection active; JSONObject config;
 public IBinder onBind(Intent i){return null;}
 static void checkURL(String value) throws Exception {
  URL u=new URL(value); if(u.getUserInfo()!=null||u.getHost().isEmpty())throw new Exception();
  if(u.getProtocol().equals("https"))return;
  if(!u.getProtocol().equals("http") || !(u.getHost().matches("[0-9.]+")||u.getHost().equals("localhost")))throw new Exception();
  InetAddress ip=InetAddress.getByName(u.getHost());if(!ip.isLoopbackAddress()&&!ip.isSiteLocalAddress())throw new Exception();
 }
 static void validate(JSONObject c)throws Exception{checkURL(c.getString("relay"));checkURL(c.getString("mcp"));if(!c.getString("device").matches("[A-Za-z0-9_-]{1,64}")||c.getString("agent_token").isEmpty()||c.getString("mcp_token").isEmpty())throw new Exception();}
 void notifyState(String text){Notification n=new Notification.Builder(this,"remote").setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("Mika 远程协助已开启").setContentText(text).setOngoing(true).setContentIntent(PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE)).addAction(new Notification.Action.Builder(null,"停止连接",PendingIntent.getService(this,0,new Intent(this,BridgeService.class).setAction("STOP"),PendingIntent.FLAG_IMMUTABLE)).build()).build();startForeground(31001,n,android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);}
 public int onStartCommand(Intent i,int flags,int id){if(i!=null&&"STOP".equals(i.getAction())){stopSelf();return START_NOT_STICKY;}
 ((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(new NotificationChannel("remote","远程协助",NotificationManager.IMPORTANCE_LOW));notifyState("正在连接中继");if(running)return START_STICKY;
 try{config=MainActivity.read(this);validate(config);}catch(Exception e){stopSelf();return START_NOT_STICKY;}
 running=true;worker=Executors.newSingleThreadExecutor();worker.submit(()->{int failures=0;while(running){try{
 JSONObject command=post(endpoint("next"),config.getString("agent_token"),new JSONObject(),25000);if(!command.has("id")){failures=0;notifyState("中继已连接，等待任务；点此查看配置");continue;}
 JSONObject response;try{response=post(config.getString("mcp"),config.getString("mcp_token"),command.getJSONObject("rpc"),52000);}catch(Exception e){response=new JSONObject().put("jsonrpc","2.0").put("id",command.getJSONObject("rpc").opt("id")).put("error",new JSONObject().put("code",-32001).put("message","Mika 本机连接失败，请检查 MCP 是否开启"));}
 JSONObject result=new JSONObject().put("id",command.getString("id")).put("response",response);post(endpoint("result"),config.getString("agent_token"),result,8000);failures=0;notifyState("已转交任务，远程连接中");
 }catch(Exception e){if(!running)break;notifyState("连接暂时中断，正在重连；可随时停止");try{Thread.sleep(Math.min(30000,1000L<<Math.min(++failures,5)));}catch(InterruptedException stop){break;}}}});return START_STICKY;}
 String endpoint(String action)throws Exception{return config.getString("relay").replaceAll("/+$","")+"/v1/"+config.getString("device")+"/"+action;}
 JSONObject post(String url,String token,JSONObject body,int timeout)throws Exception{
  HttpURLConnection c=(HttpURLConnection)new URL(url).openConnection();active=c;try{c.setInstanceFollowRedirects(false);c.setConnectTimeout(8000);c.setReadTimeout(timeout);c.setRequestMethod("POST");c.setDoOutput(true);c.setRequestProperty("Authorization","Bearer "+token);c.setRequestProperty("Content-Type","application/json");c.setRequestProperty("Accept","application/json, text/event-stream");c.setRequestProperty("MCP-Protocol-Version","2025-06-18");byte[] data=body.toString().getBytes("UTF-8");c.setFixedLengthStreamingMode(data.length);try(OutputStream out=c.getOutputStream()){out.write(data);}if(c.getResponseCode()!=200)throw new IOException("HTTP failure");ByteArrayOutputStream out=new ByteArrayOutputStream();try(InputStream in=c.getInputStream()){byte[] buf=new byte[8192];int n;while((n=in.read(buf))!=-1){if(out.size()+n>2097152)throw new IOException("Too large");out.write(buf,0,n);}}return new JSONObject(out.toString("UTF-8"));}finally{c.disconnect();active=null;}}
 public void onDestroy(){running=false;if(active!=null)active.disconnect();if(worker!=null)worker.shutdownNow();super.onDestroy();}
}
