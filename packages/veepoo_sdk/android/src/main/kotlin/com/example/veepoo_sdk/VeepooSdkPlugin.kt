package com.example.veepoo_sdk

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.inuker.bluetooth.library.Code
import com.inuker.bluetooth.library.model.BleGattProfile
import com.veepoo.protocol.VPOperateManager
import com.veepoo.protocol.listener.base.*
import com.veepoo.protocol.listener.data.*
import com.veepoo.protocol.model.datas.*
import com.veepoo.protocol.model.settings.CustomSettingData
import com.veepoo.protocol.model.enums.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject
import android.util.Log

private const val TAG = "VeepooPlugin"

class VeepooSdkPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private lateinit var context: Context
    private val mainHandler = Handler(Looper.getMainLooper())
    private var currentMac: String? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        VPOperateManager.getInstance().init(context) // Initialize SDK
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "veepoo_methods")
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "veepoo_events")
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "connect" -> {
                val mac = call.argument<String>("mac") ?: return result.error("INVALID_ARG", "MAC required", null)
                currentMac = mac
                Log.i(TAG, "[connect] Connecting to MAC: $mac")
                
                // Register connection status listener immediately to avoid missing callbacks
                VPOperateManager.getInstance().registerConnectStatusListener(mac, object : IABleConnectStatusListener() {
                    override fun onConnectStatusChanged(mac: String?, status: Int) {
                        Log.i(TAG, "[connectionState] mac=$mac status=$status")
                        sendEvent(JSONObject().apply {
                            put("type", "connectionState")
                            put("state", status)
                        })
                    }
                })

                VPOperateManager.getInstance().connectDevice(mac, { code, profile, isOadModel ->
                    Log.i(TAG, "[connect] connectDevice result code=$code")
                    if (code == Code.REQUEST_SUCCESS) {
                        mainHandler.post { result.success(true) }
                    } else {
                        Log.e(TAG, "[connect] Connection FAILED with code=$code")
                        mainHandler.post { result.success(false) }
                    }
                }, { state ->
                    Log.i(TAG, "[connect] notifyState callback, state=$state")
                    sendEvent(JSONObject().apply {
                        put("type", "notifyState")
                        put("state", state)
                    })
                })
            }
            "startScan" -> {
                VPOperateManager.getInstance().startScanDevice(object : com.inuker.bluetooth.library.search.response.SearchResponse {
                    override fun onSearchStarted() {}
                    override fun onDeviceFounded(device: com.inuker.bluetooth.library.search.SearchResult?) {
                        if (device != null && device.name.isNotEmpty()) {
                            sendEvent(JSONObject().apply {
                                put("type", "scanResult")
                                put("mac", device.address)
                                put("name", device.name)
                            })
                        }
                    }
                    override fun onSearchStopped() {}
                    override fun onSearchCanceled() {}
                })
                result.success(true)
            }
            "stopScan" -> {
                VPOperateManager.getInstance().stopScanDevice()
                result.success(true)
            }
            "disconnect" -> {
                VPOperateManager.getInstance().disconnectWatch(IBleWriteResponse {
                    mainHandler.post { result.success(true) }
                })
            }
            "confirmDevicePwd" -> {
                val pwd = call.argument<String>("pwd") ?: "0000"
                Log.i(TAG, "[confirmDevicePwd] Sending password confirmation...")
                VPOperateManager.getInstance().confirmDevicePwd(IBleWriteResponse { }, 
                object : IPwdDataListener {
                    override fun onPwdDataChange(pwdData: PwdData?) {
                        val status = pwdData?.getmStatus()
                        val success = status == EPwdStatus.CHECK_AND_TIME_SUCCESS
                        Log.i(TAG, "[confirmDevicePwd] onPwdDataChange status=$status success=$success")
                        mainHandler.post { result.success(success) }
                    }
                    override fun onConnectionConfirmTimeout() {
                        Log.e(TAG, "[confirmDevicePwd] TIMEOUT - no response from device")
                        mainHandler.post { result.success(false) }
                    }
                }, 
                object : IDeviceFuctionDataListener {
                    override fun onFunctionSupportDataChange(functionSupport: FunctionDeviceSupportData?) {}
                    override fun onDeviceFunctionPackage1Report(p0: DeviceFunctionPackage1?) {}
                    override fun onDeviceFunctionPackage2Report(p0: DeviceFunctionPackage2?) {}
                    override fun onDeviceFunctionPackage3Report(p0: DeviceFunctionPackage3?) {}
                    override fun onDeviceFunctionPackage4Report(p0: DeviceFunctionPackage4?) {}
                    override fun onDeviceFunctionPackage5Report(p0: DeviceFunctionPackage5?) {}
                }, 
                object : ISocialMsgDataListener {
                    override fun onSocialMsgSupportDataChange(socailMsgData: FunctionSocailMsgData?) {}
                    override fun onSocialMsgSupportDataChange2(p0: FunctionSocailMsgData?) {}
                }, 
                object : ICustomSettingDataListener {
                    override fun OnSettingDataChange(p0: CustomSettingData?) {}
                }, pwd, false)
            }
            "syncPersonInfo" -> {
                val sex = if (call.argument<Int>("sex") == 1) ESex.MAN else ESex.WOMEN
                val height = call.argument<Int>("height") ?: 170
                val weight = call.argument<Int>("weight") ?: 60
                val age = call.argument<Int>("age") ?: 25
                val targetStep = call.argument<Int>("targetStep") ?: 8000
                Log.i(TAG, "[syncPersonInfo] sex=$sex height=$height weight=$weight age=$age steps=$targetStep")
                
                VPOperateManager.getInstance().syncPersonInfo(IBleWriteResponse { }, object : IPersonInfoDataListener {
                    override fun OnPersoninfoDataChange(status: EOprateStauts?) {
                        Log.i(TAG, "[syncPersonInfo] result status=$status")
                        mainHandler.post { result.success(status == EOprateStauts.OPRATE_SUCCESS) }
                    }
                }, PersonInfoData(sex, height, weight, age, targetStep))
            }
            "startDetectHeart" -> {
                Log.i(TAG, "[startDetectHeart] Starting heart rate detection...")
                var consecutiveZeroCount = 0
                // Threshold: 8 ticks with value=0 → declare off-wrist.
                // STATE_INIT warmup on a worn band typically resolves in 2-4 ticks,
                // but STATE_INIT when NOT worn continues indefinitely.
                val ZERO_COUNT_THRESHOLD = 8
                VPOperateManager.getInstance().startDetectHeart(IBleWriteResponse { },
                object : IHeartDataListener {
                    override fun onDataChange(heartData: HeartData?) {
                        Log.d(TAG, "[heartRate] status=${heartData?.heartStatus} value=${heartData?.data} zeroCount=$consecutiveZeroCount")
                        if (heartData != null) {
                            val status = heartData.heartStatus
                            val value = heartData.data
                            if (value > 20) {
                                // Valid heart rate reading → on-wrist, reset counter
                                consecutiveZeroCount = 0
                                sendEvent(JSONObject().apply {
                                    put("type", "heartRate")
                                    put("value", value)
                                })
                                sendEvent(JSONObject().apply {
                                    put("type", "checkWear")
                                    put("isRemoved", false)
                                })
                            } else if (status == EHeartStatus.STATE_HEART_WEAR_ERROR) {
                                // Band explicitly signals incorrect wearing → immediate off-wrist
                                consecutiveZeroCount = 0
                                sendEvent(JSONObject().apply {
                                    put("type", "checkWear")
                                    put("isRemoved", true)
                                })
                            } else if (status == EHeartStatus.STATE_HEART_BUSY) {
                                // Device is busy with another operation — do NOT count, do nothing
                                Log.d(TAG, "[heartRate] Device busy, skipping count")
                            } else {
                                // STATE_INIT or STATE_HEART_DETECT with value=0:
                                // Both mean no valid pulse detected. Count them together.
                                // When worn, sensor quickly resolves to STATE_HEART_NORMAL (value>20).
                                // When not worn, it stays at 0 indefinitely → off-wrist after threshold.
                                consecutiveZeroCount++
                                Log.d(TAG, "[heartRate] No pulse tick #$consecutiveZeroCount / $ZERO_COUNT_THRESHOLD")
                                if (consecutiveZeroCount >= ZERO_COUNT_THRESHOLD) {
                                    sendEvent(JSONObject().apply {
                                        put("type", "checkWear")
                                        put("isRemoved", true)
                                    })
                                }
                            }
                        }
                    }
                })
                result.success(true)
            }
            "stopDetectHeart" -> {
                VPOperateManager.getInstance().stopDetectHeart(IBleWriteResponse { })
                result.success(true)
            }
            "startDetectSPO2" -> {
                Log.i(TAG, "[startDetectSPO2] Starting SpO2 detection...")
                VPOperateManager.getInstance().startDetectSPO2H(IBleWriteResponse { },
                object : ISpo2hDataListener {
                    override fun onSpO2HADataChange(spo2Data: Spo2hData?) {
                        Log.d(TAG, "[spo2] state=${spo2Data?.spState} value=${spo2Data?.value}")
                        if (spo2Data != null && spo2Data.value > 0) {
                            sendEvent(JSONObject().apply {
                                put("type", "spo2")
                                put("value", spo2Data.value)
                            })
                        }
                    }
                })
                result.success(true)
            }
            "stopDetectSPO2" -> {
                VPOperateManager.getInstance().stopDetectSPO2H(IBleWriteResponse { },
                object : ISpo2hDataListener {
                    override fun onSpO2HADataChange(spo2Data: Spo2hData?) {}
                })
                result.success(true)
            }
            "startDetectBP" -> {
                Log.i(TAG, "[startDetectBP] Starting blood pressure detection...")
                VPOperateManager.getInstance().startDetectBP(IBleWriteResponse { },
                object : IBPDetectDataListener {
                    override fun onDataChange(bpData: BpData?) {
                        val high = bpData?.highPressure ?: 0
                        val low = bpData?.lowPressure ?: 0
                        Log.d(TAG, "[bloodPressure] status=${bpData?.status} progress=${bpData?.progress} high=$high low=$low")
                        if (bpData != null && high > 0 && low > 0) {
                            sendEvent(JSONObject().apply {
                                put("type", "bloodPressure")
                                put("sys", high)
                                put("dia", low)
                            })
                        }
                    }
                }, EBPDetectModel.DETECT_MODEL_PUBLIC)
                result.success(true)
            }
            "stopDetectBP" -> {
                VPOperateManager.getInstance().stopDetectBP(IBleWriteResponse { }, EBPDetectModel.DETECT_MODEL_PUBLIC)
                result.success(true)
            }
            "startDetectTemp" -> {
                Log.i(TAG, "[startDetectTemp] Starting temperature detection...")
                VPOperateManager.getInstance().startDetectTempture(IBleWriteResponse { },
                object : ITemptureDetectDataListener {
                    override fun onDataChange(tempData: TemptureDetectData?) {
                        val progress = tempData?.progress ?: 0
                        val temp = tempData?.tempture ?: 0f
                        val tempBase = tempData?.temptureBase ?: 0f
                        Log.d(TAG, "[temperature] progress=$progress core=$temp skin=$tempBase")
                        if (temp > 0f || tempBase > 0f) {
                            sendEvent(JSONObject().apply {
                                put("type", "temperature")
                                put("value", temp)
                                put("valueBase", tempBase)
                            })
                        }
                    }
                })
                result.success(true)
            }
            "stopDetectTemp" -> {
                VPOperateManager.getInstance().stopDetectTempture(IBleWriteResponse { },
                object : ITemptureDetectDataListener {
                    override fun onDataChange(tempData: TemptureDetectData?) {}
                })
                result.success(true)
            }
            "readSportStep" -> {
                Log.i(TAG, "[readSportStep] Reading daily activity/steps data...")
                VPOperateManager.getInstance().readSportStep(IBleWriteResponse { },
                object : ISportDataListener {
                    override fun onSportDataChange(sportData: SportData?) {
                        if (sportData != null) {
                            Log.d(TAG, "[sportData] steps=${sportData.step} dis=${sportData.dis} kcal=${sportData.kcal}")
                            sendEvent(JSONObject().apply {
                                put("type", "sportData")
                                put("step", sportData.step)
                                put("distance", sportData.dis)
                                put("calories", sportData.kcal)
                            })
                        }
                    }
                })
                result.success(true)
            }
            "startDetectHrv" -> {
                Log.i(TAG, "[startDetectHrv] Starting HRV detection...")
                VPOperateManager.getInstance().startDetectHrv(IBleWriteResponse { },
                object : IHrvDetectListener {
                    override fun onHrvDetect(hrv: Int) {
                        Log.d(TAG, "[hrvData] hrv=$hrv")
                        if (hrv > 0) {
                            sendEvent(JSONObject().apply {
                                put("type", "hrv")
                                put("value", hrv)
                            })
                        }
                    }
                    override fun onDetectFailed(detectState: HrvDetectState) {
                        Log.e(TAG, "[hrv] onDetectFailed state=$detectState")
                    }
                    override fun onDetectStop() {
                        Log.i(TAG, "[hrv] onDetectStop")
                    }
                })
                result.success(true)
            }
            "stopDetectHrv" -> {
                VPOperateManager.getInstance().stopDetectHrv(IBleWriteResponse { }, object : IHrvDetectListener {
                    override fun onHrvDetect(hrv: Int) {}
                    override fun onDetectFailed(detectState: HrvDetectState) {}
                    override fun onDetectStop() {}
                })
                result.success(true)
            }
            "startDetectPressure" -> {
                Log.i(TAG, "[startDetectPressure] Starting pressure (stress) detection...")
                VPOperateManager.getInstance().startDetectPressure(IBleWriteResponse { },
                object : IPressureDetectListener {
                    override fun onDetecting(progress: Int) {}
                    override fun onDetectSuccess(pressure: Int) {
                        Log.d(TAG, "[pressureData] stress=$pressure")
                        if (pressure > 0) {
                            sendEvent(JSONObject().apply {
                                put("type", "stress")
                                put("value", pressure)
                            })
                        }
                    }
                    override fun onDetectFailed(detectState: PressureDetectState) {
                        Log.e(TAG, "[pressure] onDetectFailed state=$detectState")
                    }
                    override fun onDetectStop() {
                        Log.i(TAG, "[pressure] onDetectStop")
                    }
                })
                result.success(true)
            }
            "stopDetectPressure" -> {
                VPOperateManager.getInstance().stopDetectPressure(IBleWriteResponse { })
                result.success(true)
            }
            "readBattery" -> {
                Log.i(TAG, "[readBattery] Reading battery level...")
                VPOperateManager.getInstance().readBattery(IBleWriteResponse { code ->
                    Log.d(TAG, "[readBattery] writeResponse code=$code")
                }, object : IBatteryDataListener {
                    override fun onDataChange(batteryData: BatteryData?) {
                        if (batteryData != null) {
                            val level = if (batteryData.isPercent) batteryData.batteryPercent else batteryData.batteryLevel
                            Log.i(TAG, "[battery] level=$level (isPercent=${batteryData.isPercent}, percent=${batteryData.batteryPercent}, levelVal=${batteryData.batteryLevel})")
                            sendEvent(JSONObject().apply {
                                put("type", "battery")
                                put("value", level)
                            })
                        }
                    }
                })
                result.success(true)
            }
            "readSleepData" -> {
                Log.i(TAG, "[readSleepData] Reading sleep metrics...")
                readSleepFromDay(0) { total, deep, light, rem, wake, quality ->
                    if (total == 0) {
                        Log.i(TAG, "[readSleepData] Today sleep is 0, checking yesterday (day 1)...")
                        readSleepFromDay(1) { t1, d1, l1, r1, w1, q1 ->
                            sendSleepEvent(t1, d1, l1, r1, w1, q1)
                        }
                    } else {
                        sendSleepEvent(total, deep, light, rem, wake, quality)
                    }
                }
                result.success(true)
            }
            "startDetectEcg" -> {
                Log.i(TAG, "[startDetectEcg] Starting ECG detection...")
                try {
                    VPOperateManager.getInstance().startDetectECG(IBleWriteResponse { code ->
                        Log.d(TAG, "[startDetectEcg] writeResponse code=$code")
                    }, true, object : IECGDetectListener {
                        override fun onEcgDetectInfoChange(info: EcgDetectInfo?) {
                            Log.d(TAG, "[ecgInfo] freq=${info?.frequency} drawFreq=${info?.drawFrequency}")
                        }

                        override fun onEcgDetectStateChange(state: EcgDetectState?) {
                            if (state != null) {
                                val progress = state.progress
                                val statusName = state.deviceState?.name ?: "UNKNOWN"
                                val hr = if (state.hr1 > 0) state.hr1 else state.hr2
                                val hrv = state.hrv
                                val isUnpassWear = state.deviceState == EDeviceStatus.UNPASS_WEAR
                                Log.d(TAG, "[ecgState] progress=$progress status=$statusName hr=$hr hrv=$hrv unpassWear=$isUnpassWear")
                                
                                sendEvent(JSONObject().apply {
                                    put("type", "ecgState")
                                    put("progress", progress)
                                    put("deviceStatus", statusName)
                                    put("unpassWear", isUnpassWear)
                                    put("hr", hr)
                                    put("hrv", hrv)
                                })
                            }
                        }

                        override fun onEcgADCChange(adc1: IntArray?, adc2: IntArray?) {
                            val array = adc1 ?: adc2
                            if (array != null && array.isNotEmpty()) {
                                val jsonArray = org.json.JSONArray()
                                for (v in array) {
                                    jsonArray.put(v)
                                }
                                sendEvent(JSONObject().apply {
                                    put("type", "ecgAdc")
                                    put("adc", jsonArray)
                                })
                            }
                        }

                        override fun onEcgDetectResultChange(resultData: EcgDetectResult?) {
                            if (resultData != null) {
                                Log.i(TAG, "[ecgResult] isSuccess=${resultData.isSuccess} aveHeart=${resultData.aveHeart} aveHrv=${resultData.aveHrv} aveQT=${resultData.aveQT} aveResRate=${resultData.aveResRate}")
                                sendEvent(JSONObject().apply {
                                    put("type", "ecgResult")
                                    put("isSuccess", resultData.isSuccess)
                                    put("aveHeart", resultData.aveHeart)
                                    put("aveHrv", resultData.aveHrv)
                                    put("aveQt", resultData.aveQT)
                                    put("aveResRate", resultData.aveResRate)
                                    put("diseaseResult", resultData.diseaseResult ?: 0)
                                })
                            }
                        }

                        override fun onEcgDetectDiagnosisChange(diag: EcgDiagnosis?) {
                            if (diag != null) {
                                Log.i(TAG, "[ecgDiagnosis] diseaseRisk=${diag.diseaseRisk} pressure=${diag.pressureIndex} fatigue=${diag.fatigueIndex} myocarditis=${diag.myocarditisRisk} chd=${diag.chdRisk}")
                                sendEvent(JSONObject().apply {
                                    put("type", "ecgDiagnosis")
                                    put("diseaseRisk", diag.diseaseRisk)
                                    put("pressureIndex", diag.pressureIndex)
                                    put("fatigueIndex", diag.fatigueIndex)
                                    put("myocarditisRisk", diag.myocarditisRisk)
                                    put("chdRisk", diag.chdRisk)
                                    put("angioscleroticRisk", diag.angioscleroticRisk)
                                })
                            }
                        }
                    })
                    result.success(true)
                } catch (e: UnsatisfiedLinkError) {
                    Log.e(TAG, "[startDetectEcg] UnsatisfiedLinkError: ${e.message}", e)
                    result.error("NATIVE_LIB_ERROR", "Failed to load libnative-lib.so: ${e.message}", null)
                } catch (e: Exception) {
                    Log.e(TAG, "[startDetectEcg] Error starting ECG: ${e.message}", e)
                    result.error("ECG_START_ERROR", e.message, null)
                }
            }
            "stopDetectEcg" -> {
                Log.i(TAG, "[stopDetectEcg] Stopping ECG detection...")
                try {
                    VPOperateManager.getInstance().stopDetectECG(IBleWriteResponse { code ->
                        Log.d(TAG, "[stopDetectEcg] writeResponse code=$code")
                    }, true, object : IECGDetectListener {
                        override fun onEcgDetectInfoChange(info: EcgDetectInfo?) {}
                        override fun onEcgDetectStateChange(state: EcgDetectState?) {}
                        override fun onEcgADCChange(adc1: IntArray?, adc2: IntArray?) {}
                        override fun onEcgDetectResultChange(resultData: EcgDetectResult?) {}
                        override fun onEcgDetectDiagnosisChange(diag: EcgDiagnosis?) {}
                    })
                    result.success(true)
                } catch (e: Throwable) {
                    Log.e(TAG, "[stopDetectEcg] Error stopping ECG: ${e.message}", e)
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun readSleepFromDay(dayNumber: Int, callback: (total: Int, deep: Int, light: Int, rem: Int, wake: Int, quality: Int) -> Unit) {
        VPOperateManager.getInstance().readSleepDataSingleDay(IBleWriteResponse { code ->
            Log.d(TAG, "[readSleepDataSingleDay] day=$dayNumber writeCode=$code")
        }, object : ISleepDataListener {
            override fun onSleepDataChange(dayStr: String?, sleepData: SleepData?) {
                if (sleepData != null) {
                    val deep = sleepData.deepSleepTime
                    val light = sleepData.lowSleepTime
                    val total = sleepData.allSleepTime
                    val wake = sleepData.wakeCount
                    val quality = sleepData.sleepQulity
                    Log.d(TAG, "[readSleepDataSingleDay] day=$dayNumber total=$total deep=$deep light=$light wake=$wake quality=$quality")
                    callback(total, deep, light, 0, wake, quality)
                } else {
                    callback(0, 0, 0, 0, 0, 0)
                }
            }
            override fun onSleepProgress(progress: Float) {}
            override fun onSleepProgressDetail(p0: String?, p1: Int) {}
            override fun onReadSleepComplete() {}
        }, dayNumber, 3)
    }

    private fun sendSleepEvent(total: Int, deep: Int, light: Int, rem: Int, wake: Int, quality: Int) {
        Log.i(TAG, "[sleepData] sendSleepEvent total=$total deep=$deep light=$light rem=$rem wake=$wake quality=$quality")
        sendEvent(JSONObject().apply {
            put("type", "sleepData")
            put("totalSleepMinutes", total)
            put("deepSleepMinutes", deep)
            put("lightSleepMinutes", light)
            put("remSleepMinutes", rem)
            put("wakeCount", wake)
            put("sleepQuality", quality)
        })
    }

    private fun sendEvent(jsonObject: JSONObject) {
        mainHandler.post {
            eventSink?.success(jsonObject.toString())
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // Setup connection listener to stream connection states
        val macToRegister = currentMac ?: run {
            Log.w(TAG, "[onListen] No MAC stored, cannot register connect status listener")
            return
        }
        Log.i(TAG, "[onListen] Registering connection status listener for MAC=$macToRegister")
        VPOperateManager.getInstance().registerConnectStatusListener(macToRegister, object : IABleConnectStatusListener() {
            override fun onConnectStatusChanged(mac: String?, status: Int) {
                Log.i(TAG, "[connectionState] mac=$mac status=$status")
                sendEvent(JSONObject().apply {
                    put("type", "connectionState")
                    put("state", status)
                })
            }
        })
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }
}
