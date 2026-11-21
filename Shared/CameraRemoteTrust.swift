import Foundation
import Security

final class CameraRemoteTrust: NSObject, URLSessionDelegate {
    private let lock = NSLock()
    private var pinned: String?
    private var observed: String?

    init(fingerprint: String?) { pinned = fingerprint }

    var fingerprint: String? { lock.lock(); defer { lock.unlock() }; return observed }

    func pin(_ value: String) { lock.lock(); pinned = value; lock.unlock() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else { completionHandler(.performDefaultHandling, nil); return }
        let value = CameraRemoteCoding.fingerprint(SecCertificateCopyData(certificate) as Data)
        lock.lock()
        let allowed = pinned == nil || pinned == value
        if allowed { observed = value }
        lock.unlock()
        completionHandler(allowed ? .useCredential : .cancelAuthenticationChallenge, allowed ? URLCredential(trust: trust) : nil)
    }
}
