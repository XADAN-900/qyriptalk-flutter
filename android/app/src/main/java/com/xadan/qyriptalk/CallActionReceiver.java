package com.xadan.qyriptalk;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Bildirimdeki "Reddet" (gelen arama) ve "Aramayı bitir" (süren görüşme) butonları. */
public class CallActionReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (NotificationHelper.ACTION_DECLINE.equals(action)) {
            NotificationHelper.cancelCall(context);
            String callId = intent.getStringExtra(NotificationHelper.EXTRA_CALL_ID);
            if (callId == null) callId = ChatWatcher.lastCallId;
            // Uygulama açık olmasa da karşı tarafa "reddedildi" bilgisini veritabanından ilet.
            ChatWatcher.get(context).declineCall(callId);
            MainActivity.sendAction("declined", callId, null);
        } else if (NotificationHelper.ACTION_HANGUP.equals(action)) {
            MainActivity.sendAction("hangup", null, null);
            KeepAliveService.start(context, false);
        }
    }
}
