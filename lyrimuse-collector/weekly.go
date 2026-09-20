package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	neturl "net/url"
	"os"
	"strconv"
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

type lastfmChartWeek struct{ From, To int64 }

type lastfmChartEntry struct {
	Name, Artist string
	PlayCount    int
	Mbid         string
}

func lastfmAPIGet(ctx context.Context, params neturl.Values, out any) error {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	params.Set("format", "json")
	u := "https://ws.audioscrobbler.com/2.0/?" + params.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("lastfm status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func lastfmWeeklyChartList(ctx context.Context, user, apiKey string) ([]lastfmChartWeek, error) {
	var out struct {
		WeeklyChartList struct {
			Chart []struct{ From, To string } `json:"chart"`
		} `json:"weeklychartlist"`
	}
	params := neturl.Values{"method": {"user.getWeeklyChartList"}, "user": {user}, "api_key": {apiKey}}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	weeks := make([]lastfmChartWeek, 0, len(out.WeeklyChartList.Chart))
	for _, c := range out.WeeklyChartList.Chart {
		from, _ := strconv.ParseInt(c.From, 10, 64)
		to, _ := strconv.ParseInt(c.To, 10, 64)
		weeks = append(weeks, lastfmChartWeek{From: from, To: to})
	}
	return weeks, nil
}

func lastfmWeeklyTopTracks(ctx context.Context, user, apiKey string, from, to int64) ([]lastfmChartEntry, error) {
	var out struct {
		WeeklyTrackChart struct {
			Track []struct {
				Name      string `json:"name"`
				PlayCount string `json:"playcount"`
				Artist    struct {
					Text string `json:"#text"`
				} `json:"artist"`
			} `json:"track"`
		} `json:"weeklytrackchart"`
	}
	params := neturl.Values{
		"method": {"user.getWeeklyTrackChart"}, "user": {user}, "api_key": {apiKey},
		"from": {strconv.FormatInt(from, 10)}, "to": {strconv.FormatInt(to, 10)},
	}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	entries := make([]lastfmChartEntry, 0, len(out.WeeklyTrackChart.Track))
	for _, t := range out.WeeklyTrackChart.Track {
		pc, _ := strconv.Atoi(t.PlayCount)
		entries = append(entries, lastfmChartEntry{Name: t.Name, Artist: t.Artist.Text, PlayCount: pc})
	}
	return entries, nil
}

func lastfmWeeklyTopArtists(ctx context.Context, user, apiKey string, from, to int64) ([]lastfmChartEntry, error) {
	var out struct {
		WeeklyArtistChart struct {
			Artist []struct {
				Name      string `json:"name"`
				PlayCount string `json:"playcount"`
			} `json:"artist"`
		} `json:"weeklyartistchart"`
	}
	params := neturl.Values{
		"method": {"user.getWeeklyArtistChart"}, "user": {user}, "api_key": {apiKey},
		"from": {strconv.FormatInt(from, 10)}, "to": {strconv.FormatInt(to, 10)},
	}
	if err := lastfmAPIGet(ctx, params, &out); err != nil {
		return nil, err
	}
	entries := make([]lastfmChartEntry, 0, len(out.WeeklyArtistChart.Artist))
	for _, a := range out.WeeklyArtistChart.Artist {
		pc, _ := strconv.Atoi(a.PlayCount)
		entries = append(entries, lastfmChartEntry{Name: a.Name, PlayCount: pc})
	}
	return entries, nil
}

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

	lastfmConfigured := p.cfg.LastfmUser != "" && p.cfg.lastfmBridgeAPIKey() != ""
	lbConfigured := p.cfg.User != "" && p.cfg.Token != ""
	source := resolveDigestSource(features.WeeklyDigestSource, lastfmConfigured, lbConfigured)
	if source == "" {
		return
	}

	var from, to int64
	if source == digestSourceLastfm {
		weeks, err := lastfmWeeklyChartList(p.ctx, p.cfg.LastfmUser, p.cfg.lastfmBridgeAPIKey())
		if err != nil || len(weeks) == 0 {
			return
		}
		latest := weeks[len(weeks)-1]
		if latest.To > now.Unix() {
			return
		}
		from, to = latest.From, latest.To
	} else {
		thisMonday := mostRecentMonday(now)
		from, to = thisMonday.AddDate(0, 0, -7).Unix(), thisMonday.Unix()
	}
	if to <= p.weeklyState.load() {
		return
	}

	var stats digestStats
	var err error
	if source == digestSourceLastfm {
		stats, err = lastfmDigestStats(p.ctx, p.cfg.LastfmUser, p.cfg.lastfmBridgeAPIKey(), from, to)
	} else {
		stats, err = listenbrainzDigestStats(p.ctx, p.lb.root, p.cfg.User, from, to)
	}
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
