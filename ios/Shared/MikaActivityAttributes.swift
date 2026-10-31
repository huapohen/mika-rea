import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct MikaActivityAttributes:ActivityAttributes {
    struct ContentState:Codable,Hashable {
        var phase:String
        var headline:String
        var detail:String
        var canStop:Bool
        var updatedAt:Date
    }
    var operationID:String
    var target:String
}
