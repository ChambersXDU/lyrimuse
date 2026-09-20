package main

import "time"

type lyricsDecision struct {

	Path      string `json:"path"`
	DecidedAt int64  `json:"decided_at"`

	ScoringVersion int `json:"scoring_version"`

	QueryArtist  string  `json:"query_artist,omitempty"`
	QueryTitle   string  `json:"query_title,omitempty"`
	QueryAlbum   string  `json:"query_album,omitempty"`
	DurationSecs float64 `json:"duration_secs,omitempty"`

	SourcesResponded []string `json:"sources_responded,omitempty"`

	SourcesSkipped []string `json:"sources_skipped,omitempty"`

	Winner string `json:"winner,omitempty"`

	Applied bool `json:"applied"`

	Candidates []lyricsDecisionCandidate `json:"candidates,omitempty"`

	RetryMethod    string `json:"retry_method,omitempty"`
	CorrectedTitle string `json:"corrected_title,omitempty"`

	QueriesTried []lyricQueryRecord `json:"queries_tried,omitempty"`
}

type lyricsDecisionCandidate struct {
	Source string `json:"source"`
	Score  int    `json:"score"`

	ScoreTerms []scoreTerm `json:"score_terms,omitempty"`

	Title  string `json:"title,omitempty"`
	Artist string `json:"artist,omitempty"`
	Album  string `json:"album,omitempty"`

	CoverURL                   string  `json:"cover_url,omitempty"`
	SourceReportedDurationSecs float64 `json:"source_reported_duration_secs,omitempty"`
	HasWordTiming              bool    `json:"has_word_timing,omitempty"`
	Instrumental               bool    `json:"instrumental,omitempty"`

	BakedTranslationLines int `json:"baked_translation_lines,omitempty"`

	ConsensusPeers []string `json:"consensus_peers,omitempty"`
}

const (
	lyricsDecisionPathFirstResolve  = "first-resolve"
	lyricsDecisionPathUpgrade       = "upgrade"
	lyricsDecisionPathRefill        = "refill"
	lyricsDecisionPathRescore       = "rescore"
	lyricsDecisionPathManualRematch = "manual-rematch"
)

func lyricsDecisionPaths() []string {
	return []string{
		lyricsDecisionPathFirstResolve,
		lyricsDecisionPathUpgrade,
		lyricsDecisionPathRefill,
		lyricsDecisionPathRescore,
		lyricsDecisionPathManualRematch,
	}
}

func buildLyricsDecision(
	path, artist, title, album string, durationSecs float64,
	scored []scoredLyricCandidateResult, picked *scoredLyricCandidateResult, applied bool,
) *lyricsDecision {
	d := &lyricsDecision{
		Path:             path,
		DecidedAt:        time.Now().Unix(),
		ScoringVersion:   lyricsScoringVersion,
		QueryArtist:      artist,
		QueryTitle:       title,
		QueryAlbum:       album,
		DurationSecs:     durationSecs,
		SourcesResponded: lyricSourcesResponded(scored),
		Applied:          applied,
		Candidates:       make([]lyricsDecisionCandidate, 0, len(scored)),
	}
	if picked != nil {
		d.Winner = picked.Source

		d.RetryMethod, d.CorrectedTitle = picked.RetryMethod, picked.RetriedTitle
	}
	for i := range scored {
		c := &scored[i]
		d.Candidates = append(d.Candidates, lyricsDecisionCandidate{
			Source:                     c.Source,
			Score:                      c.Score,
			ScoreTerms:                 c.ScoreTerms,
			Title:                      c.Title,
			Artist:                     c.Artist,
			Album:                      c.Album,
			CoverURL:                   c.CoverURL,
			SourceReportedDurationSecs: c.SourceReportedDurationSecs,
			HasWordTiming:              c.HasWordTiming,
			Instrumental:               c.Instrumental,
			BakedTranslationLines:      c.BakedTranslationLines,
			ConsensusPeers:             c.ConsensusPeers,
		})
	}
	return d
}
