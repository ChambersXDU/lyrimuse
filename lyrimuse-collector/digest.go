package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
)

const digestTopN = 3

type digestTally struct {
	Name, Sub string
	Count     int
}

type digestStats struct {
	TotalPlays      int
	TotalDurationMs int64

	TopTracks  []digestTally
	TopArtists []digestTally
}

type lbListenEntry struct {
	Title, Artist string
	ListenedAt    int64
	DurationMs    int64
}

func lbListensInRange(ctx context.Context, root, user string, fromUnix, toUnix int64) ([]lbListenEntry, error) {
	var all []lbListenEntry
	cursor := toUnix
	for page := 0; page < 10; page++ {
		entries, oldestInPage, err := lbListensBefore(ctx, root, user, fromUnix, cursor)
		if err != nil {
			return nil, err
		}
		all = append(all, entries...)
		if len(entries) < 100 || oldestInPage <= fromUnix {
			break
		}
		cursor = oldestInPage
	}
	return all, nil
}

func lbListensBefore(ctx context.Context, root, user string, fromUnix, maxTs int64) ([]lbListenEntry, int64, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	url := fmt.Sprintf("%s/1/user/%s/listens?count=100&min_ts=%d&max_ts=%d", root, user, fromUnix, maxTs)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, 0, err
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, 0, fmt.Errorf("listenbrainz status %d", resp.StatusCode)
	}
	var out struct {
		Payload struct {
			Listens []struct {
				ListenedAt    int64 `json:"listened_at"`
				TrackMetadata struct {
					TrackName      string `json:"track_name"`
					ArtistName     string `json:"artist_name"`
					AdditionalInfo struct {
						DurationMs int64 `json:"duration_ms"`
					} `json:"additional_info"`
				} `json:"track_metadata"`
			} `json:"listens"`
		} `json:"payload"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, 0, err
	}
	entries := make([]lbListenEntry, 0, len(out.Payload.Listens))
	oldest := int64(0)
	for _, l := range out.Payload.Listens {
		entries = append(entries, lbListenEntry{
			Title: l.TrackMetadata.TrackName, Artist: l.TrackMetadata.ArtistName,
			ListenedAt: l.ListenedAt, DurationMs: l.TrackMetadata.AdditionalInfo.DurationMs,
		})
		if oldest == 0 || l.ListenedAt < oldest {
			oldest = l.ListenedAt
		}
	}
	return entries, oldest, nil
}

func listenbrainzDigestStats(ctx context.Context, root, user string, from, to int64) (digestStats, error) {
	listens, err := lbListensInRange(ctx, root, user, from, to)
	if err != nil {
		return digestStats{}, err
	}
	var stats digestStats
	stats.TotalPlays = len(listens)
	trackIndex, artistIndex := map[string]int{}, map[string]int{}
	var trackTallies, artistTallies []digestTally
	for _, l := range listens {
		stats.TotalDurationMs += l.DurationMs
		tk := l.Title + "|" + l.Artist
		if idx, ok := trackIndex[tk]; ok {
			trackTallies[idx].Count++
		} else {
			trackIndex[tk] = len(trackTallies)
			trackTallies = append(trackTallies, digestTally{Name: l.Title, Sub: l.Artist, Count: 1})
		}

		ak := artistMergeNameKey(l.Artist)
		if idx, ok := artistIndex[ak]; ok {
			artistTallies[idx].Count++
		} else {
			artistIndex[ak] = len(artistTallies)

			artistTallies = append(artistTallies, digestTally{Name: artistMergeDisplayName(l.Artist), Count: 1})
		}
	}
	sort.SliceStable(trackTallies, func(i, j int) bool { return trackTallies[i].Count > trackTallies[j].Count })
	sort.SliceStable(artistTallies, func(i, j int) bool { return artistTallies[i].Count > artistTallies[j].Count })
	if len(trackTallies) > digestTopN {
		trackTallies = trackTallies[:digestTopN]
	}
	if len(artistTallies) > digestTopN {
		artistTallies = artistTallies[:digestTopN]
	}
	stats.TopTracks, stats.TopArtists = trackTallies, artistTallies
	return stats, nil
}

func digestPush(a *alerter, title string, stats digestStats) {
	var b strings.Builder
	fmt.Fprintf(&b, "共播放 %d 次", stats.TotalPlays)
	if stats.TotalDurationMs > 0 {
		totalMin := stats.TotalDurationMs / 60000
		if totalMin >= 60 {
			fmt.Fprintf(&b, " · 约 %d 小时 %d 分", totalMin/60, totalMin%60)
		} else {
			fmt.Fprintf(&b, " · 约 %d 分", totalMin)
		}
	}
	if len(stats.TopArtists) > 1 {
		b.WriteString("\n\nTop 歌手：\n")
		for i, t := range stats.TopArtists {
			fmt.Fprintf(&b, "%d. %s（%d）\n", i+1, t.Name, t.Count)
		}
	}
	if len(stats.TopTracks) > 1 {
		b.WriteString("\nTop 歌曲：\n")
		for i, t := range stats.TopTracks {
			fmt.Fprintf(&b, "%d. %s - %s（%d）\n", i+1, t.Sub, t.Name, t.Count)
		}
	}
	a.push(title, strings.TrimRight(b.String(), "\n"))
}
