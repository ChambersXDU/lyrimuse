package main

import (
	"bytes"
	"context"
	_ "image/jpeg"
	_ "image/png"
	"log"
	"net/http"
	"time"
)

type alerter struct {
	platform       string
	url            string
	dingtalkSecret string
	feishuSecret   string
}

func newAlerter(platform, url, dingtalkSecret, feishuSecret string) *alerter {
	return &alerter{
		platform: platform, url: url,
		dingtalkSecret: dingtalkSecret, feishuSecret: feishuSecret,
	}
}

func (a *alerter) push(title, body string) {
	payload, contentType, err := buildNotifyPayload(a.platform, title, body, a.feishuSecret)
	if err != nil {
		return
	}
	target := a.url
	if a.platform == platformDingtalk {
		target = dingtalkSignedURL(a.url, a.dingtalkSecret)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", contentType)
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		log.Printf("notify push failed (platform=%s): %v", a.platform, err)
		return
	}
	resp.Body.Close()
}
