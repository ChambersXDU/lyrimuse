package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	platformBark       = "bark"
	platformDingtalk   = "dingtalk"
	platformWecom      = "wecom"
	platformDiscord    = "discord"
	platformFeishu     = "feishu"
	platformServerChan = "serverchan"
)

func buildNotifyPayload(platform, title, body, feishuSecret string) (payload []byte, contentType string, err error) {
	switch platform {
	case platformDingtalk, platformWecom:

		b, err := json.Marshal(map[string]any{
			"msgtype": "text",
			"text":    map[string]string{"content": title + "\n" + body},
		})
		return b, "application/json", err
	case platformFeishu:
		content := map[string]any{
			"msg_type": "text",
			"content":  map[string]string{"text": title + "\n" + body},
		}
		if feishuSecret != "" {
			content["timestamp"] = feishuTimestamp()
			content["sign"] = feishuSign(content["timestamp"].(string), feishuSecret)
		}
		b, err := json.Marshal(content)
		return b, "application/json", err
	case platformDiscord:

		b, err := json.Marshal(map[string]any{
			"content": "**" + title + "**\n" + body,
		})
		return b, "application/json", err
	case platformServerChan:

		form := url.Values{"title": {title}, "desp": {body}}
		return []byte(form.Encode()), "application/x-www-form-urlencoded", nil
	default:
		b, err := json.Marshal(map[string]any{
			"title": title, "body": body, "group": "nowplaying", "level": "active",
		})
		return b, "application/json", err
	}
}

func dingtalkSignedURL(rawURL, secret string) string {
	if secret == "" {
		return rawURL
	}
	ts := strconv.FormatInt(time.Now().UnixMilli(), 10)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(ts + "\n" + secret))
	sign := base64.StdEncoding.EncodeToString(mac.Sum(nil))
	sep := "?"
	if strings.Contains(rawURL, "?") {
		sep = "&"
	}
	return rawURL + sep + "timestamp=" + ts + "&sign=" + url.QueryEscape(sign)
}

func feishuTimestamp() string {
	return strconv.FormatInt(time.Now().Unix(), 10)
}

func feishuSign(timestamp, secret string) string {
	mac := hmac.New(sha256.New, []byte(timestamp+"\n"+secret))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}
