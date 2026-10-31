package com.huapohen.mikabridge;
import android.app.*; import android.os.*; import android.content.*; import android.widget.*; import org.json.*;
import java.nio.file.*; import javax.crypto.*; import javax.crypto.spec.*; import android.security.keystore.*; import java.security.*; import android.util.Base64;
public class MainActivity extends Activity {
 static JSONObject read(android.content.Context c) throws Exception {
  java.io.File f=new java.io.File(c.getFilesDir(),"bootstrap.json");
  if(f.exists()){JSONObject j=new JSONObject(new String(Files.readAllBytes(f.toPath()),"UTF-8"));save(c,j); f.delete();return j;}
  String encrypted=c.getSharedPreferences("bridge",0).getString("config",""); if(encrypted.isEmpty())return new JSONObject();
  byte[] all=Base64.decode(encrypted,0); Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,java.util.Arrays.copyOfRange(all,0,12)));return new JSONObject(new String(cipher.doFinal(java.util.Arrays.copyOfRange(all,12,all.length)),"UTF-8"));
 }
 static java.security.Key key() throws Exception {KeyStore ks=KeyStore.getInstance("AndroidKeyStore");ks.load(null);if(!ks.containsAlias("mika-bridge")){KeyGenerator g=KeyGenerator.getInstance("AES","AndroidKeyStore");g.init(new KeyGenParameterSpec.Builder("mika-bridge",KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT).setBlockModes("GCM").setEncryptionPaddings("NoPadding").build());g.generateKey();}return ks.getKey("mika-bridge",null);}
 static void save(android.content.Context c,JSONObject j)throws Exception{Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());byte[] data=cipher.doFinal(j.toString().getBytes("UTF-8"));byte[] all=new byte[12+data.length];System.arraycopy(cipher.getIV(),0,all,0,12);System.arraycopy(data,0,all,12,data.length);c.getSharedPreferences("bridge",0).edit().putString("config",Base64.encodeToString(all,0)).commit();}
 public void onCreate(Bundle state){super.onCreate(state);LinearLayout layout=new LinearLayout(this);layout.setOrientation(1);layout.setPadding(32,50,32,32);setContentView(layout);
 TextView heading=new TextView(this);heading.setText("Mika 远程协助\n开启后允许已配对的 iPhone 通过 Mika 执行任务。通知栏可随时停止。公网请使用 HTTPS 中继。\n");layout.addView(heading);
 String[] names={"relay","device","agent_token","mcp","mcp_token"};String[] labels={"HTTPS 中继地址","设备 ID","设备连接令牌","本机 Mika MCP 地址","Mika MCP 令牌"};EditText[] fields=new EditText[5];JSONObject config;try{config=read(this);}catch(Exception e){config=new JSONObject();}
 for(int i=0;i<5;i++){fields[i]=new EditText(this);fields[i].setHint(labels[i]);fields[i].setSingleLine(true);fields[i].setText(config.optString(names[i]));if(names[i].contains("token"))fields[i].setInputType(129);layout.addView(fields[i]);}
 Button start=new Button(this);start.setText("保存并开启连接");layout.addView(start);start.setOnClickListener(v->{try{JSONObject j=new JSONObject();for(int i=0;i<5;i++)j.put(names[i],fields[i].getText().toString().trim());BridgeService.validate(j);save(this,j);startForegroundService(new Intent(this,BridgeService.class));Toast.makeText(this,"连接已开启，状态见通知栏",0).show();}catch(Exception e){android.util.Log.w("MikaBridge","Configuration failed: "+e.getClass().getSimpleName());Toast.makeText(this,"配置失败："+e.getClass().getSimpleName(),0).show();}});
 Button stop=new Button(this);stop.setText("停止远程连接");layout.addView(stop);stop.setOnClickListener(v->stopService(new Intent(this,BridgeService.class)));
 if(Build.VERSION.SDK_INT>=33)requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"},1);
 }
}
