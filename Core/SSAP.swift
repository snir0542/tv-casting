import Foundation

/// A message from the TV's control socket (ws://TV:3000), as far as we care.
enum SSAPReply: Equatable {
    case prompt                                   // the TV shows "allow this device?"
    case registered(clientKey: String)
    case response(id: String, payload: [String: String])
    case error(id: String, message: String)
}

/// LG webOS "SSAP" control protocol: JSON over a WebSocket on port 3000.
enum SSAP {
    static let openURI = "ssap://system.launcher/open"
    static let pointerURI = "ssap://com.webos.service.networkinput/getPointerInputSocket"
    /// Sent as text on the pointer socket: a click where the pointer is.
    static let clickCommand = "type:click\n\n"

    /// Relative pointer move. The pointer may rest on the TV browser's own toolbar, where a click can
    /// reload the page, so it is moved to the top-left corner and then to the screen centre first.
    static func pointerMove(dx: Int, dy: Int) -> String { "type:move\ndx:\(dx)\ndy:\(dy)\ndown:0\n\n" }
    static let pointerToCentre = [pointerMove(dx: -3000, dy: -3000), pointerMove(dx: 960, dy: 540)]

    static func register(clientKey: String?) -> String {
        var payload = (try? JSONSerialization.jsonObject(with: Data(registerPayload.utf8))) as? [String: Any] ?? [:]
        if let clientKey { payload["client-key"] = clientKey }
        return json(["type": "register", "id": "register_0", "payload": payload])
    }

    static func request(id: String, uri: String, payload: [String: String] = [:]) -> String {
        json(["type": "request", "id": id, "uri": uri, "payload": payload])
    }

    static func parse(_ text: String) -> SSAPReply? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        let id = obj["id"] as? String ?? ""
        let payload = obj["payload"] as? [String: Any] ?? [:]
        switch type {
        case "registered":
            guard let key = payload["client-key"] as? String else { return nil }
            return .registered(clientKey: key)
        case "response":
            if payload["pairingType"] as? String == "PROMPT" { return .prompt }
            return .response(id: id, payload: payload.mapValues(describe))
        case "error":
            return .error(id: id, message: obj["error"] as? String ?? "unknown error")
        default:
            return nil
        }
    }

    /// "ws://192.168.1.122:3000/resources/x/netinput.pointer.sock" -> "/resources/x/netinput.pointer.sock"
    static func pointerPath(fromSocketPath socketPath: String) -> String? {
        guard let url = URL(string: socketPath), !url.path.isEmpty else { return nil }
        return url.path
    }

    private static func describe(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return "\(value)"
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Registration payload of LG's own remote app. Taken from PyWebOSTV
    /// (https://github.com/supersaiyanmode/PyWebOSTV, MIT License), which uses the same signed manifest.
    private static let registerPayload = #"""
    {
     "forcePairing": false,
     "pairingType": "PROMPT",
     "manifest": {
      "appVersion": "1.1",
      "manifestVersion": 1,
      "permissions": [
       "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED", "CONTROL_AUDIO",
       "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING",
       "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV", "CONTROL_POWER", "READ_APP_STATUS",
       "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE", "READ_RUNNING_APPS",
       "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE", "READ_COUNTRY_INFO",
       "READ_SETTINGS", "CONTROL_TV_SCREEN", "CONTROL_TV_STANBY", "CONTROL_FAVORITE_GROUP",
       "CONTROL_USER_INFO", "CHECK_BLUETOOTH_DEVICE", "CONTROL_BLUETOOTH", "CONTROL_TIMER_INFO",
       "STB_INTERNAL_CONNECTION", "CONTROL_RECORDING", "READ_RECORDING_STATE", "WRITE_RECORDING_LIST",
       "READ_RECORDING_LIST", "READ_RECORDING_SCHEDULE", "WRITE_RECORDING_SCHEDULE",
       "READ_STORAGE_DEVICE_LIST", "READ_TV_PROGRAM_INFO", "CONTROL_BOX_CHANNEL", "READ_TV_ACR_AUTH_TOKEN",
       "READ_TV_CONTENT_STATE", "READ_TV_CURRENT_TIME", "ADD_LAUNCHER_CHANNEL", "SET_CHANNEL_SKIP",
       "RELEASE_CHANNEL_SKIP", "CONTROL_CHANNEL_BLOCK", "DELETE_SELECT_CHANNEL", "CONTROL_CHANNEL_GROUP",
       "SCAN_TV_CHANNELS", "CONTROL_TV_POWER", "CONTROL_WOL"
      ],
      "signatures": [
       {
        "signature": "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw==",
        "signatureVersion": 1
       }
      ],
      "signed": {
       "appId": "com.lge.test",
       "created": "20140509",
       "localizedAppNames": {"": "LG Remote App", "ko-KR": "리모컨 앱", "zxx-XX": "ЛГ Rэмotэ AПП"},
       "localizedVendorNames": {"": "LG Electronics"},
       "permissions": [
        "TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS",
        "READ_LGE_SDX", "READ_NOTIFICATIONS", "SEARCH", "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT",
        "CONTROL_POWER", "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS", "READ_UPDATE_INFO",
        "UPDATE_FROM_REMOTE_APP", "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME"
       ],
       "serial": "2f930e2d2cfe083771f68e4fe7bb07",
       "vendorId": "com.lge"
      }
     }
    }
    """#
}
