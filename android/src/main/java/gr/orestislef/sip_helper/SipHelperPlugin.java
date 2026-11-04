package gr.orestislef.sip_helper;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.AutomaticGainControl;
import android.media.audiofx.NoiseSuppressor;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.Process;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.RequiresApi;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.TimeUnit;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Native call audio for sip_helper on Android.
 *
 * Playback: an AudioTrack fed from a writer thread (16-bit mono PCM).
 * Capture: an AudioRecord on the VOICE_COMMUNICATION source (hardware echo
 * cancellation), delivered to Dart as 8 kHz 16-bit mono frames of 20 ms.
 * Session: communication mode, audio focus, speaker / Bluetooth routing, the
 * proximity screen lock and a foreground service while a call is up.
 */
public class SipHelperPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler, ActivityAware,
        PluginRegistry.RequestPermissionsResultListener {

    private static final String TAG = "SipHelper";
    private static final int PERMISSION_REQUEST = 0x5170;
    private static final int MIC_RATE = 8000;
    private static final int MAX_QUEUED_CHUNKS = 40;

    private interface PermissionCallback {
        void done(boolean granted);
    }

    private Context context;
    private AudioManager audioManager;
    private MethodChannel channel;
    private EventChannel micChannel;
    private final Handler main = new Handler(Looper.getMainLooper());
    private EventChannel.EventSink micSink;
    private ActivityPluginBinding activityBinding;
    private final List<PermissionCallback> permissionCallbacks = new ArrayList<>();

    // Player
    private final Object playerLock = new Object();
    private AudioTrack track;
    private int playerRate = 16000;
    private volatile boolean playerOpen = false;
    private final LinkedBlockingDeque<byte[]> writeQueue = new LinkedBlockingDeque<>();
    private Thread writer;
    private volatile boolean writerRunning = false;
    private final Runnable idleRelease = new Runnable() {
        @Override
        public void run() {
            if (!callActive && writeQueue.isEmpty()) releaseTrack();
        }
    };

    // Recorder
    private AudioRecord record;
    private int recordRate = MIC_RATE;
    private Thread reader;
    private volatile boolean recording = false;
    private AcousticEchoCanceler echoCanceler;
    private NoiseSuppressor noiseSuppressor;
    private AutomaticGainControl gainControl;

    // Session
    private volatile boolean callActive = false;
    private boolean speakerOn = false;
    private boolean scoStarted = false;
    private AudioFocusRequest focusRequest;
    private final AudioManager.OnAudioFocusChangeListener focusListener =
            new AudioManager.OnAudioFocusChangeListener() {
                @Override
                public void onAudioFocusChange(int focusChange) {
                }
            };
    private PowerManager.WakeLock proximityLock;

    // ── FlutterPlugin ──────────────────────────────────────────

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        channel = new MethodChannel(binding.getBinaryMessenger(), "sip_helper/audio");
        channel.setMethodCallHandler(this);
        micChannel = new EventChannel(binding.getBinaryMessenger(), "sip_helper/audio/mic");
        micChannel.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        stopRecorder();
        closePlayer();
        stopSession();
        writerRunning = false;
        if (writer != null) writer.interrupt();
        channel.setMethodCallHandler(null);
        micChannel.setStreamHandler(null);
    }

    // ── ActivityAware (needed for the permission dialog) ───────

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activityBinding = binding;
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        // The permission result goes to the recreated activity, keep waiting.
        if (activityBinding != null) {
            activityBinding.removeRequestPermissionsResultListener(this);
        }
        activityBinding = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges();
        // No activity left to deliver a permission result: fail the waiters
        // instead of leaving them hanging.
        List<PermissionCallback> callbacks = new ArrayList<>(permissionCallbacks);
        permissionCallbacks.clear();
        for (PermissionCallback c : callbacks) c.done(hasMicPermission());
    }

    // ── EventChannel (microphone frames) ───────────────────────

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        micSink = events;
    }

    @Override
    public void onCancel(Object arguments) {
        micSink = null;
    }

    // ── Method calls ───────────────────────────────────────────

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull final MethodChannel.Result result) {
        switch (call.method) {
            case "hasPermission":
                result.success(hasMicPermission());
                break;
            case "requestPermission":
                requestMicPermission(new PermissionCallback() {
                    @Override
                    public void done(boolean granted) {
                        result.success(granted);
                    }
                });
                break;
            case "openPlayer": {
                Integer rate = call.argument("sampleRate");
                openPlayer(rate != null ? rate : 16000);
                result.success(true);
                break;
            }
            case "write": {
                Object data = call.arguments;
                if (data instanceof byte[]) write((byte[]) data);
                result.success(null);
                break;
            }
            case "resetPlayer":
                resetPlayer();
                result.success(null);
                break;
            case "closePlayer":
                closePlayer();
                result.success(null);
                break;
            case "openRecorder":
                if (hasMicPermission()) {
                    result.success(startRecorder());
                } else {
                    requestMicPermission(new PermissionCallback() {
                        @Override
                        public void done(boolean granted) {
                            result.success(granted && startRecorder());
                        }
                    });
                }
                break;
            case "closeRecorder":
                stopRecorder();
                result.success(null);
                break;
            case "startSession": {
                Boolean speaker = call.argument("speaker");
                speakerOn = speaker != null && speaker;
                startSession();
                result.success(null);
                break;
            }
            case "stopSession":
                stopSession();
                result.success(null);
                break;
            case "setSpeaker": {
                Boolean on = call.argument("on");
                speakerOn = on != null && on;
                applyRoute();
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    // ── Permission ─────────────────────────────────────────────

    private boolean hasMicPermission() {
        if (Build.VERSION.SDK_INT < 23) return true;
        return context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED;
    }

    private void requestMicPermission(PermissionCallback callback) {
        if (hasMicPermission()) {
            callback.done(true);
            return;
        }
        Activity activity = activityBinding != null ? activityBinding.getActivity() : null;
        if (activity == null || Build.VERSION.SDK_INT < 23) {
            Log.w(TAG, "No activity to ask for the microphone permission");
            callback.done(false);
            return;
        }
        permissionCallbacks.add(callback);
        if (permissionCallbacks.size() == 1) {
            activity.requestPermissions(
                    new String[]{Manifest.permission.RECORD_AUDIO}, PERMISSION_REQUEST);
        }
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions,
                                              @NonNull int[] grantResults) {
        if (requestCode != PERMISSION_REQUEST) return false;
        boolean granted = grantResults.length > 0
                && grantResults[0] == PackageManager.PERMISSION_GRANTED;
        List<PermissionCallback> callbacks = new ArrayList<>(permissionCallbacks);
        permissionCallbacks.clear();
        for (PermissionCallback c : callbacks) c.done(granted);
        if (granted && callActive) startCallService();
        return true;
    }

    // ── Player ─────────────────────────────────────────────────

    private void openPlayer(int rate) {
        synchronized (playerLock) {
            if (rate != playerRate && track != null) releaseTrackLocked();
            playerRate = rate;
            playerOpen = true;
        }
        ensureWriter();
    }

    private void write(byte[] data) {
        if (!playerOpen || data.length == 0) return;
        while (writeQueue.size() >= MAX_QUEUED_CHUNKS) writeQueue.pollFirst();
        writeQueue.offerLast(data);
        ensureWriter();
        main.removeCallbacks(idleRelease);
        if (!callActive) main.postDelayed(idleRelease, 4000);
    }

    private void resetPlayer() {
        writeQueue.clear();
        synchronized (playerLock) {
            if (track != null) {
                try {
                    track.pause();
                    track.flush();
                    track.play();
                } catch (IllegalStateException e) {
                    releaseTrackLocked();
                }
            }
        }
    }

    private void closePlayer() {
        playerOpen = false;
        writeQueue.clear();
        main.removeCallbacks(idleRelease);
        releaseTrack();
    }

    private void releaseTrack() {
        synchronized (playerLock) {
            releaseTrackLocked();
        }
    }

    private void releaseTrackLocked() {
        if (track == null) return;
        try {
            track.pause();
            track.flush();
        } catch (IllegalStateException ignored) {
        }
        track.release();
        track = null;
    }

    private AudioTrack createTrack() {
        int usage = callActive
                ? AudioAttributes.USAGE_VOICE_COMMUNICATION
                : AudioAttributes.USAGE_NOTIFICATION_RINGTONE;
        int content = callActive
                ? AudioAttributes.CONTENT_TYPE_SPEECH
                : AudioAttributes.CONTENT_TYPE_SONIFICATION;
        AudioAttributes attributes = new AudioAttributes.Builder()
                .setUsage(usage)
                .setContentType(content)
                .build();
        AudioFormat format = new AudioFormat.Builder()
                .setSampleRate(playerRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build();
        int min = AudioTrack.getMinBufferSize(playerRate, AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        int size = Math.max(Math.max(min, 0) * 2, playerRate * 2 / 5);
        AudioTrack t;
        if (Build.VERSION.SDK_INT >= 23) {
            t = new AudioTrack.Builder()
                    .setAudioAttributes(attributes)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(size)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build();
        } else {
            t = new AudioTrack(attributes, format, size, AudioTrack.MODE_STREAM,
                    AudioManager.AUDIO_SESSION_ID_GENERATE);
        }
        if (t.getState() != AudioTrack.STATE_INITIALIZED) {
            t.release();
            return null;
        }
        t.play();
        return t;
    }

    private void ensureWriter() {
        if (writerRunning) return;
        writerRunning = true;
        writer = new Thread(new Runnable() {
            @Override
            public void run() {
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO);
                while (writerRunning) {
                    byte[] chunk;
                    try {
                        chunk = writeQueue.pollFirst(500, TimeUnit.MILLISECONDS);
                    } catch (InterruptedException e) {
                        break;
                    }
                    if (chunk == null) continue;
                    AudioTrack t;
                    synchronized (playerLock) {
                        if (!playerOpen) continue;
                        if (track == null) {
                            try {
                                track = createTrack();
                            } catch (Exception e) {
                                Log.w(TAG, "AudioTrack failed: " + e);
                                track = null;
                            }
                        }
                        t = track;
                    }
                    if (t == null) continue;
                    int offset = 0;
                    while (offset < chunk.length && writerRunning) {
                        int n;
                        try {
                            n = t.write(chunk, offset, chunk.length - offset);
                        } catch (Exception e) {
                            n = -1;
                        }
                        if (n <= 0) break;
                        offset += n;
                    }
                }
            }
        }, "sip_helper-player");
        writer.start();
    }

    // ── Recorder ───────────────────────────────────────────────

    private synchronized boolean startRecorder() {
        if (recording) return true;
        int[] rates = {MIC_RATE, 16000, 48000, 44100};
        AudioRecord created = null;
        for (int rate : rates) {
            int min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT);
            if (min <= 0) continue;
            int size = Math.max(min * 2, rate * 2 / 5);
            AudioRecord r;
            try {
                r = new AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, rate,
                        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size);
            } catch (Exception e) {
                continue;
            }
            if (r.getState() != AudioRecord.STATE_INITIALIZED) {
                r.release();
                continue;
            }
            created = r;
            recordRate = rate;
            break;
        }
        if (created == null) {
            Log.w(TAG, "No usable AudioRecord configuration");
            return false;
        }
        record = created;
        attachEffects(record.getAudioSessionId());
        try {
            record.startRecording();
        } catch (IllegalStateException e) {
            releaseRecord();
            return false;
        }
        if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
            releaseRecord();
            return false;
        }
        recording = true;
        final AudioRecord active = record;
        final int rate = recordRate;
        reader = new Thread(new Runnable() {
            @Override
            public void run() {
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO);
                int frameBytes = rate / 50 * 2; // 20 ms
                byte[] buf = new byte[frameBytes];
                while (recording) {
                    int got = 0;
                    boolean failed = false;
                    while (got < frameBytes && recording) {
                        int n = active.read(buf, got, frameBytes - got);
                        if (n < 0) {
                            // Dead object or the microphone was taken away.
                            Log.w(TAG, "Microphone read failed: " + n);
                            failed = true;
                            break;
                        }
                        if (n == 0) break;
                        got += n;
                    }
                    if (failed) {
                        recording = false;
                        break;
                    }
                    if (got < frameBytes) {
                        if (!recording) break;
                        continue;
                    }
                    final byte[] out = rate == MIC_RATE ? buf.clone() : downsample(buf, rate);
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            EventChannel.EventSink sink = micSink;
                            if (sink != null && recording) sink.success(out);
                        }
                    });
                }
            }
        }, "sip_helper-mic");
        reader.start();
        if (callActive) startCallService();
        return true;
    }

    /** Box-filter resample of 16-bit mono PCM to 8 kHz. */
    private static byte[] downsample(byte[] in, int rate) {
        int inSamples = in.length / 2;
        int outSamples = inSamples * MIC_RATE / rate;
        byte[] out = new byte[outSamples * 2];
        double ratio = (double) rate / MIC_RATE;
        for (int i = 0; i < outSamples; i++) {
            int start = (int) (i * ratio);
            int end = Math.min(inSamples, (int) ((i + 1) * ratio));
            if (end <= start) end = Math.min(inSamples, start + 1);
            long sum = 0;
            for (int j = start; j < end; j++) {
                sum += (short) ((in[j * 2] & 0xFF) | (in[j * 2 + 1] << 8));
            }
            int v = (int) (sum / Math.max(1, end - start));
            out[i * 2] = (byte) (v & 0xFF);
            out[i * 2 + 1] = (byte) ((v >> 8) & 0xFF);
        }
        return out;
    }

    private void attachEffects(int sessionId) {
        try {
            if (AcousticEchoCanceler.isAvailable()) {
                echoCanceler = AcousticEchoCanceler.create(sessionId);
                if (echoCanceler != null) echoCanceler.setEnabled(true);
            }
            if (NoiseSuppressor.isAvailable()) {
                noiseSuppressor = NoiseSuppressor.create(sessionId);
                if (noiseSuppressor != null) noiseSuppressor.setEnabled(true);
            }
            if (AutomaticGainControl.isAvailable()) {
                gainControl = AutomaticGainControl.create(sessionId);
                if (gainControl != null) gainControl.setEnabled(true);
            }
        } catch (Exception e) {
            Log.w(TAG, "Audio effects not available: " + e);
        }
    }

    private synchronized void stopRecorder() {
        if (!recording && record == null) return;
        recording = false;
        if (record != null) {
            try {
                record.stop();
            } catch (IllegalStateException ignored) {
            }
        }
        if (reader != null) {
            try {
                reader.join(300);
            } catch (InterruptedException ignored) {
            }
            reader = null;
        }
        releaseRecord();
    }

    private void releaseRecord() {
        recording = false;
        if (echoCanceler != null) {
            echoCanceler.release();
            echoCanceler = null;
        }
        if (noiseSuppressor != null) {
            noiseSuppressor.release();
            noiseSuppressor = null;
        }
        if (gainControl != null) {
            gainControl.release();
            gainControl = null;
        }
        if (record != null) {
            record.release();
            record = null;
        }
    }

    // ── Session ────────────────────────────────────────────────

    private void startSession() {
        if (!callActive) {
            callActive = true;
            main.removeCallbacks(idleRelease);
            requestFocus();
            try {
                audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION);
            } catch (SecurityException e) {
                Log.w(TAG, "Cannot switch to communication mode: " + e);
            }
            // Voice now goes out as a call stream, not as a ringtone.
            writeQueue.clear();
            releaseTrack();
            startCallService();
        }
        applyRoute();
    }

    private void stopSession() {
        if (!callActive) return;
        callActive = false;
        speakerOn = false;
        if (Build.VERSION.SDK_INT >= 31) {
            try {
                audioManager.clearCommunicationDevice();
            } catch (Exception ignored) {
            }
        } else {
            if (scoStarted) {
                audioManager.setBluetoothScoOn(false);
                audioManager.stopBluetoothSco();
                scoStarted = false;
            }
            audioManager.setSpeakerphoneOn(false);
        }
        try {
            audioManager.setMode(AudioManager.MODE_NORMAL);
        } catch (SecurityException ignored) {
        }
        abandonFocus();
        setProximity(false);
        stopCallService();
        writeQueue.clear();
        releaseTrack();
    }

    private void applyRoute() {
        if (!callActive) return;
        if (Build.VERSION.SDK_INT >= 31) {
            AudioDeviceInfo target = null;
            List<AudioDeviceInfo> devices = audioManager.getAvailableCommunicationDevices();
            if (speakerOn) {
                target = findDevice(devices, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER);
            } else {
                target = findDevice(devices, AudioDeviceInfo.TYPE_BLE_HEADSET,
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_WIRED_HEADSET,
                        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE);
            }
            try {
                if (target != null) {
                    audioManager.setCommunicationDevice(target);
                } else {
                    audioManager.clearCommunicationDevice();
                }
            } catch (Exception e) {
                Log.w(TAG, "Routing failed: " + e);
            }
        } else {
            audioManager.setSpeakerphoneOn(speakerOn);
            boolean useSco = !speakerOn && hasBluetoothHeadset();
            if (useSco && !scoStarted) {
                try {
                    audioManager.startBluetoothSco();
                    audioManager.setBluetoothScoOn(true);
                    scoStarted = true;
                } catch (Exception e) {
                    Log.w(TAG, "Bluetooth SCO failed: " + e);
                }
            } else if (!useSco && scoStarted) {
                audioManager.setBluetoothScoOn(false);
                audioManager.stopBluetoothSco();
                scoStarted = false;
            }
        }
        setProximity(!speakerOn);
    }

    @RequiresApi(31)
    private static AudioDeviceInfo findDevice(List<AudioDeviceInfo> devices, int... types) {
        for (int type : types) {
            for (AudioDeviceInfo d : devices) {
                if (d.getType() == type) return d;
            }
        }
        return null;
    }

    private boolean hasBluetoothHeadset() {
        if (Build.VERSION.SDK_INT < 23) return false;
        for (AudioDeviceInfo d : audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            if (d.getType() == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) return true;
        }
        return false;
    }

    private void requestFocus() {
        if (Build.VERSION.SDK_INT >= 26) {
            focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build())
                    .setOnAudioFocusChangeListener(focusListener)
                    .build();
            audioManager.requestAudioFocus(focusRequest);
        } else {
            audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_VOICE_CALL,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT);
        }
    }

    private void abandonFocus() {
        if (Build.VERSION.SDK_INT >= 26) {
            if (focusRequest != null) audioManager.abandonAudioFocusRequest(focusRequest);
            focusRequest = null;
        } else {
            audioManager.abandonAudioFocus(focusListener);
        }
    }

    /** Turn the screen off when the phone is held to the ear. */
    private void setProximity(boolean on) {
        try {
            if (on && callActive) {
                if (proximityLock == null) {
                    PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
                    if (pm == null || !pm.isWakeLockLevelSupported(
                            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                        return;
                    }
                    proximityLock = pm.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                            "sip_helper:proximity");
                    proximityLock.setReferenceCounted(false);
                }
                if (!proximityLock.isHeld()) proximityLock.acquire();
            } else if (proximityLock != null && proximityLock.isHeld()) {
                proximityLock.release();
            }
        } catch (Exception e) {
            Log.w(TAG, "Proximity lock failed: " + e);
        }
    }

    private void startCallService() {
        if (!callActive || SipCallService.isRequested()) return;
        // Android 14 refuses a microphone service before the permission, and
        // Android 12+ refuses to start one from the background.
        if (!hasMicPermission() || activityBinding == null) return;
        Intent intent = new Intent(context, SipCallService.class);
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
            SipCallService.markRequested(true);
        } catch (Exception e) {
            Log.w(TAG, "Call service not started: " + e);
        }
    }

    private void stopCallService() {
        if (!SipCallService.isRequested()) return;
        SipCallService.markRequested(false);
        // Ask the service to stop itself after it called startForeground:
        // stopping it before that crashes the app on Android 8 and newer.
        Intent intent = new Intent(context, SipCallService.class)
                .setAction(SipCallService.ACTION_STOP);
        try {
            context.startService(intent);
        } catch (Exception e) {
            try {
                context.stopService(new Intent(context, SipCallService.class));
            } catch (Exception ignored) {
            }
        }
    }
}
