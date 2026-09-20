package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

const weeklyDigestCheckInterval = 2 * time.Hour

type weeklyDigestState struct{ path string }

func (s weeklyDigestState) load() int64 {
	if s.path == "" {
		return 0
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return 0
	}
	var v struct {
		LastTo int64 `json:"last_to"`
	}
	json.Unmarshal(b, &v)
	return v.LastTo
}

func (s weeklyDigestState) save(lastTo int64) {
	if s.path == "" {
		return
	}
	data, err := json.Marshal(struct {
		LastTo int64 `json:"last_to"`
	}{lastTo})
	if err != nil {
		return
	}
	os.WriteFile(s.path, data, 0o644)
}

var weeklyDigestPath string

func mostRecentMonday(t time.Time) time.Time {
	wd := int(t.Weekday())
	if wd == 0 {
		wd = 7
	}
	y, m, d := t.Date()
	startOfToday := time.Date(y, m, d, 0, 0, 0, 0, t.Location())
	return startOfToday.AddDate(0, 0, -(wd - 1))
}

func (p *poller) weeklyDigest(now time.Time) {
	if !features.WeeklyDigest || p.lb.alerter == nil || p.lb.alerter.url == "" {
		return
	}
	if !p.weeklyLastCheckedAt.IsZero() && now.Sub(p.weeklyLastCheckedAt) < weeklyDigestCheckInterval {
		return
	}
	p.weeklyLastCheckedAt = now

	if p.cfg.User == "" || p.cfg.Token == "" {
		return
	}

	thisMonday := mostRecentMonday(now)
	from, to := thisMonday.AddDate(0, 0, -7).Unix(), thisMonday.Unix()
	if to <= p.weeklyState.load() {
		return
	}

	stats, err := listenbrainzDigestStats(p.ctx, p.lb.root, p.cfg.User, from, to)
	if err != nil {
		return
	}
	if stats.TotalPlays == 0 {
		p.weeklyState.save(to)
		return
	}
	title := fmt.Sprintf("🎵 上周听歌小结（%s~%s）",
		time.Unix(from, 0).Local().Format("01-02"), time.Unix(to, 0).Local().Format("01-02"))
	digestPush(p.lb.alerter, title, stats)
	p.weeklyState.save(to)
}
