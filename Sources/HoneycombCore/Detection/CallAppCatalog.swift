/// Apps whose mic use means a call. Browsers need a second check (the tab title), because
/// a browser also uses the mic for dictation and voice chat.
public enum CallAppCatalog {
    public static let builtIn: [CallApp] = [
        CallApp(bundleId: "us.zoom.xos", name: "Zoom", kind: .app),
        CallApp(bundleId: "com.microsoft.teams2", name: "Teams", kind: .app),
        CallApp(bundleId: "com.microsoft.teams", name: "Teams", kind: .app),
        CallApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", kind: .app),
        CallApp(bundleId: "com.apple.FaceTime", name: "FaceTime", kind: .app),
        CallApp(bundleId: "Cisco-Systems.Spark", name: "Webex", kind: .app),
        CallApp(bundleId: "com.cisco.webexmeetingsapp", name: "Webex", kind: .app),
        CallApp(bundleId: "com.hnc.Discord", name: "Discord", kind: .app),
        CallApp(bundleId: "net.whatsapp.WhatsApp", name: "WhatsApp", kind: .app),
        CallApp(bundleId: "com.google.Chrome", name: "Chrome", kind: .browser),
        CallApp(bundleId: "company.thebrowser.Browser", name: "Arc", kind: .browser),
        CallApp(bundleId: "com.apple.Safari", name: "Safari", kind: .browser),
        CallApp(bundleId: "com.microsoft.edgemac", name: "Edge", kind: .browser),
        CallApp(bundleId: "com.brave.Browser", name: "Brave", kind: .browser),
        CallApp(bundleId: "org.mozilla.firefox", name: "Firefox", kind: .browser),
    ]
}
