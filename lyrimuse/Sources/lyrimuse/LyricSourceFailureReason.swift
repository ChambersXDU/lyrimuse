import Foundation

enum LyricSourceFailureReason {
    static func text(forCode code: String) -> String {
        switch code {
        case "lyricfind_region_restricted":
            return L10n.t("YouTube Music 在这个网络所在地区不可用（地区限制，非网络故障）")
        case "musixmatch_rate_limited":
            return L10n.t("Musixmatch 拒绝了匿名 token 请求（反爬限流，hint=captcha），不是网络故障，稍后重试通常会恢复")
        case "netease_rate_limited":
            return L10n.t("网易云接口限流（短时间内请求过多，操作频繁，code 405），不是网络故障")
        case "deezer_auth_failed":

            return L10n.t("Deezer 换取匿名访问令牌失败（不是这首歌没有歌词，稍后重试通常会恢复）")
        case "musixmatch_direct_blocked":

            return L10n.t("Musixmatch 的接口地址在当前网络下直连不通（TCP/TLS 都没有响应），系统代理也不可用——开启代理后通常会恢复")

        case "dns_failed":
            return L10n.t("域名解析失败（DNS），请求根本没发出去——常见于 VPN / 公司网络接管了 DNS；浏览器能开网页不代表这里能通")
        case "connect_failed":

            return L10n.t("连接失败或超时，没有拿到任何响应")
        case "server_error":
            return L10n.t("服务器报错（HTTP 5xx），稍后重试通常会恢复")
        case "upstream_unreachable":

            return L10n.t("依赖的上游源（网易云 / QQ音乐）没连上，这一轮没法查")

        case "no_response":
            return L10n.t("两首探测曲都没有响应，这个源目前可能不可用")
        case "network_down":
            return L10n.t("网络请求全部失败（DNS/连接问题），这一轮探测本身就没跑起来")
        default:

            return code
        }
    }
}
