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
import com.veepoo.protocol.model.settings.*
import com.veepoo.protocol.model.enums.*
import com.veepoo.protocol.util.VPLogger
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
    private var currentConnectStatusListener: IABleConnectStatusListener? = null
    private var isHeartDetecting = false
    private var heartRetryRunnable: Runnable? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        VPLogger.setDebug(false) // Disable verbose internal Bluetooth logging spam
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
                
                // Ensure scanning is stopped prior to GATT connection to prevent status 133 errors
                try {
                    VPOperateManager.getInstance().stopScanDevice()
                } catch (e: Exception) {
                    Log.w(TAG, "[connect] Error stopping scan before connect: ${e.message}")
                }
                
                // Unregister any previous connect status listener to avoid duplicate callbacks
                currentConnectStatusListener?.let { listener ->
                    try {
                        VPOperateManager.getInstance().unregisterConnectStatusListener(mac, listener)
                    } catch (_: Exception) {}
                }

                // Register connection status listener immediately to avoid missing callbacks
                val listener = object : IABleConnectStatusListener() {
                    override fun onConnectStatusChanged(mac: String?, status: Int) {
                        Log.i(TAG, "[connectionState] mac=$mac status=$status")
                        sendEvent(JSONObject().apply {
                            put("type", "connectionState")
                            put("state", status)
                        })
                    }
                }
                currentConnectStatusListener = listener
                VPOperateManager.getInstance().registerConnectStatusListener(mac, listener)

                val isReplied = java.util.concurrent.atomic.AtomicBoolean(false)
                VPOperateManager.getInstance().connectDevice(mac, { code, profile, isOadModel ->
                    Log.i(TAG, "[connect] connectDevice result code=$code")
                    if (isReplied.compareAndSet(false, true)) {
                        if (code == Code.REQUEST_SUCCESS) {
                            mainHandler.post { result.success(true) }
                        } else {
                            Log.e(TAG, "[connect] Connection FAILED with code=$code")
                            mainHandler.post { result.success(false) }
                        }
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
                try {
                    VPOperateManager.getInstance().stopScanDevice()
                } catch (_: Exception) {}

                VPOperateManager.getInstance().startScanDevice(object : com.inuker.bluetooth.library.search.response.SearchResponse {
                    override fun onSearchStarted() {}
                    override fun onDeviceFounded(device: com.inuker.bluetooth.library.search.SearchResult?) {
                        if (device != null) {
                            val address = device.address ?: ""
                            if (address.isNotEmpty()) {
                                val name = when {
                                    !device.name.isNullOrEmpty() && device.name != "NULL" -> device.name
                                    device.device != null && !device.device.name.isNullOrEmpty() && device.device.name != "NULL" -> device.device.name
                                    else -> "Unknown Device"
                                }
                                sendEvent(JSONObject().apply {
                                    put("type", "scanResult")
                                    put("mac", address)
                                    put("name", name)
                                    })
                            }
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
                val isReplied = java.util.concurrent.atomic.AtomicBoolean(false)
                try {
                    currentMac?.let { mac ->
                        currentConnectStatusListener?.let { listener ->
                            VPOperateManager.getInstance().unregisterConnectStatusListener(mac, listener)
                        }
                    }
                } catch (_: Exception) {}
                currentConnectStatusListener = null

                VPOperateManager.getInstance().disconnectWatch(IBleWriteResponse {
                    if (isReplied.compareAndSet(false, true)) {
                        mainHandler.post { result.success(true) }
                    }
                })
            }
            "confirmDevicePwd" -> {
                val pwd = call.argument<String>("pwd") ?: "0000"
                Log.i(TAG, "[confirmDevicePwd] Sending password confirmation with isScienceSleep=true...")
                val isReplied = java.util.concurrent.atomic.AtomicBoolean(false)
                VPOperateManager.getInstance().confirmDevicePwd(IBleWriteResponse { }, 
                object : IPwdDataListener {
                    override fun onPwdDataChange(pwdData: PwdData?) {
                        val status = pwdData?.getmStatus()
                        val success = status == EPwdStatus.CHECK_AND_TIME_SUCCESS
                        Log.i(TAG, "[confirmDevicePwd] onPwdDataChange status=$status success=$success")
                        if (isReplied.compareAndSet(false, true)) {
                            mainHandler.post { result.success(success) }
                        }
                    }
                    override fun onConnectionConfirmTimeout() {
                        Log.e(TAG, "[confirmDevicePwd] TIMEOUT - no response from device")
                        if (isReplied.compareAndSet(false, true)) {
                            mainHandler.post { result.success(false) }
                        }
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
                }, pwd, true)
            }
            "enableAutoDetectSettings" -> {
                Log.i(TAG, "[enableAutoDetectSettings] Enabling 24/7 background SpO2, Respiration, Heart, BP, Temp & Stress monitoring...")
                
                // 1. SpO2 & Respiration Auto Detect (All day / Night)
                try {
                    val setting = AllSetSetting(EAllSetType.SPO2H_NIGHT_AUTO_DETECT, 0, 0, 23, 59, 1, 1)
                    VPOperateManager.getInstance().settingSpo2hAutoDetect(IBleWriteResponse { code ->
                        Log.d(TAG, "[settingSpo2hAutoDetect] writeResponse code=$code")
                    }, object : IAllSetDataListener {
                        override fun onAllSetDataChangeListener(data: AllSetData?) {
                            Log.i(TAG, "[settingSpo2hAutoDetect] onAllSetDataChangeListener result=${data?.oprateResult} oprate=${data?.oprate}")
                        }
                    }, setting)
                } catch (e: Exception) {
                    Log.e(TAG, "[settingSpo2hAutoDetect] Error: ${e.message}")
                }

                // 2. Custom Settings for Auto Detect (Heart, BP, Temp, HRV, Stress, SpO2)
                try {
                    val customSetting = CustomSetting(true, true, true, true, true).apply {
                        setOpenAutoHeartDetect(true)
                        setOpenAutoBpDetect(true)
                        setIsOpenSpo2hLowRemind(EFunctionStatus.SUPPORT_OPEN)
                        setIsOpenAutoHRV(EFunctionStatus.SUPPORT_OPEN)
                        setIsOpenAutoTemperatureDetect(EFunctionStatus.SUPPORT_OPEN)
                        setStressDetect(EFunctionStatus.SUPPORT_OPEN)
                        temperatureUnit = ETemperatureUnit.CELSIUS
                        bloodGlucoseUnit = EBloodGlucoseUnit.mmol_L
                        uricAcidUnit = EUricAcidUnit.umol_L
                        bloodFatUnit = EBloodFatUnit.mmol_L
                    }
                    VPOperateManager.getInstance().changeCustomSetting(IBleWriteResponse { code ->
                        Log.d(TAG, "[changeCustomSetting] writeResponse code=$code")
                    }, object : ICustomSettingDataListener {
                        override fun OnSettingDataChange(customSettingData: CustomSettingData?) {
                            Log.i(TAG, "[changeCustomSetting] OnSettingDataChange data=$customSettingData")
                        }
                    }, customSetting)
                } catch (e: Exception) {
                    Log.e(TAG, "[changeCustomSetting] Error: ${e.message}")
                }

                result.success(true)
            }
            "syncPersonInfo" -> {
                val sex = if (call.argument<Int>("sex") == 1) ESex.MAN else ESex.WOMEN
                val height = call.argument<Int>("height") ?: 170
                val weight = call.argument<Int>("weight") ?: 60
                val age = call.argument<Int>("age") ?: 25
                val targetStep = call.argument<Int>("targetStep") ?: 8000
                Log.i(TAG, "[syncPersonInfo] sex=$sex height=$height weight=$weight age=$age steps=$targetStep")
                val isReplied = java.util.concurrent.atomic.AtomicBoolean(false)
                VPOperateManager.getInstance().syncPersonInfo(IBleWriteResponse { }, object : IPersonInfoDataListener {
                    override fun OnPersoninfoDataChange(status: EOprateStauts?) {
                        Log.i(TAG, "[syncPersonInfo] result status=$status")
                        if (isReplied.compareAndSet(false, true)) {
                            mainHandler.post { result.success(status == EOprateStauts.OPRATE_SUCCESS) }
                        }
                    }
                }, PersonInfoData(sex, height, weight, age, targetStep))
            }
            "startDetectHeart" -> {
                Log.i(TAG, "[startDetectHeart] Starting heart rate detection...")
                isHeartDetecting = true
                startHeartDetectionWithRetry()
                result.success(true)
            }
            "stopDetectHeart" -> {
                isHeartDetecting = false
                heartRetryRunnable?.let { mainHandler.removeCallbacks(it) }
                VPOperateManager.getInstance().stopDetectHeart(IBleWriteResponse { })
                result.success(true)
            }
            "startDetectSPO2" -> {
                Log.i(TAG, "[startDetectSPO2] Starting SpO2 & Respiration detection...")
                VPOperateManager.getInstance().startDetectSPO2H(IBleWriteResponse { },
                object : ISpo2hDataListener {
                    override fun onSpO2HADataChange(spo2Data: Spo2hData?) {
                        Log.d(TAG, "[spo2] state=${spo2Data?.spState} deviceState=${spo2Data?.deviceState} value=${spo2Data?.value} rate=${spo2Data?.rateValue}")
                        if (spo2Data != null) {
                            if (spo2Data.value > 0) {
                                sendEvent(JSONObject().apply {
                                    put("type", "spo2")
                                    put("value", spo2Data.value)
                                })
                            }
                            if (spo2Data.rateValue > 0) {
                                sendEvent(JSONObject().apply {
                                    put("type", "respiratoryRate")
                                    put("value", spo2Data.rateValue)
                                })
                            }
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
            "startDetectBreath" -> {
                Log.i(TAG, "[startDetectBreath] Starting breath detection...")
                VPOperateManager.getInstance().startDetectBreath(IBleWriteResponse { },
                object : IBreathDataListener {
                    override fun onDataChange(breathData: BreathData?) {
                        val value = breathData?.value ?: 0
                        Log.d(TAG, "[breathData] progress=${breathData?.progressValue} value=$value")
                        if (breathData != null && value > 0) {
                            sendEvent(JSONObject().apply {
                                put("type", "respiratoryRate")
                                put("value", value)
                            })
                        }
                    }
                })
                result.success(true)
            }
            "stopDetectBreath" -> {
                Log.i(TAG, "[stopDetectBreath] Stopping breath detection...")
                VPOperateManager.getInstance().stopDetectBreath(IBleWriteResponse { },
                object : IBreathDataListener {
                    override fun onDataChange(breathData: BreathData?) {}
                })
                result.success(true)
            }
            "startDetectBP" -> {
                Log.i(TAG, "[startDetectBP] Starting blood pressure detection...")
                VPOperateManager.getInstance().startDetectBP(IBleWriteResponse { },
                object : IBPDetectDataListener {
                    override fun onDataChange(bpData: BpData?) {
                        val status = bpData?.status
                        val high = bpData?.highPressure ?: 0
                        val low = bpData?.lowPressure ?: 0
                        val progress = bpData?.progress ?: 0
                        Log.d(TAG, "[bloodPressure] status=$status progress=$progress high=$high low=$low")
                        if (bpData != null && progress >= 100) {
                            // Veepoo SDK valid systolic range [60-300], diastolic range [20-200]
                            if (high >= 60 && low >= 20) {
                                sendEvent(JSONObject().apply {
                                    put("type", "bloodPressure")
                                    put("sys", high)
                                    put("dia", low)
                                })
                            } else {
                                Log.w(TAG, "[bloodPressure] Reading $high/$low discarded (inconclusive measurement, not a wear error)")
                            }
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
            "readSpo2hOrigin" -> {
                val day = call.argument<Int>("day") ?: 0
                readSpo2hOriginFromDay(day) { latestSpo2, latestRr ->
                    if (latestSpo2 == 0 && latestRr == 0 && day == 0) {
                        readSpo2hOriginFromDay(1) { ySpo2, yRr ->
                            sendSpo2hOriginEvents(ySpo2, yRr)
                        }
                    } else {
                        sendSpo2hOriginEvents(latestSpo2, latestRr)
                    }
                }
                result.success(true)
            }
            "readOriginData" -> {
                val day = call.argument<Int>("day") ?: 0
                readOriginDataFromDay(day)
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

    private fun startHeartDetectionWithRetry() {
        heartRetryRunnable?.let { mainHandler.removeCallbacks(it) }
        VPOperateManager.getInstance().startDetectHeart(IBleWriteResponse { },
            object : IHeartDataListener {
                override fun onDataChange(heartData: HeartData?) {
                    if (heartData != null) {
                        val status = heartData.heartStatus
                        val value = heartData.data
                        Log.d(TAG, "[heartRate] status=$status value=$value")
                        if (value > 20) {
                            sendEvent(JSONObject().apply {
                                put("type", "heartRate")
                                put("value", value)
                            })
                        } else if (status == EHeartStatus.STATE_HEART_WEAR_ERROR && isHeartDetecting) {
                            Log.i(TAG, "[heartRate] Sensor reported STATE_HEART_WEAR_ERROR during active detection; resetting & retrying...")
                            val r = Runnable {
                                if (isHeartDetecting) {
                                    try {
                                        VPOperateManager.getInstance().stopDetectHeart(IBleWriteResponse { })
                                    } catch (_: Exception) {}
                                    mainHandler.postDelayed({
                                        if (isHeartDetecting) {
                                            startHeartDetectionWithRetry()
                                        }
                                    }, 400)
                                }
                            }
                            heartRetryRunnable = r
                            mainHandler.postDelayed(r, 1000)
                        }
                    }
                }
            })
    }

    private fun readSpo2hOriginFromDay(dayNumber: Int, callback: (latestSpo2: Int, latestRr: Int) -> Unit) {
        var latestSpo2 = 0
        var latestRr = 0
        VPOperateManager.getInstance().readSpo2hOrigin(IBleWriteResponse { code ->
            if (code != 0) Log.d(TAG, "[readSpo2hOrigin] day=$dayNumber writeCode=$code")
        }, object : ISpo2hOriginDataListener {
            override fun onReadOriginProgress(progress: Float) {}
            override fun onReadOriginProgressDetail(p0: Int, p1: String?, p2: Int, p3: Int) {}
            override fun onSpo2hOriginListener(data: Spo2hOriginData?) {
                if (data != null) {
                    val oxy = data.oxygenValue
                    val rr = data.respirationRate
                    if (oxy > 0) latestSpo2 = oxy
                    if (rr > 0) latestRr = rr
                }
            }
            override fun onReadOriginComplete() {
                if (latestSpo2 > 0 || latestRr > 0) {
                    Log.i(TAG, "[readSpo2hOrigin] Loaded day=$dayNumber spo2=$latestSpo2 rr=$latestRr")
                }
                callback(latestSpo2, latestRr)
            }
        }, dayNumber)
    }

    private fun readOriginDataFromDay(dayNumber: Int) {
        val readAllDays = dayNumber < 0
        Log.i(TAG, "[readOriginData] Reading 5-minute historical origin data from band (allDays=$readAllDays, day=$dayNumber)...")
        val listener = object : IOriginData3Listener, IOriginDataListener {
            override fun onOriginFiveMinuteListDataChange(originList: List<OriginData3>?) {
                if (originList.isNullOrEmpty()) return
                Log.i(TAG, "[readOriginData] Received ${originList.size} 5-minute OriginData3 items from band")
                val recordsArray = org.json.JSONArray()
                for (item in originList) {
                    val mTime = item.getmTime()
                    val cal = mTime?.toCalendar()
                    val timestamp = cal?.timeInMillis ?: ((mTime?.timestampSeconds?.toLong() ?: 0L) * 1000L)
                    if (timestamp <= 0L) continue

                    // Extract SpO2 & RR from array if available
                    var spo2 = 0
                    val oxyArray = item.oxygens
                    if (oxyArray != null) {
                        for (ox in oxyArray) {
                            if (ox in 51..100) {
                                spo2 = ox
                                break
                            }
                        }
                    }

                    var rr = 0
                    val rrArray = item.resRates
                    if (rrArray != null) {
                        for (r in rrArray) {
                            if (r in 5..60) {
                                rr = r
                                break
                            }
                        }
                    }

                    // For OriginData3, heart rate can be in ppgs array or ecgs array or rateValue
                    var hr = item.rateValue
                    if (hr <= 0 && item.ppgs != null) {
                        for (p in item.ppgs) {
                            if (p in 30..220) {
                                hr = p
                                break
                            }
                        }
                    }
                    if (hr <= 0 && item.ecgs != null) {
                        for (e in item.ecgs) {
                            if (e in 30..220) {
                                hr = e
                                break
                            }
                        }
                    }

                    val sys = item.highValue
                    val dia = item.lowValue
                    val temp = item.temperature
                    val tempSkin = item.baseTemperature
                    val steps = item.stepValue
                    val cals = item.calValue
                    val dis = item.disValue
                    val stress = item.pressure

                    // Guard: skip entries where all vitals are zero
                    if (hr == 0 && sys == 0 && temp <= 0f && steps == 0 && spo2 == 0) continue

                    val obj = JSONObject().apply {
                        put("timestamp", timestamp)
                        put("hr", hr)
                        put("bpSys", sys)
                        put("bpDia", dia)
                        put("tempC", temp.toDouble())
                        put("tempSkin", tempSkin.toDouble())
                        put("steps", steps)
                        put("calories", cals)
                        put("distanceKm", dis)
                        put("stress", stress)
                        put("spo2", spo2)
                        put("respirationRate", rr)
                    }
                    recordsArray.put(obj)
                }

                if (recordsArray.length() > 0) {
                    sendEvent(JSONObject().apply {
                        put("type", "originVitalsHistory")
                        put("records", recordsArray)
                    })
                }
            }

            override fun onOringinFiveMinuteDataChange(item: OriginData?) {
                if (item == null) return
                val mTime = item.getmTime()
                val cal = mTime?.toCalendar()
                val timestamp = cal?.timeInMillis ?: ((mTime?.timestampSeconds?.toLong() ?: 0L) * 1000L)
                if (timestamp <= 0L) return

                val hr = item.rateValue
                val sys = item.highValue
                val dia = item.lowValue
                val temp = item.temperature
                val tempSkin = item.baseTemperature
                val steps = item.stepValue
                val cals = item.calValue
                val dis = item.disValue

                if (hr == 0 && sys == 0 && temp <= 0f && steps == 0) return

                val recordsArray = org.json.JSONArray()
                val obj = JSONObject().apply {
                    put("timestamp", timestamp)
                    put("hr", hr)
                    put("bpSys", sys)
                    put("bpDia", dia)
                    put("tempC", temp.toDouble())
                    put("tempSkin", tempSkin.toDouble())
                    put("steps", steps)
                    put("calories", cals)
                    put("distanceKm", dis)
                    put("stress", 0)
                    put("spo2", 0)
                    put("respirationRate", 0)
                }
                recordsArray.put(obj)

                sendEvent(JSONObject().apply {
                    put("type", "originVitalsHistory")
                    put("records", recordsArray)
                })
            }

            override fun onOriginHalfHourDataChange(halfHourData: OriginHalfHourData?) {}

            override fun onOringinHalfHourDataChange(originHalfHourData: OriginHalfHourData?) {}

            override fun onOriginHRVOriginListDataChange(hrvList: List<HRVOriginData>?) {
                if (hrvList.isNullOrEmpty()) return
                Log.i(TAG, "[readOriginData] Received ${hrvList.size} HRVOriginData items")
                val recordsArray = org.json.JSONArray()
                for (item in hrvList) {
                    val cal = item.getmTime()?.toCalendar()
                    val timestamp = cal?.timeInMillis ?: 0L
                    if (timestamp <= 0L || item.hrvValue <= 0) continue
                    recordsArray.put(JSONObject().apply {
                        put("timestamp", timestamp)
                        put("hrv", item.hrvValue)
                    })
                }
                if (recordsArray.length() > 0) {
                    sendEvent(JSONObject().apply {
                        put("type", "originHrvHistory")
                        put("records", recordsArray)
                    })
                }
            }

            override fun onOriginSpo2OriginListDataChange(spo2List: List<Spo2hOriginData>?) {
                if (spo2List.isNullOrEmpty()) return
                Log.i(TAG, "[readOriginData] Received ${spo2List.size} Spo2hOriginData items")
                val recordsArray = org.json.JSONArray()
                for (item in spo2List) {
                    val cal = item.getmTime()?.toCalendar()
                    val timestamp = cal?.timeInMillis ?: 0L
                    if (timestamp <= 0L) continue
                    recordsArray.put(JSONObject().apply {
                        put("timestamp", timestamp)
                        put("spo2", item.oxygenValue)
                        put("respirationRate", item.respirationRate)
                        put("hr", item.heartValue)
                    })
                }
                if (recordsArray.length() > 0) {
                    sendEvent(JSONObject().apply {
                        put("type", "originSpo2History")
                        put("records", recordsArray)
                    })
                }
            }

            override fun onReadOriginProgress(progress: Float) {
                Log.d(TAG, "[readOriginData] progress=$progress")
            }

            override fun onReadOriginProgressDetail(day: Int, date: String?, current: Int, total: Int) {
                Log.d(TAG, "[readOriginData] day=$day date=$date current=$current total=$total")
            }

            override fun onReadOriginComplete() {
                Log.i(TAG, "[readOriginData] Completed reading historical data from band")
                sendEvent(JSONObject().apply {
                    put("type", "originDataComplete")
                    put("day", dayNumber)
                })
            }
        }

        val writeResp = IBleWriteResponse { code ->
            Log.d(TAG, "[readOriginData] writeCode=$code")
        }

        if (readAllDays) {
            VPOperateManager.getInstance().readOriginData(writeResp, listener, 3)
        } else {
            VPOperateManager.getInstance().readOriginDataSingleDay(writeResp, listener, dayNumber, 1, 3)
        }
    }

    private fun sendSpo2hOriginEvents(spo2: Int, rr: Int) {
        if (spo2 > 0) {
            sendEvent(JSONObject().apply {
                put("type", "spo2")
                put("value", spo2)
            })
        }
        if (rr > 0) {
            sendEvent(JSONObject().apply {
                put("type", "respiratoryRate")
                put("value", rr)
            })
        }
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
