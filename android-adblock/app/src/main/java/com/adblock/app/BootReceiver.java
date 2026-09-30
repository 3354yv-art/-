package com.adblock.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.VpnService;

/** מפעיל מחדש את החוסם אחרי אתחול/עדכון, אם המשתמש השאיר אותו פעיל וההרשאה כבר ניתנה. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        try {
            boolean enabled = ctx.getSharedPreferences(AdBlockVpnService.PREFS, Context.MODE_PRIVATE)
                    .getBoolean(AdBlockVpnService.KEY_ENABLED, false);
            if (!enabled || VpnService.prepare(ctx) != null) return; // prepare != null => אין הרשאה עדיין
            ctx.startService(new Intent(ctx, AdBlockVpnService.class));
        } catch (Throwable ignored) { }
    }
}
