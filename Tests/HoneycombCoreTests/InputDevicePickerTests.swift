import CoreAudio
import Testing
@testable import HoneycombCore

struct InputDevicePickerTests {
    let builtIn = InputDevice(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone", transport: .builtIn)
    let usb = InputDevice(id: 2, uid: "usb-mic", name: "USB Mic", transport: .usb)
    let blackHole = InputDevice(id: 3, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", transport: .virtual)
    let callApps = Set(CallAppCatalog.builtIn.map(\.bundleId))

    func pick(_ uses: [InputUse]) -> InputDevice? {
        InputDevicePicker.pick(devices: [builtIn, usb, blackHole], defaultInput: builtIn.id,
                               callAppInputs: InputDevicePicker.inputsToFollow(uses, callApps: callApps))
    }

    @Test func otherRecordersNeverChooseTheMic() {
        #expect(pick([InputUse(bundleID: "com.obsproject.obs-studio", devices: [blackHole.id])]) == builtIn)
        #expect(pick([InputUse(bundleID: "com.apple.CoreSpeech", devices: [usb.id])]) == builtIn)
    }

    @Test func theCallAppsMicWinsOverOtherRecorders() {
        let uses = [
            InputUse(bundleID: "com.obsproject.obs-studio", devices: [blackHole.id]),
            InputUse(bundleID: "us.zoom.xos", devices: [usb.id]),
        ]
        #expect(pick(uses) == usb)
    }

    @Test func callAppsRecordingFromHelperProcessesAreFollowed() {
        #expect(pick([InputUse(bundleID: "com.google.Chrome.helper", devices: [usb.id])]) == usb)
        #expect(pick([InputUse(bundleID: "com.obsproject.obs-studio", devices: [blackHole.id]),
                      InputUse(bundleID: "com.apple.avconferenced", devices: [usb.id])]) == usb)
        #expect(pick([InputUse(bundleID: "com.obsproject.obs-studio", devices: [blackHole.id]),
                      InputUse(bundleID: "com.apple.WebKit.GPU", devices: [usb.id])]) == usb)
    }
}
