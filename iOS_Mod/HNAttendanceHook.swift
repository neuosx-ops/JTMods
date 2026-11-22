//
//  HNAttendanceHook.swift
//  Runner - Automatic Attendance (Chấm công tự động với ảnh có sẵn)
//

import UIKit
import PhotosUI

@objc(HNAttendanceHook)
public class HNAttendanceHook: NSObject {

    public static var facePhotoPath: String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        return (docs as NSString).appendingPathComponent("face_attendance.jpg")
    }

    @objc public static func saveFacePhoto(_ image: UIImage) {
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: URL(fileURLWithPath: facePhotoPath))
        }
    }

    @objc public static func performAutomaticClock(clockType: Int, completion: @escaping (Bool, String) -> Void) {
        let workflow = HNCompactWorkflow.shared
        let token = workflow.currentAuthToken
        let headers = workflow.capturedJtHeaders

        guard !token.isEmpty else {
            completion(false, "Chưa bắt được authToken. Vui lòng mở tab cá nhân trên app trước.")
            return
        }

        let staffNo = headers["staffNo"] ?? "01857162"
        let userId = headers["userId"] ?? "10750293"

        let lat = String(format: "%.6f", HNLocationHook.savedLatitude != 0 ? HNLocationHook.savedLatitude : 11.735085)
        let lng = String(format: "%.6f", HNLocationHook.savedLongitude != 0 ? HNLocationHook.savedLongitude : 108.361265)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let clockTime = formatter.string(from: Date())

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: facePhotoPath),
           let faceImageData = try? Data(contentsOf: URL(fileURLWithPath: facePhotoPath)),
           let faceImage = UIImage(data: faceImageData) {
            uploadAndClock(image: faceImage, clockType: clockType, clockTime: clockTime, lat: lat, lng: lng, token: token, staffNo: staffNo, userId: userId, completion: completion)
        } else {
            pushClock(faceUrl: "osb180low365del/yl-web-jmsvn-app-bc/ls/20261122/ZUI3zWrRxC_flipped_1795352320540_compressed_1795352320647.jpg", clockType: clockType, clockTime: clockTime, lat: lat, lng: lng, token: token, staffNo: staffNo, userId: userId, completion: completion)
        }
    }

    private static func uploadAndClock(image: UIImage, clockType: Int, clockTime: String, lat: String, lng: String, token: String, staffNo: String, userId: String, completion: @escaping (Bool, String) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            pushClock(faceUrl: "osb180low365del/yl-web-jmsvn-app-bc/ls/20261122/ZUI3zWrRxC_flipped_1795352320540_compressed_1795352320647.jpg", clockType: clockType, clockTime: clockTime, lat: lat, lng: lng, token: token, staffNo: staffNo, userId: userId, completion: completion)
            return
        }

        let fileName = "face_\(Int(Date().timeIntervalSince1970)).jpg"

        guard let ossUrl = URL(string: "https://bc.jtexpress.vn/bc/oss/common/getUploadOssUrl") else {
            completion(false, "URL getUploadOssUrl không hợp lệ")
            return
        }

        var req = URLRequest(url: ossUrl)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "authToken")
        req.setValue(staffNo, forHTTPHeaderField: "staffNo")
        req.setValue(userId, forHTTPHeaderField: "userId")

        let body: [String: Any] = [
            "moduleName": "ls",
            "scanType": 10,
            "fileNameList": [fileName]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]],
                  let first = dataArr.first,
                  let uploadUrlStr = first["ossUploadUrl"] as? String,
                  let ossPath = first["ossPath"] as? String,
                  let uploadUrl = URL(string: uploadUrlStr) else {
                pushClock(faceUrl: "osb180low365del/yl-web-jmsvn-app-bc/ls/20261122/ZUI3zWrRxC_flipped_1795352320540_compressed_1795352320647.jpg", clockType: clockType, clockTime: clockTime, lat: lat, lng: lng, token: token, staffNo: staffNo, userId: userId, completion: completion)
                return
            }

            var putReq = URLRequest(url: uploadUrl)
            putReq.httpMethod = "PUT"
            putReq.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            putReq.httpBody = imageData

            URLSession.shared.dataTask(with: putReq) { _, res, _ in
                let httpRes = res as? HTTPURLResponse
                guard httpRes?.statusCode == 200 else {
                    pushClock(faceUrl: ossPath, clockType: clockType, clockTime: clockTime, lat: lat, lng: lng, token: token, staffNo: staffNo, userId: userId, completion: completion)
                    return
                }

                guard let detectUrl = URL(string: "https://bc.jtexpress.vn/bc/attendanceClock/faceDetection") else {
                    pushClock(faceUrl: ossPath, clockType: clockType, clockTime: clockTime, lat: lat, lng: lng, token: token, staffNo: staffNo, userId: userId, completion: completion)
                    return
                }

                var detReq = URLRequest(url: detectUrl)
                detReq.httpMethod = "POST"
                detReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                detReq.setValue(token, forHTTPHeaderField: "authToken")
                detReq.setValue(staffNo, forHTTPHeaderField: "staffNo")
                detReq.setValue(userId, forHTTPHeaderField: "userId")
                detReq.httpBody = try? JSONSerialization.data(withJSONObject: ["url": ossPath])

                URLSession.shared.dataTask(with: detReq) { _, _, _ in
                    pushClock(faceUrl: ossPath, clockType: clockType, clockTime: clockTime, lat: lat, lng: lng, token: token, staffNo: staffNo, userId: userId, completion: completion)
                }.resume()
            }.resume()
        }.resume()
    }

    private static func pushClock(faceUrl: String, clockType: Int, clockTime: String, lat: String, lng: String, token: String, staffNo: String, userId: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "https://bc.jtexpress.vn/bc/attendanceClock/push") else {
            completion(false, "URL không hợp lệ")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "authToken")
        request.setValue(staffNo, forHTTPHeaderField: "staffNo")
        request.setValue(userId, forHTTPHeaderField: "userId")
        request.setValue("iOS_com.jtexpress.vietnam.outfield.VDFUY8YFL8", forHTTPHeaderField: "App-Platform")
        request.setValue("3.0.355", forHTTPHeaderField: "App-Version")
        request.setValue("e452tmruz507", forHTTPHeaderField: "appid")
        request.setValue("ios", forHTTPHeaderField: "devicefrom")
        request.setValue("VN", forHTTPHeaderField: "langType")

        let payload: [String: Any] = [
            "clockType": clockType,
            "facePass": 1,
            "clockTime": clockTime,
            "longitude": lng,
            "latitude": lat,
            "faceUrl": faceUrl
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(false, "Lỗi mã hóa JSON payload")
            return
        }
        request.httpBody = httpBody

        let tagged = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: "HNInternalStatusCheck", in: tagged)

        URLSession.shared.dataTask(with: tagged as URLRequest) { data, _, error in
            if let error = error {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(false, "Phản hồi server không hợp lệ") }
                return
            }

            let msg = (json["msg"] as? String) ?? "Thành công"
            let code = json["code"] as? Int ?? 0
            let succ = (code == 1) || ((json["succ"] as? Bool) == true)

            DispatchQueue.main.async {
                completion(succ, msg)
            }
        }.resume()
    }
}
