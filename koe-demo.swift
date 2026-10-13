import Foundation
DistributedNotificationCenter.default().postNotificationName(Notification.Name("org.arasaki.koe.demo"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
