import Foundation

/// Gọi REST API thiết bị của TingPush (chỉ cần App ID).
struct TingPushAPI {
    let serverURL: URL
    let appId: String

    func register(_ body: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v1/apps/\(appId)/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        send(request) { result in
            completion(result.flatMap { data in
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard let id = json?["id"] as? String else {
                    return .failure(TingPushError.http(status: 200, body: String(data: data, encoding: .utf8) ?? ""))
                }
                return .success(id)
            })
        }
    }

    func unsubscribe(deviceId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v1/apps/\(appId)/devices/\(deviceId)"))
        request.httpMethod = "DELETE"
        send(request) { completion($0.map { _ in () }) }
    }

    private func send(_ request: URLRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = request
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let data = data ?? Data()
            if (200..<300).contains(status) {
                completion(.success(data))
            } else {
                completion(.failure(TingPushError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")))
            }
        }.resume()
    }
}
