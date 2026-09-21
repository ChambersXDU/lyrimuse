import Foundation

enum LyricSourceFailureReason {
    static func text(forCode code: String) -> String {
        switch code {
        case "dns_failed":
            return L10n.t("域名解析失败（DNS），请求根本没发出去——常见于 VPN / 公司网络接管了 DNS；浏览器能开网页不代表这里能通")
        case "connect_failed":

            return L10n.t("连接失败或超时，没有拿到任何响应")
        case "server_error":
            return L10n.t("服务器报错（HTTP 5xx），稍后重试通常会恢复")
        case "upstream_unreachable":
            return L10n.t("歌词源没有连上，这一轮没法查询")

        case "no_response":
            return L10n.t("两首探测曲都没有响应，这个源目前可能不可用")
        case "network_down":
            return L10n.t("网络请求全部失败（DNS/连接问题），这一轮探测本身就没跑起来")
        default:

            return code
        }
    }
}
