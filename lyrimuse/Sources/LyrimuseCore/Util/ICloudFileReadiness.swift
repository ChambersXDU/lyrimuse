import Foundation

public enum ICloudFileReadiness {

    public static func isReadyToRead(
        downloadingStatus: URLUbiquitousItemDownloadingStatus?,
        realPathExists: Bool
    ) -> Bool {
        if let downloadingStatus { return downloadingStatus == .current }
        return realPathExists
    }
}
