package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

const dailyDigestCheckInterval = 30 * time.Minute

const dailyDigestTriggerHour = 22

type dailyDigestState struct{ path string }

func (s dailyDigestState) load() string {
	if s.path == "" {
		return ""
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return ""
	}
	var v struct {
		LastDate string `json:"last_date"`
	}
	json.Unmarshal(b, &v)
	return v.LastDate
}

func (s dailyDigestState) save(date string) {
	if s.path == "" {
		return
	}
	data, err := json.Marshal(struct {
		LastDate string `json:"last_date"`
	}{date})
	if err != nil {
		return
	}
	os.WriteFile(s.path, data, 0o644)
}

var dailyDigestPath string

func (p *poller) dailyDigest(now time.Time) {
	if !features.DailyDigest || p.lb.alerter == nil || p.lb.alerter.url == "" {
		return
	}
	if !p.dailyLastCheckedAt.IsZero() && now.Sub(p.dailyLastCheckedAt) < dailyDigestCheckInterval {
		return
	}
	p.dailyLastCheckedAt = now

	if now.Hour() < dailyDigestTriggerHour {
		return
	}
	today := now.Format("2006-01-02")
	if today == p.dailyState.load() {
		return
	}

	lastfmConfigured := p.cfg.LastfmUser != "" && p.cfg.lastfmBridgeAPIKey() != ""
	lbConfigured := p.cfg.User != "" && p.cfg.Token != ""
	source := resolveDigestSource(features.DailyDigestSource, lastfmConfigured, lbConfigured)
	if source == "" {
		return
	}

	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	var stats digestStats
	var err error
	if source == digestSourceLastfm {
		stats, err = lastfmDigestStats(p.ctx, p.cfg.LastfmUser, p.cfg.lastfmBridgeAPIKey(), midnight.Unix(), now.Unix())
	} else {
		stats, err = listenbrainzDigestStats(p.ctx, p.lb.root, p.cfg.User, midnight.Unix(), now.Unix())
	}
	if err != nil {
		return
	}
	if stats.TotalPlays == 0 {
		p.dailyState.save(today)
		return
	}
	digestPush(p.lb.alerter, fmt.Sprintf("🎧 今日听歌报告（%s）", now.Format("01-02")), stats)
	p.dailyState.save(today)
}
