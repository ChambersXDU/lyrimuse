package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestConsensusPeersReachDecisionJSON(t *testing.T) {

	same := "[00:01.00]we were both young when i first saw you\n" +
		"[00:06.00]i close my eyes and the flashback starts\n" +
		"[00:11.00]im standing there on a balcony in summer air\n" +
		"[00:16.00]see the lights see the party the ball gowns\n"
	diff := "[00:01.00]completely different words entirely here\n" +
		"[00:06.00]nothing at all shared with the other two\n" +
		"[00:11.00]another unrelated closing line for this one\n" +
		"[00:16.00]and one more line that matches nobody else\n"

	raw := map[string]lyricSourceResult{
		"qq":     {source: "qq", lyr: same},
		"lrclib": {source: "lrclib", lyr: same},
		"kugou":  {source: "kugou", lyr: diff},
	}
	scored := rankLyricSourceResults("someone", "song", "", 0, raw)

	bySource := map[string]scoredLyricCandidateResult{}
	for _, c := range scored {
		bySource[c.Source] = c
	}

	for _, tc := range []struct{ src, peer string }{{"qq", "lrclib"}, {"lrclib", "qq"}} {
		got := bySource[tc.src].ConsensusPeers
		if len(got) != 1 || got[0] != tc.peer {
			t.Errorf("%s 的 ConsensusPeers = %v, want [%s] —— 名单没从 contentConsensusPeers 传到候选上",
				tc.src, got, tc.peer)
		}
	}
	if got := bySource["kugou"].ConsensusPeers; len(got) != 0 {
		t.Errorf("kugou 正文跟谁都不一样,ConsensusPeers 应为空,实际 %v", got)
	}

	qqTerms := map[string]int{}
	for _, tm := range bySource["qq"].ScoreTerms {
		qqTerms[tm.Kind] = tm.Points
	}
	if qqTerms[scoreTermConsensus] != 150 {
		t.Errorf("qq 的 consensus 分 = %d, want 150(1 家印证)—— 换成名单不该改变判据",
			qqTerms[scoreTermConsensus])
	}

	win := bySource["qq"]
	d := buildLyricsDecision(lyricsDecisionPathFirstResolve, "someone", "song", "", 0, scored, &win, true)
	blob, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(blob), `"consensus_peers":["lrclib"]`) {
		t.Errorf("序列化后的存档里找不到 consensus_peers:\n%s", blob)
	}
}

func TestQueriesTriedReachDecisionJSON(t *testing.T) {
	ctx, log := withLyricQueryLog(context.Background())

	log.record("音樂頑童", "Musiq Soulchild - Buddy", lyricQueryReasonFrom(ctx), sortedLyricSourceOnly(ctx))

	splitCtx := withLyricQueryReason(ctx, lyricQueryReasonTitleSplit)
	log.record("Musiq Soulchild", "Buddy", lyricQueryReasonFrom(splitCtx), sortedLyricSourceOnly(splitCtx))

	aliasCtx := withLyricQueryReason(withLyricSourceOnly(ctx, []string{"musixmatch", "qq", "kugou"}),
		lyricQueryReasonAliasMissing)
	log.record("JW", "NOT YOUR FAULT", lyricQueryReasonFrom(aliasCtx), sortedLyricSourceOnly(aliasCtx))

	got := log.queries()
	if len(got) != 3 {
		t.Fatalf("记了 %d 组查询词, want 3: %+v", len(got), got)
	}
	if got[0].Reason != "" || got[0].Artist != "音樂頑童" || len(got[0].Sources) != 0 {
		t.Errorf("首轮那一组不对: %+v", got[0])
	}
	if got[1].Reason != lyricQueryReasonTitleSplit || got[1].Artist != "Musiq Soulchild" {
		t.Errorf("拆分那一组不对: %+v", got[1])
	}

	if want := []string{"qq", "kugou", "musixmatch"}; strings.Join(got[2].Sources, ",") != strings.Join(want, ",") {
		t.Errorf("别名轮的源名单 = %v, want %v —— 必须按 lyricSourceNames 定序,否则同一轮解析每次序列化出不同 JSON",
			got[2].Sources, want)
	}

	d := buildLyricsDecision(lyricsDecisionPathFirstResolve, "音樂頑童", "Musiq Soulchild - Buddy", "", 0, nil, nil, false)
	d.QueriesTried = got
	blob, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	s := string(blob)
	for _, needle := range []string{
		`"queries_tried":[`,
		`{"artist":"音樂頑童","title":"Musiq Soulchild - Buddy"}`,
		`"reason":"title-split"`,
		`"reason":"alias-missing","sources":["qq","kugou","musixmatch"]`,
	} {
		if !strings.Contains(s, needle) {
			t.Errorf("序列化后的存档里找不到 %s:\n%s", needle, s)
		}
	}
}

func TestQueryLogDedupesAdjacentDuplicates(t *testing.T) {
	_, log := withLyricQueryLog(context.Background())
	log.record("A", "T", lyricQueryReasonPrimaryVar, nil)
	log.record("A", "T", lyricQueryReasonPrimaryVar, nil)
	log.record("B", "T", lyricQueryReasonPrimaryVar, nil)
	log.record("A", "T", lyricQueryReasonPrimaryVar, nil)
	if got := log.queries(); len(got) != 3 {
		t.Errorf("相邻去重后应剩 3 组,实际 %d: %+v", len(got), got)
	}

	_, capped := withLyricQueryLog(context.Background())
	for i := 0; i < lyricQueryLogMax+10; i++ {
		capped.record("A", string(rune('a'+i%26))+string(rune('0'+i/26)), lyricQueryReasonAliasRescue, nil)
	}
	if got := capped.queries(); len(got) != lyricQueryLogMax {
		t.Errorf("上限没生效: %d 组, want %d", len(got), lyricQueryLogMax)
	}

	var nilLog *lyricQueryLog
	nilLog.record("A", "T", "", nil)
	if got := nilLog.queries(); got != nil {
		t.Errorf("nil 收集器应返回 nil,实际 %v", got)
	}
	if got := lyricQueryLogFrom(context.Background()); got != nil {
		t.Errorf("ctx 上没挂时应返回 nil,实际 %v", got)
	}
}
