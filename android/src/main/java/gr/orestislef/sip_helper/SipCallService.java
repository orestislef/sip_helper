package gr.orestislef.sip_helper;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

/**
 * Foreground service that runs while a call is up, so Android keeps the
 * microphone open when the app goes to the background or the screen turns
 * off.
 */
public class SipCallService extends Service {
    static final String ACTION_STOP = "gr.orestislef.sip_helper.STOP_CALL_SERVICE";
    private static final String CHANNEL_ID = "sip_helper_call";
    private static final int NOTIFICATION_ID = 0x5171;

    private static volatile boolean requested = false;

    static boolean isRequested() {
        return requested;
    }

    static void markRequested(boolean value) {
        requested = value;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // startForeground always comes first: a service started with
        // startForegroundService must call it, even when it is told to stop.
        try {
            Notification notification = buildNotification();
            if (Build.VERSION.SDK_INT >= 30) {
                startForeground(NOTIFICATION_ID, notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
        } catch (Exception e) {
            Log.w("SipHelper", "Cannot start call service: " + e);
            requested = false;
            stopSelf();
            return START_NOT_STICKY;
        }
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            finish();
        }
        return START_NOT_STICKY;
    }

    private void finish() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } else {
            stopForeground(true);
        }
        stopSelf();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        requested = false;
        finish();
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        requested = false;
        super.onDestroy();
    }

    private Notification buildNotification() {
        NotificationManager manager =
                (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26 && manager != null) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "Calls", NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            manager.createNotificationChannel(channel);
        }

        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);

        ApplicationInfo info = getApplicationInfo();
        CharSequence label = getPackageManager().getApplicationLabel(info);
        builder.setContentTitle(label)
                .setContentText("Call in progress")
                .setSmallIcon(android.R.drawable.sym_action_call)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_CALL);

        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch != null) {
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;
            builder.setContentIntent(PendingIntent.getActivity(this, 0, launch, flags));
        }
        return builder.build();
    }
}
