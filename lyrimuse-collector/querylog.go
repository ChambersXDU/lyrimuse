package main

import (
	"context"
	"slices"
	"sync"
)

const (
	lyricQueryReasonPrimary      = ""
	lyricQueryReasonTitleSplit   = "title-split"
	lyricQueryReasonAliasRescue  = "alias-rescue"
	lyricQueryReasonAliasRoma    = "alias-roma"
	lyricQueryReasonAliasMissing = "alias-missing"
	lyricQueryReasonPrimaryVar   = "primary-artist-variant"
	lyricQueryReasonTitleAlbum   = "title-from-album"
	lyricQueryReasonTitleSearch  = "title-from-artist-search"

	lyricQueryReasonTitleStorefront = "title-from-apple-storefront"
)

func lyricQueryReasons() []string {
	return []string{
		lyricQueryReasonTitleSplit,
		lyricQueryReasonAliasRescue,
		lyricQueryReasonAliasRoma,
		lyricQueryReasonAliasMissing,
		lyricQueryReasonPrimaryVar,
		lyricQueryReasonTitleAlbum,
		lyricQueryReasonTitleSearch,
		lyricQueryReasonTitleStorefront,
	}
}

const lyricQueryLogMax = 24

type lyricQueryRecord struct {
	Artist string `json:"artist"`
	Title  string `json:"title,omitempty"`

	Reason string `json:"reason,omitempty"`

	Sources []string `json:"sources,omitempty"`
}

type lyricQueryLog struct {
	mu      sync.Mutex
	records []lyricQueryRecord
}

type lyricQueryLogKey struct{}
type lyricQueryReasonKey struct{}

func withLyricQueryLog(ctx context.Context) (context.Context, *lyricQueryLog) {
	l := &lyricQueryLog{}
	return context.WithValue(ctx, lyricQueryLogKey{}, l), l
}

func lyricQueryLogFrom(ctx context.Context) *lyricQueryLog {
	if ctx == nil {
		return nil
	}
	l, _ := ctx.Value(lyricQueryLogKey{}).(*lyricQueryLog)
	return l
}

func withLyricQueryReason(ctx context.Context, reason string) context.Context {
	return context.WithValue(ctx, lyricQueryReasonKey{}, reason)
}

func lyricQueryReasonFrom(ctx context.Context) string {
	if ctx == nil {
		return lyricQueryReasonPrimary
	}
	r, _ := ctx.Value(lyricQueryReasonKey{}).(string)
	return r
}

func (l *lyricQueryLog) record(artist, title, reason string, sources []string) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.records) >= lyricQueryLogMax {
		return
	}
	rec := lyricQueryRecord{Artist: artist, Title: title, Reason: reason}
	if len(sources) > 0 {
		rec.Sources = append([]string(nil), sources...)
	}

	if n := len(l.records); n > 0 && sameLyricQueryRecord(l.records[n-1], rec) {
		return
	}
	l.records = append(l.records, rec)
}

func sameLyricQueryRecord(a, b lyricQueryRecord) bool {
	if a.Artist != b.Artist || a.Title != b.Title || a.Reason != b.Reason || len(a.Sources) != len(b.Sources) {
		return false
	}
	for i := range a.Sources {
		if a.Sources[i] != b.Sources[i] {
			return false
		}
	}
	return true
}

func (l *lyricQueryLog) queries() []lyricQueryRecord {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.records) == 0 {
		return nil
	}
	return append([]lyricQueryRecord(nil), l.records...)
}

func sortedLyricSourceOnly(ctx context.Context) []string {
	only := lyricSourceOnlyFrom(ctx)
	if len(only) == 0 {
		return nil
	}
	out := make([]string, 0, len(only))
	for _, s := range lyricSourceNames {
		if only[s] {
			out = append(out, s)
		}
	}

	for s := range only {
		if !slices.Contains(lyricSourceNames, s) {
			out = append(out, s)
		}
	}
	return out
}
