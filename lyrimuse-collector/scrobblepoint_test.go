package main

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func withScrobblePoint(t *testing.T, point string) {
	t.Helper()
	saved := features.LastfmScrobblePoint
	features.LastfmScrobblePoint = point
	t.Cleanup(func() { features.LastfmScrobblePoint = saved })
}

func withTempListenLog(t *testing.T) {
	t.Helper()
	saved := listenLogPath
	listenLogPath = filepath.Join(t.TempDir(), "listens.jsonl")
	t.Cleanup(func() { listenLogPath = saved })
}

func TestScrobblePointFlagRoundTrip(t *testing.T) {
	const key = "lastfm_scrobble_point"
	cases := []struct {
		name string
		body string
		want string
	}{
		{"缺省 → 官方规则", `{}`, scrobblePointHalf},
		{"显式 50", `{"` + key + `":"50"}`, scrobblePointHalf},
		{"75", `{"` + key + `":"75"}`, scrobblePoint75},
		{"90", `{"` + key + `":"90"}`, scrobblePoint90},
		{"end", `{"` + key + `":"end"}`, scrobblePointEnd},
		{"非法值 → 官方规则", `{"` + key + `":"80"}`, scrobblePointHalf},
		{"没有低于一半的档", `{"` + key + `":"25"}`, scrobblePointHalf},
		{"类型错(数字)→ 整份解析失败,仍兜底", `{"` + key + `":75}`, scrobblePointHalf},
	}
	for _, c := range cases {
		if got := loadFeatureFlagsFromJSON(t, c.body).LastfmScrobblePoint; got != c.want {
			t.Errorf("%s: %s → %q, want %q", c.name, c.body, got, c.want)
		}
	}
	if got := scrobblePointHalf + scrobblePoint75 + scrobblePoint90 + scrobblePointEnd; got != "507590end" {
		t.Errorf("档位字符串跟 Swift 侧 LastfmScrobblePoint.rawValue 是契约,变了两边一起改: %q", got)
	}
}

func TestLastfmScrobblePointReached(t *testing.T) {
	cases := []struct {
		name             string
		point            string
		duration, played float64
		endedNaturally   bool
		want             bool
	}{
		{"默认档:官方阈值已过就发", scrobblePointHalf, 200, 100, false, true},
		{"默认档:不看 playedSecs(调用前提是阈值已过)", scrobblePointHalf, 200, 0, false, true},
		{"75%:149/200 没到", scrobblePoint75, 200, 149, false, false},
		{"75%:150/200 到了", scrobblePoint75, 200, 150, false, true},
		{"90%:179/200 没到", scrobblePoint90, 200, 179, false, false},
		{"90%:180/200 到了", scrobblePoint90, 200, 180, false, true},
		{"90%:10 分钟的歌,官方 240 s 早过、90% 还没到——不套 4 分钟上限", scrobblePoint90, 600, 300, false, false},
		{"曲终:播放中永远不到", scrobblePointEnd, 200, 199, false, false},
		{"曲终:放完了", scrobblePointEnd, 200, 100, true, true},
		{"75%:曲长未知 → 官方规则", scrobblePoint75, 0, 10, false, true},
		{"曲终:曲长未知 → 官方规则", scrobblePointEnd, 0, 10, false, true},
	}
	for _, c := range cases {
		withScrobblePoint(t, c.point)
		s := &playSession{meta: snapshot{Duration: c.duration}, playedSecs: c.played, endedNaturally: c.endedNaturally}
		if got := lastfmScrobblePointReached(s); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestSessionEndedNaturally(t *testing.T) {
	now := time.Date(2026, 9, 6, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name              string
		duration, lastPos float64
		ago               time.Duration
		playing           bool
		want              bool
	}{
		{"自然切歌:最后一拍离曲尾 3 s,5 s 后看到新曲", 200, 197, 5 * time.Second, true, true},
		{"crossfade:离曲尾 10 s 就接歌(188+2=190 ≥ 188)", 200, 188, 2 * time.Second, true, true},
		{"中途切歌", 200, 100, 2 * time.Second, true, false},
		{"离曲尾 22 s 切掉(176+2=178 < 188):不算", 200, 176, 2 * time.Second, true, false},
		{"播放器退出:最后一拍离曲尾 25 s,15 s 后才终结——外推封顶 10 s(175+10=185 < 188)", 200, 175, 15 * time.Second, true, false},
		{"歌单末尾停播:最后一拍离曲尾 3 s,15 s 后终结(197+10 ≥ 188)", 200, 197, 15 * time.Second, true, true},
		{"暂停在曲尾前 5 s 很久后切歌:取原值不外推(195 ≥ 188)", 200, 195, time.Hour, false, true},
		{"暂停在中间很久:不外推", 200, 100, time.Hour, false, false},
		{"短曲 40 s:容差收窄到 4 s,33+2=35 < 36 不算", 40, 33, 2 * time.Second, true, false},
		{"短曲 40 s:35+2=37 ≥ 36 算", 40, 35, 2 * time.Second, true, true},
		{"曲长未知:判不了", 0, 100, time.Second, true, false},
	}
	for _, c := range cases {
		s := &playSession{meta: snapshot{Duration: c.duration}, lastPos: c.lastPos, lastPosAt: now.Add(-c.ago), lastPlaying: c.playing}
		if got := sessionEndedNaturally(s, now); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
	never := &playSession{meta: snapshot{Duration: 200}, lastPlaying: true}
	if sessionEndedNaturally(never, now) {
		t.Error("从未记过位置的会话不该判成放完")
	}
	if got := trackEndSlack(240); got != 12 {
		t.Errorf("trackEndSlack(240) = %v, want 12", got)
	}
	if got := trackEndSlack(60); got != 6 {
		t.Errorf("trackEndSlack(60) = %v, want 6", got)
	}
}

func TestRecordLastfmListenDefersUntilPoint(t *testing.T) {
	withScrobblePoint(t, scrobblePoint90)
	withTempListenLog(t)
	p := &poller{ctx: context.Background(), cfg: &config{}}

	s := &playSession{meta: snapshot{Title: "长歌", Artist: "A", Duration: 200}, startedAt: time.Now().Add(-2 * time.Minute), playedSecs: 100, submitting: true}
	outcome := submitOutcome{sess: s, meta: s.meta, artistName: "A", startedAt: s.startedAt.Unix()}

	p.applySubmitOutcome(submitOutcome{sess: s, meta: s.meta, artistName: "A", startedAt: s.startedAt.Unix(), err: context.DeadlineExceeded})
	if s.listenSent || s.lastfmPending == nil || s.lastfmSettled {
		t.Fatalf("LB 失败:listenSent=%v pending=%v settled=%v", s.listenSent, s.lastfmPending != nil, s.lastfmSettled)
	}

	first := s.lastfmPending
	p.applySubmitOutcome(outcome)
	if !s.listenSent || s.lastfmPending != first || s.lastfmSettled {
		t.Fatalf("LB 成功:listenSent=%v samePending=%v settled=%v", s.listenSent, s.lastfmPending == first, s.lastfmSettled)
	}
	if n := len(readListenLog()); n != 0 {
		t.Fatalf("没到点不该记本地日志,却有 %d 行", n)
	}
	s.playedSecs = 178
	if p.settleLastfmPending(s) {
		t.Fatal("89% 不该发")
	}
	s.playedSecs = 180
	if !p.settleLastfmPending(s) {
		t.Fatal("90% 应发")
	}
	if got := readListenLog(); len(got) != 1 || got[0].TI != "长歌" || got[0].UTS != s.startedAt.Unix() {
		t.Fatalf("到点应记一行本地日志,got %+v", got)
	}
	if s.lastfmPending != nil || !s.lastfmSettled {
		t.Fatal("发过之后应清空挂起、置 settled")
	}

	p.applySubmitOutcome(outcome)
	if p.settleLastfmPending(s) || len(readListenLog()) != 1 {
		t.Fatal("已发过的不该重复记")
	}

	withScrobblePoint(t, scrobblePointHalf)
	s2 := &playSession{meta: snapshot{Title: "老规矩", Artist: "A", Duration: 200}, startedAt: time.Now().Add(-2 * time.Minute), playedSecs: 100, submitting: true}
	p.applySubmitOutcome(submitOutcome{sess: s2, meta: s2.meta, artistName: "A", startedAt: s2.startedAt.Unix()})
	if s2.lastfmPending != nil || !s2.lastfmSettled || !s2.listenSent {
		t.Fatalf("默认档应当场发:pending=%v settled=%v listenSent=%v", s2.lastfmPending != nil, s2.lastfmSettled, s2.listenSent)
	}
	if got := readListenLog(); len(got) != 2 || got[1].TI != "老规矩" {
		t.Fatalf("默认档应立即多一行,got %+v", got)
	}
}

func TestScrobblePointEndCommitsOnlyWhenTrackFinished(t *testing.T) {
	withScrobblePoint(t, scrobblePointEnd)
	withTempListenLog(t)
	now := time.Now()
	p := &poller{ctx: context.Background(), cfg: &config{}}
	mk := func(title string, lastPos float64, ago time.Duration) *playSession {
		return &playSession{
			key: "k", meta: snapshot{Title: title, Artist: "A", Duration: 200}, startedAt: now.Add(-3 * time.Minute),
			playedSecs: 150, lastPlaying: true, lastPos: lastPos, lastPosAt: now.Add(-ago), submitting: true,
		}
	}
	submit := func(s *playSession) {
		p.applySubmitOutcome(submitOutcome{sess: s, meta: s.meta, artistName: "A", startedAt: s.startedAt.Unix()})
	}

	cut := mk("切掉", 150, 2*time.Second)
	submit(cut)
	if cut.lastfmPending == nil || !cut.listenSent {
		t.Fatalf("曲终档播放中应挂起、LB 照常收尾:pending=%v listenSent=%v", cut.lastfmPending != nil, cut.listenSent)
	}
	p.sess = cut
	p.finalize(now)
	if !cut.ended || cut.endedNaturally || cut.lastfmPending == nil || cut.lastfmSettled || len(readListenLog()) != 0 {
		t.Fatalf("中途切歌:ended=%v natural=%v pending=%v settled=%v log=%d", cut.ended, cut.endedNaturally, cut.lastfmPending != nil, cut.lastfmSettled, len(readListenLog()))
	}

	done := mk("放完", 197, 5*time.Second)
	submit(done)
	p.sess = done
	p.finalize(now)
	if !done.endedNaturally || done.lastfmPending != nil || !done.lastfmSettled {
		t.Fatalf("放到结尾:natural=%v pending=%v settled=%v", done.endedNaturally, done.lastfmPending != nil, done.lastfmSettled)
	}
	if got := readListenLog(); len(got) != 1 || got[0].TI != "放完" {
		t.Fatalf("放到结尾应记一行,got %+v", got)
	}

	late := mk("迟到", 198, 3*time.Second)
	p.sess = late
	p.finalize(now)
	if late.lastfmPending != nil {
		t.Fatal("结果没回来之前不该有挂起")
	}
	submit(late)
	if late.lastfmPending != nil || !late.lastfmSettled {
		t.Fatalf("迟到的结果应按会话结束时的判据当场发:pending=%v settled=%v", late.lastfmPending != nil, late.lastfmSettled)
	}
	if got := readListenLog(); len(got) != 2 || got[1].TI != "迟到" {
		t.Fatalf("应共两行,got %+v", got)
	}

	lateCut := mk("迟到且切掉", 120, 3*time.Second)
	p.sess = lateCut
	p.finalize(now)
	submit(lateCut)
	if lateCut.lastfmPending == nil || lateCut.lastfmSettled || len(readListenLog()) != 2 {
		t.Fatalf("迟到且切掉:pending=%v settled=%v log=%d", lateCut.lastfmPending != nil, lateCut.lastfmSettled, len(readListenLog()))
	}
}

func TestSettleLastfmPendingSyncAtExit(t *testing.T) {
	withScrobblePoint(t, scrobblePoint75)
	withTempListenLog(t)
	p := &poller{ctx: context.Background(), cfg: &config{}}
	meta := snapshot{Title: "退出前", Artist: "A", Duration: 200}
	s := &playSession{meta: meta, playedSecs: 100, lastfmPending: &pendingLastfmListen{artistName: "A", meta: meta, startedAt: 1_700_000_000}}

	p.settleLastfmPendingSync(context.Background(), s)
	if s.lastfmSettled || len(readListenLog()) != 0 {
		t.Fatal("50% 没到 75%,退出时不该发")
	}
	s.playedSecs = 160
	p.settleLastfmPendingSync(context.Background(), s)
	if !s.lastfmSettled || s.lastfmPending != nil {
		t.Fatal("到点应发并置 settled")
	}
	p.settleLastfmPendingSync(context.Background(), s)
	if got := readListenLog(); len(got) != 1 || got[0].UTS != 1_700_000_000 {
		t.Fatalf("应恰好一行,got %+v", got)
	}
}
